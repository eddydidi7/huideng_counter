import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/app_controller.dart';
import '../data/remote/chat_remote.dart';
import '../services/voice_call_service.dart';
import 'chat_avatar.dart';
import 'video_call_panel.dart';

class VoiceCallScope extends InheritedWidget {
  final VoiceCallService? service;
  const VoiceCallScope({
    super.key,
    required this.service,
    required super.child,
  });
  static VoiceCallService? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VoiceCallScope>()?.service;
  @override
  bool updateShouldNotify(VoiceCallScope oldWidget) =>
      service != oldWidget.service;
}

class VoiceCallHost extends StatefulWidget {
  final AppController app;
  final Widget child;
  const VoiceCallHost({super.key, required this.app, required this.child});
  @override
  State<VoiceCallHost> createState() => _VoiceCallHostState();
}

class _VoiceCallHostState extends State<VoiceCallHost>
    with WidgetsBindingObserver {
  VoiceCallService? service;
  StreamSubscription<AuthState>? auth;
  SupabaseClient? client;
  String tr(String a, String b) => widget.app.text(a, b);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.app.addListener(configure);
    configure();
  }

  void configure() {
    final next = widget.app.cloud?.client;
    if (next != client) {
      unawaited(auth?.cancel());
      client = next;
      auth = next?.auth.onAuthStateChange.listen((_) => configure());
    }
    final id = next?.auth.currentUser?.id;
    if (id == service?.remote.userId) return;
    service?.removeListener(changed);
    service?.dispose();
    service = id == null || next == null
        ? null
        : VoiceCallService(ChatRemote(next, id));
    service?.addListener(changed);
    if (mounted) setState(() {});
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    service?.setVisible(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) unawaited(service?.poll());
  }

  @override
  void dispose() {
    widget.app.removeListener(configure);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(auth?.cancel());
    service?.removeListener(changed);
    service?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = service;
    return VoiceCallScope(
      service: s,
      child: Stack(
        children: [
          widget.child,
          if (s?.active == true)
            Positioned.fill(
              child: PopScope(
                canPop: false,
                child: Scaffold(
                  body: s!.isVideo
                      ? VideoCallPanel(service: s, tr: tr)
                      : SafeArea(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                ChatAvatar(
                                  remote: s.remote,
                                  roomId: s.call!['room_id'] as String,
                                  radius: 42,
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  s.name,
                                  style: const TextStyle(fontSize: 24),
                                ),
                                const SizedBox(height: 10),
                                Text(tr('语音通话', 'Voice call')),
                                const SizedBox(height: 20),
                                Text(
                                  s.connectedAt != null
                                      ? _duration(
                                          DateTime.now().difference(
                                            s.connectedAt!,
                                          ),
                                        )
                                      : s.incoming
                                      ? tr('来电', 'Incoming call')
                                      : s.status == 'ringing'
                                      ? tr('等待接听…', 'Ringing…')
                                      : tr('正在连接…', 'Connecting…'),
                                  style: const TextStyle(fontSize: 28),
                                ),
                                if (s.status == 'reconnecting')
                                  Text(
                                    tr(
                                      '网络变化，正在重新连接…',
                                      'Network changed. Reconnecting…',
                                    ),
                                  ),
                                if (s.connectedAt != null)
                                  Text(
                                    s.quality == 'good'
                                        ? tr('网络良好', 'Good connection')
                                        : s.quality == 'fair'
                                        ? tr('网络一般', 'Fair connection')
                                        : s.quality == 'poor'
                                        ? tr('网络较差', 'Poor connection')
                                        : tr('正在检测网络', 'Checking connection'),
                                  ),
                                if (!s.turnConfigured && !s.incoming)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 16),
                                    child: Text(
                                      tr(
                                        '中继尚未配置，部分网络可能无法接通',
                                        'Relay is not configured; some networks may not connect.',
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                const SizedBox(height: 40),
                                Wrap(
                                  spacing: 20,
                                  runSpacing: 16,
                                  alignment: WrapAlignment.center,
                                  children: [
                                    if (s.incoming)
                                      FilledButton.icon(
                                        onPressed: s.creating ? null : s.accept,
                                        icon: const Icon(Icons.call),
                                        label: Text(tr('接听', 'Accept')),
                                      ),
                                    if (!s.incoming) ...[
                                      IconButton.filledTonal(
                                        onPressed: s.toggleMute,
                                        icon: Icon(
                                          s.muted ? Icons.mic_off : Icons.mic,
                                        ),
                                        tooltip: tr('静音', 'Mute'),
                                      ),
                                      IconButton.filledTonal(
                                        onPressed: s.toggleSpeaker,
                                        icon: Icon(
                                          s.speaker
                                              ? Icons.volume_up
                                              : Icons.hearing,
                                        ),
                                        tooltip: tr('扬声器', 'Speaker'),
                                      ),
                                    ],
                                    FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                                      onPressed: () =>
                                          s.hangup(decline: s.incoming),
                                      icon: const Icon(Icons.call_end),
                                      label: Text(
                                        s.incoming
                                            ? tr('拒绝', 'Decline')
                                            : tr('挂断', 'End'),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
            ),
          if (s != null && !s.active && s.failure != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 100,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          s.failure!.contains('CALL_BUSY')
                              ? tr(
                                  '对方正在通话，请稍后再试',
                                  'The user is busy. Try later.',
                                )
                              : s.failure!.contains('TURN_REQUIRED')
                              ? tr(
                                  '当前网络无法直连，需配置通话中继后重试',
                                  'Direct connection failed. Configure a relay and retry.',
                                )
                              : tr(
                                  '通话未接通或已中断，请检查网络、麦克风、摄像头权限和通话服务配置',
                                  'Call failed or disconnected. Check network, microphone permission and call service configuration.',
                                ),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          s.failure = null;
                          changed();
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _duration(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}
