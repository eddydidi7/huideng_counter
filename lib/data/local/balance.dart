import 'package:sqflite/sqflite.dart';
import '../../domain/models.dart';

Future<int> balanceOf(DatabaseExecutor tx, Map<String, Object?> project) async {
  final rows = await tx.query(
    'ledger_balances',
    where: 'project_id = ?',
    whereArgs: [project['id']],
  );
  return rows.isEmpty
      ? project['total'] as int
      : int.parse(rows.single['balance'] as String);
}

Future<void> saveBalance(DatabaseExecutor tx, String id, int value) async {
  await tx.insert('ledger_balances', {
    'project_id': id,
    'balance': '$value',
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  await tx.update(
    'projects',
    {'total': value.clamp(0, maxCount)},
    where: 'id = ?',
    whereArgs: [id],
  );
}
