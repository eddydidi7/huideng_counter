import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/domain/voice_sdp.dart';

void main() {
  test('Audio preference leaves video negotiation unchanged', () {
    const video =
        'm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 VP8/90000\r\na=sendrecv\r\n';
    const audio =
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n';
    expect(preferVoiceOpus(audio + video), endsWith(video));
  });
  test('Opus preference preserves fallback codecs and existing fmtp', () {
    const sdp =
        'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 0 111 8\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=0\r\n';
    final result = preferVoiceOpus(sdp);
    expect(result, contains('m=audio 9 UDP/TLS/RTP/SAVPF 111 0 8'));
    expect(
      result,
      contains('minptime=10;useinbandfec=1;maxaveragebitrate=32000'),
    );
    expect(preferVoiceOpus(result), result);
  });
  test('No Opus is a valid fallback, missing fmtp is added', () {
    const fallback = 'v=0\r\nm=audio 9 RTP/AVP 0\r\n';
    expect(preferVoiceOpus(fallback), fallback);
    expect(
      preferVoiceOpus('m=audio 9 RTP/AVP 111\r\na=rtpmap:111 opus/48000/2\r\n'),
      contains('useinbandfec=1'),
    );
  });
}
