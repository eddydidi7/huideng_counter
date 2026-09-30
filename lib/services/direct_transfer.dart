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
import 'resumable_transfer.dart';

const maxDirectFileBytes = 5 * 1024 * 1024 * 1024;
const directChunkBytes = 16384;
const directWindowBytes = 4 * 1024 * 1024;
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
      _disposed = false,
      _polling = false,
      _negotiating = false,
      _started = false,
      _remoteSet = false;
  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  RandomAccessFile? _output;
  File? _partial;
  File? _checkpoint;
  int _verified = 0;
  bool _ready = false;
  Future<void>? _sending;
  Future<void>? _cleanupFuture;
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
    if (!_disposed) notifyListeners();
  }

  Future<dynamic> _api(String action, [Map<String, dynamic> data = const {}]) =>
      live.transferCall(action, {
        'id': id,
        if (offer['_device_id'] != null) 'device_id': offer['_device_id'],
        ...data,
      });
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
        if (_ended) return;
        _partial = File(p.join(folder.path, 'receiving.part'));
        _checkpoint = File(p.join(folder.path, 'checkpoint.json'));
        try {
          if (await _partial!.exists() && await _checkpoint!.exists()) {
            final checkpoint =
                jsonDecode(await _checkpoint!.readAsString()) as Map;
            if (checkpoint['size'] == size) {
              _verified = (checkpoint['bytes'] as num).toInt();
              if (_verified < 0 ||
                  _verified > size ||
                  _verified > await _partial!.length()) {
                _verified = 0;
              }
            }
          }
        } catch (_) {
          _verified = 0;
        }
        _output = await _partial!.open(mode: FileMode.append);
        if (_ended) {
          await _output!.close();
          _output = null;
          return;
        }
        await _output!.truncate(_verified);
        await _output!.setPosition(_verified);
        await for (final block in _partial!.openRead(0, _verified)) {
          if (_ended) return;
          _hash.add(block);
        }
        if (_ended) return;
        bytes = _verified;
        _lastAck = bytes;
        _speedBytes = bytes;
        _speedAt = _activity = DateTime.now();
        await _api('accept');
      } else {
        if (offer['_resume'] == true) {
          final result = await _api('restart');
          if (result['state'] == 'complete') {
            state = 'complete';
            bytes = size;
            _ended = true;
            _changed();
            return;
          }
        }
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
      final timeout = state == 'waiting' || state == 'connecting'
          ? const Duration(minutes: 15)
          : const Duration(minutes: 2);
      if (DateTime.now().difference(_activity) > timeout) {
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
    if (!sender) {
      unawaited(
        _text({
          'type': 'resume',
          'bytes': bytes,
        }).catchError((Object e) => fail(e)),
      );
    }
  }

  Future<void> _text(Map<String, dynamic> value) async {
    if (!_ended) await _channel!.send(RTCDataChannelMessage(jsonEncode(value)));
  }

  Future<void> _send() async {
    final input = LargeSource.fromReference(sourcePath!);
    try {
      if (await input.length() != size) throw StateError('SOURCE_CHANGED');
      var heartbeatAt = DateTime.now();
      // Rehash the retained prefix so the final digest covers the entire file,
      // including bytes sent before a disconnect or application restart.
      for (var offset = 0; offset < _sent && !_ended;) {
        final length = (_sent - offset).clamp(0, 1024 * 1024);
        final block = await input.read(offset, length);
        if (block.length != length) throw StateError('SOURCE_CHANGED');
        _hash.add(block);
        offset += block.length;
        _activity = DateTime.now();
        if (_activity.difference(heartbeatAt) > const Duration(seconds: 5)) {
          await _text({'type': 'rehashing'});
          heartbeatAt = _activity;
        }
      }
      Uint8List? cached;
      var cachedAt = 0;
      while (_sent < size && !_ended) {
        while (!_ended &&
            (_sent - bytes >= directWindowBytes ||
                await _channel!.getBufferedAmount() > directWindowBytes)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        if (_ended) return;
        if (cached == null || _sent >= cachedAt + cached.length) {
          cachedAt = _sent;
          final length = (size - _sent).clamp(0, 1024 * 1024);
          cached = await input.read(_sent, length);
          if (cached.length != length) throw StateError('SOURCE_CHANGED');
        }
        final start = _sent - cachedAt;
        final block = Uint8List.sublistView(
          cached,
          start,
          (start + directChunkBytes).clamp(0, cached.length),
        );
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
      if (bytes - _lastAck >= 1048576 || bytes == size) {
        await _output!.flush();
        await _checkpoint!.writeAsString(
          jsonEncode({'size': size, 'bytes': bytes}),
          flush: true,
        );
        _verified = bytes;
        _lastAck = bytes;
        await _text({'type': 'ack', 'bytes': bytes});
        _changed();
      }
      return;
    }
    final value = jsonDecode(message.text) as Map<String, dynamic>;
    if (value['type'] == 'resume' && sender && !_ready) {
      final offset = value['bytes'];
      if (offset is! int || offset < 0 || offset > size) {
        throw StateError('INVALID_RESUME');
      }
      _ready = true;
      bytes = _sent = offset;
      _speedBytes = bytes;
      _speedAt = DateTime.now();
      _sending = _send().catchError((Object e) {
        unawaited(fail(e));
      });
    } else if (value['type'] == 'rehashing' && !sender) {
      // Large resumed prefixes may take a while to hash on slower devices.
      return;
    } else if (value['type'] == 'ack' && sender) {
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
      if (await _checkpoint!.exists()) await _checkpoint!.delete();
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
    failure = e.toString();
    state = failure!.contains('PEER_CANCELLED') ? 'cancelled' : 'failed';
    _timer?.cancel();
    _changed();
    if (failure!.contains('CHECKSUM_FAILED')) {
      try {
        await _api('cancel');
      } catch (_) {}
    }
    await _cleanup(
      discard: state == 'cancelled' || failure!.contains('CHECKSUM_FAILED'),
    );
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
    await _cleanup(discard: true);
  }

  Future<void> _cleanup({bool discard = false}) =>
      _cleanupFuture ??= _doCleanup(discard);

  Future<void> _doCleanup(bool discard) async {
    await _incoming;
    await _sending;
    await _output?.close();
    _output = null;
    if (discard) {
      if (_partial != null && await _partial!.exists()) {
        await _partial!.delete();
      }
      if (_checkpoint != null && await _checkpoint!.exists()) {
        await _checkpoint!.delete();
      }
    }
    await _channel?.close();
    await _pc?.close();
  }

  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    if (!_ended) {
      await fail(StateError('TRANSFER_SUSPENDED'));
    } else {
      await _cleanup();
    }
    super.dispose();
  }
}
