import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'local_sync_store.dart';

class PushReply {
  final int? revision;
  final Map<String, Object?>? result;
  final String? conflict;
  final Map<String, Object?>? remote;
  const PushReply.accepted(int this.revision, [this.result])
    : conflict = null,
      remote = null;
  const PushReply.conflict(String this.conflict, this.remote)
    : revision = null,
      result = null;
}

class PullPage {
  final int nextCursor;
  final List<Map<String, Object?>> changes;
  final bool hasMore;
  const PullPage(this.nextCursor, this.changes, {required this.hasMore});
}

class SyncFailure implements Exception {
  final String code;
  final bool authenticationRequired;
  final Duration? retryAfter;
  const SyncFailure(
    this.code, {
    this.authenticationRequired = false,
    this.retryAfter,
  });
}

/// Supabase adapter will implement these RPCs using a client scoped to one user.
abstract interface class SyncGateway {
  Future<PushReply> push(SyncJob job);
  Future<PullPage> pull(int after);
}

typedef PageConsumer =
    Future<void> Function(Transaction tx, List<Map<String, Object?>> changes);

/// No dependency on Flutter, sockets, Android or Windows. Foreground integration
/// calls start()/stop(); resume and connectivity changes call wake().
/// Not wired to the app until auth, metadata snapshots and pull projection exist.
class SyncCoordinator {
  final LocalSyncStore local;
  final SyncGateway remote;
  final String userId;
  final String? Function() authenticatedUserId;
  final SnapshotBuilder snapshot;
  final PageConsumer consume;
  final void Function(String status)? onStatus;
  Timer? _timer;
  bool _running = false, _enabled = false, _authPaused = false;
  int _epoch = 0;
  DateTime? _pullRetryAt;
  int _pullAttempts = 0;
  SyncCoordinator({
    required this.local,
    required this.remote,
    required this.userId,
    required this.authenticatedUserId,
    required this.snapshot,
    required this.consume,
    this.onStatus,
  });

  bool _valid(int epoch) =>
      _enabled &&
      !_authPaused &&
      _epoch == epoch &&
      authenticatedUserId() == userId;
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
    _timer = null;
  }

  Future<void> waitUntilIdle() async {
    while (_running) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void credentialsRefreshed() {
    _authPaused = false;
    unawaited(wake());
  }

  Future<void> wake() async {
    final epoch = _epoch;
    if (_running || !_valid(epoch)) return;
    _running = true;
    try {
      for (var i = 0; i < 50 && _valid(epoch); i++) {
        final job = await local.next(userId, snapshot);
        if (job == null || !_valid(epoch)) break;
        try {
          final reply = await remote
              .push(job)
              .timeout(const Duration(seconds: 20));
          if (!_valid(epoch)) return;
          if (reply.conflict != null) {
            await local.conflict(job, reply.conflict!, reply.remote);
          } else {
            await local.acknowledge(job, reply.revision!, result: reply.result);
          }
        } catch (error) {
          if (!_valid(epoch)) return;
          if (error is SyncFailure && error.authenticationRequired) {
            _authPaused = true;
            onStatus?.call('authentication_required');
            return;
          }
          await local.retry(
            job,
            error is SyncFailure ? error.code : 'transport_error',
            retryAfter: error is SyncFailure ? error.retryAfter : null,
          );
          onStatus?.call('retry_pending');
          break;
        }
      }
      if (!_valid(epoch) ||
          (_pullRetryAt != null && local.clock().isBefore(_pullRetryAt!))) {
        return;
      }
      for (var pageNumber = 0; pageNumber < 10 && _valid(epoch); pageNumber++) {
        final state = (await local.db.query(
          'sync_state',
          where: 'user_id = ?',
          whereArgs: [userId],
        )).single;
        final cursor = state['pull_cursor'] as int;
        final page = await remote
            .pull(cursor)
            .timeout(const Duration(seconds: 20));
        if (!_valid(epoch)) return;
        if (page.hasMore && page.nextCursor <= cursor) {
          throw StateError('Non-advancing page');
        }
        await local.applyPage(
          userId,
          cursor,
          page.nextCursor,
          (tx) => consume(tx, page.changes),
        );
        _pullAttempts = 0;
        _pullRetryAt = null;
        if (!page.hasMore) {
          await local.completeCycle(userId);
          onStatus?.call('cycle_finished');
          break;
        }
      }
    } catch (error) {
      if (_valid(epoch)) {
        if (error is SyncFailure && error.authenticationRequired) {
          _authPaused = true;
          onStatus?.call('authentication_required');
        } else {
          _pullAttempts = (_pullAttempts + 1).clamp(1, 10);
          _pullRetryAt = local.clock().add(
            Duration(seconds: (1 << _pullAttempts).clamp(2, 3600)),
          );
          onStatus?.call('retry_pending');
        }
      }
    } finally {
      _running = false;
    }
  }
}
