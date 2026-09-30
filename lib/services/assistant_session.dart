import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'resumable_transfer.dart';
import 'transfer_activity.dart';

/// 文件传输助手: moves files between this account's own devices.
/// Signalling via device_transfer_v1 (migration 202609250073); file bytes go
/// only over the WebRTC data channel - a LAN path on the same Wi-Fi (ICE
/// prefers host candidates), otherwise a direct P2P path. There is no TURN
/// relay and never a cloud-storage fallback.
class AssistantApi {
  AssistantApi(this.client, this.deviceId);
  final SupabaseClient client;
  final String deviceId;

  static Future<AssistantApi> open(SupabaseClient client) async {
    final user = client.auth.currentUser?.id;
    if (user == null) throw const AuthException('login_required');
    final prefs = await SharedPreferences.getInstance();
    final key = 'assistant.device.$user';
    var id = prefs.getString(key);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(key, id);
    }
    return AssistantApi(client, id);
  }

  Future<Map<String, dynamic>> call(String action, [Map<String, dynamic> data = const {}]) async {
    final value = await client
        .rpc('device_transfer_v1', params: {
          'p_action': action,
          'p_data': {'device_id': deviceId, ...data},
        })
        .timeout(const Duration(seconds: 15));
    return Map<String, dynamic>.from(value as Map);
  }

  static Future<({String name, String platform})> describe() async {
    final info = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        return (name: '${a.brand} ${a.model}'.trim(), platform: 'android');
      }
      if (Platform.isWindows) {
        final w = await info.windowsInfo;
        return (name: w.computerName, platform: 'windows');
      }
      if (Platform.isIOS) return (name: (await info.iosInfo).name, platform: 'ios');
      if (Platform.isMacOS) return (name: (await info.macOsInfo).computerName, platform: 'macos');
    } catch (_) {}
    return (name: Platform.localHostname, platform: Platform.operatingSystem);
  }

  Future<Map<String, dynamic>> heartbeat() async {
    final d = await describe();
    return call('heartbeat', {'name': d.name, 'platform': d.platform});
  }
}

/// Unfinished transfers on this device, so a transfer survives an app
/// restart and resumes where the receiver's verified prefix ends.
class AssistantRegistry {
  static Future<File> _file() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'assistant_transfers.json'));

  static Future<List<Map<String, dynamic>>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      return [for (final r in jsonDecode(await f.readAsString()) as List) Map<String, dynamic>.from(r as Map)];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<Map<String, dynamic>> rows) async {
    final f = await _file();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(rows), flush: true);
    await tmp.rename(f.path);
  }

  static Future<void> upsert(Map<String, dynamic> record) async {
    final rows = await load();
    rows.removeWhere((r) => r['id'] == record['id']);
    rows.add(record);
    await _save(rows);
  }

  static Future<void> remove(String id) async {
    final rows = await load();
    rows.removeWhere((r) => r['id'] == id);
    await _save(rows);
  }
}

Future<Directory> assistantReceiveDirectory() async {
  Directory? base;
  try {
    base = Platform.isAndroid ? await getExternalStorageDirectory() : await getDownloadsDirectory();
  } catch (_) {}
  base ??= await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(base.path, '文殊传输'));
  await dir.create(recursive: true);
  return dir;
}

class AssistantSession extends ChangeNotifier implements TransferLink {
  AssistantSession({required this.api, required this.record, this.peerFactory});
  final AssistantApi api;
  final Map<String, dynamic> record;
  final Future<RTCPeerConnection> Function(Map<String, dynamic>)? peerFactory;

  bool get sending => record['role'] == 'send';
  String get id => record['id'] as String;
  String get name => record['name'] as String;
  int get size => (record['size'] as num).toInt();
  int get block => (record['block'] as num?)?.toInt() ?? assistantBlockBytes;

  /// waiting | connecting | transferring | paused | interrupted | unreachable
  /// | verifying | complete | cancelled | failed
  String state = 'connecting';
  String? route, savedPath, error;
  bool paused = false, _closed = false, _connected = false, _polling = false, _running = false;
  int bytes = 0, _cursor = 0, _epoch = 0, _attempts = 0;
  double speed = 0;
  int _speedBytes = 0;
  DateTime _speedAt = DateTime.now(), _attemptAt = DateTime.fromMillisecondsSinceEpoch(0);
  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  final _ice = <RTCIceCandidate>[];
  bool _remoteSet = false;
  Timer? _poll, _ticker;
  BlockSender? _sender;
  BlockReceiver? _receiver;
  ReceiverProtocol? _protocol;
  LargeSource? _source;
  Future<void> _incoming = Future.value();

