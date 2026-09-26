import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../../domain/models.dart';
import '../local/balance.dart';

class SqliteCounterRepository implements CounterRepository {
  final Database db;
  final DateTime Function() clock;
  SqliteCounterRepository(this.db, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  String get now => clock().toUtc().toIso8601String();
  Map<String, Object?> meta(String time) => {
    'id': const Uuid().v4(),
    'createdAt': time,
    'updatedAt': time,
    'syncStatus': 'pending',
    'deletedAt': null,
  };
  String day(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Future<void> recoverSessions() async {
    // Each tap already persisted. An interrupted session ends at its last tap.
    await db.rawUpdate(
      "UPDATE sessions SET endAt = updatedAt, syncStatus = 'pending' WHERE endAt IS NULL AND syncStatus != 'synced'",
    );
  }

  @override
  Future<List<CounterProject>> projects() async => (await db.rawQuery(
    'SELECT p.*, b.balance AS eventBalance, (SELECT COUNT(*) FROM count_events e WHERE e.projectId = p.id '
    'AND e.localDay = ? AND e.deletedAt IS NULL) AS today '
    'FROM projects p LEFT JOIN ledger_balances b ON b.project_id=p.id WHERE p.deletedAt IS NULL ORDER BY position, createdAt',
    [day(clock().toLocal())],
  )).map(CounterProject.new).toList();

  @override
  Future<void> saveProject(String name, String? imagePath, {String? id}) async {
    if (name.trim().isEmpty || name.trim().length > 80) {
      throw ArgumentError('name');
    }
    final time = now;
    if (id == null) {
      await db.transaction((tx) async {
        final rows = await tx.rawQuery(
          'SELECT COALESCE(MAX(position), -1) + 1 AS n FROM projects',
        );
        await tx.insert('projects', {
          ...meta(time),
          'name': name.trim(),
          'imagePath': imagePath,
          'position': rows.first['n'],
          'total': 0,
        });
      });
    } else {
      await db.update(
        'projects',
        {
          'name': name.trim(),
          'imagePath': imagePath,
          'updatedAt': time,
          'syncStatus': 'pending',
        },
        where: 'id = ? AND deletedAt IS NULL',
        whereArgs: [id],
      );
    }
  }

  @override
  Future<void> deleteProject(String id) async {
    await db.transaction((tx) async {
      final time = now;
      for (final table in [
        'count_changes',
        'count_events',
        'sessions',
        'corrections',
        'projects',
      ]) {
        await tx.update(
          table,
          {'deletedAt': time, 'updatedAt': time, 'syncStatus': 'pending'},
          where: '${table == 'projects' ? 'id' : 'projectId'} = ?',
          whereArgs: [id],
        );
      }
    });
  }

  @override
  Future<void> reorder(List<String> ids) async {
    await db.transaction((tx) async {
      for (var i = 0; i < ids.length; i++) {
        await tx.update(
          'projects',
          {'position': i, 'updatedAt': now, 'syncStatus': 'pending'},
          where: 'id = ? AND deletedAt IS NULL',
          whereArgs: [ids[i]],
        );
      }
    });
  }

  @override
  Future<String> beginSession(String projectId, {DateTime? startedAt}) =>
      db.transaction((tx) async {
        final p = (await tx.query(
          'projects',
          where: 'id = ? AND deletedAt IS NULL',
          whereArgs: [projectId],
        )).single;
        final time = (startedAt ?? clock()).toUtc().toIso8601String();
        final row = {
          ...meta(time),
          'projectId': projectId,
          'startAt': time,
          'totalAfter': p['total'],
        };
        await tx.insert('sessions', row);
        return row['id'] as String;
      });

  @override
  Future<int> increment(
    String sessionId, {
    CountSource source = CountSource.screen,
    DateTime? occurredAt,
  }) => db.transaction((tx) async {
    final session = (await tx.query(
      'sessions',
      where: 'id = ? AND endAt IS NULL AND deletedAt IS NULL',
      whereArgs: [sessionId],
    )).single;
    final projectId = session['projectId'];
    final project = (await tx.query(
      'projects',
      where: 'id = ? AND deletedAt IS NULL',
      whereArgs: [projectId],
    )).single;
    final total = (await balanceOf(tx, project)) + 1;
    if (total < 0 || total > maxCount) throw RangeError('count');
    final time = (occurredAt ?? clock()).toUtc().toIso8601String();
    await tx.update(
      'projects',
      {
        'total': total.clamp(0, maxCount),
        'lastRecitedAt': time,
        'updatedAt': time,
        'syncStatus': 'pending',
      },
      where: 'id = ?',
      whereArgs: [projectId],
    );
    await tx.update(
      'sessions',
      {
        'added': (session['added'] as int) + 1,
        'totalAfter': total,
        'updatedAt': time,
        'syncStatus': 'pending',
      },
      where: 'id = ?',
      whereArgs: [sessionId],
    );
    final eventMeta = meta(time);
    await tx.insert('count_events', {
      ...eventMeta,
      'sessionId': sessionId,
      'projectId': projectId,
      'occurredAt': time,
      'localDay': day(DateTime.parse(time).toLocal()),
    });
    await tx.insert('count_changes', {
      ...eventMeta,
      'projectId': projectId,
      'sessionId': sessionId,
      'occurredAt': time,
      'occurredAtMicros': DateTime.parse(time).microsecondsSinceEpoch,
      'delta': 1,
      'source': source.name,
      'beforeValue': total - 1,
      'afterValue': total,
      'originKind': 'count_events',
      'originId': eventMeta['id'],
    });
    await saveBalance(tx, projectId as String, total);
    return total;
  });

  @override
  Future<void> endSession(String sessionId) async {
    final time = now;
    await db.update(
      'sessions',
      {'endAt': time, 'updatedAt': time, 'syncStatus': 'pending'},
      where: 'id = ? AND endAt IS NULL',
      whereArgs: [sessionId],
    );
  }

  @override
  Future<void> correct(
    String projectId,
    CorrectionMode mode,
    int amount,
    String note,
  ) async {
    if (amount < 0 || amount > maxCount) throw RangeError('amount');
    await db.transaction((tx) async {
      final row = (await tx.query(
        'projects',
        where: 'id = ? AND deletedAt IS NULL',
        whereArgs: [projectId],
      )).single;
      final before = await balanceOf(tx, row);
      final after = switch (mode) {
        CorrectionMode.add => before + amount,
        CorrectionMode.subtract => before - amount,
        CorrectionMode.set => amount,
      };
      if ((after - before).abs() > maxCount || after < 0 || after > maxCount) {
        throw RangeError('total');
      }
      final time = now;
      await saveBalance(tx, projectId, after);
      final correctionMeta = meta(time);
      await tx.insert('corrections', {
        ...correctionMeta,
        'projectId': projectId,
        'occurredAt': time,
        'beforeValue': before,
        'delta': after - before,
        'afterValue': after,
        'note': note.trim(),
      });
      await tx.insert('count_changes', {
        ...correctionMeta,
        'projectId': projectId,
        'occurredAt': time,
        'occurredAtMicros': DateTime.parse(time).microsecondsSinceEpoch,
        'delta': after - before,
        'source': 'manual_${mode.name}',
        'beforeValue': before,
        'afterValue': after,
        'note': note.trim(),
        'originKind': 'corrections',
        'originId': correctionMeta['id'],
      });
      await tx.update(
        'projects',
        {'total': after, 'updatedAt': time, 'syncStatus': 'pending'},
        where: 'id = ?',
        whereArgs: [projectId],
      );
    });
  }

  @override
  Future<List<Map<String, Object?>>> history(
    String projectId,
  ) async => db.rawQuery(
    "SELECT 'session' AS kind, startAt AS occurredAt, endAt, added AS delta, "
    'totalAfter AS afterValue, totalAfter - added AS beforeValue, NULL AS note '
    'FROM sessions WHERE projectId = ? AND added > 0 AND deletedAt IS NULL '
    "UNION ALL SELECT 'correction', occurredAt, NULL, delta, afterValue, beforeValue, note "
    'FROM corrections WHERE projectId = ? AND deletedAt IS NULL ORDER BY occurredAt DESC',
    [projectId, projectId],
  );

  @override
  Future<List<Map<String, Object?>>> changes(
    String projectId, {
    DateTime? from,
    DateTime? until,
    int limit = 100,
    int offset = 0,
  }) async {
    if (limit < 1 || limit > 500 || offset < 0) {
      throw ArgumentError('pagination');
    }
    final where = ['projectId = ?', 'deletedAt IS NULL'];
    final args = <Object?>[projectId];
    if (from != null) {
      where.add('occurredAtMicros >= ?');
      args.add(from.microsecondsSinceEpoch);
    }
    if (until != null) {
      where.add('occurredAtMicros < ?');
      args.add(until.microsecondsSinceEpoch);
    }
    return db.query(
      'count_changes',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'occurredAtMicros DESC, id DESC',
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<Map<String, String>> settings() async => {
    for (final row in await db.query('settings', where: 'deletedAt IS NULL'))
      row['settingKey'] as String: row['value'] as String,
  };

  @override
  Future<void> saveSetting(String key, String value) async {
    final time = now;
    await db.transaction((tx) async {
      final existing = await tx.query(
        'settings',
        where: 'settingKey = ?',
        whereArgs: [key],
      );
      if (existing.isEmpty) {
        await tx.insert('settings', {
          ...meta(time),
          'settingKey': key,
          'value': value,
        });
      } else {
        await tx.update(
          'settings',
          {'value': value, 'updatedAt': time, 'syncStatus': 'pending'},
          where: 'settingKey = ?',
          whereArgs: [key],
        );
      }
    });
  }
}
