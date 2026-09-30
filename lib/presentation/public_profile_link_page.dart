import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import 'public_profile_page.dart';

/// The in-app destination for a stable `/u/{public_id}` HTTPS link.
/// It deliberately reads the public RPC only, so a link cannot expose private
/// notes, contact remarks, files, or the authenticated profile payload.
class PublicProfileLinkPage extends StatelessWidget {
  const PublicProfileLinkPage({
    super.key,
    required this.app,
    required this.publicId,
  });
  final AppController app;
  final String publicId;

  @override
  Widget build(BuildContext context) =>
      PublicProfilePage.publicLink(app: app, publicId: publicId);
}
