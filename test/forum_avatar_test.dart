import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:huideng_counter/presentation/chat_avatar.dart';
import 'package:huideng_counter/services/chat_image.dart';

void main() {
  test('public avatars use current profile path and fail closed', () async {
    String? path = 'author/current.jpg';
    final signed = <String>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-key',
      httpClient: MockClient((request) async {
        if (request.url.path.contains('/rpc/public_forum_avatar')) {
          return http.Response(
            jsonEncode(path),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        signed.add(request.url.path);
        return http.Response(
          jsonEncode({
            'signedURL': '/object/sign/chat-avatars/$path?token=test',
          }),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    expect(await client.rpc<dynamic>('public_forum_avatar'), path);
    expect(
      await client.storage.from('chat-avatars').createSignedUrl(path, 300),
      contains('current.jpg'),
    );
    signed.clear();
    final avatar = ChatAvatar(publicClient: client, userId: 'author');
    expect(await avatar.load(), contains('current.jpg'));
    path = 'author/replacement.jpg';
    expect(await avatar.load(), contains('replacement.jpg'));
    path = null;
    expect(await avatar.load(), isNull);
    expect(signed, hasLength(2));
    await client.dispose();
  });

  test(
    'avatar upload creates a bounded thumbnail without changing chat images',
    () {
      final input = img.encodePng(img.Image(width: 800, height: 400));
      final avatar = img.decodeImage(compressChatAvatar(input))!;
      expect(avatar.width, 256);
      expect(avatar.height, 128);
      expect(img.decodeImage(compressChatImage(input))!.width, 800);
    },
  );
}
