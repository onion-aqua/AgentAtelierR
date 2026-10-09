import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/desktop_tts_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AbortOnlyClient extends http.BaseClient {
  int posts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    posts++;
    await (request as http.AbortableRequest).abortTrigger;
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final target = Uri.parse('https://api.fish.audio/v1/tts');
  const settings = DesktopProxySettings(server: '127.0.0.1:7890');

  test(
    'configured HTTP CONNECT proxies include environment and system settings',
    () {
      expect(
        const DesktopProxySettings(
          environment: {'HTTPS_PROXY': 'http://localhost:7897'},
          server:
              'http=127.0.0.1:7890;https=127.0.0.1:7891;socks=127.0.0.1:7892',
        ).proxiesFor(target),
        ['PROXY localhost:7897', 'PROXY 127.0.0.1:7891'],
      );
      expect(
        const DesktopProxySettings(
          environment: {'ALL_PROXY': 'http://127.0.0.1:7890'},
        ).proxiesFor(target),
        ['PROXY 127.0.0.1:7890'],
      );
    },
  );

  test('local endpoints, proxy bypasses and unsupported proxy schemes stay private', () {
    for (final host in ['localhost', '127.0.0.1', '[::1]']) {
      expect(settings.proxiesFor(Uri.parse('http://$host:9000/tts')), isEmpty);
    }
    for (final bypass in ['*.fish.audio', 'api.fish.audio', '.fish.audio']) {
      expect(
        DesktopProxySettings(
          server: settings.server,
          bypass: bypass,
        ).proxiesFor(target),
        isEmpty,
      );
    }
    expect(
      const DesktopProxySettings(
        server: '127.0.0.1:7890',
        environment: {'NO_PROXY': '.fish.audio'},
      ).proxiesFor(target),
      isEmpty,
    );
    for (final proxy in [
      'socks5://localhost:1080',
      'https://localhost:7890',
      'http://user:secret@localhost:7890',
      'host:0',
      'http://localhost:7890/path',
    ]) {
      expect(DesktopProxySettings(server: proxy).proxiesFor(target), isEmpty);
    }
  });

  test(
    'system proxy configuration is obtained through the Windows channel',
    () async {
      const channel = MethodChannel('agentatelier/network');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getSystemProxyConfig');
            return {'server': '127.0.0.1:7890', 'bypass': '<local>'};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final actual = await readDesktopProxySettings();
      expect(actual.server, settings.server);
      expect(actual.bypass, '<local>');
    },
  );

  test('bypass supports explicit default ports and IPv6 hosts', () {
    for (final (url, bypass) in [
      ('http://internal.example/tts', 'internal.example:80'),
      ('https://api.fish.audio/tts', 'api.fish.audio:443'),
      ('http://[fd00::1]:9000/tts', '[fd00::1]:9000'),
      ('http://[fd00::1]/tts', 'fd00::1'),
    ]) {
      expect(
        DesktopProxySettings(
          server: settings.server,
          bypass: bypass,
        ).proxiesFor(Uri.parse(url)),
        isEmpty,
      );
    }
    expect(
      DesktopProxySettings(
        server: settings.server,
        bypass: 'api.fish.audio:80',
      ).proxiesFor(target),
      ['PROXY 127.0.0.1:7890'],
    );
  });

  test('reachable direct route sends one POST and reuses its probe', () async {
    var probes = 0;
    var posts = 0;
    final client = DesktopTtsClient(
      directClient: MockClient((request) async {
        posts++;
        expect(request.method, 'POST');
        return http.Response('audio', 200);
      }),
      probe: (uri, proxy) async {
        probes++;
        expect(proxy, 'DIRECT');
        return true;
      },
      readSettings: () async =>
          throw StateError('direct should not read proxy settings'),
    );
    addTearDown(client.close);
    await client.post(target, body: 'one');
    await client.post(target, body: 'two');
    expect(probes, 1);
    expect(posts, 2);
  });

  test(
    'unreachable direct route selects system proxy before synthesis',
    () async {
      final probes = <String>[];
      var posts = 0;
      final client = DesktopTtsClient(
        directClient: MockClient(
          (_) async => throw StateError('no direct POST'),
        ),
        readSettings: () async => settings,
        probe: (uri, proxy) async {
          probes.add(proxy);
          return proxy != 'DIRECT';
        },
        proxyClientFactory: (proxy) {
          expect(proxy, 'PROXY 127.0.0.1:7890');
          return MockClient((request) async {
            posts++;
            expect(request.headers['Authorization'], 'Bearer private-test-key');
            expect(request.headers['model'], 's2-pro');
            expect(request.body, contains('こんにちは'));
            return http.Response.bytes([0x49, 0x44, 0x33], 200);
          });
        },
      );
      addTearDown(client.close);
      expect(
        await FishAudioClient(client: client).synthesizeBytes(
          apiKey: 'private-test-key',
          referenceId: 'voice',
          text: 'こんにちは',
        ),
        [0x49, 0x44, 0x33],
      );
      expect(probes, ['DIRECT', 'PROXY 127.0.0.1:7890']);
      expect(posts, 1);
    },
  );

  test('proxy alternatives are probed before sending a POST', () async {
    final probes = <String>[];
    final client = DesktopTtsClient(
      readSettings: () async => const DesktopProxySettings(
        environment: {'HTTPS_PROXY': 'http://localhost:7897'},
        server: '127.0.0.1:7890',
      ),
      probe: (uri, proxy) async {
        probes.add(proxy);
        return proxy == 'PROXY 127.0.0.1:7890';
      },
      proxyClientFactory: (_) =>
          MockClient((_) async => http.Response('ok', 200)),
    );
    addTearDown(client.close);
    await client.post(target);
    expect(probes, ['DIRECT', 'PROXY localhost:7897', 'PROXY 127.0.0.1:7890']);
  });

  test('parallel sentences share the same pending route probe', () async {
    final ready = Completer<bool>();
    var probes = 0;
    final client = DesktopTtsClient(
      directClient: MockClient((_) async => http.Response('ok', 200)),
      probe: (_, _) {
        probes++;
        return ready.future;
      },
    );
    addTearDown(client.close);
    final requests = [client.post(target), client.post(target)];
    await Future<void>.delayed(Duration.zero);
    expect(probes, 1);
    ready.complete(true);
    await Future.wait(requests);
    expect(probes, 1);
  });

  test(
    'expired proxy route probes direct again to recover after network changes',
    () async {
      var now = DateTime.utc(2026, 10, 9);
      var directReachable = false;
      final probes = <String>[];
      final client = DesktopTtsClient(
        now: () => now,
        directClient: MockClient((_) async => http.Response('direct', 200)),
        readSettings: () async => settings,
        probe: (_, proxy) async {
          probes.add(proxy);
          return proxy != 'DIRECT' || directReachable;
        },
        proxyClientFactory: (_) =>
            MockClient((_) async => http.Response('proxy', 200)),
      );
      addTearDown(client.close);
      expect((await client.post(target)).body, 'proxy');
      directReachable = true;
      now = now.add(const Duration(minutes: 3));
      expect((await client.post(target)).body, 'direct');
      expect(probes, ['DIRECT', 'PROXY 127.0.0.1:7890', 'DIRECT']);
    },
  );

  test('real direct send failure moves the existing Fish retry to proxy without internal replay', () async {
    var directPosts = 0;
    var proxyPosts = 0;
    final probes = <String>[];
    final client = DesktopTtsClient(
      directClient: MockClient((request) async {
        directPosts++;
        throw http.ClientException('network reset');
      }),
      readSettings: () async => settings,
      probe: (_, proxy) async {
        probes.add(proxy);
        return true;
      },
      proxyClientFactory: (_) => MockClient((_) async {
        proxyPosts++;
        return http.Response.bytes([1, 2, 3], 200);
      }),
    );
    addTearDown(client.close);
    expect(
      await FishAudioClient(client: client)
          .synthesizeBytes(apiKey: 'key', referenceId: 'voice', text: 'hello'),
      [1, 2, 3],
    );
    expect(directPosts, 1);
    expect(proxyPosts, 1);
    expect(probes, ['DIRECT', 'PROXY 127.0.0.1:7890']);
  });

  test('local custom Fish endpoint skips system proxy and probing', () async {
    final client = DesktopTtsClient(
      directClient: MockClient((_) async => http.Response('local', 200)),
      probe: (_, _) async => throw StateError('no probe'),
      readSettings: () async => throw StateError('no proxy'),
    );
    addTearDown(client.close);
    expect(
      (await client.post(Uri.parse('http://127.0.0.1:9000/tts'))).body,
      'local',
    );
  });

  test('synthesis deadline switches existing retries to proxy after HEAD succeeded', () async {
    final direct = _AbortOnlyClient();
    var proxyPosts = 0;
    final probes = <String>[];
    final client = DesktopTtsClient(
      directClient: direct,
      readSettings: () async => settings,
      probe: (_, proxy) async {
        probes.add(proxy);
        return true;
      },
      proxyClientFactory: (_) => MockClient((_) async {
        proxyPosts++;
        return http.Response.bytes([1, 2, 3], 200);
      }),
    );
    addTearDown(client.close);
    final fish = FishAudioClient(
      client: client,
      requestTimeout: const Duration(milliseconds: 50),
    );
    expect(
      await fish.synthesizeBytes(
        apiKey: 'key',
        referenceId: 'voice',
        text: 'hello',
      ),
      [1, 2, 3],
    );
    expect(direct.posts, 1);
    expect(proxyPosts, 1);
    expect(probes, ['DIRECT', 'PROXY 127.0.0.1:7890']);
  });

  test('plain cancellation keeps the healthy cached direct route', () async {
    final direct = _AbortOnlyClient();
    var probes = 0;
    final client = DesktopTtsClient(
      directClient: direct,
      probe: (_, _) async {
        probes++;
        return true;
      },
    );
    addTearDown(client.close);
    for (var i = 0; i < 2; i++) {
      final abort = Completer<void>();
      final sent = client.send(
        http.AbortableRequest('POST', target, abortTrigger: abort.future),
      );
      final assertion = expectLater(
        sent,
        throwsA(isA<http.RequestAbortedException>()),
      );
      await Future<void>.delayed(Duration.zero);
      abort.complete();
      await assertion;
    }
    expect(probes, 1);
    expect(direct.posts, 2);
  });

  test('abort during preflight never sends the synthesis POST', () async {
    final ready = Completer<bool>();
    final abort = Completer<void>();
    var posts = 0;
    final client = DesktopTtsClient(
      directClient: MockClient((_) async {
        posts++;
        return http.Response('ok', 200);
      }),
      probe: (_, _) => ready.future,
    );
    addTearDown(client.close);
    final sent = client.send(
      http.AbortableRequest('POST', target, abortTrigger: abort.future),
    );
    final assertion = expectLater(
      sent,
      throwsA(isA<http.RequestAbortedException>()),
    );
    abort.complete();
    await assertion;
    ready.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(posts, 0);
  });

  test(
    'probe reaches local HTTP errors without authorization, text, or POST',
    () async {
      // This is an isolated local transport test, not a remote Fish synthesis.
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final checked = Completer<void>();
      server.listen((request) async {
        expect(request.method, 'HEAD');
        expect(request.uri.path, '/');
        expect(request.uri.query, isEmpty);
        expect(request.headers.value('authorization'), isNull);
        expect(
          await request.fold<int>(0, (total, bytes) => total + bytes.length),
          0,
        );
        request.response.statusCode = 405;
        await request.response.close();
        checked.complete();
      });
      expect(
        await probeDesktopConnection(
          Uri.parse('http://127.0.0.1:${server.port}/v1/tts?private=removed'),
          'DIRECT',
        ),
        isTrue,
      );
      await checked.future;
    },
  );

  test(
    'actual IOClient sends via the configured HTTP proxy without TUN',
    () async {
      HttpOverrides.global = null;
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      var requests = 0;
      proxy.listen((request) async {
        requests++;
        expect(request.method, 'POST');
        expect(request.uri.host, 'fish-proxy.invalid');
        expect(request.headers.value('authorization'), 'Bearer test-only-key');
        await request.drain<void>();
        request.response.headers.contentType = ContentType('audio', 'mpeg');
        request.response.add([1, 2, 3]);
        await request.response.close();
      });
      final client = DesktopTtsClient(
        readSettings: () async =>
            DesktopProxySettings(server: '127.0.0.1:${proxy.port}'),
        probe: (_, route) async => route != 'DIRECT',
      );
      addTearDown(client.close);
      final result = await FishAudioClient(client: client).synthesizeBytes(
        apiKey: 'test-only-key',
        referenceId: 'voice',
        text: 'proxy test',
        baseUrl: 'http://fish-proxy.invalid/v1/tts',
      );
      expect(result, [1, 2, 3]);
      expect(requests, 1);
    },
  );
}
