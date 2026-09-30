import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_controller.dart';
import 'home_page.dart';
import 'settings_page.dart';
import 'shared.dart';
import 'notes_page.dart';
import 'chat_page.dart';
import 'chat_navigation_icon.dart';
import 'forum_page.dart';
import 'tibetan_calendar_page.dart';

class AppShell extends StatefulWidget {
  final AppController app;
  const AppShell({super.key, required this.app});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int selected = 0;
  int chatUnread = 0;
  Widget navMark(String label, Color color) => SizedBox(
    width: 54,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: ExcludeSemantics(
        child: Text(
          label,
          maxLines: 1,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    ),
  );
  Future<void> selectDestination(int value) async {
    setState(() => selected = value);
  }

  // A pushed sub-page (chat room, note editor, forum post, ...) covers this
  // whole Scaffold via the root Navigator, so it naturally stops hit-testing
  // from reaching this gesture detector at all — no extra "are we on a
  // sub-page" check is needed. Within a module's own root page, any more
  // specific horizontal gesture (forum channel/image swipe, a slider, a
  // horizontal list) sits deeper in the tree and is hit-tested first, so it
  // wins the gesture arena over this outer, whole-page detector.
  void swipeModule(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 200) return;
    if (velocity < 0 && selected < 4) {
      selectDestination(selected + 1);
    } else if (velocity > 0 && selected > 0) {
      selectDestination(selected - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accents = dark
        ? const [
            Color(0xFF64B5F6),
            Color(0xFFDF9298),
            Color(0xFF39D985),
            Color(0xFFC598FF),
            Color(0xFFFFC94A),
          ]
        : const [
            Color(0xFF176CB2),
            Color(0xFFAC4D59),
            Color(0xFF078544),
            Color(0xFF833FC2),
            Color(0xFF976400),
          ];
    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: swipeModule,
        child: IndexedStack(
        index: selected,
        children:
            <Widget>[
                  HomePage(app: app),
                  ForumPage(app: app, embedded: true),
                  ChatPage(
                    app: app,
                    onUnreadChanged: (value) {
                      if (mounted && value != chatUnread) {
                        setState(() => chatUnread = value);
                      }
                    },
                  ),
                  NotesPage(app: app),
                  TibetanCalendarPage(app: app),
                ].indexed
                .map(
                  (entry) => TickerMode(
                    enabled: selected == entry.$1,
                    child: entry.$2,
                  ),
                )
                .toList(),
        ),
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          indicatorColor: accents[selected].withValues(
            alpha: dark ? 0.22 : 0.14,
          ),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: 12,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
              color: states.contains(WidgetState.selected)
                  ? accents[selected]
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        child: NavigationBar(
          height: 48,
          elevation: 0,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
          selectedIndex: selected,
          onDestinationSelected: selectDestination,
          destinations: [
            NavigationDestination(
              icon: navMark('计数', accents[0]),
              selectedIcon: navMark('计数', accents[0]),
              label: app.text('计数', 'Counter'),
            ),
            NavigationDestination(
              icon: navMark('红书', accents[1]),
              selectedIcon: navMark('红书', accents[1]),
              label: app.text('红书', 'Hongshu'),
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: chatUnread > 0,
                label: Text(chatUnread > 99 ? '99+' : '$chatUnread'),
                child: ChatNavigationIcon(selected: selected == 2),
              ),
              label: app.text('聊天', 'Chat'),
            ),
            NavigationDestination(
              icon: navMark('笔记', accents[3]),
              selectedIcon: navMark('笔记', accents[3]),
              label: app.text('笔记', 'Notes'),
            ),
            NavigationDestination(
              icon: navMark('藏历', accents[4]),
              selectedIcon: navMark('藏历', accents[4]),
              label: app.text('藏历', 'Calendar'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Preserves existing configured website access until the native modules are connected.
class WebModulePage extends StatelessWidget {
  final AppController app;
  final bool forum;
  const WebModulePage({super.key, required this.app, required this.forum});
  @override
  Widget build(BuildContext context) {
    final value = forum ? app.forumUrl : app.calendarUrl;
    final uri = Uri.tryParse(value);
    final configured =
        uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          forum
              ? app.text('红书', 'Hongshu')
              : app.text('藏历', 'Tibetan Calendar'),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  forum ? Icons.forum_outlined : Icons.calendar_month_outlined,
                  size: 56,
                ),
                const SizedBox(height: 20),
                Text(
                  configured
                      ? app.text(
                          '可打开已配置的网页',
                          'Your configured website is available',
                        )
                      : app.text(
                          '内容服务尚未连接',
                          'Content service is not connected',
                        ),
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  app.text(
                    '目前保留网页入口，可在设置中配置。',
                    'Website access is available through the URL in Settings.',
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                if (configured)
                  FilledButton.icon(
                    icon: const Icon(Icons.open_in_new),
                    label: Text(app.text('打开网页', 'Open website')),
                    onPressed: () async {
                      try {
                        if (!await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        )) {
                          throw StateError('launch');
                        }
                      } catch (e) {
                        if (context.mounted) showFailure(context, app, e);
                      }
                    },
                  ),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => SettingsPage(app: app),
                    ),
                  ),
                  child: Text(app.text('设置', 'Settings')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
