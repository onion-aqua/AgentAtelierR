import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Only used for desktop Fish Audio. Other providers keep their own transport.
http.Client createFishAudioTransport() => Platform.isWindows
    ? (_desktopFishTransport ??= DesktopTtsClient())
    : http.Client();

DesktopTtsClient? _desktopFishTransport;

class DesktopProxySettings {
  const DesktopProxySettings({
    this.environment = const {},
    this.server = '',
    this.bypass = '',
  });

  final Map<String, String> environment;
  final String server;
  final String bypass;

  List<String> proxiesFor(Uri target) {
    if (isLocalTarget(target) ||
        _matchesBypass(
          target,
          environment['no_proxy'] ?? environment['NO_PROXY'] ?? '',
          ',',
        )) {
      return const [];
    }
    final result = <String>{};
    for (final key in [
      '${target.scheme}_proxy',
      '${target.scheme.toUpperCase()}_PROXY',
      'all_proxy',
      'ALL_PROXY',
    ]) {
      final directive = _httpProxy(environment[key] ?? '');
      if (directive != null) result.add(directive);
    }
    if (!_matchesBypass(target, bypass, ';')) {
      final entries = server.split(';');
      for (final entry in entries) {
        final assignment = entry.split('=');
        if (assignment.length > 1 &&
            assignment.first.trim().toLowerCase() != target.scheme) {
          continue;
        }
        final directive = _httpProxy(assignment.last);
        if (directive != null) result.add(directive);
      }
    }
    return result.toList();
  }

  static bool isLocalTarget(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost') || host == '::1') {
      return true;
    }
    final ip = InternetAddress.tryParse(host);
    return ip?.isLoopback == true;
  }

  static String? _httpProxy(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text.contains('://') ? text : 'http://$text');
    // Dart's PROXY directive is a plain HTTP CONNECT proxy. Do not silently
    // downgrade TLS/SOCKS proxies or expose unsupported proxy credentials.
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535) {
      return null;
    }
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    return 'PROXY $host:${uri.port}';
  }

  static bool _matchesBypass(Uri uri, String raw, String separator) {
    final host = uri.host.toLowerCase();
    for (final entry in raw.toLowerCase().split(separator)) {
      var pattern = entry.trim();
      if (pattern.isEmpty) continue;
      if (pattern == '*') return true;
      if (pattern == '<local>' && !host.contains('.') && !host.contains(':')) {
        return true;
      }
      // Parse the written port rather than Uri.hasPort: :80 on an HTTP URI
      // is normalized away. Accept both bracketed and bare IPv6 bypass hosts.
      final parsedEntry = _bypassEntry.firstMatch(pattern);
      if (parsedEntry != null) {
        final port = parsedEntry.group(3);
        if (port != null && int.tryParse(port) != uri.port) continue;
        pattern = parsedEntry.group(1) ?? parsedEntry.group(2)!;
      } else if (InternetAddress.tryParse(pattern) == null) {
        continue;
      }
      if (pattern.startsWith('.')) pattern = pattern.substring(1);
      if (host == pattern || host.endsWith('.$pattern')) return true;
      if (pattern.contains('*')) {
        final expression = pattern.split('*').map(RegExp.escape).join('.*');
        if (RegExp('^$expression\$').hasMatch(host)) return true;
      }
    }
    return false;
  }

  static final _bypassEntry = RegExp(r'^(?:\[([^\]]+)\]|([^:]+))(?::(\d+))?$');
}

Future<DesktopProxySettings> readDesktopProxySettings() async {
  Map<Object?, Object?>? config;
  try {
    config = await const MethodChannel('agentatelier/network')
        .invokeMapMethod<Object?, Object?>('getSystemProxyConfig');
  } on MissingPluginException {
    // Old desktop runners can still use the process's configured HTTP proxy.
  } on PlatformException {
    // Unavailable system settings do not prevent direct or environment routes.
  }
  return DesktopProxySettings(
    environment: Platform.environment,
    server: config?['server'] is String ? config!['server'] as String : '',
    bypass: config?['bypass'] is String ? config!['bypass'] as String : '',
  );
}

typedef DesktopConnectionProbe = Future<bool> Function(
  Uri target,
  String proxy,
);

/// Probe TLS + HTTP without credentials, user text, or a synthesis POST.
/// Every HTTP status (including HEAD 404/405) proves transport reachability.
Future<bool> probeDesktopConnection(Uri target, String proxy) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..findProxy = (_) => proxy;
  try {
    final probeUrl = target.replace(
      path: '/',
      query: '',
      fragment: '',
      userInfo: '',
    );
    await (() async {
      final request = await client.headUrl(probeUrl);
      request.followRedirects = false;
      final response = await request.close();
      await response.drain<void>();
    })().timeout(const Duration(seconds: 4));
    return true;
  } on SocketException {
    return false;
  } on HttpException {
    return false;
  } on HandshakeException {
    return false;
  } on TimeoutException {
    return false;
  } finally {
    // Also cancels DNS/connect/response work when the probe deadline expires.
    client.close(force: true);
  }
}

