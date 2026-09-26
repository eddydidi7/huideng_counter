import 'package:flutter/material.dart';

class ChatTopBar extends StatelessWidget {
  const ChatTopBar({
    super.key,
    required this.english,
    this.onContacts,
    this.onProfile,
    required this.onResources,
    this.onCommunity,
    this.onSearch,
    this.onAdd,
  });
  final bool english;
  final VoidCallback? onContacts, onSearch, onProfile;
  final VoidCallback? onCommunity;
  final VoidCallback onResources;
  final ValueChanged<String>? onAdd;
  String tr(String zh, String en) => english ? en : zh;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final blue = Color(dark ? 0xFF65BFFF : 0xFF146EB4);
    final yellow = Color(dark ? 0xFFFFD54F : 0xFFA87300);
    return Row(
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
            tooltip: tr('个人主页', 'Profile'),
            onPressed: onProfile,
            padding: EdgeInsets.zero,
            // Keep the existing 48dp touch target; only the profile glyph is
            // enlarged so it matches the visual weight of the other controls.
            icon: const Icon(
              Icons.person_outline,
              color: Color(0xFF65BFFF),
              size: 37,
            ),
          ),
        ),
        for (final entry in [(tr('网盘', 'Drive'), onResources, 1, blue)])
          Expanded(
            flex: entry.$3,
            child: TextButton(
              onPressed: entry.$2,
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 48),
                padding: const EdgeInsets.symmetric(horizontal: 1),
                foregroundColor: entry.$4,
                textStyle: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(entry.$1, maxLines: 1),
              ),
            ),
          ),
        SizedBox(
          width: 52,
          height: 48,
          child: IconButton(
            tooltip: tr('搜索', 'Search'),
            onPressed: onSearch,
            style: IconButton.styleFrom(
              side: BorderSide(color: Theme.of(context).colorScheme.outline),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.search, size: 31),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 12, right: 8),
          child: SizedBox(
            width: 52,
            height: 48,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: yellow, width: 1.5),
                borderRadius: BorderRadius.circular(10),
                color: yellow.withValues(alpha: 0.06),
              ),
              child: PopupMenuButton<String>(
                tooltip: tr('添加', 'Add'),
                enabled: onAdd != null,
                padding: EdgeInsets.zero,
                icon: Icon(Icons.add, size: 26, color: yellow),
                onSelected: onAdd,
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'scan',
                    child: Text(tr('扫一扫', 'Scan QR code')),
                  ),
                  PopupMenuItem(
                    value: 'add',
                    child: Text(tr('添加好友', 'Add friend')),
                  ),
                  PopupMenuItem(
                    value: 'group',
                    child: Text(tr('创建群聊', 'Create group')),
                  ),
                  PopupMenuItem(
                    value: 'contacts',
                    child: Text(tr('发起聊天', 'Start chat')),
                  ),
                  PopupMenuItem(
                    value: 'privacy',
                    child: Text(tr('陌生人聊天开关', 'Stranger message settings')),
                  ),
                  PopupMenuItem(
                    value: 'profile_settings',
                    child: Text(tr('聊天资料与状态', 'Chat profile and status')),
                  ),
                  PopupMenuItem(
                    value: 'display',
                    child: Text(tr('显示方式 ›', 'Display mode ›')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
