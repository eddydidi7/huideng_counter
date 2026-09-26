import '../local/large_note_io.dart';
import 'package:flutter/foundation.dart';
import '../../core/sync_diagnostics.dart';
import 'dart:async';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

abstract interface class NotesGateway {
  Future<Map<String, dynamic>> push(Map<String, dynamic> request);
  Future<List<Map<String, dynamic>>> pull(int cursor);
}

/// A separate account-scoped outbox; failures never block counting or saving.
class NotesSync {
  final Database db;
  final NotesGateway remote;
  final String userId;
  final String? Function() authenticatedUser;
  final void Function()? onChanged;
  Timer? _timer;
  bool _enabled = false, _running = false;
  int _epoch = 0, _failures = 0;
  DateTime? _retryAt;
  String status = 'local_saved';
  String? lastError;
  bool _requestedAgain = false;
  void authenticationChanged() {
    if (authenticatedUser() != userId) {
      status = 'waiting_login';
      onChanged?.call();
    } else {
      start();
      unawaited(wake(force: true));
    }
  }

  String? lastSync;
  NotesSync(
    this.db,
    this.remote,
    this.userId,
    this.authenticatedUser, {
    this.onChanged,
  });
  bool valid(int epoch) =>
      _enabled && epoch == _epoch && authenticatedUser() == userId;
  void start() {
    if (_enabled) return;
    _enabled = true;
    _timer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(wake()),
    );
    unawaited(wake());
  }

  void stop() {
    _enabled = false;
    _epoch++;
    _timer?.cancel();
  }

  Future<void> waitUntilIdle() async {
    while (_running) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> wake({bool force = false}) async {
    final epoch = _epoch;
    if (authenticatedUser() != userId) {
      status = 'waiting_login';
      SyncDiagnostics.record('notes_auth_missing', {
        'user_id': userId,
        'sync_status': status,
      });
      onChanged?.call();
      return;
    }
    if (force && !_enabled) start();
    if (_running) {
      if (force) _requestedAgain = true;
      return;
    }
    if (!_enabled ||
        (!force && _retryAt != null && DateTime.now().isBefore(_retryAt!))) {
      return;
    }
    _running = true;
    Map<String, dynamic>? activeRequest;
    status = 'syncing';
    lastError = null;
    onChanged?.call();
    try {
      if ((await db.query('sync_scope')).single['user_id'] != userId) {
        throw StateError('Wrong local owner');
      }
      SyncDiagnostics.record('notes_local_state', {
        'user_id': userId,
        'note_count': Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM notes'),
        ),
        'queue_count': Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM note_outbox'),
        ),
        'schema_version': await db.getVersion(),
      });
      lastSync =
          (await db.query('note_sync_state')).single['last_sync_at'] as String?;
      if (force) await db.update('note_outbox', {'next_at': 0});
      for (var i = 0; i < 50 && valid(epoch); i++) {
        final request = await freeze();
        activeRequest = request;
        if (request == null) break;
        SyncDiagnostics.record('note_push', {
          'user_id': userId,
          'note_id': request['p_id'],
          'queue_item_id': request['p_request'],
          'sync_status': status,
        });
        final reply = await remote
            .push(request)
            .timeout(const Duration(minutes: 15));
        if (!valid(epoch)) return;
        await acknowledge(request, reply);
        SyncDiagnostics.record('note_ack', {
          'user_id': userId,
          'note_id': request['p_id'],
          'queue_item_id': request['p_request'],
          'request_result': reply['conflict'] == true
              ? 'conflict_copy'
              : 'accepted',
        });
        activeRequest = null;
      }
      for (var i = 0; i < 10 && valid(epoch); i++) {
        final cursor =
            (await db.query('note_sync_state')).single['cursor'] as int;
        final rows = await remote
            .pull(cursor)
            .timeout(const Duration(minutes: 15));
        if (!valid(epoch)) return;
        await db.transaction((tx) async {
          await tx.update('sync_scope', {'applying_remote': 1});
          var next = cursor;
          for (final row in rows) {
            checkOwner(row);
            final rev = row['revision'] as int;
            if (rev <= next) throw StateError('Invalid note cursor');
            next = rev;
            if ((await tx.query(
              'note_outbox',
              columns: ['note_id'],
              where: 'note_id=?',
              whereArgs: [row['id']],
            )).isEmpty) {
              await apply(tx, row);
            }
          }
          await tx.update('sync_scope', {'applying_remote': 0});
          await tx.update('note_sync_state', {'cursor': next});
        });
        if (rows.length < 100) {
          lastSync = DateTime.now().toUtc().toIso8601String();
          await db.update('note_sync_state', {'last_sync_at': lastSync});
          break;
        }
      }
      _failures = 0;
      _retryAt = null;
      status =
          (await db.query(
            'note_outbox',
            columns: ['note_id'],
            limit: 1,
          )).isEmpty
          ? 'synced'
          : 'waiting';
    } catch (error) {
      if (valid(epoch)) {
        _failures = (_failures + 1).clamp(1, 10);
        _retryAt = DateTime.now().add(
          Duration(
            seconds: [5, 15, 30, 60, 120, 300][(_failures - 1).clamp(0, 5)],
          ),
        );
        final failure = error is NoteSyncFailure
            ? error
            : NoteSyncFailure(
                error is TimeoutException ? 'waiting_network' : 'failed',
                message: error.runtimeType.toString(),
              );
        lastError = failure.category;
        SyncDiagnostics.record('note_sync_error', {
          'user_id': userId,
          'note_id': activeRequest?['p_id'],
          'queue_item_id': activeRequest?['p_request'],
          'sync_status': failure.category,
          'retry_count': _failures,
          'http_status': failure.httpStatus,
          'postgrest_code': failure.code,
          'supabase_message': failure.message,
        });
        if (activeRequest != null) {
          await db.rawUpdate(
            'UPDATE note_outbox SET attempts=attempts+1,next_at=?,last_error=? WHERE note_id=?',
            [
              _retryAt!.millisecondsSinceEpoch,
              failure.category,
              activeRequest['p_id'],
            ],
          );
        }
        status = failure.category;
      }
    } finally {
      _running = false;
      onChanged?.call();
      if (_requestedAgain && valid(_epoch)) {
        _requestedAgain = false;
        unawaited(wake(force: true));
      }
    }
  }

  /// Preserve a frozen request even when a later local edit occurs. A lost HTTP
  /// response can therefore be retried without creating duplicate conflict copies.
  Future<Map<String, dynamic>?> freeze() => db.transaction((tx) async {
    final rows = await tx.query(
      'note_outbox',
      columns: ['note_id', 'generation', 'payload IS NOT NULL AS has_payload'],
      where: 'next_at<=?',
      whereArgs: [DateTime.now().millisecondsSinceEpoch],
      orderBy: 'attempts,note_id',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final job = rows.single;
    if (job['has_payload'] == 1) {
      final payload = await readLargeText(
        tx,
        'note_outbox',
        'payload',
        'note_id',
        job['note_id']!,
      );
      return compute(decodeFrozenNote, payload);
    }
    final id = job['note_id'];
    final note = (await noteRows(tx, id as String)).single;
    final known = await tx.query(
      'note_cloud',
      where: 'note_id=?',
      whereArgs: [id],
    );
    final request = <String, dynamic>{
      'p_request': const Uuid().v4(),
      'p_id': id,
      'p_base': known.isEmpty ? 0 : known.single['revision'],
      'p_data': {
        for (final key in [
          'title',
          'body',
          'source_post_id',
          'source_meta',
          'isPinned',
          'isFavorite',
          'isFavorite2',
          'isArchived',
          'createdAt',
          'updatedAt',
          'deletedAt',
        ])
          key: note[key],
      },
      'p_history': (note['body'] as String).length >= 100000
          ? <Map<String, Object?>>[]
          : await noteHistory(tx, id),
      'local_generation': job['generation'],
      'local_version': note['version'],
    };
    await tx.update(
      'note_outbox',
      {
        'request_id': request['p_request'],
        'payload': await compute(encodeNoteRequest, request),
      },
      where: 'note_id=?',
      whereArgs: [id],
    );
    return request;
  });

  void checkOwner(Map<String, dynamic> row) {
    if (row['user_id'] != userId) throw StateError('Wrong remote owner');
  }

  Future<void> acknowledge(
    Map<String, dynamic> request,
    Map<String, dynamic> reply,
  ) => db.transaction((tx) async {
    final saved = Map<String, dynamic>.from(reply['saved']);
    checkOwner(saved);
    final id = request['p_id'];
    final job = (await tx.query(
      'note_outbox',
      columns: ['note_id', 'request_id', 'generation'],
      where: 'note_id=?',
      whereArgs: [id],
    )).single;
    if (job['request_id'] != request['p_request']) {
      throw StateError('Wrong receipt');
    }
    final changed = job['generation'] != request['local_generation'];
    await tx.update('sync_scope', {'applying_remote': 1});
    if (reply['conflict'] == true) {
      if (saved['id'] != request['p_request']) {
        throw StateError('Invalid conflict copy');
      }
      final current = Map<String, dynamic>.from(reply['current']);
      if (current['id'] != id) throw StateError('Invalid conflict source');
      checkOwner(current);
      final local = (await noteRows(tx, id as String)).single;
      // Server made a durable copy with the request UUID. Keep any edits made
      // during the HTTP call on that copy and queue them against its new revision.
      await apply(tx, saved);
      if (changed) {
        await tx.update(
          'notes',
          {
            ...local,
            'id': saved['id'],
            'version': (local['version'] as int) + 1,
            'syncStatus': 'pending',
          },
          where: 'id=?',
          whereArgs: [saved['id']],
        );
        await tx.insert('note_revisions', {
          'id': const Uuid().v4(),
          'noteId': saved['id'],
          'payload': await compute(encodeNoteRequest, local),
          'createdAt': local['updatedAt'],
        });
        await tx.insert('note_outbox', {
          'note_id': saved['id'],
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await tx.delete('note_outbox', where: 'note_id=?', whereArgs: [id]);
      await apply(tx, current, force: true);
    } else {
      if (saved['id'] != id) throw StateError('Wrong note receipt');
      await tx.insert('note_cloud', {
        'note_id': id,
        'revision': saved['revision'],
        'conflict_of': saved['conflict_of'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (changed) {
        await tx.update(
          'note_outbox',
          {
            'request_id': null,
            'payload': null,
            'attempts': 0,
            'next_at': 0,
            'last_error': null,
          },
          where: 'note_id=?',
          whereArgs: [id],
        );
      } else {
        await tx.delete('note_outbox', where: 'note_id=?', whereArgs: [id]);
        // Only metadata changes: the open editor's version remains valid.
        await tx.update(
          'notes',
          {'syncStatus': 'synced'},
          where: 'id=?',
          whereArgs: [id],
        );
      }
    }
    await tx.update('sync_scope', {'applying_remote': 0});
  });

  Future<void> apply(
    Transaction tx,
    Map<String, dynamic> row, {
    bool force = false,
  }) async {
    checkOwner(row);
    final id = row['id'];
    final known = await tx.query(
      'note_cloud',
      where: 'note_id=?',
      whereArgs: [id],
    );
    if (!force &&
        known.isNotEmpty &&
        (known.single['revision'] as int) >= (row['revision'] as int)) {
      return;
    }
    final old = await noteRows(tx, id as String);
    final data = Map<String, dynamic>.from(row['data']);
    final value = <String, Object?>{
      for (final key in [
        'title',
        'body',
        'isPinned',
        'isFavorite',
        'isArchived',
        'createdAt',
        'updatedAt',
        'deletedAt',
      ])
        key: data[key],
      'isFavorite': data['isFavorite2'] == 1 ? 1 : data['isFavorite'] ?? 0,
      'isFavorite2': 0,
      'source_post_id': data['source_post_id'],
      'source_meta': data['source_meta'] ?? '{}',
      'id': id,
      'version': old.isEmpty ? 1 : (old.single['version'] as int) + 1,
      'syncStatus': 'synced',
    };
    if (old.isEmpty) {
      await tx.insert('notes', value);
    } else {
      await tx.update('notes', value, where: 'id=?', whereArgs: [id]);
    }
    await tx.insert('note_cloud', {
      'note_id': id,
      'revision': row['revision'],
      'conflict_of': row['conflict_of'],
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    for (final raw in (row['history'] as List? ?? [])) {
      final revision = Map<String, dynamic>.from(raw);
      await tx.insert('note_revisions', {
        'id': revision['id'],
        'noteId': id,
        'payload': revision['payload'],
        'createdAt': revision['createdAt'],
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await tx.insert('note_revisions', {
      'id': const Uuid().v5(
        Namespace.url.value,
        'huideng/note/$id/${row['revision']}',
      ),
      'noteId': id,
      'payload': await compute(encodeNoteRequest, value),
      'createdAt': data['updatedAt'],
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}

String encodeNoteRequest(Map<String, dynamic> value) => jsonEncode(value);

Map<String, dynamic> decodeFrozenNote(String value) =>
    Map<String, dynamic>.from(jsonDecode(value));
