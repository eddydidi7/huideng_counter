import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../data/remote/chat_live.dart';

const maxDirectFileBytes = 3000000000;
const directChunkBytes = 16384;
const directWindowBytes = 1048576;
String safeReceivedName(String name) {
  final clean = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  return clean.isEmpty ? 'file' : clean;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

/// Bounded-memory, reliable ordered transfer. Sender progress is receiver-ACKed
/// bytes, and completion requires a matching SHA-256 acknowledgement.
class DirectTransfer extends ChangeNotifier {
  final ChatLive live;
  final Map<String, dynamic> offer;
  final String? sourcePath;
  final Future<RTCPeerConnection> Function(Map<String, dynamic>)? peerFactory;
  final Future<Directory> Function()? receiveDirectory;
  final Duration pollInterval;
  DirectTransfer(
    this.live,
    this.offer, {
    this.sourcePath,
    this.peerFactory,
    this.receiveDirectory,
    this.pollInterval = const Duration(seconds: 2),
  });
  bool get sender => sourcePath != null;
  String get id => offer['id'] as String;
  int get size => (offer['size'] as num).toInt();
  String state = 'connecting';
  String? savedPath, failure;
  int bytes = 0, _sent = 0, _lastAck = 0, _cursor = 0, _queued = 0;
  bool _ended = false,
      _polling = false,
      _negotiating = false,
      _started = false,
      _remoteSet = false;
  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  RandomAccessFile? _output;
  File? _partial;
  Timer? _timer;
  final _digest = _DigestSink();
  late final ByteConversionSink _hash = sha256.startChunkedConversion(_digest);
  String? _expectedHash;
  Future<void> _incoming = Future.value();
  final List<RTCIceCandidate> _ice = [];
  DateTime _activity = DateTime.now();
  bool get ended => _ended;
  double bytesPerSecond = 0;
  int _speedBytes = 0;
  DateTime _speedAt = DateTime.now();
  int? get remainingSeconds =>
      bytesPerSecond > 0 ? ((size - bytes) / bytesPerSecond).ceil() : null;
  void _changed() {
    final now = DateTime.now();
    final elapsed = now.difference(_speedAt).inMilliseconds;
    if (elapsed >= 1000) {
      bytesPerSecond = (bytes - _speedBytes) * 1000 / elapsed;
      _speedBytes = bytes;
      _speedAt = now;
    }
    notifyListeners();
  }

  Future<dynamic> _api(String action, [Map<String, dynamic> data = const {}]) =>
      live.call(action, {'id': id, ...data});
  Future<void> start() async {
    try {
      if (size < 1 || size > maxDirectFileBytes) throw StateError('FILE_SIZE');
      if (!sender) {
        final dir =
            await (receiveDirectory?.call() ??
                getApplicationDocumentsDirectory());
        final folder = Directory(
          p.join(dir.path, 'received_chat_files', live.remote.userId, id),
        );
        await folder.create(recursive: true);
        _partial = File(p.join(folder.path, 'receiving.part'));
        _output = await _partial!.open(mode: FileMode.write);
        await _api('accept');
      } else {
        state = 'waiting';
      }
      _changed();
      await _poll();
      if (!_ended) {
        _timer = Timer.periodic(pollInterval, (_) => unawaited(_poll()));
      }
    } catch (e) {
      await fail(e);
    }
  }

  Future<void> _poll() async {
    if (_ended || _polling) return;
    _polling = true;
    try {
      live.remote.checkUser();
      if (DateTime.now().difference(_activity) > const Duration(minutes: 2)) {
        throw StateError('TRANSFER_TIMEOUT');
      }
      final result = await _api('poll', {'after': _cursor});
      if (_ended) return;
      if (['cancelled', 'expired'].contains(result['state'])) {
        throw StateError('PEER_CANCELLED');
      }
      if (result['state'] == 'accepted' && !_negotiating) {
        _negotiating = true;
        state = 'connecting';
        _changed();
        await _connect();
      }
      for (final signal in result['signals'] as List) {
        await _signal(Map<String, dynamic>.from(signal['payload']));
        _cursor = (signal['seq'] as num).toInt();
      }
    } catch (e) {
      await fail(e);
    } finally {
      _polling = false;
    }
  }

  Future<void> _post(Map<String, dynamic> value) async {
    if (_ended) return;
    await _api('signal', {'nonce': const Uuid().v4(), 'payload': value});
  }

  Future<void> _connect() async {
    _pc = await (peerFactory ?? createPeerConnection)({
      'iceServers': [
        {
          'urls': [
            'stun:stun.cloudflare.com:3478',
            'stun:stun.l.google.com:19302',
          ],
        },
      ],
    });
    if (_ended) {
      await _pc?.close();
      return;
    }
    _pc!.onIceCandidate = (c) {
      if (c.candidate != null && c.candidate!.isNotEmpty) {
        unawaited(
          _post({
            'type': 'ice',
            'candidate': c.candidate,
            'sdpMid': c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          }).catchError((Object e) => fail(e)),
        );
      }
    };
    _pc!.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        unawaited(fail(StateError('P2P_UNREACHABLE')));
      }
    };
    _pc!.onDataChannel = _bind;
    if (sender) {
      _bind(
        await _pc!.createDataChannel(
          'huideng-file-v1',
          RTCDataChannelInit()..ordered = true,
        ),
      );
      final description = await _pc!.createOffer();
      await _pc!.setLocalDescription(description);
      await _post({'type': 'offer', 'sdp': description.sdp});
    }
  }

  Future<void> _signal(Map<String, dynamic> value) async {
    if (_ended) return;
    if (value['type'] == 'ice') {
      final c = RTCIceCandidate(
        value['candidate'] as String?,
        value['sdpMid'] as String?,
        value['sdpMLineIndex'] as int?,
      );
      if (_remoteSet) {
        await _pc!.addCandidate(c);
      } else {
        _ice.add(c);
      }
    } else if (value['type'] == 'offer' && !sender ||
        value['type'] == 'answer' && sender) {
      await _pc!.setRemoteDescription(
        RTCSessionDescription(value['sdp'] as String, value['type'] as String),
      );
      _remoteSet = true;
      for (final c in _ice) {
        await _pc!.addCandidate(c);
      }
      _ice.clear();
      if (!sender) {
        final a = await _pc!.createAnswer();
        await _pc!.setLocalDescription(a);
        await _post({'type': 'answer', 'sdp': a.sdp});
      }
    }
  }

  void _bind(RTCDataChannel channel) {
    if (_channel != null) {
      unawaited(channel.close());
      return;
    }
    _channel = channel;
    channel.onMessage = (message) {
      if (_ended) return;
      final length = message.isBinary
          ? message.binary.length
          : message.text.length;
      _queued += length;
      if (_queued > directWindowBytes * 2 ||
          !message.isBinary && length > 2048) {
        unawaited(fail(StateError('PROTOCOL_LIMIT')));
        return;
      }
      _incoming = _incoming
          .then((_) async {
            if (!_ended) await _receive(message);
          })
          .catchError((Object e) {
            unawaited(fail(e));
          })
          .whenComplete(() => _queued -= length);
    };
    channel.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        _open();
      }
      if (s == RTCDataChannelState.RTCDataChannelClosed && !_ended) {
        unawaited(fail(StateError('CONNECTION_CLOSED')));
      }
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) _open();
  }

  void _open() {
    if (_started || _ended) return;
    _started = true;
    _activity = DateTime.now();
    state = 'transferring';
    _changed();
    if (sender) unawaited(_send().catchError((Object e) => fail(e)));
  }

  Future<void> _text(Map<String, dynamic> value) async {
    if (!_ended) await _channel!.send(RTCDataChannelMessage(jsonEncode(value)));
  }

  Future<void> _send() async {
    final input = await File(sourcePath!).open();
    try {
      if (await input.length() != size) throw StateError('SOURCE_CHANGED');
      while (_sent < size && !_ended) {
        while (!_ended &&
            (_sent - bytes >= directWindowBytes ||
                await _channel!.getBufferedAmount() > directWindowBytes)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        if (_ended) return;
        final block = await input.read(directChunkBytes);
        if (block.isEmpty || _sent + block.length > size) {
          throw StateError('SOURCE_CHANGED');
        }
        _hash.add(block);
        _sent += block.length;
        await _channel!.send(RTCDataChannelMessage.fromBinary(block));
      }
      if (_ended) return;
      _hash.close();
      _expectedHash = _digest.value.toString();
      state = 'verifying';
      _changed();
      await _text({'type': 'end', 'size': size, 'sha256': _expectedHash});
    } finally {
      await input.close();
    }
  }

  Future<void> _receive(RTCDataChannelMessage message) async {
    _activity = DateTime.now();
    if (message.isBinary) {
      if (sender ||
          message.binary.length > directChunkBytes ||
          bytes + message.binary.length > size) {
        throw StateError('PROTOCOL_SIZE');
      }
      await _output!.writeFrom(message.binary);
      _hash.add(message.binary);
      bytes += message.binary.length;
      if (bytes - _lastAck >= 262144 || bytes == size) {
        _lastAck = bytes;
        await _text({'type': 'ack', 'bytes': bytes});
        _changed();
      }
      return;
    }
    final value = jsonDecode(message.text) as Map<String, dynamic>;
    if (value['type'] == 'ack' && sender) {
      final n = value['bytes'] as int;
      if (n < bytes || n > _sent) throw StateError('INVALID_ACK');
      bytes = n;
      _changed();
    } else if (value['type'] == 'end' && !sender) {
      _hash.close();
      if (bytes != size ||
          value['size'] != size ||
          value['sha256'] != _digest.value.toString()) {
        throw StateError('CHECKSUM_FAILED');
      }
      state = 'verifying';
      _changed();
      await _output!.flush();
      await _output!.close();
      _output = null;
      savedPath = p.join(
        _partial!.parent.path,
        'received_${safeReceivedName(offer['name'] as String)}',
      );
      await _partial!.rename(savedPath!);
      _partial = null;
      await _api('complete');
      await _text({
        'type': 'done',
        'size': size,
        'sha256': _digest.value.toString(),
      });
      // Wait for final receipt so closing native channel cannot drop the done packet.
      state = 'received';
      _changed();
    } else if (value['type'] == 'done' && sender) {
      if (_expectedHash == null ||
          value['sha256'] != _expectedHash ||
          value['size'] != size) {
        throw StateError('CHECKSUM_FAILED');
      }
      await _text({'type': 'receipt'});
      _ended = true;
      state = 'complete';
      bytes = size;
      _timer?.cancel();
      _changed();
      // Receiver closes after receipt; keep channel until page is dismissed.
    } else if (value['type'] == 'receipt' && !sender && savedPath != null) {
      _ended = true;
      state = 'complete';
      _timer?.cancel();
      _changed();
    } else {
      throw StateError('PROTOCOL_MESSAGE');
    }
  }

  Future<void> fail(Object e) async {
    if (_ended) return;
    debugPrint('P2P transfer $id: ${e.runtimeType}: $e');
    _ended = true;
    state = 'failed';
    failure = e.toString();
    _timer?.cancel();
    _changed();
    try {
      await _api('cancel');
    } catch (e) {
      debugPrint('P2P cancel: ${e.runtimeType}');
    }
    await _cleanup();
  }

  Future<void> cancel() async {
    if (_ended) return;
    _ended = true;
    state = 'cancelled';
    _timer?.cancel();
    _changed();
    try {
      await _api('cancel');
    } catch (e) {
      debugPrint('P2P cancel: ${e.runtimeType}');
    }
    await _cleanup();
  }

  Future<void> _cleanup() async {
    await _incoming;
    await _output?.close();
    _output = null;
    if (_partial != null && await _partial!.exists()) await _partial!.delete();
    await _channel?.close();
    await _pc?.close();
  }

  Future<void> shutdown() async {
    if (!_ended) {
      await cancel();
    } else {
      await _cleanup();
    }
    super.dispose();
  }
}
