import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local conversation metadata only. File bytes never enter this store.
class TransferActivity extends ChangeNotifier {
  TransferActivity._(this.userId);
  static final _accounts = <String, TransferActivity>{};
  static TransferActivity forUser(String userId) =>
      _accounts.putIfAbsent(userId, () => TransferActivity._(userId));
  final String userId;
  final Map<String, Map<String, dynamic>> records = {};
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  String get _key => 'chat.transfer.activity.$userId';

  Future<void> load() => _loading ??= () async {
    final preferences = await SharedPreferences.getInstance();
    try {
      final rows = jsonDecode(preferences.getString(_key) ?? '[]') as List;
      for (final row in rows) {
        final data = Map<String, dynamic>.from(row as Map);
        if (![
          'complete',
          'cancelled',
          'failed',
          'paused',
        ].contains(data['state'])) {
          data['state'] = 'interrupted';
        }
        records.putIfAbsent(data['id'] as String, () => data);
      }
      notifyListeners();
    } catch (_) {
      // A damaged summary must not prevent access to the actual transfer journal.
    }
  }();

  void update({
    required String id,
    required String name,
    required String state,
    int bytes = 0,
    int size = 0,
    String? savedPath,
  }) {
    final old = records[id];
    if (old?['state'] == state &&
        old?['bytes'] == bytes &&
        old?['path'] == savedPath) {
      return;
    }
    final changedState = old?['state'] != state;
    records[id] = {
      'id': id,
      'name': name,
      'state': state,
      'bytes': bytes,
      'size': size,
      'at': changedState
          ? DateTime.now().toUtc().toIso8601String()
          : old!['at'],
      'path': ?savedPath,
    };
    notifyListeners();
    if (!changedState && old?['path'] == savedPath) return;
    _writes = _writes
        .then((_) async {
          await load();
          final preferences = await SharedPreferences.getInstance();
          await preferences.setString(
            _key,
            jsonEncode(sortedRecords.take(100).toList()),
          );
        })
        .catchError((Object error) {
          debugPrint('Transfer summary: $error');
        });
  }

  List<Map<String, dynamic>> get sortedRecords =>
      records.values.toList()
        ..sort((a, b) => (b['at'] as String).compareTo(a['at'] as String));
  Map<String, dynamic>? get latest => sortedRecords.firstOrNull;
  Future<void> get flushed => _writes;
}
