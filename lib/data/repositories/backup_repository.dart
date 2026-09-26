import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../../domain/models.dart';
import '../local/local_database.dart';

class BackupFailure implements Exception {
  final String code;
  BackupFailure(this.code);
}

/// Portable logical snapshot. Never includes credentials, queue cursors or SQL.
class BackupRepository {
  static const maxBytes = 100 * 1024 * 1024;
  static const tables = [
    'projects',
    'sessions',
    'count_events',
    'corrections',
    'count_changes',
    'settings',
    'event_sync',
    'guest_import_claims',
    'cloud_projects',
    'notes',
    'note_revisions',
  ];
  final Database db;
  final Directory root;
  BackupRepository(this.db, this.root);

  /// UTF-8 BOM + RFC-style quoting for Excel/WPS and other CSV readers.
  Future<Uint8List> exportCsv({
    String? projectId,
    DateTime? from,
    DateTime? until,
  }) async {
    final conditions = <String>[];
    final args = <Object?>[];
    if (projectId != null) {
      conditions.add('p.id=?');
      args.add(projectId);
    }
    if (from != null) {
      conditions.add('c.occurredAtMicros>=?');
      args.add(from.toUtc().microsecondsSinceEpoch);
    }
    if (until != null) {
      conditions.add('c.occurredAtMicros<?');
      args.add(until.toUtc().microsecondsSinceEpoch);
    }
    final rows = await db.transaction(
      (tx) => tx.rawQuery("""
      SELECT p.id AS project_id, p.name AS project_name,
        p.position AS project_order, p.deletedAt AS project_deleted_at,
        c.id AS event_id, c.occurredAt AS occurred_at,
        c.delta, c.beforeValue AS count_before, c.afterValue AS count_after,
        c.source, c.note, c.sessionId AS session_id,
        c.createdAt AS created_at, c.updatedAt AS updated_at,
        c.deletedAt AS event_deleted_at, e.device_id AS device
      FROM projects p LEFT JOIN count_changes c ON c.projectId = p.id
      LEFT JOIN event_sync e ON e.event_id=c.id
      ${conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}'}
      ORDER BY p.position, p.id, c.occurredAtMicros, c.id
    """, args),
    );
    const columns = [
      'project_id',
      'project_name',
      'project_order',
      'project_deleted_at',
      'event_id',
      'occurred_at',
      'delta',
      'count_before',
      'count_after',
      'source',
      'note',
      'session_id',
      'created_at',
      'updated_at',
      'event_deleted_at',
      'device',
    ];
    String cell(Object? value) {
      var text = value?.toString() ?? '';
      // User-entered text must not become a spreadsheet formula.
      if (value is String && RegExp(r'^[\s]*[=+@-]').hasMatch(text)) {
        text = "'$text";
      }
      return '"${text.replaceAll('"', '""')}"';
    }

    final csv = StringBuffer('\uFEFF')
      ..write(columns.map(cell).join(','))
      ..write('\r\n');
    for (final row in rows) {
      csv.write('${columns.map((key) => cell(row[key])).join(',')}\r\n');
    }
    final bytes = Uint8List.fromList(utf8.encode(csv.toString()));
    if (bytes.length > maxBytes) throw BackupFailure('size');
    return bytes;
  }

