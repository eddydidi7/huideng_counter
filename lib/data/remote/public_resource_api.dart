import 'package:http_parser/http_parser.dart';
import '../../services/apk_files.dart';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../domain/cloud_file.dart';
import '../../domain/public_resource.dart';
import 'resource_resumable_upload.dart';
import 'resource_transfer_error.dart';

typedef ResourceCall =
    Future<Map<String, dynamic>> Function(Map<String, dynamic>);

abstract class ResourceLibraryApi {
  String get owner;
  Future<ResourceListing> list({
    bool mine = false,
    String search = '',
    String category = '',
    String sort = 'time',
    String? cursor,
  });
  Future<PublicResource> upload(
    DriveUpload task,
    void Function(double) progress,
  );
  Future<String> download(PublicResource file, void Function(double) progress);
  void guard();
  void close();
}

abstract class ResourceWebShareApi {
  Future<String> webShare(PublicResource file);
}

abstract class ResourcePreviewApi {
  Future<File> preview(PublicResource file, {bool large = false});
}

class PublicResourceApi
    implements ResourceLibraryApi, ResourceWebShareApi, ResourcePreviewApi {
  @override
  Future<File> preview(PublicResource file, {bool large = false}) async {
    guard();
    // Reauthorize even on a disk cache hit: taken-down files cannot be reopened.
    final result = await request('preview', {'id': file.id, 'large': large});
    final uri = Uri.tryParse(result['url'] as String? ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        !uri.path.contains('/render/image/')) {
      throw const DriveFailure('INVALID_RESPONSE');
    }
    final dir = Directory(
      p.join((await getTemporaryDirectory()).path, 'resource-previews', owner),
    );
    await dir.create(recursive: true);
    final target = File(
      p.join(
        dir.path,
        '${file.id}-${file.checksum}-${large ? 1440 : 480}.preview',
      ),
    );
    if (await target.exists()) return target;
    final response = await _http
        .send(http.Request('GET', uri)..followRedirects = false)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200 ||
        !(response.headers['content-type'] ?? '').startsWith('image/')) {
      await response.stream.listen(null).cancel();
      throw const DriveFailure('FILE_UNAVAILABLE');
    }
    final data = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      if (data.length + chunk.length > (large ? 4194304 : 1048576)) {
        throw const DriveFailure('FILE_TOO_LARGE');
      }
      data.addAll(chunk);
    }
    guard();
    // Only derived previews in this dedicated cache are evicted, never originals.
    final cached = await dir
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.preview'))
        .cast<File>()
        .toList();
    final stats = <(File, FileStat)>[];
    var cachedBytes = 0;
    for (final entry in cached) {
      final stat = await entry.stat();
      cachedBytes += stat.size;
      stats.add((entry, stat));
    }
    stats.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final entry in stats) {
      if (cachedBytes + data.length <= 64 * 1024 * 1024) break;
      try {
        await entry.$1.delete();
        cachedBytes -= entry.$2.size;
      } on FileSystemException {
        /* Another preview may be in use. */
      }
    }
    await target.writeAsBytes(data, flush: true);
    return target;
  }

  @override
  Future<String> webShare(PublicResource file) async {
    final result = await request('share', {'id': file.id});
    final url = result['url'] as String? ?? '';
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const DriveFailure('INVALID_RESPONSE');
    }
    return url;
  }

  PublicResourceApi({
    required this.owner,
    required ResourceCall call,
    required void Function() checkSession,
    http.Client? httpClient,
    Future<Directory> Function()? downloadDirectory,
  }) : _call = call,
       _checkSession = checkSession,
       _http = httpClient ?? http.Client(),
       _directory = downloadDirectory ?? getApplicationDocumentsDirectory;

  factory PublicResourceApi.supabase(SupabaseClient client) {
    final user = client.auth.currentUser;
    final owner = user?.id ?? 'guest';
    return PublicResourceApi(
      owner: owner,
      checkSession: () {
        // Public read actions are authorised by the Edge Function and its
        // published-resource RPC. Mutations still fail server-side without a
        // signed-in account.
        if (user != null && client.auth.currentUser?.id != owner) {
          throw const DriveFailure('LOGIN_REQUIRED');
        }
      },
      call: (body) async {
        try {
          final result = await client.functions.invoke(
            'public-resources',
            body: body,
          );
          return Map<String, dynamic>.from(result.data);
        } on FunctionException catch (e) {
          final failure = resourceHttpFailure(
            'edge.${body['action']}',
            e.status,
            e.details,
          );
          if (e.status == 404) {
            throw const DriveFailure('RESOURCE_NOT_CONFIGURED');
          }
          throw DriveFailure(
            e.details is Map && e.details['error'] is String
                ? e.details['error']
                : failure.code,
          );
        }
      },
    );
  }

  @override
  final String owner;
  final ResourceCall _call;
  final void Function() _checkSession;
  final http.Client _http;
  final Future<Directory> Function() _directory;
  bool _closed = false;
  @override
  void guard() {
    if (_closed) throw const DriveFailure('LOGIN_REQUIRED');
    _checkSession();
  }

  Future<Map<String, dynamic>> request(
    String action, [
    Map<String, dynamic> payload = const {},
  ]) async {
    guard();
    late final Map<String, dynamic> result;
    try {
      result = await _call({
        'api_version': 1,
        'action': action,
        ...payload,
      }).timeout(Duration(seconds: action == 'complete' ? 150 : 30));
    } catch (e, stack) {
      resourceTransportFailure('edge.$action', e, stack);
    }
    guard();
    if (result['api_version'] != 1) throw const DriveFailure('UPDATE_REQUIRED');
    if (result['error'] is String) throw DriveFailure(result['error']);
    return result;
  }

  @override
  Future<ResourceListing> list({
    bool mine = false,
    String search = '',
    String category = '',
    String sort = 'time',
    String? cursor,
  }) async {
    try {
      final result = ResourceListing.fromJson(
        await request('list', {
          'scope': mine ? 'mine' : 'public',
          'search': search,
          'category': category,
          'sort': sort,
          'cursor': cursor,
        }),
      );
      if (!mine && result.files.any((f) => !f.published)) {
        throw const DriveFailure('INVALID_RESPONSE');
      }
      return result;
    } on DriveFailure catch (e) {
      if (e.code != 'RESOURCE_NOT_CONFIGURED') rethrow;
      return ResourceListing.fromJson({
        'config': <String, dynamic>{},
        'files': [],
        'next_cursor': null,
      });
    }
  }

  @override
  Future<PublicResource> upload(
    DriveUpload task,
    void Function(double) progress,
  ) async {
    guard();
    final source = File(task.path);
    if (!await source.exists()) throw const DriveFailure('LOCAL_FILE_MISSING');
    if (await source.length() != task.size ||
        (await sha256.bind(source.openRead()).first).toString() !=
            task.checksum) {
      throw const DriveFailure('LOCAL_FILE_CHANGED');
    }
    // Same upload_id on retry/restart: the server reserves quota atomically and
    // must return the existing upload, never another object or metadata row.
    for (var attempt = 0; attempt < 2; attempt++) {
      final plan = await request('begin', {
        'upload_protocol': 'tus',
        'upload_id': task.id,
        'file_name': task.name,
        if (isApk(task.name)) 'mime_type': apkMime,
        'file_size': task.size,
        'checksum': task.checksum,
        'category': task.category,
        'description': task.description,
      });
      if (plan['already_uploaded'] == true) return _completed(plan, task);
      if (plan['resumable'] is Map) {
        if (plan['resumable']['stored'] != true) {
          await uploadResourceResumable(
            client: _http,
            source: source,
            task: task,
            owner: owner,
            plan: Map<String, dynamic>.from(plan['resumable']),
            guard: guard,
            progress: (value) => progress(value * 0.9),
          );
        }
        for (var check = 0; check < 128; check++) {
          final result = await request('complete', {
            'upload_id': task.id,
            'upload_protocol': 'tus',
          });
          if (result['verifying'] != true) {
            final completed = _completed(result, task);
            progress(1);
            return completed;
          }
          final done = result['verified_bytes'];
          if (done is! num || done < 0 || done > task.size) {
            throw const DriveFailure('INVALID_RESPONSE');
          }
          progress(0.9 + 0.1 * done / task.size);
        }
        throw const DriveFailure('VERIFY_FAILED');
      }
      final transfer = ResourceTransfer.fromJson(
        Map<String, dynamic>.from(plan['transfer']),
      );
      if (!['PUT', 'POST'].contains(transfer.method)) {
        throw const DriveFailure('INVALID_TRANSFER');
      }
      var sent = 0;
      final stream = source.openRead().map((chunk) {
        guard();
        sent += chunk.length;
        if (sent > task.size) throw const DriveFailure('LOCAL_FILE_CHANGED');
        progress(task.size == 0 ? 1 : sent / task.size);
        return chunk;
      });
      http.BaseRequest uploadRequest;
      if (transfer.method == 'POST') {
        uploadRequest = http.MultipartRequest('POST', transfer.uri)
          ..fields.addAll(transfer.fields)
          ..files.add(
            http.MultipartFile(
              transfer.fileField,
              stream,
              task.size,
              filename: task.name,
              contentType: isApk(task.name) ? MediaType.parse(apkMime) : null,
            ),
          );
      } else {
        final put = http.StreamedRequest('PUT', transfer.uri)
          ..contentLength = task.size;
        uploadRequest = put;
      }
      uploadRequest.headers.addAll(transfer.headers);
      if (isApk(task.name) && transfer.method == 'PUT') {
        uploadRequest.headers['content-type'] = apkMime;
      }
      uploadRequest.followRedirects = false;
      // Only the signed plan travels to object storage; Supabase JWT stays in
      // the Edge Function call. Never log URLs or headers containing signatures.
      final sending = _http.send(uploadRequest);
      if (uploadRequest is http.StreamedRequest) {
        final sink = uploadRequest.sink;
        await Future.wait([
          sink.addStream(stream).then((_) => sink.close()),
          sending.then((_) {}),
        ]).timeout(const Duration(minutes: 30));
      }
      final response = await sending.timeout(const Duration(minutes: 30));
      final responseBody = await response.stream.bytesToString().timeout(
        const Duration(seconds: 30),
      );
      guard();
      if (response.statusCode == 403 && attempt == 0) continue;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw resourceHttpFailure(
          'upload.${transfer.method}',
          response.statusCode,
          responseBody,
        );
      }
      final result = await request('complete', {'upload_id': task.id});
      final file = _completed(result, task);
      progress(1);
      return file;
    }
    throw const DriveFailure('UPLOAD_FAILED');
  }

  PublicResource _completed(Map<String, dynamic> result, DriveUpload task) {
    final file = PublicResource.fromJson(
      Map<String, dynamic>.from(result['file']),
    );
    if (file.size != task.size ||
        file.checksum != task.checksum ||
        !['published', 'pending', 'rejected', 'hidden'].contains(file.status)) {
      throw const DriveFailure('INVALID_RESPONSE');
    }
    return file;
  }

  @override
  Future<String> download(
    PublicResource file,
    void Function(double) progress,
  ) async {
    guard();
    if (!file.published) throw const DriveFailure('FILE_UNAVAILABLE');
    // Authorize even if a verified local copy exists: hidden resources must not
    // remain accessible from stale lists through this screen.
    var plan = await request('download', {'id': file.id});
    final root = Directory(
      p.join((await _directory()).path, 'public_resources', owner, file.id),
    );
    await root.create(recursive: true);
    final safe = p
        .basename(file.name)
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
    // UUID prefix also avoids Windows reserved basenames (CON, PRN, ...).
    var target = File(
      p.join(
        root.path,
        '${file.id}_${safe.length > 100 ? safe.substring(safe.length - 100) : safe}',
      ),
    );
    if (await target.exists()) {
      if (await target.length() == file.size &&
          (await sha256.bind(target.openRead()).first).toString() ==
              file.checksum) {
        guard();
        progress(1);
        return target.path;
      }
      target = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}');
    }
    final partial = File('${target.path}.partial');
    for (var attempt = 0; attempt < 2; attempt++) {
      final transfer = ResourceTransfer.fromJson(
        Map<String, dynamic>.from(plan['transfer']),
      );
      if (transfer.method != 'GET') {
        throw const DriveFailure('INVALID_TRANSFER');
      }
      final req = http.Request('GET', transfer.uri)
        ..headers.addAll(transfer.headers)
        ..followRedirects = false;
      final response = await _http
          .send(req)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 403 && attempt == 0) {
        await response.stream.drain<void>().timeout(
          const Duration(seconds: 30),
        );
        plan = await request('download', {'id': file.id});
        continue;
      }
      if (response.statusCode != 200) {
        await response.stream.drain<void>().timeout(
          const Duration(seconds: 30),
        );
        throw const DriveFailure('DOWNLOAD_FAILED');
      }
      var received = 0;
      final sink = partial.openWrite();
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          guard();
          received += chunk.length;
          if (received > file.size) throw const DriveFailure('CHECKSUM_FAILED');
          sink.add(chunk);
          progress(file.size == 0 ? 1 : received / file.size);
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
  void close() {
    _closed = true;
    _http.close();
  }
}
