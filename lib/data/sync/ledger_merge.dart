import 'dart:convert';
import '../../domain/models.dart';

/// Pure merge policy, shared by future Android/Windows/iOS sync consumers.
/// Negative/overflow balances are reported, never clamped or silently discarded.
class LedgerMerge {
  final List<Map<String, Object?>> events;
  final BigInt balance;
  LedgerMerge(this.events, this.balance);
  bool get requiresResolution =>
      balance < BigInt.zero || balance > BigInt.from(maxCount);

  static LedgerMerge combine(
    String userId,
    String projectId,
    Iterable<Map<String, Object?>> local,
    Iterable<Map<String, Object?>> remote,
  ) {
    final byId = <String, Map<String, Object?>>{};
    final fingerprints = <String, String>{};
    var balance = BigInt.zero;
    for (final row in [...local, ...remote]) {
      if (row['user_id'] != userId || row['project_id'] != projectId) {
        throw StateError('Cross-account/project event rejected');
      }
      final id = row['id'];
      final delta = row['delta'];
      if (id is! String ||
          id.isEmpty ||
          delta is! int ||
          delta.abs() > maxCount) {
        throw FormatException('Invalid event');
      }
      final canonical = <String, Object?>{
        for (final key in [
          'id',
          'user_id',
          'project_id',
          'delta',
          'count_after',
          'created_at',
          'updated_at',
          'occurred_at',
          'device_id',
          'source',
          'session_id',
          'note',
        ])
          key: row[key],
      };
      // PostgreSQL and Dart can serialize the same instant with different offsets.
      for (final field in ['created_at', 'updated_at', 'occurred_at']) {
        final value = canonical[field];
        if (value is String) {
          canonical[field] = DateTime.parse(value).toUtc().toIso8601String();
        }
      }
      final fingerprint = jsonEncode(canonical);
      if (fingerprints.containsKey(id)) {
        if (fingerprints[id] != fingerprint) {
          throw StateError('UUID payload mismatch: $id');
        }
        continue;
      }
      fingerprints[id] = fingerprint;
      byId[id] = Map.unmodifiable(row);
      balance += BigInt.from(delta);
    }
    return LedgerMerge(List.unmodifiable(byId.values), balance);
  }
}
