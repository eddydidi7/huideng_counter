import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/data/remote/chat_live.dart';
import 'package:huideng_counter/data/remote/chat_remote.dart';
import 'package:huideng_counter/services/direct_transfer.dart';

class Remote extends ChatRemote {
  Remote(String id)
    : super(SupabaseClient('https://example.test', 'public-test'), id);
  @override
  void checkUser() {}
}

class Server {
  String state = 'offered';
  final signals = <Map<String, dynamic>>[];
}

class Live extends ChatLive {
  final Server server;
  Live(String id, this.server) : super(Remote(id));
  @override
  Future<dynamic> transferCall(
    String action, [
    Map<String, dynamic> data = const {},
  ]) => call(action, data);
  @override
  Future<dynamic> call(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    if (action == 'restart') {
      server.state = 'offered';
      server.signals.clear();
    }
    if (action == 'accept') server.state = 'accepted';
    if (action == 'cancel') server.state = 'cancelled';
    if (action == 'complete') server.state = 'complete';
    if (action == 'signal') {
      server.signals.add({
        'seq': server.signals.length + 1,
        'sender': remote.userId,
        'payload': data['payload'],
      });
    }
    if (action == 'poll') {
      return {
        'state': server.state,
        'signals': server.signals
            .where(
              (s) =>
                  s['sender'] != remote.userId &&
                  (s['seq'] as int) > (data['after'] as int),
            )
            .toList(),
      };
    }
    return {};
  }
}

class Channel extends Fake implements RTCDataChannel {
  Channel? peer;
  bool corrupt = false;
  int maxPacket = 0;
  int sentBytes = 0;
  int? disconnectAfter;
  @override
  RTCDataChannelState state = RTCDataChannelState.RTCDataChannelConnecting;
  @override
  Function(RTCDataChannelMessage)? onMessage;
  @override
  Function(RTCDataChannelState)? onDataChannelState;
  @override
  Future<int> getBufferedAmount() async => 0;
  @override
  Future<void> send(RTCDataChannelMessage message) async {
    if (message.isBinary) {
      if (disconnectAfter != null && sentBytes >= disconnectAfter!) {
        throw StateError('TEST_DISCONNECTED');
      }
      sentBytes += message.binary.length;
      maxPacket = message.binary.length > maxPacket
          ? message.binary.length
          : maxPacket;
      if (corrupt) {
        final copy = Uint8List.fromList(message.binary);
        copy[0] ^= 1;
        message = RTCDataChannelMessage.fromBinary(copy);
        corrupt = false;
      }
    }
    peer!.onMessage?.call(message);
  }

  @override
  Future<void> close() async {
    state = RTCDataChannelState.RTCDataChannelClosed;
  }
}

class Peer extends Fake implements RTCPeerConnection {
  Peer? other;
  final channel = Channel();
  @override
  Function(RTCIceCandidate)? onIceCandidate;
  @override
  Function(RTCPeerConnectionState)? onConnectionState;
  @override
  Function(RTCDataChannel)? onDataChannel;
  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit init,
  ) async => channel;
  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription('sdp', 'offer');
  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription('sdp', 'answer');
  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}
  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    if (description.type == 'answer') {
      channel.peer = other!.channel;
      other!.channel.peer = channel;
      other!.onDataChannel?.call(other!.channel);
      channel.state = RTCDataChannelState.RTCDataChannelOpen;
      other!.channel.state = RTCDataChannelState.RTCDataChannelOpen;
      other!.channel.onDataChannelState?.call(other!.channel.state);
      channel.onDataChannelState?.call(channel.state);
    }
  }

  @override
  Future<void> close() async {}
}

