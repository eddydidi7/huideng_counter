import 'resource_share.dart';
import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../data/remote/public_resource_api.dart';
import 'public_resources_page.dart';

class CloudDrivePage extends StatelessWidget {
  const CloudDrivePage({
    super.key,
    required this.app,
    required this.settingsPage,
    this.initialResourceId,
  });
  final AppController app;
  final Widget settingsPage;
  final String? initialResourceId;
  @override
  Widget build(BuildContext context) => PublicResourcesPage(
    translate: app.text,
    initialResourceId: initialResourceId,
    onShare: (file) => shareResource(context, app, file),
    onSaveToGroup: (file) => saveResourceToGroup(context, app, file),
    settingsPage: settingsPage,
    createApi: () {
      final client = app.cloud?.client;
      if (client == null) return null;
      return PublicResourceApi.supabase(client);
    },
  );
}