  Future<Uint8List> export() async {
    final snapshot = await db.transaction((tx) async {
      final result = <String, Object?>{};
      for (final table in tables) {
        result[table] = await tx.query(table);
      }
      result['owner'] = (await tx.query('sync_scope')).single['user_id'];
      return result;
    });
    final assets = <String, Object?>{};
    var imageBytes = 0;
    final remoteImages = {
      for (final row in snapshot['cloud_projects'] as List)
        (row as Map)['project_id']: row['image_key'],
    };
    for (final raw in snapshot['projects'] as List) {
      final project = raw as Map;
      final path = project['imagePath'];
      if (path == null && remoteImages[project['id']] != null) {
        throw BackupFailure('missing_image');
      }
      if (path is String) {
        final file = File(path);
        if (!await file.exists()) throw BackupFailure('missing_image');
        final size = await file.length();
        imageBytes += size;
        if (size > 20 * 1024 * 1024 || imageBytes * 4 ~/ 3 > maxBytes) {
          throw BackupFailure('size');
        }
        final bytes = await file.readAsBytes();
        assets[project['id'] as String] = {
          'bytes': base64Encode(bytes),
          'sha256': sha256.convert(bytes).toString(),
          'extension': p.extension(path).toLowerCase(),
        };
      }
    }
    final payload = jsonEncode({'tables': snapshot, 'images': assets});
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'huideng-backup',
          'version': 2,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'payload': payload,
          'sha256': sha256.convert(utf8.encode(payload)).toString(),
        }),
      ),
    );
    if (bytes.length > maxBytes) throw BackupFailure('size');
    return bytes;
  }

  Future<int> import(Uint8List bytes, {required bool restoreSettings}) async {
    if (bytes.length > maxBytes) throw BackupFailure('size');
    final envelope = jsonDecode(utf8.decode(bytes)) as Map;
    if (envelope['format'] != 'huideng-backup' ||
        ![1, 2].contains(envelope['version'])) {
      throw BackupFailure('format');
    }
    final payload = envelope['payload'] as String;
    if (sha256.convert(utf8.encode(payload)).toString() != envelope['sha256']) {
      throw BackupFailure('checksum');
    }
    final data = jsonDecode(payload) as Map;
    final rows = data['tables'] as Map;
    final owner = (await db.query('sync_scope')).single['user_id'];
    if (owner != rows['owner']) throw BackupFailure('owner');
    final images = data['images'] as Map;
    await root.create(recursive: true);
    final staging = await root.createTemp('restore-');
    Database? checked;
    try {
      // Validate types, columns, foreign keys and unique constraints away from live data.
      checked = await LocalDatabase.openAt(
        p.join(staging.path, 'validate.sqlite'),
      );
      final stagedImages = <String, String>{};
      for (final entry in images.entries) {
        if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(entry.key as String)) {
          throw BackupFailure('format');
        }
        final asset = entry.value as Map;
        final ext = asset['extension'];
        if (!['.png', '.jpg', '.jpeg', '.webp'].contains(ext)) {
          throw BackupFailure('format');
        }
        final content = base64Decode(asset['bytes'] as String);
        if (content.length > 20 * 1024 * 1024 ||
            sha256.convert(content).toString() != asset['sha256']) {
          throw BackupFailure('checksum');
        }
        final file = File(p.join(staging.path, '${entry.key}$ext'));
        await file.writeAsBytes(content, flush: true);
        stagedImages[entry.key as String] = file.path;
      }
      await checked.transaction((tx) async {
        await tx.update('sync_scope', {'applying_remote': 1});
        for (final table in tables) {
          final columns = (await tx.rawQuery(
            'PRAGMA table_info($table)',
          )).map((r) => r['name']).toSet();
          final items =
              (rows[table] ??
                      (envelope['version'] == 1 &&
                              ['notes', 'note_revisions'].contains(table)
                          ? []
                          : null))
                  as List;
          for (final item in items) {
            final row = Map<String, Object?>.from(item as Map);
            if (!columns.containsAll(row.keys) ||
                row.values.any((v) => v != null && v is! String && v is! int)) {
              throw BackupFailure('format');
            }
            if (table == 'projects') {
              final id = row['id'] as String;
              if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id)) {
                throw BackupFailure('format');
              }
              if (row['imagePath'] != null && !stagedImages.containsKey(id)) {
                throw BackupFailure('missing_image');
              }
              row['imagePath'] = stagedImages[id];
            }
            if (table == 'event_sync' && row['user_id'] != owner) {
              throw BackupFailure('owner');
            }
            if (table == 'settings' &&
                ![
                  'language',
                  'haptics',
                  'calendarUrl',
                  'forumUrl',
                  'noticeUrl',
                ].contains(row['settingKey'])) {
              continue;
            }
            await tx.insert(table, row);
          }
        }
        final events = await tx.rawQuery(
          'SELECT c.*, e.user_id, e.device_id, e.payload FROM count_changes c LEFT JOIN event_sync e ON e.event_id=c.id',
        );
        for (final e in events) {
          if (DateTime.parse(
                e['occurredAt'] as String,
              ).microsecondsSinceEpoch !=
              e['occurredAtMicros']) {
            throw BackupFailure('format');
          }
          if (e['device_id'] is! String ||
              e['delta'] is! int ||
              (e['delta'] as int).abs() > maxCount) {
            throw BackupFailure('format');
          }
          if (e['payload'] != null) {
            final frozen = jsonDecode(e['payload'] as String) as Map;
            for (final pair in {
              'created_at': 'createdAt',
              'updated_at': 'updatedAt',
              'occurred_at': 'occurredAt',
            }.entries) {
              if (DateTime.parse(frozen[pair.key] as String).toUtc() !=
                  DateTime.parse(e[pair.value] as String).toUtc()) {
                throw BackupFailure('event_conflict');
              }
            }
            for (final pair in {
              'id': 'id',
              'user_id': 'user_id',
              'project_id': 'projectId',
              'delta': 'delta',
              'count_after': 'afterValue',
              'device_id': 'device_id',
              'source': 'source',
              'session_id': 'sessionId',
              'note': 'note',
            }.entries) {
              if (frozen[pair.key] != e[pair.value]) {
                throw BackupFailure('event_conflict');
              }
            }
          }
        }
      });
      final imageDir = Directory(p.join(root.path, 'images'));
      await imageDir.create(recursive: true);
      final copied = <String, String>{};
      // Generated destination names; a backup can never choose filesystem paths.
      for (final entry in stagedImages.entries) {
        final target = p.join(
          imageDir.path,
          '${const Uuid().v4()}${p.extension(entry.value)}',
        );
        await File(entry.value).copy(target);
        copied[entry.key] = target;
      }
      var added = 0;
      final source = checked;
      final validated = <String, List<Map<String, Object?>>>{};
      for (final table in tables) {
        validated[table] = await source.query(table);
      }
      await db.transaction((tx) async {
        if ((await tx.query('sync_scope')).single['user_id'] != owner) {
          throw BackupFailure('owner');
        }
        final claims = validated['guest_import_claims']!;
        for (final claim in claims) {
          final old = await tx.query(
            'guest_import_claims',
            where: 'project_id=?',
            whereArgs: [claim['project_id']],
          );
          if (old.isNotEmpty && old.single['user_id'] != claim['user_id']) {
            throw BackupFailure('owner');
          }
          if (old.isEmpty) await tx.insert('guest_import_claims', claim);
        }
        final newProjects = <String>{};
        final noteIds = <String, String>{};
        for (final sourceNote in validated['notes']!) {
          final note = {
            ...sourceNote,
            'isFavorite': sourceNote['isFavorite2'] == 1
                ? 1
                : sourceNote['isFavorite'] ?? 0,
            'isFavorite2': 0,
          };
          final id = note['id'] as String;
          final old = await tx.query('notes', where: 'id=?', whereArgs: [id]);
          String targetId = id;
          if (old.isNotEmpty) {
            final differs = [
              'title',
              'body',
              'isPinned',
              'isFavorite',
              'isFavorite2',
              'isArchived',
              'deletedAt',
            ].any((key) => old.single[key] != note[key]);
            if (differs) {
              // Stable copy ID makes importing the same conflicting backup idempotent.
              final keys = note.keys.toList()..sort();
              targetId = const Uuid().v5(
                '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
                'huideng-note-restore:$id:${jsonEncode({for (final key in keys) key: note[key]})}',
              );
            }
          }
          noteIds[id] = targetId;
          if ((await tx.query(
            'notes',
            where: 'id=?',
            whereArgs: [targetId],
          )).isEmpty) {
            await tx.insert('notes', {
              ...note,
              'id': targetId,
              'syncStatus': 'pending',
            });
          }
        }
        for (final revision in validated['note_revisions']!) {
          final targetId = noteIds[revision['noteId']]!;
          final revisionId = targetId == revision['noteId']
              ? revision['id'] as String
              : const Uuid().v5(
                  '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
                  'huideng-note-revision:$targetId:${revision['id']}',
                );
          final old = await tx.query(
            'note_revisions',
            where: 'id=?',
            whereArgs: [revisionId],
          );
          if (old.isNotEmpty) {
            if (old.single['payload'] != revision['payload'] ||
                old.single['noteId'] != targetId) {
              throw BackupFailure('event_conflict');
            }
          } else {
            await tx.insert('note_revisions', {
              ...revision,
              'id': revisionId,
              'noteId': targetId,
            });
          }
        }
        for (final project in validated['projects']!) {
          final id = project['id'] as String;
          final old = await tx.query(
            'projects',
            where: 'id=?',
            whereArgs: [id],
          );
          if (old.isEmpty) {
            await tx.insert('projects', {
              ...project,
              'imagePath': copied[id],
              'total': 0,
              'syncStatus': 'pending',
            });
            newProjects.add(id);
          }
        }
        for (final table in [
          'sessions',
          'count_events',
          'corrections',
          'count_changes',
        ]) {
          for (final row in validated[table]!) {
            final old = await tx.query(
              table,
              where: 'id=?',
              whereArgs: [row['id']],
            );
            if (old.isNotEmpty) {
              if (table == 'count_changes') {
                for (final field in [
                  'projectId',
                  'sessionId',
                  'occurredAtMicros',
                  'delta',
                  'source',
                  'beforeValue',
                  'afterValue',
                  'note',
                  'originKind',
                  'originId',
                ]) {
                  if (old.single[field] != row[field]) {
                    throw BackupFailure('event_conflict');
                  }
                }
              }
              continue;
            }
            await tx.insert(table, {...row, 'syncStatus': 'pending'});
            if (table == 'count_changes') {
              final provenance = validated['event_sync']!.singleWhere(
                (e) => e['event_id'] == row['id'],
              );
              await tx.update(
                'event_sync',
                {
                  'device_id': provenance['device_id'],
                  'payload': provenance['payload'],
                },
                where: 'event_id=?',
                whereArgs: [row['id']],
              );
              added++;
            }
          }
        }
        for (final row in validated['cloud_projects']!) {
          if (newProjects.contains(row['project_id'])) {
            await tx.insert('cloud_projects', row);
          }
        }
        if (restoreSettings) {
          for (final row in validated['settings']!) {
            final old = await tx.query(
              'settings',
              where: 'settingKey=?',
              whereArgs: [row['settingKey']],
            );
            if (old.isEmpty) {
              await tx.insert('settings', {...row, 'syncStatus': 'pending'});
            } else {
              await tx.update(
                'settings',
                {
                  'value': row['value'],
                  'updatedAt': DateTime.now().toUtc().toIso8601String(),
                  'syncStatus': 'pending',
                },
                where: 'settingKey=?',
                whereArgs: [row['settingKey']],
              );
            }
          }
        }
        for (final project in validated['projects']!) {
          final id = project['id'] as String;
          final changes = await tx.query(
            'count_changes',
            where: 'projectId=?',
            whereArgs: [id],
            orderBy: 'occurredAtMicros DESC',
          );
          final total = changes.fold<BigInt>(
            BigInt.zero,
            (n, e) => n + BigInt.from(e['delta'] as int),
          );
          await tx.insert('ledger_balances', {
            'project_id': id,
            'balance': total.toString(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          await tx.update(
            'projects',
            {
              'total': total < BigInt.zero
                  ? 0
                  : total > BigInt.from(maxCount)
                  ? maxCount
                  : total.toInt(),
              if (changes.isNotEmpty)
                'lastRecitedAt': changes.first['occurredAt'],
            },
            where: 'id=?',
            whereArgs: [id],
          );
        }
      });
      return added;
    } finally {
      await checked?.close();
      // Only this operation's freshly created staging directory is removed.
      if (!p.isWithin(root.absolute.path, staging.absolute.path)) {
        throw StateError('Invalid staging directory');
      }
      await staging.delete(recursive: true);
    }
  }
}
