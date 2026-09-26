const maxCount = 9007199254740991;

class CounterProject {
  final String id, name;
  final String? imagePath;
  final int total, today, position;
  final BigInt balance;
  String get displayTotal => balance.toString();
  bool get needsReview =>
      balance < BigInt.zero || balance > BigInt.from(maxCount);
  final DateTime? lastRecitedAt;
  CounterProject(Map<String, Object?> row)
    : id = row['id'] as String,
      name = row['name'] as String,
      imagePath = row['imagePath'] as String?,
      balance = BigInt.parse('${row['eventBalance'] ?? row['total']}'),
      total =
          int.tryParse('${row['eventBalance'] ?? row['total']}') ??
          row['total'] as int,
      today = (row['today'] as int?) ?? 0,
      position = row['position'] as int,
      lastRecitedAt = row['lastRecitedAt'] == null
          ? null
          : DateTime.parse(row['lastRecitedAt'] as String).toLocal();
}

enum CorrectionMode { add, subtract, set }

enum CountSource { volumeUp, volumeDown, screen, keyboard }

abstract class CounterRepository {
  Future<List<CounterProject>> projects();
  Future<void> saveProject(String name, String? imagePath, {String? id});
  Future<void> deleteProject(String id);
  Future<void> reorder(List<String> ids);
  Future<String> beginSession(String projectId, {DateTime? startedAt});
  Future<int> increment(
    String sessionId, {
    CountSource source = CountSource.screen,
    DateTime? occurredAt,
  });
  Future<void> endSession(String sessionId);
  Future<void> correct(
    String projectId,
    CorrectionMode mode,
    int amount,
    String note,
  );
  Future<List<Map<String, Object?>>> history(String projectId);
  Future<List<Map<String, Object?>>> changes(
    String projectId, {
    DateTime? from,
    DateTime? until,
    int limit = 100,
    int offset = 0,
  });
  Future<Map<String, String>> settings();
  Future<void> saveSetting(String key, String value);
}
