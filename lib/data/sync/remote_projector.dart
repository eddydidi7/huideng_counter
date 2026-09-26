import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../../domain/models.dart';
import 'ledger_merge.dart';
import 'snapshot_builder.dart';

class RemoteProjector {
  final String userId;
  RemoteProjector(this.userId);
  Future<void> apply(Transaction tx, List<Map<String, Object?>> rows) async {
    final changed = <String>{};
    for (final row in rows) {
      if (row['user_id'] != userId) throw StateError('Wrong owner');
      final kind = row['kind'] as String, id = row['entity_id'] as String;
      final payload = jsonMap(row['payload']);
      final rev = row['revision'] as int;
      if (payload['user_id'] != userId ||
          payload['id'] != id ||
          payload['revision'] != rev) {
        throw StateError('Invalid envelope');
      }
      if (kind == 'event') {
        await _event(tx, payload, rev);
        changed.add(payload['project_id'] as String);
      } else {
        await document(tx, kind, id, jsonMap(payload['data']), rev);
      }
      final pending = await tx.query(
        'sync_queue',
        where: 'entity_type=? AND entity_id=?',
        whereArgs: [kind, id],
      );
      if (kind != 'event' && pending.isNotEmpty) continue;
      await tx.rawInsert(
        '''INSERT INTO sync_remote_versions VALUES(?,?,?) ON CONFLICT(entity_type,entity_id)
        DO UPDATE SET server_revision=MAX(server_revision,excluded.server_revision)''',
        [kind, id, rev],
      );
    }
    for (final id in changed) {
      var balance = BigInt.zero;
      final events = await tx.query(
        'count_changes',
        columns: ['delta'],
        where: 'projectId=?',
        whereArgs: [id],
      );
      for (final e in events) {
        balance += BigInt.from(e['delta'] as int);
      }
      // Preserve every event even if the balance cannot fit the old cache/UI range.
      await tx.insert('ledger_balances', {
        'project_id': id,
        'balance': balance.toString(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.update(
        'projects',
        {
          'total': balance < BigInt.zero
              ? 0
              : balance > BigInt.from(maxCount)
              ? maxCount
              : balance.toInt(),
        },
        where: 'id=?',
        whereArgs: [id],
      );
    }
  }

  Future<void> _event(Transaction tx, Map<String, Object?> e, int rev) async {
    final id = e['id'] as String, project = e['project_id'] as String;
    if (e['delta'] is! int || (e['delta'] as int).abs() > maxCount) {
      throw StateError('Invalid delta');
    }
    final old = await tx.query(
      'event_sync',
      where: 'event_id=?',
      whereArgs: [id],
    );
    if (old.isNotEmpty) {
      if (old.single['payload'] != null) {
        LedgerMerge.combine(
          userId,
          project,
          [jsonMap(old.single['payload'])],
          [e],
        );
      } else {
        // This can happen after retry/import; validate original event fields.
        final local = (await tx.query(
          'count_changes',
          where: 'id=?',
          whereArgs: [id],
        )).single;
        if (local['delta'] != e['delta'] ||
            local['projectId'] != project ||
            local['source'] != e['source'] ||
            DateTime.parse(local['occurredAt'] as String).toUtc() !=
                DateTime.parse(e['occurred_at'] as String).toUtc()) {
          throw StateError('UUID collision');
        }
      }
      return;
    }
    final p = (await tx.query(
      'projects',
      where: 'id=?',
      whereArgs: [project],
    )).single;
    final time = DateTime.parse(
      e['occurred_at'] as String,
    ).toUtc().toIso8601String();
    final delta = e['delta'] as int, after = e['count_after'] as int?;
    final manual =
        (e['source'] as String).startsWith('manual_') ||
        e['source'] == 'legacy_correction';
    final session = e['session_id'] as String?;
    final meta = {
      'id': id,
      'createdAt': e['created_at'],
      'updatedAt': e['updated_at'],
      'syncStatus': 'synced',
      'deletedAt': p['deletedAt'],
    };
    if (!manual && delta == 1) {
      final sid =
          session ?? const Uuid().v5(Namespace.url.value, 'huideng/event/$id');
      await tx.insert('sessions', {
        'id': sid,
        'projectId': project,
        'startAt': time,
        'endAt': time,
        'added': 0,
        'totalAfter': after ?? 0,
        'createdAt': time,
        'updatedAt': time,
        'syncStatus': 'synced',
        'deletedAt': p['deletedAt'],
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final date = DateTime.parse(time).toLocal();
      await tx.insert('count_events', {
        ...meta,
        'projectId': project,
        'sessionId': sid,
        'occurredAt': time,
        'localDay':
            '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
      });
    } else if (manual && after != null) {
      await tx.insert('corrections', {
        ...meta,
        'projectId': project,
        'occurredAt': time,
        'beforeValue': after - delta,
        'delta': delta,
        'afterValue': after,
        'note': e['note'],
      });
    }
    await tx.insert('count_changes', {
      ...meta,
      'projectId': project,
      'sessionId': session,
      'occurredAt': time,
      'occurredAtMicros': DateTime.parse(time).microsecondsSinceEpoch,
      'delta': delta,
      'source': e['source'],
      'beforeValue': after == null ? null : after - delta,
      'afterValue': after,
      'note': e['note'],
      'originKind': manual ? 'corrections' : 'count_events',
      'originId': id,
    });
    await tx.insert('event_sync', {
      'event_id': id,
      'user_id': userId,
      'device_id': e['device_id'],
      'sync_status': 'synced',
      'server_revision': rev,
      'payload': jsonEncode(e),
    });
    if (!manual &&
        (p['lastRecitedAt'] == null ||
            DateTime.parse(
              time,
            ).isAfter(DateTime.parse(p['lastRecitedAt'] as String)))) {
      await tx.update(
        'projects',
        {'lastRecitedAt': time},
        where: 'id=?',
        whereArgs: [project],
      );
    }
  }

  Future<void> document(
    Transaction tx,
    String kind,
    String id,
    Map<String, Object?> data,
    int rev, {
    bool force = false,
  }) async {
    final cache = await tx.query(
      'cloud_documents',
      where: 'kind=? AND id=?',
      whereArgs: [kind, id],
    );
    if (cache.isNotEmpty && (cache.single['revision'] as int) > rev) return;
    await tx.insert('cloud_documents', {
      'kind': kind,
      'id': id,
      'payload': jsonEncode(data),
      'revision': rev,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    final pending = await tx.query(
      'sync_queue',
      where: 'entity_type=? AND entity_id=?',
      whereArgs: [kind, id],
    );
    final known = await tx.query(
      'sync_remote_versions',
      where: 'entity_type=? AND entity_id=?',
      whereArgs: [kind, id],
    );
    if (!force &&
        (pending.isNotEmpty ||
            (known.isNotEmpty &&
                (known.single['server_revision'] as int) >= rev))) {
      return;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    if (kind == 'project') {
      final existing = await tx.query(
        'projects',
        where: 'id=?',
        whereArgs: [id],
      );
      if (existing.isEmpty) {
        final positions = await tx.rawQuery(
          'SELECT COALESCE(MAX(position),-1)+1 AS p FROM projects',
        );
        await tx.insert('projects', {
          'id': id,
          'name': data['name'],
          'total': 0,
          'position': positions.single['p'],
          'createdAt': now,
          'updatedAt': now,
          'syncStatus': 'synced',
          'deletedAt': data['deleted_at'],
        });
      } else {
        await tx.update(
          'projects',
          {
            'name': data['name'],
            'deletedAt': data['deleted_at'],
            'updatedAt': now,
            'syncStatus': 'synced',
          },
          where: 'id=?',
          whereArgs: [id],
        );
      }
      final images = await tx.query(
        'cloud_projects',
        where: 'project_id=?',
        whereArgs: [id],
      );
      final previous = images.isEmpty ? null : images.single['image_key'];
      await tx.insert('cloud_projects', {
        'project_id': id,
        'image_key': data['image_key'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      final localImage = await tx.query(
        'sync_queue',
        where: "entity_type='image' AND entity_id=?",
        whereArgs: [id],
      );
      if (localImage.isEmpty &&
          (previous != data['image_key'] || existing.isEmpty)) {
        await tx.update(
          'projects',
          {'imagePath': null},
          where: 'id=?',
          whereArgs: [id],
        );
        if (data['image_key'] != null) await enqueue(tx, 'download', id);
      }
      if (data['deleted_at'] != null) {
        for (final table in [
          'count_changes',
          'count_events',
          'corrections',
          'sessions',
        ]) {
          await tx.update(
            table,
            {'deletedAt': data['deleted_at']},
            where: 'projectId=?',
            whereArgs: [id],
          );
        }
      }
    } else if (kind == 'setting') {
      if (![
        'language',
        'haptics',
        'calendarUrl',
        'forumUrl',
        'noticeUrl',
      ].contains(id)) {
        throw StateError('Unknown setting');
      }
      final old = await tx.query(
        'settings',
        where: 'settingKey=?',
        whereArgs: [id],
      );
      if (old.isEmpty) {
        await tx.insert('settings', {
          'id': const Uuid().v4(),
          'settingKey': id,
          'value': data['value'],
          'createdAt': now,
          'updatedAt': now,
          'syncStatus': 'synced',
        });
      } else {
        await tx.update(
          'settings',
          {'value': data['value'], 'updatedAt': now, 'syncStatus': 'synced'},
          where: 'settingKey=?',
          whereArgs: [id],
        );
      }
    } else if (kind == 'order') {
      final ids = (data['ids'] as List).cast<String>();
      if (ids.toSet().length != ids.length) throw StateError('Duplicate order');
      final local = (await tx.query(
        'projects',
        columns: ['id'],
        orderBy: 'position,createdAt,id',
      )).map((r) => r['id'] as String);
      final combined = [...ids, ...local.where((id) => !ids.contains(id))];
      for (var i = 0; i < combined.length; i++) {
        await tx.update(
          'projects',
          {'position': i},
          where: 'id=?',
          whereArgs: [combined[i]],
        );
      }
    } else if (kind == 'session') {
      final p = (await tx.query(
        'projects',
        where: 'id=?',
        whereArgs: [data['project_id']],
      )).single;
      final value = {
        'id': id,
        'projectId': data['project_id'],
        'startAt': data['start_at'],
        'endAt': data['end_at'],
        'added': data['added'],
        'totalAfter': data['total_after'],
        'createdAt': data['created_at'],
        'updatedAt': data['updated_at'],
        'deletedAt': p['deletedAt'] ?? data['deleted_at'],
        'syncStatus': 'synced',
      };
      final exists = await tx.query('sessions', where: 'id=?', whereArgs: [id]);
      if (exists.isEmpty) {
        await tx.insert('sessions', value);
      } else {
        await tx.update('sessions', value, where: 'id=?', whereArgs: [id]);
      }
    } else {
      throw StateError('Unknown remote kind');
    }
  }
}
