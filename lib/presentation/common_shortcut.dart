import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import 'my_page.dart';

class CommonShortcut extends StatelessWidget {
  final AppController app;
  const CommonShortcut({super.key, required this.app});

  @override
  Widget build(BuildContext context) => TextButton(
    style: TextButton.styleFrom(
      foregroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF64B5F6)
          : const Color(0xFF176CB2),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
    ),
    onPressed: () => Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => SettingsServicesPage(app: app)),
    ),
    child: FittedBox(child: Text(app.text('常用', 'Common'))),
  );
}