http.Client _routeClient(String proxy) => IOClient(
  HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..findProxy = (_) => proxy,
);

class DesktopTtsClient extends http.BaseClient {
  DesktopTtsClient({
    http.Client? directClient,
    http.Client Function(String)? proxyClientFactory,
    Future<DesktopProxySettings> Function()? readSettings,
    DesktopConnectionProbe? probe,
    DateTime Function()? now,
    this.routeLifetime = const Duration(minutes: 2),
  }) : _direct = directClient ?? _routeClient('DIRECT'),
       _proxyClientFactory = proxyClientFactory ?? _routeClient,
       _readSettings = readSettings ?? readDesktopProxySettings,
       _probe = probe ?? probeDesktopConnection,
       _now = now ?? DateTime.now;

  final http.Client _direct;
  final http.Client Function(String) _proxyClientFactory;
  final Future<DesktopProxySettings> Function() _readSettings;
  final DesktopConnectionProbe _probe;
  final DateTime Function() _now;
  final Duration routeLifetime;
  final _proxyClients = <String, http.Client>{};
  final _routes = <String, _Route>{};
  final _pending = <String, Future<String>>{};
  final _directFailures = <String, DateTime>{};
  final _requestRoutes = Expando<String>();
  bool _closed = false;

  Future<String> _route(Uri uri) async {
    if (DesktopProxySettings.isLocalTarget(uri)) return 'DIRECT';
    final origin = uri.origin;
    final cached = _routes[origin];
    if (cached != null && _now().isBefore(cached.expires)) return cached.proxy;
    final existing = _pending[origin];
    if (existing != null) return existing;
    final pending = _selectRoute(uri);
    _pending[origin] = pending;
    try {
      return await pending;
    } finally {
      _pending.remove(origin);
    }
  }

  Future<String> _selectRoute(Uri uri) async {
    final failedUntil = _directFailures[uri.origin];
    if ((failedUntil == null || !_now().isBefore(failedUntil)) &&
        await _probe(uri, 'DIRECT')) {
      _directFailures.remove(uri.origin);
      return _remember(uri, 'DIRECT');
    }
    _directFailures[uri.origin] = _now().add(const Duration(seconds: 30));
    final settings = await _readSettings();
    for (final proxy in settings.proxiesFor(uri)) {
      if (await _probe(uri, proxy)) return _remember(uri, proxy);
    }
    throw http.ClientException(
      'Fish Audio 直连不可达，且没有可用的系统 HTTP 代理。请检查代理软件与系统代理设置。',
      uri,
    );
  }

  String _remember(Uri uri, String proxy) {
    _routes[uri.origin] = _Route(proxy, _now().add(routeLifetime));
    return proxy;
  }

  void _failed(Uri uri, String proxy, Object error) {
    if (error is http.RequestAbortedException ||
        !(error is http.ClientException ||
            error is IOException ||
            error is TimeoutException)) {
      return;
    }
    if (_routes[uri.origin]?.proxy == proxy) _routes.remove(uri.origin);
    if (proxy == 'DIRECT') {
      _directFailures[uri.origin] = _now().add(const Duration(seconds: 30));
    }
  }

  /// Fish's timeout uses the same abort signal as user cancellation. Only an
  /// actual deadline should invalidate the selected route for the next retry.
  void requestTimedOut(http.BaseRequest request) {
    final proxy = _requestRoutes[request];
    if (proxy != null) {
      _failed(request.url, proxy, TimeoutException('Fish Audio 请求超时'));
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('Fish Audio transport closed');
    final selection = _route(request.url);
    final String proxy;
    if (request case http.Abortable(:final abortTrigger?)) {
      proxy = await Future.any([
        selection,
        abortTrigger.then<String>(
          (_) => throw http.RequestAbortedException(request.url),
        ),
      ]);
    } else {
      proxy = await selection;
    }
    if (_closed) throw http.ClientException('Fish Audio transport closed');
    final client = proxy == 'DIRECT'
        ? _direct
        : _proxyClients.putIfAbsent(proxy, () => _proxyClientFactory(proxy));
    _requestRoutes[request] = proxy;
    try {
      final response = await client.send(request);
      return http.StreamedResponse(
        response.stream.transform(
          StreamTransformer.fromHandlers(
            handleError:
                (Object error, StackTrace stack, EventSink<List<int>> sink) {
                  _failed(request.url, proxy, error);
                  sink.addError(error, stack);
                },
          ),
        ),
        response.statusCode,
        contentLength: response.contentLength,
        headers: response.headers,
        request: response.request,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (error) {
      _failed(request.url, proxy, error);
      rethrow;
    }
  }

  @override
  void close() {
    _closed = true;
    _direct.close();
    for (final client in _proxyClients.values) {
      client.close();
    }
    _proxyClients.clear();
    _routes.clear();
  }
}

class _Route {
  const _Route(this.proxy, this.expires);
  final String proxy;
  final DateTime expires;
}
