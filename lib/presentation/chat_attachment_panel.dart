import 'package:flutter/material.dart';

class ChatAttachmentPanel extends StatelessWidget {
  const ChatAttachmentPanel({
    super.key,
    required this.english,
    required this.onSelected,
    this.enabled = true,
  });
  final bool english, enabled;
  final ValueChanged<String> onSelected;
  static const actions = <(String, IconData, String, String)>[
    ('image', Icons.photo_outlined, '相册', 'Photos'),
    ('camera', Icons.photo_camera_outlined, '拍照', 'Camera'),
    ('video', Icons.videocam_outlined, '视频通话', 'Video call'),
    ('location', Icons.location_on_outlined, '位置', 'Location'),
    ('file', Icons.folder_outlined, '文件', 'Files'),
    ('music', Icons.music_note_outlined, '音乐', 'Music'),
    ('dictation', Icons.mic_none_outlined, '语音输入', 'Dictation'),
    ('call', Icons.call_outlined, '语音通话', 'Voice call'),
    ('direct', Icons.swap_horiz, '在线直传', 'Direct transfer'),
  ];
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 238,
    child: GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisExtent: 94,
        crossAxisSpacing: 6,
      ),
      itemCount: actions.length,
      itemBuilder: (context, i) {
        final a = actions[i];
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? () => onSelected(a.$1) : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(a.$2, size: 31),
              ),
              const SizedBox(height: 5),
              Text(
                english ? a.$4 : a.$3,
                style: const TextStyle(fontSize: 12),
                maxLines: 2,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      },
    ),
  );
}
