import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:uuid/uuid.dart';
import '../core/app_controller.dart';
import '../data/repositories/chat_repository.dart';
import '../services/chat_voice_storage.dart';
import '../services/chat_audio_focus.dart';

class HoldToRecord extends StatefulWidget {
  final AppController app;
  final ChatRepository repository;
  final String room;
  final VoidCallback onQueued;
  const HoldToRecord({
    super.key,
    required this.app,
    required this.repository,
    required this.room,
    required this.onQueued,
  });
  @override
  State<HoldToRecord> createState() => _HoldToRecordState();
}

class _HoldToRecordState extends State<HoldToRecord>
    with WidgetsBindingObserver {
  final recorder = AudioRecorder();
  final watch = Stopwatch();
  Timer? tick;
  bool held = false,
      recording = false,
      cancel = false,
      starting = false,
      finishing = false;
  String? path, fileId;
  String codec = 'aac';
  String tr(String a, String b) => widget.app.text(a, b);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    chatCallActive.addListener(callChanged);
  }

  void callChanged() {
    if (chatCallActive.value) unawaited(finish(abort: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(finish(abort: true));
  }

  void notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> start() async {
    if (starting || finishing || recording || chatCallActive.value) return;
    held = true;
    cancel = false;
    starting = true;
    chatVoicePlayback.value = null;
    try {
      if (!await recorder.hasPermission()) {
        notice(tr('请允许麦克风权限后再录音', 'Microphone permission is required'));
        return;
      }
      if (!held || !mounted || chatCallActive.value) return;
      codec =
          Platform.isAndroid &&
              await recorder.isEncoderSupported(AudioEncoder.opus)
          ? 'opus'
          : 'aac';
      final dir = await ChatVoiceStorage.directory(
        widget.repository.remote.userId,
      );
      if (!held || !mounted || chatCallActive.value) return;
      fileId = const Uuid().v4();
      path = '${dir.path}/$fileId.${codec == 'opus' ? 'ogg' : 'm4a'}';
      await recorder.start(
        RecordConfig(
          encoder: codec == 'opus' ? AudioEncoder.opus : AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 48000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
        ),
        path: path!,
      );
      if (!held || !mounted || chatCallActive.value) {
        await recorder.cancel();
        return;
      }
      watch
        ..reset()
        ..start();
      setState(() => recording = true);
      tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (watch.elapsedMilliseconds >= 60000) {
          unawaited(finish());
        } else if (mounted) {
          setState(() {});
        }
      });
    } catch (e) {
      debugPrint('voice record start: ${e.runtimeType}');
      notice(
        tr('无法开始录音，请检查麦克风权限', 'Unable to record. Check microphone permission.'),
      );
    } finally {
      starting = false;
    }
  }

  Future<void> finish({bool abort = false}) async {
    held = false;
    if (finishing || !recording) return;
    finishing = true;
    tick?.cancel();
    watch.stop();
    final ms = watch.elapsedMilliseconds.clamp(0, 60000);
    final discard = abort || cancel || ms < 500;
    if (mounted) setState(() => recording = false);
    try {
      if (discard) {
        await recorder.cancel();
      } else {
        final saved = await recorder.stop();
        if (saved == null) throw StateError('VOICE_EMPTY');
        widget.repository.remote.checkUser();
        await widget.repository.store.enqueue(
          const Uuid().v4(),
          widget.room,
          '[语音]',
          attachment: {
            'voice_local_path': saved,
            'file_id': fileId,
            'codec': codec,
            'voice_duration_ms': ms,
          },
        );
        if (mounted) widget.onQueued();
      }
      if (!abort && ms < 500) notice(tr('说话时间太短', 'Recording is too short'));
    } catch (e) {
      debugPrint('voice record finish: ${e.runtimeType}');
      notice(tr('语音保存失败，请重试', 'Could not save voice message. Please retry.'));
    } finally {
      finishing = false;
    }
  }

  @override
  void dispose() {
    held = false;
    tick?.cancel();
    chatCallActive.removeListener(callChanged);
    WidgetsBinding.instance.removeObserver(this);
    // dispose cancels any live recording. Never send from a disposed page.
    unawaited(recorder.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onLongPressStart: (_) => start(),
    onLongPressMoveUpdate: (e) {
      if (mounted) setState(() => cancel = e.offsetFromOrigin.dy < -65);
    },
    onLongPressEnd: (_) => finish(),
    onLongPressCancel: () => finish(abort: true),
    child: Container(
      constraints: const BoxConstraints(minHeight: 48),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: cancel
            ? Theme.of(context).colorScheme.errorContainer
            : Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: Text(
        recording
            ? (cancel
                  ? tr('松开取消', 'Release to cancel')
                  : '${watch.elapsed.inSeconds}s · ${tr('上滑取消', 'Slide up to cancel')}')
            : tr('按住说话', 'Hold to talk'),
      ),
    ),
  );
}

