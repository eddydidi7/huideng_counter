import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../data/remote/chat_remote.dart';
import 'chat_audio_focus.dart';
import '../domain/voice_sdp.dart';

/// Foreground calls only. Realtime wakes an authenticated RPC polling loop;
/// audio never passes through PostgreSQL or Realtime.
class VoiceCallService extends ChangeNotifier {
  final ChatRemote remote;
  final String device = const Uuid().v4();
  Map<String, dynamic>? call;
  String name = '', status = 'ringing', quality = 'checking';
  String? failure;
  bool muted = false,
      speaker = false,
      turnConfigured = false,
      usingRelay = false;
  DateTime? connectedAt;
  RTCPeerConnection? peer;
  MediaStream? local;
  final renderer = RTCVideoRenderer();
  final localRenderer = RTCVideoRenderer();
  bool cameraEnabled = true, frontCamera = true;
  bool get isVideo => call?['media_type'] == 'video';
  Timer? timer;
  RealtimeChannel? channel;
  bool disposed = false,
      busy = false,
      creating = false,
      offered = false,
      remoteSet = false;
  bool visible = true;
  bool closing = false;
  int cursor = 0, generation = 0, restarts = 0, lost = 0, received = 0;
  DateTime heartbeatAt = DateTime(2000),
      statsAt = DateTime(2000),
      configAt = DateTime(2000);
  DateTime? lastRestart, disconnectedAt;
  final candidates = <RTCIceCandidate>[];
  Future<void> signalTail = Future.value();
  VoiceCallService(this.remote) {
    timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(poll()),
    );
    channel = remote.client
        .channel('voice-calls:${remote.userId}:$device')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_calls',
          callback: (_) => unawaited(poll()),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_call_signals',
          callback: (_) => unawaited(poll()),
        )
        .subscribe();
    unawaited(poll());
  }
  bool get caller => call?['caller_id'] == remote.userId;
  bool get incoming => call != null && !caller && call!['state'] == 'ringing';
  bool get active => call != null;
  void changed() {
    if (!disposed) notifyListeners();
  }

  Future<dynamic> rpc(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    remote.checkUser();
    final result = await remote.client
        .rpc(
          'chat_call_v1',
          params: {
            'p_action': action,
            'p_data': {'device_id': device, 'id': ?call?['id'], ...data},
          },
        )
        .timeout(const Duration(seconds: 12));
    remote.checkUser();
    return result;
  }

  Future<void> start(String room, String title, {bool video = false}) async {
    if (active || creating || closing) return;
    creating = true;
    failure = null;
    final epoch = generation;
    try {
      final row = Map<String, dynamic>.from(
        await rpc('start', {
          'id': const Uuid().v4(),
          'room_id': room,
          'media_type': video ? 'video' : 'audio',
        }),
      );
      if (disposed || epoch != generation) return;
      call = row;
      if (video && !isVideo) throw StateError('CALL_VIDEO_NOT_CONFIGURED');
      name = title;
      status = 'ringing';
      chatCallActive.value = true;
      chatVoicePlayback.value = null;
      changed();
      await media(epoch);
    } catch (e) {
      if (!disposed && epoch == generation) await fail(e);
    } finally {
      creating = false;
      changed();
    }
  }

  Future<void> accept() async {
    if (!incoming || creating) return;
    creating = true;
    final epoch = generation;
    try {
      await media(epoch);
      if (disposed || epoch != generation) return;
      final result = await rpc('accept');
      if (disposed || epoch != generation) return;
      call = Map<String, dynamic>.from(result['call']);
      status = 'connecting';
    } catch (e) {
      if (!disposed && epoch == generation) await fail(e);
    } finally {
      creating = false;
      changed();
    }
  }

  Future<Map<String, dynamic>> configuration() async {
    final servers = <dynamic>[
      {
        'urls': [
          'stun:stun.cloudflare.com:3478',
          'stun:stun.l.google.com:19302',
        ],
      },
    ];
    turnConfigured = false;
    try {
      final result = await remote.client.functions
          .invoke('voice-config', body: {'region': 'auto'})
          .timeout(const Duration(seconds: 8));
      if (result.status == 200 && result.data is Map) {
        final data = Map<String, dynamic>.from(result.data);
        final extras = data['iceServers'];
        if (extras is List) servers.addAll(extras);
        turnConfigured = data['turnConfigured'] == true;
      }
    } catch (e) {
      debugPrint('voice TURN unavailable: ${e.runtimeType}');
    }
    configAt = DateTime.now();
    return {'iceServers': servers, 'sdpSemantics': 'unified-plan'};
  }

  Future<void> media(int epoch) async {
    if (peer != null) return;
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': isVideo
          ? {
              'facingMode': 'user',
              'width': {'ideal': 640},
              'height': {'ideal': 480},
              'frameRate': {'ideal': 24, 'max': 30},
            }
          : false,
    });
    if (disposed || epoch != generation) {
      for (final t in stream.getTracks()) {
        await t.stop();
      }
      await stream.dispose();
      return;
    }
    local = stream;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !muted;
    }
    final config = await configuration();
    if (disposed || epoch != generation) return;
    final pc = await createPeerConnection(config);
    if (disposed || epoch != generation) {
      await pc.close();
      await pc.dispose();
      return;
    }
    peer = pc;
    if (renderer.textureId == null) await renderer.initialize();
    if (disposed || epoch != generation) return;
    if (isVideo) {
      if (localRenderer.textureId == null) await localRenderer.initialize();
      if (disposed || epoch != generation) return;
      localRenderer.srcObject = stream;
      setVisible(visible);
    }
    pc.onTrack = (event) {
      if (!disposed && epoch == generation && event.streams.isNotEmpty) {
        renderer.srcObject = event.streams.first;
        changed();
      }
    };
    pc.onIceCandidate = (c) {
      if (c.candidate?.isNotEmpty ?? false) {
        queueSignal({'type': 'candidate', 'candidate': c.toMap()});
      }
    };
    pc.onConnectionState = (state) {
      if (disposed || epoch != generation) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        status = 'connected';
        connectedAt ??= DateTime.now();
        disconnectedAt = null;
        restarts = 0;
      } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        status = 'reconnecting';
        disconnectedAt ??= DateTime.now();
      }
      changed();
    };
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
    speaker = isVideo;
    await Helper.setSpeakerphoneOn(speaker);
    changed();
  }

  /// Preserve signal order (offer before candidates) and nonce across retries.
  void queueSignal(Map<String, dynamic> payload) {
    final cid = call?['id'], nonce = const Uuid().v4(), epoch = generation;
    signalTail = signalTail.then((_) async {
      for (var attempt = 0; attempt < 3; attempt++) {
        if (disposed || epoch != generation || cid != call?['id']) return;
        try {
          await rpc('signal', {'id': cid, 'nonce': nonce, 'payload': payload});
          return;
        } catch (e) {
          if (attempt == 2) {
            debugPrint('voice signal failed: ${e.runtimeType}');
            status = 'reconnecting';
            changed();
          } else {
            await Future<void>.delayed(Duration(seconds: 1 << attempt));
          }
        }
      }
    });
  }

  Future<void> offer({bool restart = false}) async {
    final pc = peer;
    if (pc == null) return;
    final original = await pc.createOffer({
      'iceRestart': restart,
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': isVideo,
    });
    final sdp = RTCSessionDescription(
      preferVoiceOpus(original.sdp!),
      original.type,
    );
    // WebRTC negotiates Opus/FEC with the remote endpoint. Do not claim support
    // simply because an SDP parameter was requested.
    queueSignal({'type': 'offer', 'sdp': sdp.sdp});
    await pc.setLocalDescription(sdp);
    offered = true;
  }

  Future<void> process(Map<String, dynamic> signal) async {
    final pc = peer;
    if (pc == null) return;
    switch (signal['type']) {
      case 'offer':
        await pc.setRemoteDescription(
          RTCSessionDescription(signal['sdp'] as String, 'offer'),
        );
        remoteSet = true;
        final original = await pc.createAnswer();
        final answer = RTCSessionDescription(
          preferVoiceOpus(original.sdp!),
          original.type,
        );
        queueSignal({'type': 'answer', 'sdp': answer.sdp});
        await pc.setLocalDescription(answer);
      case 'answer':
        await pc.setRemoteDescription(
          RTCSessionDescription(signal['sdp'] as String, 'answer'),
        );
        remoteSet = true;
      case 'candidate':
        final c = Map<String, dynamic>.from(signal['candidate']);
        candidates.add(
          RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']),
        );
      case 'restart':
        if (caller) await restart();
    }
    if (remoteSet) {
      while (candidates.isNotEmpty) {
        await pc.addCandidate(candidates.removeAt(0));
      }
    }
  }

  Future<void> restart() async {
    if (lastRestart != null &&
        DateTime.now().difference(lastRestart!).inSeconds < 10) {
      return;
    }
    if (restarts >= 3) return;
    lastRestart = DateTime.now();
    restarts++;
    await peer?.setConfiguration(await configuration());
    if (caller) {
      await offer(restart: true);
    } else {
      queueSignal({'type': 'restart'});
    }
  }

  Future<void> poll() async {
    if (disposed || busy || creating || closing || (!visible && !active)) {
      return;
    }
    busy = true;
    final epoch = generation;
    try {
      if (!active) {
        final inbox = await rpc('inbox');
        if (disposed || epoch != generation || active) return;
        if (inbox != null) {
          call = Map<String, dynamic>.from(inbox);
          name = call!['nickname'] as String? ?? '';
          status = 'ringing';
          failure = null;
          chatCallActive.value = true;
          chatVoicePlayback.value = null;
          changed();
        }
        return;
      }
      final result = await rpc('poll', {'after': cursor});
      if (disposed || epoch != generation) return;
      call = Map<String, dynamic>.from(result['call']);
      if (!['ringing', 'accepted'].contains(call!['state'])) {
        await close();
        return;
      }
      if (call!['state'] == 'accepted') {
        if (peer == null) return;
        if (caller && !offered) {
          status = 'connecting';
          await offer();
        }
        for (final s in result['signals'] as List) {
          if (disposed || epoch != generation) return;
          await process(Map<String, dynamic>.from(s['payload']));
          cursor = (s['seq'] as num).toInt();
        }
        final now = DateTime.now();
        if (now.difference(heartbeatAt).inSeconds >= 25) {
          await rpc('heartbeat');
          heartbeatAt = now;
        }
        if (now.difference(statsAt).inSeconds >= 5) {
          await stats();
          statsAt = now;
        }
        final accepted = DateTime.parse(call!['accepted_at'] as String);
        if ((connectedAt == null && now.difference(accepted).inSeconds > 60) ||
            (disconnectedAt != null &&
                now.difference(disconnectedAt!).inSeconds > 60)) {
          throw StateError(
            turnConfigured ? 'CALL_CONNECTION_FAILED' : 'CALL_TURN_REQUIRED',
          );
        }
        if (disconnectedAt != null &&
            now.difference(disconnectedAt!).inSeconds >= 5) {
          await restart();
        }
        if (caller && now.difference(configAt).inMinutes >= 10) await restart();
      }
      changed();
    } on PostgrestException catch (e) {
      if (disposed || epoch != generation) return;
      if (active && e.code == '42501') {
        await fail(e);
      } else {
        debugPrint('voice RPC: ${e.code}');
      }
    } catch (e) {
      if (disposed || epoch != generation) return;
      if (e is StateError) {
        await fail(e);
      } else if (active) {
        disconnectedAt ??= DateTime.now();
        status = 'reconnecting';
        changed();
        if (DateTime.now().difference(disconnectedAt!).inSeconds > 60) {
          await fail(e);
        }
      }
    } finally {
      busy = false;
    }
  }

  Future<void> stats() async {
    final pc = peer;
    if (pc == null) return;
    final reports = await pc.getStats();
    double? rtt, jitter, loss;
    for (final report in reports) {
      final v = report.values;
      if (report.type == 'inbound-rtp' &&
          (v['kind'] == 'audio' || v['mediaType'] == 'audio')) {
        final l = (v['packetsLost'] as num? ?? 0).toInt(),
            r = (v['packetsReceived'] as num? ?? 0).toInt();
        final dl = (l - lost).clamp(0, 1000000),
            dr = (r - received).clamp(0, 1000000);
        if (dl + dr > 0) loss = dl / (dl + dr);
        lost = l;
        received = r;
        jitter = (v['jitter'] as num?)?.toDouble();
      }
      if (report.type == 'candidate-pair' &&
          v['state'] == 'succeeded' &&
          (v['nominated'] == true || v['selected'] == true)) {
        rtt = (v['currentRoundTripTime'] as num?)?.toDouble();
        usingRelay = reports.any(
          (r) =>
              (r.id == v['localCandidateId'] ||
                  r.id == v['remoteCandidateId']) &&
              r.values['candidateType'] == 'relay',
        );
      }
    }
    quality = loss == null && rtt == null
        ? 'checking'
        : (loss ?? 0) > .08 || (rtt ?? 0) > .5 || (jitter ?? 0) > .1
        ? 'poor'
        : (loss ?? 0) > .03 || (rtt ?? 0) > .25
        ? 'fair'
        : 'good';
    for (final sender in await pc.getSenders()) {
      if (!['audio', 'video'].contains(sender.track?.kind)) continue;
      final params = sender.parameters;
      for (final encoding in params.encodings ?? <RTCRtpEncoding>[]) {
        encoding.maxBitrate = sender.track?.kind == 'video'
            ? (quality == 'poor'
                  ? 180000
                  : quality == 'fair'
                  ? 400000
                  : 900000)
            : (quality == 'poor' ? 16000 : 32000);
      }
      if (params.encodings?.isNotEmpty ?? false) {
        await sender.setParameters(params);
      }
    }
  }

  void setVisible(bool value) {
    visible = value;
    for (final track in local?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = value && cameraEnabled;
    }
    changed();
  }

  void toggleCamera() {
    cameraEnabled = !cameraEnabled;
    setVisible(visible);
  }

  Future<void> switchCamera() async {
    final tracks = local?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
      frontCamera = !frontCamera;
      changed();
    } catch (e) {
      debugPrint('camera switch unavailable: ${e.runtimeType}');
    }
  }

  Future<void> toggleMute() async {
    muted = !muted;
    for (final t in local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    changed();
  }

  Future<void> toggleSpeaker() async {
    try {
      await Helper.setSpeakerphoneOn(!speaker);
      speaker = !speaker;
      changed();
    } catch (e) {
      debugPrint('voice audio route: ${e.runtimeType}');
    }
  }

  Future<void> hangup({bool decline = false}) async {
    final id = call?['id'];
    // Stop capturing immediately, even while the signalling server is offline.
    await close();
    if (id != null) {
      try {
        await rpc(decline ? 'decline' : 'end', {'id': id});
      } catch (e) {
        debugPrint(
          'voice end delivery: ${e.runtimeType} (server lease will expire)',
        );
      }
    }
  }

  Future<void> fail(Object e) async {
    failure = e is StateError
        ? e.message.toString()
        : e is PostgrestException
        ? e.message
        : 'CALL_FAILED';
    debugPrint('voice call failure: ${e.runtimeType}');
    await hangup();
  }

  Future<void> close() async {
    closing = true;
    generation++;
    call = null;
    cursor = 0;
    offered = false;
    remoteSet = false;
    candidates.clear();
    connectedAt = null;
    disconnectedAt = null;
    restarts = 0;
    lastRestart = null;
    muted = false;
    speaker = false;
    cameraEnabled = true;
    frontCamera = true;
    quality = 'checking';
    lost = 0;
    received = 0;
    usingRelay = false;
    chatCallActive.value = false;
    final stream = local;
    local = null;
    final pc = peer;
    peer = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
    if (renderer.textureId != null) renderer.srcObject = null;
    if (localRenderer.textureId != null) localRenderer.srcObject = null;
    if (pc != null) {
      await pc.close();
      await pc.dispose();
    }
    closing = false;
    changed();
  }

  @override
  void dispose() {
    disposed = true;
    timer?.cancel();
    if (channel != null) unawaited(remote.client.removeChannel(channel!));
    unawaited(
      close().then((_) async {
        await renderer.dispose();
        await localRenderer.dispose();
      }),
    );
    super.dispose();
  }
}
