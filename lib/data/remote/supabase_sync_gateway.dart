import '../../services/resource_upload_policy.dart';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../sync/local_sync_store.dart';
import '../sync/sync_coordinator.dart';
import '../sync/snapshot_builder.dart';

class SupabaseSyncGateway implements SyncGateway {
  final SupabaseClient client;
  final String userId;
  final Directory images;
  SupabaseSyncGateway(this.client, this.userId, this.images);
  void owner() {
    if (client.auth.currentUser?.id != userId) {
      throw const SyncFailure(
        'authentication_required',
        authenticationRequired: true,
      );
    }
  }

  @override
  Future<PushReply> push(SyncJob job) async {
    owner();
    if (job.userId != userId) {
      throw const SyncFailure('wrong_owner', authenticationRequired: true);
    }
    try {
      if (job.entityType == 'image') {
        final source = job.payload['path'] as String?;
        if (source == null) return const PushReply.accepted(0);
        final file = File(source);
        if (!await file.exists()) {
          return const PushReply.conflict('image_missing', null);
        }
        if (await file.length() > 20 * 1024 * 1024) {
          return const PushReply.conflict('image_too_large', null);
        }
        final bytes = await file.readAsBytes();
        final ext = path.extension(source).toLowerCase();
        final mime = switch (ext) {
          '.png' => 'image/png',
          '.webp' => 'image/webp',
          '.jpg' || '.jpeg' => 'image/jpeg',
          _ => null,
        };
        if (mime == null) {
          return const PushReply.conflict('unsupported_image', null);
        }
        final key = '$userId/${job.entityId}/${sha256.convert(bytes)}$ext';
        owner();
        try {
          await checkResourceUpload(client, key, bytes.length, mime: mime);
          await client.storage
              .from('counter-images')
              .uploadBinary(
                key,
                bytes,
                fileOptions: FileOptions(contentType: mime, upsert: false),
              );
        } on StorageException catch (e) {
          if (e.statusCode != '409' && e.error != 'Duplicate') rethrow;
          final existing = await client.storage
              .from('counter-images')
              .download(key);
          if (sha256.convert(existing) != sha256.convert(bytes)) {
            return const PushReply.conflict('image_collision', null);
          }
        }
        owner();
        return PushReply.accepted(0, {'image_key': key, 'path': source});
      }
      if (job.entityType == 'download') {
        final key = job.payload['image_key'] as String?;
        if (key == null) return const PushReply.accepted(0);
        if (!key.startsWith('$userId/${job.entityId}/') || key.contains('..')) {
          return const PushReply.conflict('invalid_image_path', null);
        }
        final bytes = await client.storage.from('counter-images').download(key);
        if (bytes.length > 20 * 1024 * 1024) {
          return const PushReply.conflict('image_too_large', null);
        }
        final filename = path.basename(key);
        if (path.basenameWithoutExtension(filename) !=
            sha256.convert(bytes).toString()) {
          return const PushReply.conflict('image_checksum', null);
        }
        await images.create(recursive: true);
        final destination = File(path.join(images.path, filename));
        final temp = File('${destination.path}.tmp');
        await temp.writeAsBytes(bytes, flush: true);
        owner();
        if (!await destination.exists()) {
          await temp.rename(destination.path);
        } else {
          await temp.delete();
        }
        return PushReply.accepted(0, {
          'image_key': key,
          'path': destination.path,
        });
      }
      final raw = job.entityType == 'event'
          ? await client.rpc(
              'counter_push_event',
              params: {'p_event': job.payload},
            )
          : await client.rpc(
              'counter_put_document',
              params: {
                'p_kind': job.entityType,
                'p_id': job.entityId,
                'p_expected_revision': job.payload['base_revision'],
                'p_data': job.payload['data'],
                'p_request_id': job.requestId,
              },
            );
      owner();
      final reply = jsonMap(raw);
      if (reply['status'] == 'accepted') {
        return PushReply.accepted(reply['revision'] as int);
      }
      if (reply['status'] == 'conflict') {
        return PushReply.conflict(reply['reason'] as String, {
          'data': reply['remote'],
          'revision': reply['revision'],
        });
      }
      throw const SyncFailure('dependency_missing');
    } on PostgrestException catch (e) {
      if (['PGRST301', 'PGRST303'].contains(e.code)) {
        throw const SyncFailure(
          'session_expired',
          authenticationRequired: true,
        );
      }
      if (e.code == '42501' ||
          e.code?.startsWith('22') == true ||
          e.code == 'P0001' ||
          e.code?.startsWith('23') == true) {
        return PushReply.conflict('server_rejected', {'code': e.code});
      }
      rethrow;
    } on StorageException catch (e) {
      if (e.statusCode == '401') {
        throw const SyncFailure(
          'session_expired',
          authenticationRequired: true,
        );
      }
      if (e.statusCode == '403') {
        return const PushReply.conflict('storage_denied', null);
      }
      rethrow;
    }
  }

  @override
  Future<PullPage> pull(int after) async {
    owner();
    try {
      final raw = await client.rpc(
        'counter_pull',
        params: {'p_after': after, 'p_limit': 200},
      );
      owner();
      final rows = (raw as List).map(jsonMap).toList();
      var last = after;
      for (final r in rows) {
        if (r['user_id'] != userId ||
            r['revision'] is! int ||
            (r['revision'] as int) <= last) {
          throw StateError('Invalid feed');
        }
        last = r['revision'] as int;
      }
      return PullPage(last, rows, hasMore: rows.length == 200);
    } on PostgrestException catch (e) {
      if (['PGRST301', 'PGRST303', '42501'].contains(e.code)) {
        throw const SyncFailure(
          'session_expired',
          authenticationRequired: true,
        );
      }
      rethrow;
    }
  }
}
