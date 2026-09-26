import 'package:flutter/material.dart';

bool showChatTime(String? current, String? previous) {
  final at = DateTime.tryParse(current ?? '');
  if (at == null) return false;
  final before = DateTime.tryParse(previous ?? '');
  return before == null || at.difference(before) >= const Duration(minutes: 5);
}

String chatTimeLabel(DateTime at, DateTime now, {required bool english}) {
  at = at.toLocal();
  now = now.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = DateTime(now.year, now.month, now.day - 1);
  final day = DateTime(at.year, at.month, at.day);
  final clock =
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  if (day == today) return clock;
  if (day == yesterday) return '${english ? 'Yesterday' : '昨天'} $clock';
  return '${at.year == now.year ? '' : '${at.year}/'}${at.month}/${at.day} $clock';
}

/// Shared surface for text, voice, attachments and persisted call records.
class ChatMessageBubble extends StatelessWidget {
  const ChatMessageBubble({super.key, required this.mine, required this.child});
  final bool mine;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final background = mine
        ? (dark ? const Color(0xff41634d) : const Color(0xffc8dfbf))
        : (dark ? const Color(0xff303330) : const Color(0xfff1f2ef));
    final foreground = dark ? const Color(0xfff4f6f2) : const Color(0xff1c2820);
    return Theme(
      data: theme.copyWith(
        textTheme: theme.textTheme.apply(
          bodyColor: foreground,
          displayColor: foreground,
        ),
        iconTheme: theme.iconTheme.copyWith(color: foreground),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: foreground),
        ),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: foreground),
        child: Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          color: background,
          child: child,
        ),
      ),
    );
  }
}
