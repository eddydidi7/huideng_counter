/// Prefer negotiated Opus without removing fallback codecs. FEC is requested;
/// actual support still depends on both WebRTC endpoints.
String preferVoiceOpus(String sdp) {
  final lines = sdp.split('\r\n');
  final opus = RegExp(r'^a=rtpmap:(\d+) opus/48000', caseSensitive: false);
  String? payload;
  for (final line in lines) {
    final match = opus.firstMatch(line);
    if (match != null) {
      payload = match.group(1);
      break;
    }
  }
  if (payload == null) return sdp;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('m=audio ')) {
      final parts = lines[i].split(' ');
      final codecs = parts.skip(3).toList();
      if (codecs.remove(payload)) {
        lines[i] = [...parts.take(3), payload, ...codecs].join(' ');
      }
    }
    if (lines[i].startsWith('a=fmtp:$payload ')) {
      final parameters = lines[i]
          .substring('a=fmtp:$payload '.length)
          .split(';')
          .where(
            (p) =>
                !p.trim().startsWith('useinbandfec=') &&
                !p.trim().startsWith('maxaveragebitrate='),
          );
      lines[i] =
          'a=fmtp:$payload ${[...parameters, 'useinbandfec=1', 'maxaveragebitrate=32000'].join(';')}';
      return lines.join('\r\n');
    }
  }
  final index = lines.indexWhere((l) => opus.hasMatch(l));
  lines.insert(
    index + 1,
    'a=fmtp:$payload useinbandfec=1;maxaveragebitrate=32000',
  );
  return lines.join('\r\n');
}
