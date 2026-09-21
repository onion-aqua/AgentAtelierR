import 'dart:async';

import 'package:http/http.dart' as http;

/// A dedicated transport for optional planning. Timers abort the request,
/// including response-body reads, instead of merely abandoning its Future.
class PlanningHttpClient extends http.BaseClient {
  PlanningHttpClient(
    this.inner, {
    this.attemptTimeout = const Duration(milliseconds: 1500),
  });
  final http.Client inner;
  final Duration attemptTimeout;
  final _pending = <Completer<void>>{};
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw StateError('Planning transport closed');
    final body = await request.finalize().toBytes();
    if (_closed) throw StateError('Planning transport closed');
    final abort = Completer<void>();
    _pending.add(abort);
    final timer = Timer(attemptTimeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    final forwarded =
        http.AbortableRequest(
            request.method,
            request.url,
            abortTrigger: abort.future,
          )
          ..headers.addAll(request.headers)
          ..followRedirects = request.followRedirects
          ..maxRedirects = request.maxRedirects
          ..bodyBytes = body;
    try {
      final response = await inner.send(forwarded);
      final bytes = await response.stream.toBytes();
      return http.StreamedResponse(
        Stream.value(bytes),
        response.statusCode,
        headers: response.headers,
        request: request,
        reasonPhrase: response.reasonPhrase,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
      );
    } finally {
      timer.cancel();
      _pending.remove(abort);
    }
  }

  @override
  void close() {
    _closed = true;
    for (final abort in _pending) {
      if (!abort.isCompleted) abort.complete();
    }
    inner.close();
  }
}