Future<void> until(bool Function() condition) async {
  for (int i = 0; i < 500; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Transfer did not settle');
}

void main() {
  test(
    'interrupted session survives disposal and resumes without resending prefix',
    () async {
      final dir = await Directory.systemTemp.createTemp('chat-resume-test');
      final data = Uint8List.fromList(
        List.generate(3 * 1024 * 1024, (i) => i % 251),
      );
      final source = await File('${dir.path}/video.mp4').writeAsBytes(data);
      final server = Server();
      final a = Live('alice', server), b = Live('bob', server);
      final offer = <String, dynamic>{
        'id': 'resume-test',
        'name': 'video.mp4',
        'size': data.length,
      };
      DirectTransfer? sender, receiver;
      try {
        for (var attempt = 0; attempt < 2; attempt++) {
          final pa = Peer(), pb = Peer();
          pa.other = pb;
          pb.other = pa;
          if (attempt == 0) pa.channel.disconnectAfter = 1536 * 1024;
          sender = DirectTransfer(
            a,
            {...offer, '_resume': attempt == 1},
            sourcePath: source.path,
            peerFactory: (_) async => pa,
            pollInterval: const Duration(milliseconds: 10),
          );
          receiver = DirectTransfer(
            b,
            offer,
            peerFactory: (_) async => pb,
            receiveDirectory: () async => dir,
            pollInterval: const Duration(milliseconds: 10),
          );
          await sender.start();
          await receiver.start();
          if (attempt == 0) {
            await until(() => sender!.ended);
            expect(server.state, 'accepted');
            await until(() => receiver!.bytes >= 1048576);
            await sender.shutdown();
            await receiver.shutdown();
            final state = jsonDecode(
              await File(
                '${dir.path}/received_chat_files/bob/resume-test/checkpoint.json',
              ).readAsString(),
            );
            expect(state['bytes'], 1048576);
          } else {
            await until(() => sender!.ended && receiver!.ended);
            expect(sender.state, 'complete');
            expect(pa.channel.sentBytes, data.length - 1048576);
            expect(await File(receiver.savedPath!).readAsBytes(), data);
            await sender.shutdown();
            await receiver.shutdown();
          }
          sender = null;
          receiver = null;
        }
      } finally {
        await sender?.shutdown();
        await receiver?.shutdown();
        a.dispose();
        b.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
  for (final resumeBytes in [0, 1048576]) {
    for (final corrupt in [false, true]) {
      test(
        corrupt
            ? 'corrupt file never reports success and partial file is removed'
            : 'verified transfer resumes at $resumeBytes bytes',
        () async {
          final dir = await Directory.systemTemp.createTemp('huideng-p2p-test');
          final source = File('${dir.path}/source.bin');
          final bytes = Uint8List.fromList(
            List.generate(2500000, (i) => i % 251),
          );
          await source.writeAsBytes(bytes);
          if (resumeBytes > 0) {
            final folder = Directory(
              '${dir.path}/received_chat_files/bob/test-transfer',
            );
            await folder.create(recursive: true);
            // An unacknowledged tail must be discarded on reopening.
            await File(
              '${folder.path}/receiving.part',
            ).writeAsBytes(bytes.sublist(0, resumeBytes + 123));
            await File('${folder.path}/checkpoint.json').writeAsString(
              jsonEncode({'size': bytes.length, 'bytes': resumeBytes}),
            );
          }
          final server = Server(), left = Live('alice', Server());
          final a = Live('alice', server), b = Live('bob', server);
          final pa = Peer(), pb = Peer();
          pa.other = pb;
          pb.other = pa;
          pa.channel.corrupt = corrupt;
          final offer = <String, dynamic>{
            'id': 'test-transfer',
            'name': '../../clip.mp4',
            'size': bytes.length,
          };
          final sender = DirectTransfer(
            a,
            offer,
            sourcePath: source.path,
            peerFactory: (_) async => pa,
            pollInterval: const Duration(milliseconds: 10),
          );
          final receiver = DirectTransfer(
            b,
            offer,
            peerFactory: (_) async => pb,
            receiveDirectory: () async => dir,
            pollInterval: const Duration(milliseconds: 10),
          );
          try {
            await sender.start();
            await receiver.start();
            await until(() => sender.ended && receiver.ended);
            expect(pa.channel.maxPacket, lessThanOrEqualTo(directChunkBytes));
            if (corrupt) {
              expect(sender.state, isNot('complete'));
              expect(receiver.state, 'failed');
              await until(
                () => !File(
                  '${dir.path}/received_chat_files/bob/test-transfer/receiving.part',
                ).existsSync(),
              );
            } else {
              expect(sender.state, 'complete');
              expect(receiver.state, 'complete');
              expect(pa.channel.sentBytes, bytes.length - resumeBytes);
              expect(await File(receiver.savedPath!).readAsBytes(), bytes);
              expect(
                receiver.savedPath!.startsWith(
                  '${dir.path}${Platform.pathSeparator}received_chat_files',
                ),
                true,
              );
            }
          } finally {
            await sender.shutdown();
            await receiver.shutdown();
            a.dispose();
            b.dispose();
            left.dispose();
            await dir.delete(recursive: true);
          }
        },
      );
    }
  }
  test('cancelling before acceptance never reports a completed send', () async {
    final server = Server();
    final live = Live('alice', server);
    final transfer = DirectTransfer(live, {
      'id': 'cancel-test',
      'name': 'file',
      'size': 10,
    }, sourcePath: 'unused');
    await transfer.start();
    expect(transfer.state, 'waiting');
    await transfer.cancel();
    expect(transfer.state, 'cancelled');
    expect(server.state, 'cancelled');
    expect(transfer.bytes, 0);
    await transfer.shutdown();
    live.dispose();
  });
  test('filenames cannot escape chosen transfer directory', () {
    expect(safeReceivedName('../a\\b.exe'), '.._a_b.exe');
    expect(safeReceivedName('...'), 'file');
    expect(maxDirectFileBytes, 5368709120);
  });
}
