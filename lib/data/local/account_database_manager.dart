import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'local_database.dart';
import 'balance.dart';
import '../sync/local_sync_store.dart';
import '../repositories/note_categories.dart';
import '../repositories/sqlite_counter_repository.dart';
import 'large_note_io.dart';

class AccountDatabaseManager {
  final Directory root;
  final Database guest;
  final Map<String, Database> _opened = {};
  AccountDatabaseManager(this.root, this.guest);
  String accountPath(String user) {
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(user)) {
      throw ArgumentError('Invalid user UUID');
    }
    return p.join(root.path, 'accounts', user);
  }

  Future<Database> open(String user) async {
    if (_opened.containsKey(user)) return _opened[user]!;
    final dir = Directory(accountPath(user));
    await dir.create(recursive: true);
    final path = p.join(dir.path, 'huideng.sqlite');
    await LocalDatabase.backupBeforeUpgrade(path);
    final db = await LocalDatabase.openAt(path);
    await LocalSyncStore(db).bindGuestDatabase(user);
    if ((await db.query('projects', limit: 1)).isEmpty) {
      await db.delete('sync_queue', where: "entity_type='order'");
    }
    _opened[user] = db;
    return db;
  }

  Future<int> importGuest(String user) async {
    final target = await open(user);
    // Durable ownership claim first. On crash the same user may safely retry.
    final selected = await guest.transaction((tx) async {
      final projects = await tx.rawQuery(
        '''SELECT p.* FROM projects p LEFT JOIN guest_import_claims c ON c.project_id=p.id
        WHERE c.user_id IS NULL OR c.user_id=?''',
        [user],
      );
      for (final row in projects) {
        await tx.insert('guest_import_claims', {
          'project_id': row['id'],
          'user_id': user,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      return projects;
    });
    final imageDir = Directory(p.join(accountPath(user), 'images'));
    await imageDir.create(recursive: true);
    var imported = 0;
    for (final project in selected) {
      final id = project['id'] as String;
      String? copied = project['imagePath'] as String?;
      if (copied != null && await File(copied).exists()) {
        final destination = p.join(imageDir.path, p.basename(copied));
        if (!await File(destination).exists()) {
          await File(copied).copy(destination);
        }
        copied = destination;
      }
      final snapshots = <String, List<Map<String, Object?>>>{};
      final provenance = {
        for (final e in await guest.rawQuery(
          'SELECT e.* FROM event_sync e JOIN count_changes c ON c.id=e.event_id WHERE c.projectId=?',
          [id],
        ))
          e['event_id']: e,
      };
      for (final table in [
        'sessions',
        'count_events',
        'corrections',
        'count_changes',
      ]) {
        snapshots[table] = await guest.query(
          table,
          where: 'projectId=?',
          whereArgs: [id],
        );
      }
      await target.transaction((tx) async {
        final exists = await tx.query(
          'projects',
          where: 'id=?',
          whereArgs: [id],
        );
        if (exists.isEmpty) {
          await tx.insert('projects', {...project, 'imagePath': copied});
          imported++;
        }
        for (final entry in snapshots.entries) {
          for (final row in entry.value) {
            final old = await tx.query(
              entry.key,
              columns: ['id'],
              where: 'id=?',
              whereArgs: [row['id']],
            );
            if (old.isEmpty) {
              await tx.insert(entry.key, row);
              if (entry.key == 'count_changes' &&
                  provenance[row['id']] != null) {
                await tx.update(
                  'event_sync',
                  {'device_id': provenance[row['id']]!['device_id']},
                  where: 'event_id=?',
                  whereArgs: [row['id']],
                );
              }
            }
          }
        }
        final rows = await tx.query(
          'count_changes',
          columns: ['delta'],
          where: 'projectId=?',
          whereArgs: [id],
        );
        final total = rows.fold<int>(0, (n, row) => n + (row['delta'] as int));
        await saveBalance(tx, id, total);
      });
    }
    await _importGuestNotes(user, target);
    return imported;
  }

  /// Guest notes keep their category (source_meta) and history; inserting
  /// them queues the normal notes outbox upload. Claims use a 'note:' prefix
  /// in the shared claims table so one guest note is imported by one account.
  Future<void> _importGuestNotes(String user, Database target) async {
    final ids = await guest.transaction((tx) async {
      final rows = await tx.rawQuery(
        '''SELECT n.id FROM notes n LEFT JOIN guest_import_claims c
        ON c.project_id='note:'||n.id WHERE c.user_id IS NULL OR c.user_id=?''',
        [user],
      );
      for (final row in rows) {
        await tx.insert('guest_import_claims', {
          'project_id': 'note:${row['id']}',
          'user_id': user,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      return [for (final row in rows) row['id'] as String];
    });
    for (final id in ids) {
      final note = await noteRows(guest, id);
      if (note.isEmpty) continue;
      final history = await noteHistory(guest, id);
      await target.transaction((tx) async {
        final exists = await tx.query(
          'notes',
          columns: ['id'],
          where: 'id=?',
          whereArgs: [id],
        );
        if (exists.isNotEmpty) return;
        await tx.insert('notes', {...note.single, 'syncStatus': 'pending'});
        for (final revision in history) {
          await tx.insert(
            'note_revisions',
            revision,
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      });
    }
    final categories = await guest.query(
      'settings',
      where: 'settingKey=? AND deletedAt IS NULL',
      whereArgs: [NoteCategories.settingKey],
    );
    if (categories.isEmpty) return;
    final current = await SqliteCounterRepository(target).settings();
    await SqliteCounterRepository(target).saveSetting(
      NoteCategories.settingKey,
      NoteCategories.merge(
        current[NoteCategories.settingKey],
        categories.single['value'] as String?,
      ),
    );
  }
}
