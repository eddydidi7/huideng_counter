import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import 'public_profile_page.dart';

// A profile opened from an above-Navigator overlay must be visible over it.
final profileOverlayDepth = ValueNotifier<int>(0);

Future<void> openUserProfile(
  BuildContext context,
  AppController app, {
  String? userId,
  String? publicId,
  String? groupId,
}) async {
  if (!context.mounted) return;
  if ((userId == null || userId.isEmpty) &&
      (publicId == null || publicId.isEmpty)) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('暂时无法确定该用户，请稍后重试')));
    return;
  }
  final current = context.findAncestorWidgetOfExactType<PublicProfilePage>();
  if (current != null &&
      (publicId != null
          ? current.publicId == publicId
          : current.userId == userId)) {
    return;
  }
  final local = Navigator.maybeOf(context);
  final navigator = local ?? app.navigatorKey.currentState;
  if (navigator == null) return;
  final aboveNavigator = local == null;
  if (aboveNavigator) profileOverlayDepth.value++;
  try {
    await navigator.push<void>(
      MaterialPageRoute(
        settings: RouteSettings(name: '/profile/${publicId ?? userId}'),
        builder: (_) => publicId != null
            ? PublicProfilePage.publicLink(app: app, publicId: publicId)
            : PublicProfilePage(app: app, userId: userId!, groupId: groupId),
      ),
    );
  } finally {
    if (aboveNavigator) profileOverlayDepth.value--;
  }
}
