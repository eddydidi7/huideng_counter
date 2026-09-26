import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/voice_call_service.dart';

class VideoCallPanel extends StatelessWidget {
  final VoiceCallService service;
  final String Function(String, String) tr;
  const VideoCallPanel({super.key, required this.service, required this.tr});
  @override
  Widget build(BuildContext context) {
    final s = service;
    final elapsed = s.connectedAt == null
        ? null
        : DateTime.now().difference(s.connectedAt!);
    final status = s.status == 'reconnecting'
        ? tr('正在重新连接…', 'Reconnecting…')
        : elapsed != null
        ? '${elapsed.inMinutes.toString().padLeft(2, '0')}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}'
        : s.incoming
        ? tr('视频来电', 'Incoming video call')
        : s.status == 'ringing'
        ? tr('等待接听…', 'Ringing…')
        : tr('正在连接…', 'Connecting…');
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              textColor: Colors.white,
              title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(status),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (s.renderer.srcObject != null)
                    RTCVideoView(
                      s.renderer,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    )
                  else
                    Center(
                      child: Icon(
                        Icons.videocam_outlined,
                        size: 72,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  if (s.localRenderer.srcObject != null)
                    Positioned(
                      right: 12,
                      top: 12,
                      width: 112,
                      height: 150,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: s.cameraEnabled && s.visible
                            ? RTCVideoView(
                                s.localRenderer,
                                mirror: s.frontCamera,
                                objectFit: RTCVideoViewObjectFit
                                    .RTCVideoViewObjectFitCover,
                              )
                            : const ColoredBox(
                                color: Color(0xff292929),
                                child: Icon(
                                  Icons.videocam_off,
                                  color: Colors.white,
                                ),
                              ),
                      ),
                    ),
                ],
              ),
            ),
            if (!s.turnConfigured && !s.incoming)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  tr('部分网络可能无法接通', 'Some networks may not connect.'),
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  if (s.incoming)
                    FilledButton.icon(
                      onPressed: s.creating ? null : s.accept,
                      icon: const Icon(Icons.videocam),
                      label: Text(tr('接听', 'Accept')),
                    ),
                  if (!s.incoming) ...[
                    IconButton.filledTonal(
                      onPressed: s.toggleMute,
                      tooltip: tr('静音', 'Mute'),
                      icon: Icon(s.muted ? Icons.mic_off : Icons.mic),
                    ),
                    IconButton.filledTonal(
                      onPressed: s.toggleSpeaker,
                      tooltip: tr('扬声器', 'Speaker'),
                      icon: Icon(s.speaker ? Icons.volume_up : Icons.hearing),
                    ),
                    IconButton.filledTonal(
                      onPressed: s.toggleCamera,
                      tooltip: tr('开关摄像头', 'Toggle camera'),
                      icon: Icon(
                        s.cameraEnabled ? Icons.videocam : Icons.videocam_off,
                      ),
                    ),
                    IconButton.filledTonal(
                      onPressed: s.switchCamera,
                      tooltip: tr('切换摄像头', 'Switch camera'),
                      icon: const Icon(Icons.cameraswitch),
                    ),
                  ],
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                    ),
                    onPressed: () => s.hangup(decline: s.incoming),
                    icon: const Icon(Icons.call_end),
                    label: Text(
                      s.incoming ? tr('拒绝', 'Decline') : tr('挂断', 'End'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
