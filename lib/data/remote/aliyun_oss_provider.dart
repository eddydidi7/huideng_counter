import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide StorageCredential;
import '../../domain/cloud_file.dart';
import 'cloud_storage_provider.dart';
import 'oss_v4.dart';

class AliyunOssProvider extends CloudStorageProvider {
  AliyunOssProvider(this.client, this.owner);
  final SupabaseClient client;
  final String owner;
  final _http = http.Client();
  final Map<String, StorageCredential> _credentials = {};
  bool _closed = false;
  void guard() {
    if (_closed ||
        client.auth.currentUser?.id != owner ||
        client.auth.currentSession == null) {
      throw const DriveFailure('LOGIN_REQUIRED');
    }
  }

  Future<Map<String, dynamic>> _call(
    String action,
    Map<String, dynamic> payload,
  ) async {
    guard();
    try {
      final response = await client.functions
          .invoke('storage-token', body: {'action': action, ...payload})
          .timeout(const Duration(seconds: 90));
      guard();
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (e) {
      final details = e.details;
      throw DriveFailure(
        details is Map && details['error'] is String
            ? details['error'] as String
            : e.status == 401
            ? 'LOGIN_REQUIRED'
            : e.status == 404
            ? 'STORAGE_NOT_CONFIGURED'
            : 'STORAGE_REQUEST_FAILED',
      );
    }
  }

  @override
  Future<CloudListing> listFiles({
    bool trash = false,
    int offset = 0,
    String search = '',
    String sort = 'time',
  }) async => CloudListing(
    await _call('list', {
      'trash': trash,
      'offset': offset,
      'search': search,
      'sort': sort,
    }),
  );
  void _validateFile(CloudFile file) {
    guard();
    if (file.owner != owner ||
        file.key != 'users/$owner/cloud/${file.id}' ||
        file.deleted) {
      throw const DriveFailure('FILE_UNAVAILABLE');
    }
  }

  @override
  Future<CloudFile> uploadFile(
    DriveUpload upload, {
    void Function(double)? onProgress,
  }) async {
    guard();
    final source = File(upload.path);
    if (!await source.exists()) throw const DriveFailure('LOCAL_FILE_MISSING');
    if (await source.length() != upload.size ||
        (await sha256.bind(source.openRead()).first).toString() !=
            upload.checksum) {
      throw const DriveFailure('LOCAL_FILE_CHANGED');
    }
    guard();
    for (var attempt = 0; attempt < 2; attempt++) {
      final plan = await _call('begin', {
        'id': upload.id,
        'file_name': upload.name,
        'file_size': upload.size,
        'checksum': upload.checksum,
      });
      final file = CloudFile(Map<String, dynamic>.from(plan['file']));
      _validateFile(file);
      if (plan['alreadyUploaded'] == true) {
        onProgress?.call(1);
        return file;
      }
      final form = Map<String, dynamic>.from(plan['upload']);
      final url = Uri.parse(form['url'] as String);
      // Only server-selected HTTPS OSS endpoints. Never send auth JWT to OSS.
      if (url.scheme != 'https' || !url.host.endsWith('.aliyuncs.com')) {
        throw const DriveFailure('INVALID_ENDPOINT');
      }
      final request = http.MultipartRequest('POST', url);
      request.fields.addAll(
        Map<String, dynamic>.from(
          form['fields'],
        ).map((k, v) => MapEntry(k, v.toString())),
      );
      var sent = 0;
      final stream = source.openRead().map((chunk) {
        guard();
        sent += chunk.length;
        onProgress?.call(upload.size == 0 ? 0 : sent / upload.size);
        return chunk;
      });
      request.files.add(
        http.MultipartFile('file', stream, upload.size, filename: upload.name),
      );
      final response = await _http
          .send(request)
          .timeout(const Duration(minutes: 30));
      await response.stream.drain<void>().timeout(const Duration(seconds: 30));
      guard();
      if (response.statusCode == 403 && attempt == 0) {
        continue; // expired form: fresh scoped grant
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // A previous successful PUT may have lost its response. HEAD confirms
        // the SAME UUID; an overwrite-forbidden response is not success by itself.
        if (response.statusCode != 409) {
          throw const DriveFailure('UPLOAD_FAILED');
        }
      }
      final completed = await _call('complete', {'id': upload.id});
      final ready = CloudFile(Map<String, dynamic>.from(completed['file']));
      _validateFile(ready);
      if (!ready.ready) throw const DriveFailure('UPLOAD_NOT_COMPLETE');
      return ready;
    }
    throw const DriveFailure('UPLOAD_FAILED');
  }

  Future<StorageCredential> _credential(
    CloudFile file, {
    bool force = false,
  }) async {
    _validateFile(file);
    final cached = _credentials[file.id];
    if (!force && cached != null && cached.fresh) return cached;
    final response = await _call('download', {'id': file.id});
    final value = StorageCredential(
      Map<String, dynamic>.from(response['credential']),
    );
    if (value.objectKey != file.key ||
        value.userPrefix != 'users/$owner/' ||
        value.endpoint !=
            'https://${value.bucket}.${value.region}.aliyuncs.com' ||
        !value.fresh) {
      throw const DriveFailure('INVALID_CREDENTIAL');
    }
    _credentials[file.id] = value;
    return value;
  }

  @override
  Future<String> downloadFile(
    CloudFile file, {
    void Function(double)? onProgress,
  }) async {
    _validateFile(file);
    if (!file.ready) throw const DriveFailure('UPLOAD_NOT_COMPLETE');
    final root = Directory(
      p.join(
        (await getApplicationDocumentsDirectory()).path,
        'huideng_cloud',
        owner,
        file.id,
      ),
    );
    await root.create(recursive: true);
    final safeName = file.name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'[ .]+$'), '');
    var target = File(
      p.join(root.path, safeName.isEmpty ? 'download' : safeName),
    );
    if (await target.exists() &&
        await target.length() == file.size &&
        (await sha256.bind(target.openRead()).first).toString() ==
            file.checksum) {
      guard();
      return target.path;
    }
    // Preserve even a locally modified earlier download; never overwrite it.
    if (await target.exists()) {
      target = File(
        p.join(
          root.path,
          '${DateTime.now().microsecondsSinceEpoch}_${safeName.isEmpty ? 'download' : safeName}',
        ),
      );
    }
    final partial = File('${target.path}.partial');
    for (var attempt = 0; attempt < 2; attempt++) {
      final c = await _credential(file, force: attempt > 0);
      final req = http.Request('GET', Uri.parse('${c.endpoint}/${file.key}'))
        ..headers.addAll(ossReadHeaders(c));
      final res = await _http.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode == 403 && attempt == 0) {
        await res.stream.drain<void>();
        continue;
      }
      if (res.statusCode != 200) {
        await res.stream.drain<void>();
        throw const DriveFailure('DOWNLOAD_FAILED');
      }
      var received = 0;
      final sink = partial.openWrite();
      try {
        await for (final bytes in res.stream.timeout(
          const Duration(seconds: 30),
        )) {
          guard();
          received += bytes.length;
          if (received > file.size) throw const DriveFailure('CHECKSUM_FAILED');
          sink.add(bytes);
          onProgress?.call(file.size == 0 ? 0 : received / file.size);
        }
        await sink.flush();
        await sink.close();
        if (received != file.size ||
            (await sha256.bind(partial.openRead()).first).toString() !=
                file.checksum) {
          throw const DriveFailure('CHECKSUM_FAILED');
        }
        guard();
        await partial.rename(target.path);
        return target.path;
      } catch (_) {
        await sink.close();
        if (await partial.exists()) await partial.delete();
        rethrow;
      }
    }
    throw const DriveFailure('DOWNLOAD_FAILED');
  }

  @override
  Future<void> deleteFile(CloudFile file) async {
    _validateFile(file);
    await _call('trash', {'id': file.id});
    _credentials.remove(file.id);
  }

  @override
  Future<void> restoreFile(CloudFile file) async {
    guard();
    if (file.owner != owner) throw const DriveFailure('FILE_UNAVAILABLE');
    await _call('restore', {'id': file.id});
  }

  @override
  void close() {
    _closed = true;
    _http.close();
    _credentials.clear();
  }
}