/// One player per conversation, so continuous playback also works off screen.
class VoicePlaybackController extends ChangeNotifier
    with WidgetsBindingObserver {
  final ChatRepository repository;
  final AudioPlayer player = AudioPlayer();
  List<Map<String, dynamic>> playlist = [];
  final Set<String> played = {};
  StreamSubscription<void>? complete;
  bool loading = false, playing = false, disposed = false;
  int generation = 0;
  String? current, error;
  VoicePlaybackController(this.repository) {
    WidgetsBinding.instance.addObserver(this);
    chatVoicePlayback.addListener(selected);
    chatCallActive.addListener(callChanged);
    complete = player.onPlayerComplete.listen((_) {
      final index = playlist.indexWhere((m) => m['id'] == current);
      final next = index < 0
          ? null
          : playlist
                .skip(index + 1)
                .where(
                  (m) =>
                      m['sender_id'] != repository.remote.userId &&
                      !played.contains(m['id']),
                )
                .firstOrNull;
      chatVoicePlayback.value = next?['id'] as String?;
    });
  }
  void changed() {
    if (!disposed) notifyListeners();
  }

  void updateMessages(List<Map<String, dynamic>> messages) {
    playlist = messages
        .where(
          (m) =>
              m['recalled_at'] == null &&
              (m['voice_file_id'] != null || m['voice_local_path'] != null),
        )
        .toList();
    if (current != null && !playlist.any((m) => m['id'] == current)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!disposed &&
            current != null &&
            !playlist.any((m) => m['id'] == current)) {
          chatVoicePlayback.value = null;
        }
      });
    }
  }

  Future<void> loadPlayed(String id) async {
    if (played.contains(id)) return;
    if ((await repository.store.read('voice_played:$id')).isNotEmpty) {
      played.add(id);
      changed();
    }
  }

  void callChanged() {
    if (chatCallActive.value) chatVoicePlayback.value = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && current != null) {
      chatVoicePlayback.value = null;
    }
  }

  void selected() {
    final message = playlist
        .where((m) => m['id'] == chatVoicePlayback.value)
        .firstOrNull;
    if (message != null && !chatCallActive.value) {
      unawaited(play(message));
    } else {
      generation++;
      current = null;
      loading = false;
      playing = false;
      unawaited(player.stop());
      changed();
    }
  }

  Future<void> play(Map<String, dynamic> message) async {
    final request = ++generation;
    current = message['id'] as String;
    loading = true;
    playing = false;
    error = null;
    changed();
    await player.stop();
    try {
      final path = await ChatVoiceStorage(repository.remote).playable(message);
      if (disposed || request != generation || chatCallActive.value) return;
      await player.play(DeviceFileSource(path));
      if (disposed || request != generation) return;
      playing = true;
      played.add(current!);
      await repository.store.write('voice_played:$current', [
        {'played': true},
      ]);
    } catch (e) {
      debugPrint('voice playback: ${e.runtimeType}');
      if (!disposed && request == generation) {
        error = current;
        playing = false;
      }
    } finally {
      if (!disposed && request == generation) {
        loading = false;
        changed();
      }
    }
  }

  @override
  void dispose() {
    disposed = true;
    generation++;
    chatVoicePlayback.removeListener(selected);
    chatCallActive.removeListener(callChanged);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(complete?.cancel());
    unawaited(player.dispose());
    super.dispose();
  }
}

class VoiceMessageTile extends StatefulWidget {
  final AppController app;
  final VoicePlaybackController playback;
  final Map<String, dynamic> message;
  const VoiceMessageTile({
    super.key,
    required this.app,
    required this.playback,
    required this.message,
  });
  @override
  State<VoiceMessageTile> createState() => _VoiceMessageTileState();
}

class _VoiceMessageTileState extends State<VoiceMessageTile> {
  String get id => widget.message['id'] as String;
  @override
  void initState() {
    super.initState();
    unawaited(widget.playback.loadPlayed(id));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.playback,
    builder: (context, _) {
      final p = widget.playback;
      final selected = p.current == id;
      return TextButton.icon(
        onPressed: chatCallActive.value
            ? null
            : () {
                if (selected && (p.playing || p.loading)) {
                  chatVoicePlayback.value = null;
                } else {
                  chatVoicePlayback.value = null;
                  chatVoicePlayback.value = id;
                }
              },
        icon: Icon(
          selected && p.loading
              ? Icons.hourglass_top
              : selected && p.playing
              ? Icons.stop_circle_outlined
              : Icons.volume_up_outlined,
        ),
        label: Text(
          p.error == id
              ? widget.app.text('播放失败 · 点击重试', 'Playback failed · retry')
              : '${((widget.message['voice_duration_ms'] as num? ?? 0) / 1000).ceil()}″'
                    '${!p.played.contains(id) && widget.message['sender_id'] != p.repository.remote.userId ? ' •' : ''}',
        ),
      );
    },
  );
}
