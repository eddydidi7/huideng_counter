import '../services/chat_guest_session.dart';
import 'package:huideng_connection/connection_router.dart';
import 'package:huideng_connection/routed_transport.dart';
import 'sync_diagnostics.dart';
import '../data/sync/notes_sync.dart';
import '../data/remote/supabase_notes_gateway.dart';
import 'dart:async';
import 'dart:io';
import '../data/remote/notices_remote.dart';
import '../data/remote/app_links_remote.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;
import 'app_controller.dart';
import '../data/local/account_database_manager.dart';
import '../data/remote/secure_auth_storage.dart';
import '../data/remote/supabase_sync_gateway.dart';
import '../data/repositories/sqlite_counter_repository.dart';
import '../data/sync/local_sync_store.dart';
import '../data/sync/sync_coordinator.dart';
import '../data/sync/snapshot_builder.dart';
import '../data/sync/remote_projector.dart';
import '../data/remote/home_message_remote.dart';

class CloudController extends ChangeNotifier with WidgetsBindingObserver {
  static const projectUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://duakhsuncmbabxomynkr.supabase.co',
  );
  static const publicKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_edd7ITfdqt7vV-O67CQtrw_ysYLTrJR',
  );

  static final connection = ConnectionRouter(
    canonical: Uri.parse(projectUrl),
    project: projectUrl,
    publicKey: const String.fromEnvironment('CONNECTION_CONFIG_PUBLIC_KEY'),
    sources: const String.fromEnvironment('CONNECTION_CONFIG_URLS')
        .split(',')
        .where((s) => s.trim().isNotEmpty)
        .take(4)
        .map((s) => Uri.parse(s.trim()))
        .toList(),
  );
  static SyncHttpClient networkClient() =>
      SyncHttpClient(inner: RoutedHttpClient(connection));

  static SupabaseClient isolatedAuthClient() => SupabaseClient(
    projectUrl,
    publicKey,
    httpClient: networkClient(),
    authOptions: const AuthClientOptions(
      autoRefreshToken: false,
      authFlowType: AuthFlowType.implicit,
    ),
  );
  final AppController app;
  final AccountDatabaseManager databases;
  SupabaseClient? client;
  SyncCoordinator? worker;
  NotesSync? notesWorker;
  StreamSubscription<AuthState>? subscription;
  String? userId, email;
  String status = 'initializing';
  String? lastSync;
  int pending = 0, conflicts = 0;
  bool busy = false, ready = false, _disposed = false;
  CloudController(this.app, this.databases) {
    WidgetsBinding.instance.addObserver(this);
  }
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      SyncDiagnostics.file = File(
        p.join(databases.root.path, 'sync-diagnostics.jsonl'),
      );
      await connection.initialize();
      await Supabase.initialize(
        url: projectUrl,
        publishableKey: publicKey,
        realtimeClientOptions: RealtimeClientOptions(
          transport: (url, headers) =>
              routedWebSocket(connection, url, headers),
        ),
        httpClient: networkClient(),
        authOptions: const FlutterAuthClientOptions(
          localStorage: SecureAuthStorage(),
          detectSessionInUri: true,
        ),
      );
      client = Supabase.instance.client;
      connection.addListener(_connectionChanged);
      app.notices?.repository.remote = NoticesRemote(client!);
      unawaited(app.notices?.refresh() ?? Future<void>.value());
      app.appLinks?.repository.remote = AppLinksRemote(client!);
      unawaited(app.appLinks?.refresh() ?? Future<void>.value());
      app.homeMessage?.repository.remote = HomeMessageRemote(client!);
      unawaited(app.homeMessage?.refresh() ?? Future<void>.value());
      final offline = await SecureAuthStorage.vault.read(
        key: 'huideng.offline.user',
      );
      final current = client!.auth.currentUser;
      final saved = current?.isAnonymous == true
          ? offline
          : (current?.id ?? offline);
      if (saved != null) {
        await _activate(saved, client!.auth.currentUser?.email);
      }
      ready = true;
      status = userId == null
          ? 'guest'
          : client!.auth.currentUser?.id == userId
          ? 'ready'
          : 'authentication_required';
      subscription = client!.auth.onAuthStateChange.listen(
        (state) async {
          SyncDiagnostics.record('auth_state', {
            'user_id': state.session?.user.id,
            'event': state.event.name,
            'session_present': state.session != null,
            'expired': state.session?.isExpired,
          });
          // beginGuestRegistration's updateUser() call flips is_anonymous
          // synchronously (Supabase Auth "Confirm email" must be off — see
          // deployment notes); this fires *some* auth event here. Rather
          // than guess which one, just recognise "this session matches the
          // pending guest upgrade" on any event where the user is no longer
          // anonymous.
          if (!busy && state.session != null && !state.session!.user.isAnonymous) {
            final pendingUpgrade = await SecureAuthStorage.vault.read(
              key: 'huideng.guest-upgrade.user-id',
            );
            if (pendingUpgrade != null &&
                pendingUpgrade == state.session!.user.id) {
              try {
                if (userId != pendingUpgrade || notesWorker == null) {
                  await _activate(pendingUpgrade, state.session!.user.email);
                }
                notesWorker?.authenticationChanged();
                await SecureAuthStorage.vault.delete(
                  key: 'huideng.guest-upgrade.user-id',
                );
                unawaited(syncNow());
              } catch (e) {
                SyncDiagnostics.record('guest_upgrade_auto_activate_error', {
                  'error_type': e.runtimeType.toString(),
                });
              }
            }
          }
          if (!busy &&
              state.session != null &&
              !state.session!.user.isAnonymous &&
              [
                AuthChangeEvent.signedIn,
                AuthChangeEvent.initialSession,
              ].contains(state.event)) {
            try {
              if (userId != state.session!.user.id || notesWorker == null) {
                await _activate(
                  state.session!.user.id,
                  state.session!.user.email,
                );
              }
              notesWorker?.authenticationChanged();
            } catch (e) {
              SyncDiagnostics.record('auth_activate_error', {
                'error_type': e.runtimeType.toString(),
              });
              status = 'unavailable';
              changed();
            }
          }
          if (state.event == AuthChangeEvent.tokenRefreshed &&
              state.session?.user.id == userId) {
            worker?.credentialsRefreshed();
            unawaited(notesWorker?.wake(force: true) ?? Future<void>.value());
          }
          if (state.event == AuthChangeEvent.signedOut && userId != null) {
            notesWorker?.authenticationChanged();
            status = 'authentication_required';
            changed();
          }
        },
        onError: (Object e) {
          SyncDiagnostics.record('auth_stream_error', {
            'error_type': e.runtimeType.toString(),
          });
          notesWorker?.authenticationChanged();
          status = 'authentication_required';
          changed();
        },
      );
    } catch (e) {
      SyncDiagnostics.record('cloud_initialize_error', {
        'error_type': e.runtimeType.toString(),
      });
      status = 'unavailable';
    }
    changed();
  }

  Future<void> _activate(String id, String? address) async {
    if (client?.auth.currentUser?.isAnonymous == true &&
        client?.auth.currentUser?.id == id) {
      throw StateError('Guest chat cannot activate account sync');
    }
    worker?.stop();
    notesWorker?.stop();
    await worker?.waitUntilIdle();
    await notesWorker?.waitUntilIdle();
    final db = await databases.open(id);
    final repo = SqliteCounterRepository(db);
    await repo.recoverSessions();
    userId = id;
    email = address;
    await SecureAuthStorage.vault.write(key: 'huideng.offline.user', value: id);
    await app.switchRepository(repo, id);
    final store = LocalSyncStore(db);
    final projector = RemoteProjector(id);
    worker = SyncCoordinator(
      local: store,
      remote: SupabaseSyncGateway(
        client!,
        id,
        Directory(p.join(databases.accountPath(id), 'images')),
      ),
      userId: id,
      authenticatedUserId: () => client?.auth.currentUser?.id,
      snapshot: SyncSnapshots(store).build,
      consume: projector.apply,
      onStatus: (value) {
        status = value;
        unawaited(refresh());
      },
    );
    notesWorker = NotesSync(
      db,
      SupabaseNotesGateway(client!, id),
      id,
      () => client?.auth.currentUser?.id,
      onChanged: () {
        unawaited(app.reload());
        changed();
      },
    );
    notesWorker!.start();
    worker!.start();
    await refresh();
  }

  Future<void> connectGuestChat() async {
    if (!ready || busy || client == null) {
      throw StateError('Chat initialization pending');
    }
    if (client!.auth.currentUser != null) return;
    busy = true;
    changed();
    try {
      await ChatGuestSession.ensure(client!);
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> signIn(String address, String password) async {
    if (!ready || busy) return;
    busy = true;
    worker?.stop();
    notesWorker?.stop();
    changed();
    try {
      final result = await client!.auth.signInWithPassword(
        email: address.trim(),
        password: password,
      );
      if (result.user == null) throw StateError('No user');
      await _activate(result.user!.id, result.user!.email);
    } finally {
      busy = false;
      if (userId != null && userId == client?.auth.currentUser?.id) {
        worker?.start();
        notesWorker?.start();
      }
      changed();
    }
  }

  Future<void> register(String address, String password) async {
    if (!ready || busy) return;
    busy = true;
    changed();
    try {
      final result = await client!.auth.signUp(
        email: address.trim(),
        password: password,
        emailRedirectTo: 'huideng://login-callback',
      );
      if (result.session != null) {
        await _activate(result.user!.id, result.user!.email);
      }
    } finally {
      busy = false;
      changed();
    }
  }

  /// Converts the existing anonymous Auth user in place.  We must never call
  /// signUp here: that creates a second auth.users UUID and therefore a second
  /// chat profile/personal number.  updateUser preserves auth.uid(), so every
  /// foreign-key relationship (friends, groups, messages and posts) remains
  /// attached to the same person.
  Future<void> beginGuestRegistration(String address, String password) async {
    if (!ready || busy || client == null) throw StateError('AUTH_NOT_READY');
    await connectGuestChat();
    final current = client!.auth.currentUser;
    if (current == null || !current.isAnonymous) {
      throw StateError('GUEST_UPGRADE_REQUIRED');
    }
    busy = true;
    changed();
    try {
      await SecureAuthStorage.vault.write(
        key: 'huideng.guest-upgrade.user-id',
        value: current.id,
      );
      await client!.auth.updateUser(
        UserAttributes(email: address.trim(), password: password),
      );
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> signOut() async {
    if (busy) return;
    busy = true;
    worker?.stop();
    notesWorker?.stop();
    changed();
    try {
      await worker?.waitUntilIdle();
      await notesWorker?.waitUntilIdle();
      await client?.auth.signOut(scope: SignOutScope.local);
      await SecureAuthStorage.vault.delete(key: 'huideng.offline.user');
      worker = null;
      notesWorker = null;
      userId = null;
      email = null;
      pending = 0;
      conflicts = 0;
      lastSync = null;
      status = 'guest';
      await app.switchRepository(
        SqliteCounterRepository(databases.guest),
        'guest',
      );
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> refresh() async {
    final id = userId;
    if (id == null || _disposed) return;
    try {
      final db = await databases.open(id);
      final queue = await db.query('sync_queue');
      final states = await db.query(
        'sync_state',
        where: 'user_id=?',
        whereArgs: [id],
      );
      if (id != userId || _disposed) return;
      pending = queue.length;
      conflicts = queue.where((r) => r['state'] == 'conflict').length;
      lastSync = states.single['last_sync_at'] as String?;
      await app.reload();
      changed();
    } catch (e) {
      SyncDiagnostics.record('local_sync_state_error', {
        'error_type': e.runtimeType.toString(),
      });
      status = 'local_error';
      changed();
    }
  }

  Future<void> syncNotes() async {
    if (busy) return;
    if (client?.auth.currentSession == null ||
        client?.auth.currentUser?.isAnonymous == true) {
      notesWorker?.authenticationChanged();
      status = 'authentication_required';
      changed();
      return;
    }
    try {
      if (notesWorker == null) {
        await _activate(
          client!.auth.currentUser!.id,
          client!.auth.currentUser!.email,
        );
      }
      await notesWorker?.wake(force: true);
    } catch (e) {
      SyncDiagnostics.record('notes_manual_retry_error', {
        'error_type': e.runtimeType.toString(),
      });
      status = 'unavailable';
      changed();
    }
  }

  Future<void> syncNow() async {
    await worker?.wake();
    await notesWorker?.wake(force: true);
    await refresh();
  }

  Future<void> importGuest() async {
    if (userId == null || busy) return;
    busy = true;
    changed();
    worker?.stop();
    notesWorker?.stop();
    try {
      await worker?.waitUntilIdle();
      await notesWorker?.waitUntilIdle();
      await databases.importGuest(userId!);
      await refresh();
    } finally {
      busy = false;
      worker?.start();
      notesWorker?.start();
      changed();
    }
  }

  Future<List<Map<String, Object?>>> conflictRows() async {
    if (userId == null) return [];
    return (await databases.open(userId!)).query(
      'sync_conflicts',
      where: 'resolved_at IS NULL',
      orderBy: 'created_at DESC',
    );
  }

  Future<void> resolve(
    Map<String, Object?> conflict, {
    required bool keepLocal,
  }) async {
    final id = userId;
    if (id == null || busy) return;
    busy = true;
    changed();
    worker?.stop();
    notesWorker?.stop();
    await worker?.waitUntilIdle();
    await notesWorker?.waitUntilIdle();
    final db = await databases.open(id);
    try {
      await db.transaction((tx) async {
        final kind = conflict['entity_type'] as String,
            entity = conflict['entity_id'] as String;
        if (!['project', 'setting', 'order', 'session'].contains(kind)) {
          throw StateError('This conflict needs a corrected local edit');
        }
        final remote = await tx.query(
          'cloud_documents',
          where: 'kind=? AND id=?',
          whereArgs: [kind, entity],
        );
        if (remote.isEmpty) {
          throw StateError('Pull remote data before resolving');
        }
        final current = remote.single;
        await tx.insert('sync_remote_versions', {
          'entity_type': kind,
          'entity_id': entity,
          'server_revision': current['revision'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        if (keepLocal) {
          await enqueue(tx, kind, entity);
        } else {
          await tx.delete(
            'sync_queue',
            where: 'entity_type=? AND entity_id=?',
            whereArgs: [kind, entity],
          );
          await tx.update('sync_scope', {'applying_remote': 1});
          await RemoteProjector(id).document(
            tx,
            kind,
            entity,
            jsonMap(current['payload']),
            current['revision'] as int,
            force: true,
          );
          await tx.update('sync_scope', {'applying_remote': 0});
        }
        await tx.update(
          'sync_conflicts',
          {'resolved_at': DateTime.now().toUtc().toIso8601String()},
          where: 'entity_type=? AND entity_id=?',
          whereArgs: [kind, entity],
        );
      });
      await refresh();
    } finally {
      busy = false;
      worker?.start();
      notesWorker?.start();
      changed();
    }
  }

  bool _reconnecting = false;
  void _connectionChanged() {
    if (_disposed) return;
    changed();
    // Keep the existing Supabase client, auth session and channel registrations.
    if (!_reconnecting && client != null) unawaited(_reconnectRealtime());
  }

  Future<void> _reconnectRealtime() async {
    _reconnecting = true;
    try {
      // Closing the transport (not Realtime.disconnect) lets the SDK rejoin
      // registered channels using its normal backoff and the new routed URL.
      await client!.realtime.conn?.sink.close(1012, 'Connection route changed');
    } catch (_) {
      /* Realtime has its own reconnect backoff. */
    } finally {
      _reconnecting = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(connection.refresh());
      worker?.start();
      notesWorker?.start();
      worker?.credentialsRefreshed();
      unawaited(notesWorker?.wake(force: true) ?? Future<void>.value());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      worker?.stop();
      notesWorker?.stop();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    connection.removeListener(_connectionChanged);
    worker?.stop();
    notesWorker?.stop();
    subscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
