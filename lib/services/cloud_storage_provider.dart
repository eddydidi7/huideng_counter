import 'resource_upload_policy.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract interface class CloudStorageProvider {
  Future<void> upload(String bucket, String key, File source);
  Future<void> uploadBytes(
    String bucket,
    String key,
    Uint8List data, {
    required String contentType,
  });
  Future<String> signedUrl(String bucket, String key, int seconds);
}

class SupabaseStorageProvider implements CloudStorageProvider {
  SupabaseStorageProvider(this.client);
  final SupabaseClient client;
  @override
  Future<void> upload(String bucket, String key, File source) async {
    await checkResourceUpload(client, source.path, await source.length());
    await client.storage.from(bucket).upload(key, source);
  }

  @override
  Future<void> uploadBytes(
    String bucket,
    String key,
    Uint8List data, {
    required String contentType,
  }) async {
    await checkResourceUpload(client, key, data.length, mime: contentType);
    await client.storage
        .from(bucket)
        .uploadBinary(
          key,
          data,
          fileOptions: FileOptions(contentType: contentType),
        );
  }

  @override
  Future<String> signedUrl(String bucket, String key, int seconds) =>
      client.storage.from(bucket).createSignedUrl(key, seconds);
}