  bool get ended => ['complete', 'cancelled', 'failed'].contains(state);
  int? get remainingSeconds => speed > 1 ? ((size - bytes) / speed).ceil() : null;

  Future<void> start() async {
    try {
      if (size < 1 || size > assistantMaxFileBytes) throw StateError('FILE_SIZE');
      if (sending) {
        _source = LargeSource.fromReference(record['source'] as String);
        if (await _source!.length() != size) throw StateError('SOURCE_CHANGED');
        _sender = BlockSender(source: _source!, size: size, block: block);
        state = 'waiting';
      } else {
        _receiver = BlockReceiver(partPath: record['part'] as String, size: size, block: block);
        await _receiver!.open();
        bytes = _receiver!.verifiedBytes;
        _protocol = ReceiverProtocol(
          _receiver!,
          this,
          onVerifying: () => _set('verifying'),
          onComplete: _finishReceive,
        );
        await api.call('accept', {'id': id});
        state = 'connecting';
      }
      _changed();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _measure());
      _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => unawaited(_tick()));
      await _tick();
    } catch (e) {
      await _fail(e);
    }
  }

  void _set(String value) {
    state = value;
    _changed();
  }

  void _changed() {
    if (!_closed) notifyListeners();
  }

  void _measure() {
    bytes = sending ? (_sender?.ackedBytes ?? bytes) : (_receiver?.verifiedBytes ?? bytes);
    final now = DateTime.now(), ms = now.difference(_speedAt).inMilliseconds;
    if (ms >= 1000) {
      speed = state == 'transferring' ? (bytes - _speedBytes) * 1000 / ms : 0;
      _speedBytes = bytes;
      _speedAt = now;
    }
    _changed();
  }

  Future<void> _post(Map<String, dynamic> payload) =>
      api.call('signal', {'id': id, 'nonce': const Uuid().v4(), 'payload': payload});

  Future<void> _tick() async {
    if (_closed || _polling || ended) return;
    _polling = true;
    try {
      final r = await api.call('poll', {'id': id, 'after': _cursor});
      final serverState = r['state'] as String?;
      if (serverState == 'cancelled' || serverState == 'expired') {
        await _end('cancelled', discard: true);
        return;
      }
      if (serverState == 'complete' && sending && state != 'complete') {
        await _end('complete');
        return;
      }
      for (final s in r['signals'] as List? ?? []) {
        await _signal(Map<String, dynamic>.from(s['payload'] as Map));
        _cursor = (s['seq'] as num).toInt();
      }
      // The sender drives (re)connection; the receiver answers offers.
      if (sending && serverState == 'accepted' && !_connected) {
        final due = DateTime.now().difference(_attemptAt) > const Duration(seconds: 20);
        if (r['peer_online'] != true) {
          _set('interrupted');
        } else if (_pc == null || due) {
          if (_attempts >= 3 && state != 'connecting') {
            _set('unreachable');
          } else {
            await _connect();
          }
        }
      }
    } catch (e) {
      error = e.toString();
      if (!_connected) _set('interrupted');
    } finally {
      _polling = false;
    }
  }

  Future<RTCPeerConnection> _newPeer() async {
    final pc = await (peerFactory ?? createPeerConnection)({
      'iceServers': [
        {'urls': ['stun:stun.cloudflare.com:3478', 'stun:stun.l.google.com:19302']},
      ],
    });
    final epoch = _epoch;
    pc.onIceCandidate = (c) {
      if (c.candidate == null || c.candidate!.isEmpty || epoch != _epoch) return;
      unawaited(_post({
        'type': 'ice',
        'epoch': epoch,
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      }).catchError((Object _) {}));
    };
    pc.onConnectionState = (s) {
      if (epoch != _epoch) return;
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        unawaited(_interrupted());
      }
    };
    pc.onDataChannel = (c) => _bind(c, epoch);
    return pc;
  }

  Future<void> _resetPeer() async {
    _connected = false;
    _remoteSet = false;
    _ice.clear();
    final channel = _channel, pc = _pc;
    _channel = null;
    _pc = null;
    try {
      await channel?.close();
    } catch (_) {}
    try {
      await pc?.close();
    } catch (_) {}
  }

  Future<void> _connect() async {
    _epoch++;
    _attempts++;
    _attemptAt = DateTime.now();
    await _resetPeer();
    _set('connecting');
    _pc = await _newPeer();
    _bind(
      await _pc!.createDataChannel('wenshu-assistant-v2', RTCDataChannelInit()..ordered = true),
      _epoch,
    );
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    await _post({'type': 'offer', 'epoch': _epoch, 'sdp': offer.sdp});
  }

  Future<void> _signal(Map<String, dynamic> v) async {
    final epoch = (v['epoch'] as num?)?.toInt() ?? 0;
    if (v['type'] == 'offer' && !sending) {
      if (epoch <= _epoch && _pc != null) return;
      _epoch = epoch;
      await _resetPeer();
      _set('connecting');
      _pc = await _newPeer();
      await _pc!.setRemoteDescription(RTCSessionDescription(v['sdp'] as String, 'offer'));
      await _flushIce();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      await _post({'type': 'answer', 'epoch': epoch, 'sdp': answer.sdp});
    } else if (v['type'] == 'answer' && sending && epoch == _epoch && _pc != null && !_remoteSet) {
      await _pc!.setRemoteDescription(RTCSessionDescription(v['sdp'] as String, 'answer'));
      await _flushIce();
    } else if (v['type'] == 'ice' && epoch == _epoch) {
      final c = RTCIceCandidate(v['candidate'] as String?, v['sdpMid'] as String?, v['sdpMLineIndex'] as int?);
      if (_remoteSet && _pc != null) {
        await _pc!.addCandidate(c);
      } else {
        _ice.add(c);
      }
    }
  }

  Future<void> _flushIce() async {
    _remoteSet = true;
    for (final c in _ice) {
      await _pc!.addCandidate(c);
    }
    _ice.clear();
  }

  void _bind(RTCDataChannel channel, int epoch) {
    if (epoch != _epoch) {
      unawaited(channel.close());
      return;
    }
    _channel = channel;
    channel.onMessage = (m) {
      if (epoch != _epoch || _closed) return;
      final Object value = m.isBinary ? m.binary : (jsonDecode(m.text) as Map).cast<String, dynamic>();
      _incoming = _incoming.then((_) => _receive(value)).catchError((Object e) => _fail(e));
    };
    channel.onDataChannelState = (s) {
      if (epoch != _epoch) return;
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        unawaited(_opened());
      } else if (s == RTCDataChannelState.RTCDataChannelClosed) {
        unawaited(_interrupted());
      }
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) unawaited(_opened());
  }

  Future<void> _opened() async {
    if (_connected || _closed) return;
    _connected = true;
    _attempts = 0;
    _set(paused ? 'paused' : 'transferring');
    unawaited(_detectRoute());
    if (sending) await sendText({'type': 'hello', 'size': size, 'block': block, 'name': name});
  }

  Future<void> _detectRoute() async {
    try {
      final stats = await _pc!.getStats();
      final byId = {for (final r in stats) r.id: r};
      for (final r in stats) {
        final v = r.values;
        if (r.type == 'candidate-pair' && v['state'] == 'succeeded' && (v['nominated'] == true || v['selected'] == true)) {
          final local = byId[v['localCandidateId']]?.values['candidateType'];
          final remote = byId[v['remoteCandidateId']]?.values['candidateType'];
          route = local == 'host' && remote == 'host' ? 'lan' : 'p2p';
          _changed();
          return;
        }
      }
    } catch (_) {}
  }

  Future<void> _receive(Object value) async {
    if (value is Uint8List) {
      await _protocol!.handle(value);
      return;
    }
    final m = value as Map<String, dynamic>;
    switch (m['type']) {
      case 'hello':
        if (sending || m['size'] != size || m['block'] != block) throw StateError('PROTOCOL_MISMATCH');
        await sendText({'type': 'resume', 'verified': _receiver!.verified, 'paused': paused});
      case 'resume':
        _sender!.resumeAt((m['verified'] as num).toInt());
        if (m['paused'] == true) paused = true;
        _sender!.pause(paused);
        _set(paused ? 'paused' : 'transferring');
        if (!_running) {
          _running = true;
          final epoch = _epoch;
          unawaited(_sender!
              .run(this, () => _connected && !_closed && epoch == _epoch)
              .catchError((Object e) => _interrupted())
              .whenComplete(() => _running = false));
        }
      case 'pause' || 'continue':
        paused = m['type'] == 'pause';
        _sender?.pause(paused);
        _set(paused ? 'paused' : 'transferring');
      default:
        if (sending) {
          if (_sender!.onMessage(m)) await _end('complete');
        } else {
          await _protocol!.handle(m);
        }
    }
  }

  Future<String> _finishReceive() async {
    final target = p.join((await assistantReceiveDirectory()).path, safeFileName(name));
    savedPath = await _receiver!.finish(target);
    try {
      await api.call('complete', {'id': id});
    } catch (_) {}
    await AssistantRegistry.remove(id);
    bytes = size;
    state = 'complete';
    _changed();
    return savedPath!;
  }

  Future<void> _interrupted() async {
    if (_closed || ended || !_connected && state == 'interrupted') return;
    _connected = false;
    await _resetPeer();
    _set('interrupted');
  }

  // ---------------------------------------------------------------- controls
  Future<void> setPaused(bool value) async {
    paused = value;
    _sender?.pause(value);
    _set(value ? 'paused' : (_connected ? 'transferring' : 'interrupted'));
    if (_connected) {
      try {
        await sendText({'type': value ? 'pause' : 'continue'});
      } catch (_) {}
    }
  }

  /// After "无法直连": try again (e.g. once both devices joined one Wi-Fi).
  void retry() {
    _attempts = 0;
    _attemptAt = DateTime.fromMillisecondsSinceEpoch(0);
    _set('interrupted');
    unawaited(_tick());
  }

  Future<void> cancel() async {
    try {
      await api.call('cancel', {'id': id});
    } catch (_) {}
    await _end('cancelled', discard: true);
  }

  Future<void> _fail(Object e) async {
    if (ended) return;
    debugPrint('Assistant transfer $id: $e');
    error = e.toString();
    // Protocol errors end the session; the partial file is kept so a new
    // attempt of the same transfer can still resume from verified blocks.
    await _end('failed');
  }

  Future<void> _end(String value, {bool discard = false}) async {
    if (ended) return;
    state = value;
    _poll?.cancel();
    _ticker?.cancel();
    if (value == 'complete') bytes = size;
    _changed();
    await _resetPeer();
    await _source?.close();
    if (!sending && savedPath == null) await _receiver?.close(discard: discard);
    if (value == 'complete' || discard) await AssistantRegistry.remove(id);
  }

  Future<void> shutdown() async {
    _closed = true;
    _poll?.cancel();
    _ticker?.cancel();
    await _resetPeer();
    await _source?.close();
    if (!sending && savedPath == null) await _receiver?.close();
    super.dispose();
  }

  // ---------------------------------------------------------------- TransferLink
  @override
  Future<void> sendText(Map<String, dynamic> value) async {
    final c = _channel;
    if (c == null || !_connected && value['type'] != 'hello' && value['type'] != 'resume') {
      throw StateError('CONNECTION_CLOSED');
    }
    await c.send(RTCDataChannelMessage(jsonEncode(value)));
  }

  @override
  Future<void> sendBytes(Uint8List data) async {
    final c = _channel;
    if (c == null || !_connected) throw StateError('CONNECTION_CLOSED');
    await c.send(RTCDataChannelMessage.fromBinary(data));
  }

  @override
  Future<int> buffered() async => await _channel?.getBufferedAmount() ?? 0;
}

