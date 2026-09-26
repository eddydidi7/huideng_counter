import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'connection_router.dart';

/// Redirects only the original Supabase origin, retaining project credentials.
/// Mutations are NEVER replayed here: a timeout may follow a committed write.
class RoutedHttpClient extends http.BaseClient {
  RoutedHttpClient(
    this.router, {
    http.Client Function()? factory,
    this.readTimeout = const Duration(seconds: 8),
  }) : factory =
           factory ??
           (() => IOClient(
             HttpClient()..connectionTimeout = const Duration(seconds: 8),
           ));
  final ConnectionRouter router;
  final http.Client Function() factory;
  final Duration readTimeout;
  final _pending = <http.Client>{};
  final http.Client _direct = http.Client();
  bool _closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('Client closed');
    final managed = router.owns(request.url);
    if (!managed || (!router.configured && router.config == null))
      return _direct.send(request);
    final replayable =
        (request.method == 'GET' || request.method == 'HEAD') &&
        (request.contentLength ?? 0) == 0;
    final attempts = managed && replayable
        ? router.origins.length.clamp(1, 2)
        : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final destination = router.route(request.url);
      final inner = factory();
      _pending.add(inner);
      var keepOpen = false;
      try {
        final forwarded = http.StreamedRequest(request.method, destination)
          ..headers.addAll(request.headers)
          ..followRedirects = managed ? false : request.followRedirects
          ..maxRedirects = request.maxRedirects
          ..persistentConnection = request.persistentConnection
          ..contentLength = request.contentLength;
        // Never buffer large file bodies; a failed upload must be retried by its caller.
        unawaited(
          (replayable
                  ? forwarded.sink.close()
                  : request.finalize().pipe(forwarded.sink))
              .catchError((Object _) {}),
        );
        final response = await inner
            .send(forwarded)
            .timeout(replayable ? readTimeout : const Duration(minutes: 5));
        if (managed && [502, 503, 504].contains(response.statusCode)) {
          router.failed(destination);
          unawaited(router.refresh());
          if (attempt + 1 < attempts) continue;
        }
        keepOpen = true;
        Stream<List<int>> body() async* {
          try {
            yield* response.stream;
          } finally {
            inner.close();
            _pending.remove(inner);
          }
        }

        return http.StreamedResponse(
          body(),
          response.statusCode,
          contentLength: response.contentLength,
          headers: response.headers,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
          reasonPhrase: response.reasonPhrase,
          request: request,
        );
      } on Object catch (e) {
        final network =
            e is SocketException ||
            e is HandshakeException ||
            e is TimeoutException ||
            e is http.ClientException;
        if (managed && network) {
          router.failed(destination);
          unawaited(router.refresh());
        }
        if (!network || attempt + 1 >= attempts) rethrow;
      } finally {
        if (!keepOpen) {
          inner.close();
          _pending.remove(inner);
        }
      }
    }
    throw http.ClientException('No available connection');
  }

  @override
  void close() {
    _closed = true;
    _direct.close();
    for (final client in _pending) {
      client.close();
    }
    _pending.clear();
  }
}

WebSocketChannel routedWebSocket(
  ConnectionRouter router,
  String url,
  Map<String, String> headers, {
  WebSocketChannel Function(Uri, Map<String, String>)? connect,
}) {
  final original = Uri.parse(url);
  final destination = router.route(original);
  final channel = connect != null
      ? connect(destination, headers)
      : IOWebSocketChannel.connect(
          destination,
          headers: headers,
          connectTimeout: const Duration(seconds: 8),
        );
  unawaited(
    channel.ready.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (router.owns(original)) {
          router.failed(destination);
          unawaited(router.refresh());
        }
      },
    ),
  );
  return channel;
}
