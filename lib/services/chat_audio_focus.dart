import 'package:flutter/foundation.dart';

/// Prevent recording/playback from competing with an incoming or active call.
final chatCallActive = ValueNotifier(false);
final chatVoicePlayback = ValueNotifier<String?>(null);
