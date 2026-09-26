import 'dart:convert';
import 'dart:math';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'snapshot_builder.dart';

/// A frozen request. Retry must reuse both id and payload (never rebuild it).
class SyncJob {
  final String requestId, userId, entityType, entityId;
  final int generation, attempts;
  final Map<String, Object?> payload;
  SyncJob(
    this.requestId,
    this.userId,
    this.entityType,
    this.entityId,
    this.generation,
    this.attempts,
    this.payload,
  );
}

typedef SnapshotBuilder =
    Future<Map<String, Object?>> Function(
      DatabaseExecutor tx,
      String kind,
      String id,
    );

/// Offline outbox primitives. Intentionally has no network/auth dependency.
/// The authenticated integration must use a separate database per account.
class LocalSyncStore {
  final Database db;
  final DateTime Function() clock;
  final Random random;
  LocalSyncStore(this.db, {DateTime Function()? clock, Random? random})
    : clock = clock ?? DateTime.now,
      random = random ?? Random();

  Future<void> _requireOwner(DatabaseExecutor tx, String userId) async {
    final scope = (await tx.query('sync_scope')).single;
    if (userId.isEmpty || scope['user_id'] != userId) {
      throw StateError('Account does not own this database');
    }
  }

  /// Call only after explicit guest-import consent, never on every auth change.
  /// A database already assigned to A can never be reassigned to B.
  Future<void> bindGuestDatabase(String userId) async {
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(userId)) {
      throw ArgumentError('Supabase user UUID required');
    }
    await db.transaction((tx) async {
      final scope = (await tx.query('sync_scope')).single;
      if (scope['user_id'] != null && scope['user_id'] != userId) {
        throw StateError('Account does not own this database');
      }
      await tx.update('sync_scope', {
        'user_id': userId,
      }, where: 'singleton = 1');
      await tx.update('event_sync', {
        'user_id': userId,
      }, where: 'user_id IS NULL');
      await tx.insert('sync_state', {
        'user_id': userId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  /// Capture data and generation atomically. One worker per account/database.
  Future<SyncJob?> next(
    String userId,
    SnapshotBuilder snapshot,
  ) => db.transaction((tx) async {
    await _requireOwner(tx, userId);
    final rows = await tx.query(
      'sync_queue',
      where: "state = 'pending' AND next_attempt_at <= ?",
      whereArgs: [clock().millisecondsSinceEpoch],
      orderBy:
          "CASE entity_type WHEN 'project' THEN 0 WHEN 'event' THEN 1 WHEN 'session' THEN 2 WHEN 'order' THEN 3 ELSE 4 END, entity_id",
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final kind = row['entity_type'] as String;
    final id = row['entity_id'] as String;
    final requestId = row['request_id'] as String? ?? const Uuid().v4();
    final payload = row['payload'] == null
        ? await snapshot(tx, kind, id)
        : Map<String, Object?>.from(
            jsonDecode(row['payload'] as String) as Map,
          );
    await tx.update(
      'sync_queue',
      {'request_id': requestId, 'payload': jsonEncode(payload)},
      where: 'entity_type = ? AND entity_id = ?',
      whereArgs: [kind, id],
    );
    await tx.update(
      'sync_state',
      {'last_attempt_at': clock().toUtc().toIso8601String()},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
    return SyncJob(
      requestId,
      userId,
      kind,
      id,
      row['generation'] as int,
      row['attempts'] as int,
      Map.unmodifiable(payload),
    );
  });

  /// A stale HTTP success cannot clear a newer local edit or its pending flag.
  Future<void> acknowledge(
    SyncJob job,
    int serverRevision, {
    Map<String, Object?>? result,
  }) => db.transaction((tx) async {
    await _requireOwner(tx, job.userId);
    await tx.rawInsert(
      '''INSERT INTO sync_remote_versions(entity_type, entity_id, server_revision)
      VALUES (?, ?, ?) ON CONFLICT(entity_type, entity_id) DO UPDATE SET
      server_revision = MAX(server_revision, excluded.server_revision)''',
      [job.entityType, job.entityId, serverRevision],
    );
    final removed = await tx.delete(
      'sync_queue',
      where:
          'entity_type = ? AND entity_id = ? AND generation = ? AND request_id = ?',
      whereArgs: [job.entityType, job.entityId, job.generation, job.requestId],
    );
    if (removed == 1 &&
        result != null &&
        ['image', 'download'].contains(job.entityType)) {
      final p = (await tx.query(
        'projects',
        where: 'id=?',
        whereArgs: [job.entityId],
      )).single;
      if (job.entityType == 'image' && p['imagePath'] == result['path']) {
        await tx.insert('cloud_projects', {
          'project_id': job.entityId,
          'image_key': result['image_key'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await enqueue(tx, 'project', job.entityId);
      } else if (job.entityType == 'download') {
        final edited = await tx.query(
          'sync_queue',
          where: "entity_type='image' AND entity_id=?",
          whereArgs: [job.entityId],
        );
        final key = (await tx.query(
          'cloud_projects',
          where: 'project_id=?',
          whereArgs: [job.entityId],
        )).single['image_key'];
        if (key == result['image_key'] && edited.isEmpty) {
          await tx.update('sync_scope', {'applying_remote': 1});
          await tx.update(
            'projects',
            {'imagePath': result['path']},
            where: 'id=?',
            whereArgs: [job.entityId],
          );
          await tx.update('sync_scope', {'applying_remote': 0});
        }
      }
    }
    if (removed == 1 && job.entityType == 'event') {
      await tx.update(
        'event_sync',
        {'sync_status': 'synced', 'server_revision': serverRevision},
        where: 'event_id = ?',
        whereArgs: [job.entityId],
      );
    }
    if (removed == 1) {
      await tx.update(
        'sync_conflicts',
        {'resolved_at': clock().toUtc().toIso8601String()},
        where: 'entity_type=? AND entity_id=? AND resolved_at IS NULL',
        whereArgs: [job.entityType, job.entityId],
      );
    }
  });

  /// Transport errors have no effect on count tables. Exponential backoff + jitter.
  Future<void> retry(
    SyncJob job,
    String errorCode, {
    Duration? retryAfter,
  }) async {
    final seconds = min(3600, 2 * pow(2, min(job.attempts, 11)).toInt());
    final delay =
        retryAfter ??
        Duration(seconds: seconds, milliseconds: random.nextInt(1000));
    await _requireOwner(db, job.userId);
    await db.update(
      'sync_queue',
      {
        'attempts': job.attempts + 1,
        'next_attempt_at': clock().add(delay).millisecondsSinceEpoch,
        'last_error': errorCode,
      },
      where:
          'entity_type = ? AND entity_id = ? AND generation = ? AND request_id = ?',
      whereArgs: [job.entityType, job.entityId, job.generation, job.requestId],
    );
  }

  Future<void> conflict(
    SyncJob job,
    String reason,
    Map<String, Object?>? remote,
  ) => db.transaction((tx) async {
    await _requireOwner(tx, job.userId);
    await tx.insert('sync_conflicts', {
      'id': job.requestId,
      'user_id': job.userId,
      'entity_type': job.entityType,
      'entity_id': job.entityId,
      'local_payload': jsonEncode(job.payload),
      'remote_payload': remote == null ? null : jsonEncode(remote),
      'reason': reason,
      'created_at': clock().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await tx.update(
      'sync_queue',
      {'state': 'conflict', 'last_error': reason},
      where:
          'entity_type = ? AND entity_id = ? AND generation = ? AND request_id = ?',
      whereArgs: [job.entityType, job.entityId, job.generation, job.requestId],
    );
  });

  /// Consumer applies a whole page in this transaction before the cursor moves.
  /// Throwing (including an unsupported payload) rolls back data AND cursor.
  Future<void> applyPage(
    String userId,
    int expectedCursor,
    int nextCursor,
    Future<void> Function(Transaction tx) apply,
  ) => db.transaction((tx) async {
    await _requireOwner(tx, userId);
    final state = (await tx.query(
      'sync_state',
      where: 'user_id = ?',
      whereArgs: [userId],
    )).single;
    if (state['pull_cursor'] != expectedCursor || nextCursor < expectedCursor) {
      throw StateError('Invalid or stale sync cursor');
    }
    await tx.update('sync_scope', {
      'applying_remote': 1,
    }, where: 'singleton = 1');
    await apply(tx);
    await tx.update('sync_scope', {
      'applying_remote': 0,
    }, where: 'singleton = 1');
    await tx.update(
      'sync_state',
      {'pull_cursor': nextCursor},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  });

  /// Only after a complete successful push AND pull cycle, not an individual ACK.
  Future<void> completeCycle(String userId) => db.transaction((tx) async {
    await _requireOwner(tx, userId);
    if ((await tx.query('sync_queue', limit: 1)).isNotEmpty) return;
    await tx.update(
      'sync_state',
      {'last_sync_at': clock().toUtc().toIso8601String(), 'last_error': null},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  });

  Future<Map<String, Object?>> eventPayload(
    DatabaseExecutor tx,
    String eventId,
  ) async {
    final row = (await tx.rawQuery(
      '''SELECT c.*, e.user_id, e.device_id, e.payload FROM count_changes c
      JOIN event_sync e ON e.event_id = c.id WHERE c.id = ?''',
      [eventId],
    )).single;
    final owner = row['user_id'];
    if (owner is! String) throw StateError('Guest data is not uploadable');
    await _requireOwner(tx, owner);
    if (row['payload'] != null) return jsonMap(row['payload']);
    final payload = {
      'id': row['id'],
      'user_id': owner,
      'project_id': row['projectId'],
      'delta': row['delta'],
      'count_after': row['afterValue'],
      'created_at': row['createdAt'],
      'updated_at': row['updatedAt'],
      'device_id': row['device_id'],
      'sync_status': 'synced',
      'occurred_at': row['occurredAt'],
      'source': row['source'],
      'session_id': row['sessionId'],
      'note': row['note'],
    };
    await tx.update(
      'event_sync',
      {'payload': jsonEncode(payload)},
      where: 'event_id=?',
      whereArgs: [eventId],
    );
    return payload;
  }
}