/// Keeps this device visible to the account's other devices, collects
/// incoming offers and owns running transfers (they continue while the
/// user navigates elsewhere in the app).
class AssistantManager extends ChangeNotifier {
  AssistantManager._();
  static final instance = AssistantManager._();
  AssistantApi? api;
  List<Map<String, dynamic>> devices = [], offers = [], active = [];
  final sessions = <String, AssistantSession>{};
  bool available = true;
  String? error;
  Timer? _timer;
  bool _busy = false;

  Future<void> ensure(SupabaseClient client) async {
    final user = client.auth.currentUser?.id;
    if (user == null) return;
    if (api == null || api!.client != client || !api!.deviceId.isNotEmpty) {
      api = await AssistantApi.open(client);
    }
    // Widget tests must not leave a periodic timer behind.
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      _timer ??= Timer.periodic(const Duration(seconds: 20), (_) => unawaited(refresh()));
    }
    await refresh();
  }

  Future<void> refresh() async {
    final a = api;
    if (a == null || _busy) return;
    _busy = true;
    try {
      final r = await a.heartbeat();
      devices = [for (final d in r['devices'] as List? ?? []) Map<String, dynamic>.from(d as Map)];
      offers = [for (final o in r['offers'] as List? ?? []) Map<String, dynamic>.from(o as Map)];
      final user = a.client.auth.currentUser?.id;
      if (user != null) {
        for (final offer in offers) {
          final activity = TransferActivity.forUser(user);
          if (!activity.records.containsKey('device:${offer['id']}')) {
            activity.update(id: 'device:${offer['id']}',
              name: '${offer['name']}', state: 'waiting');
          }
        }
      }
      active = [for (final o in r['active'] as List? ?? []) Map<String, dynamic>.from(o as Map)];
      available = true;
      error = null;
    } catch (e) {
      available = !(e is PostgrestException && const ['PGRST202', '42883'].contains(e.code));
      error = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  AssistantSession _run(Map<String, dynamic> record) {
    final existing = sessions[record['id']];
    if (existing != null && !existing.ended) return existing;
    final user = api!.client.auth.currentUser!.id;
    final session = AssistantSession(api: api!, record: record);
    void changed() {
      TransferActivity.forUser(user).update(id: 'device:${session.id}',
        name: session.name, state: session.state, bytes: session.bytes,
        size: session.size, savedPath: session.savedPath);
      notifyListeners();
    }
    session.addListener(changed);
    sessions[record['id'] as String] = session;
    changed();
    unawaited(session.start());
    return session;
  }

  /// Offers [size] bytes from [reference] (a path, or an Android content URI).
  Future<AssistantSession> send({
    required String receiverDevice,
    required String reference,
    required String name,
    required int size,
  }) async {
    if (size < 1 || size > assistantMaxFileBytes) throw StateError('FILE_SIZE');
    final record = {
      'id': const Uuid().v4(),
      'role': 'send',
      'name': name,
      'size': size,
      'block': assistantBlockBytes,
      'peer': receiverDevice,
      'source': reference,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    await api!.call('offer', {
      'id': record['id'],
      'receiver_device': receiverDevice,
      'name': name,
      'size': size,
      'block_size': assistantBlockBytes,
    });
    await AssistantRegistry.upsert(record);
    return _run(record);
  }

  Future<AssistantSession> accept(Map<String, dynamic> offer) async {
    final dir = await assistantReceiveDirectory();
    final record = {
      'id': offer['id'],
      'role': 'receive',
      'name': offer['name'],
      'size': (offer['size'] as num).toInt(),
      'block': (offer['block_size'] as num?)?.toInt() ?? assistantBlockBytes,
      'peer': offer['sender_device'],
      'part': p.join(dir.path, '.receiving', '${offer['id']}.part'),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    await AssistantRegistry.upsert(record);
    offers.removeWhere((o) => o['id'] == offer['id']);
    return _run(record);
  }

  Future<void> decline(Map<String, dynamic> offer) async {
    await api!.call('cancel', {'id': offer['id']});
    offers.removeWhere((o) => o['id'] == offer['id']);
    TransferActivity.forUser(api!.client.auth.currentUser!.id).update(
      id: 'device:${offer['id']}', name: '${offer['name']}', state: 'cancelled');
    notifyListeners();
  }

  /// Unfinished transfers remembered on this device and still open on the
  /// server (7 days after acceptance).
  Future<List<Map<String, dynamic>>> resumable() async {
    final ids = {for (final a in active) a['id']};
    return [
      for (final r in await AssistantRegistry.load())
        if (ids.contains(r['id']) && (sessions[r['id']]?.ended ?? true)) r,
    ];
  }

  AssistantSession resume(Map<String, dynamic> record) => _run(record);

  Future<void> forget(Map<String, dynamic> record) async {
    try {
      await api?.call('cancel', {'id': record['id']});
    } catch (_) {}
    if (record['role'] == 'receive') {
      for (final path in ['${record['part']}', '${record['part']}.state.json']) {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }
    }
    await AssistantRegistry.remove(record['id'] as String);
    notifyListeners();
  }
}
