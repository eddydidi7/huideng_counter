import 'package:flutter/material.dart';

class FileAssistantAvatar extends StatelessWidget {
  const FileAssistantAvatar({super.key, required this.size});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: const Color(0xff238b57),
      borderRadius: BorderRadius.circular(size * .22),
    ),
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned(
          left: size * .14,
          top: size * .14,
          child: Icon(
            Icons.insert_drive_file_outlined,
            color: Colors.white,
            size: size * .48,
          ),
        ),
        Positioned(
          right: size * .10,
          bottom: size * .08,
          child: Icon(Icons.sync_alt, color: Colors.white, size: size * .46),
        ),
      ],
    ),
  );
}
