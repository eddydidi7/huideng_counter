import 'presentation/resource_warning_host.dart';
import 'presentation/app_update_host.dart';
import 'presentation/content_link_host.dart';
import 'presentation/public_profile_link_page.dart';
import 'presentation/forum_link_page.dart';
import 'dart:async';
import 'dart:io';
import 'services/solar_reminder_service.dart';
import 'core/notices_controller.dart';
import 'data/repositories/notices_repository.dart';
import 'core/app_links_controller.dart';
import 'data/repositories/app_links_repository.dart';
import 'package:path_provider/path_provider.dart';
import 'core/cloud_controller.dart';
import 'data/local/account_database_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'core/app_controller.dart';
import 'data/local/local_database.dart';
import 'data/repositories/sqlite_counter_repository.dart';
import 'presentation/app_shell.dart';
import 'presentation/voice_call_host.dart';
import 'core/home_message_controller.dart';
import 'data/local/home_message_cache.dart';
import 'data/repositories/home_message_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final repository = SqliteCounterRepository(await LocalDatabase.open());
    await repository.recoverSessions();
    final controller = AppController(repository);
    await controller.reload();
    final cloud = CloudController(
      controller,
      AccountDatabaseManager(
        Directory((await getApplicationSupportDirectory()).path),
        repository.db,
      ),
    );
    controller.cloud = cloud;
    final homeMessage = HomeMessageController(
      HomeMessageRepository(HomeMessageCache()),
    );
    controller.homeMessage = homeMessage;
    final appLinks = AppLinksController(
      AppLinksRepository(HomeMessageCache(cacheKey: 'app_links')),
    );
    controller.appLinks = appLinks;
    final notices = NoticesController(
      NoticesRepository(HomeMessageCache(cacheKey: 'notices')),
    );
    controller.notices = notices;
    unawaited(notices.initialize());
    unawaited(appLinks.initialize());
    runApp(HuidengApp(controller: controller));
    SolarReminderService.instance.start();
    unawaited(homeMessage.initialize());
    unawaited(cloud.initialize());
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '无法打开本地数据库，请重启应用。\nUnable to open local database. Please restart.\n$error',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HuidengApp extends StatelessWidget {
  final AppController controller;
  const HuidengApp({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) => MaterialApp(
      key: ValueKey(controller.scopeId),
      navigatorKey: controller.navigatorKey,
      debugShowCheckedModeBanner: false,
      title: controller.text('文殊计数器', 'Manjushri Counter'),
      locale: Locale(controller.english ? 'en' : 'zh'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [
        ...GlobalMaterialLocalizations.delegates,
        FlutterQuillLocalizations.delegate,
      ],
      themeMode: switch (controller.colorPreference) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      },
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff806044),
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: Colors.white,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xffc4a578),
          brightness: Brightness.dark,
          surface: const Color(0xff101010),
        ),
        scaffoldBackgroundColor: const Color(0xff101010),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: AppUpdateHost(app: controller, child: AppShell(app: controller)),
      onGenerateRoute: (settings) {
        final uri = Uri.tryParse(settings.name ?? '');
        if (uri != null && uri.pathSegments.length == 2 && uri.pathSegments.first == 'u') {
          return MaterialPageRoute(
            settings: settings,
            builder: (_) => PublicProfileLinkPage(app: controller, publicId: uri.pathSegments[1]),
          );
        }
        if (uri != null &&
            uri.pathSegments.length == 2 &&
            uri.pathSegments.first == 'p' &&
            isForumShareSlug(uri.pathSegments[1])) {
          return MaterialPageRoute(
            settings: settings,
            builder: (_) => ForumLinkPage(app: controller, slug: uri.pathSegments[1]),
          );
        }
        return null;
      },
      builder: (context, child) => ContentLinkHost(
        app: controller,
        navigatorKey: controller.navigatorKey,
        child: ResourceWarningHost(
          app: controller,
          child: VoiceCallHost(app: controller, child: child!),
        ),
      ),
    ),
  );
}
