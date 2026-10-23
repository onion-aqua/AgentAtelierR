import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _credentialKey = 'fish_mcp_oauth_v1';
const _clientIdKey = 'fish_mcp_client_id_v1';
const _storage = FlutterSecureStorage();

String _credential({bool expired = false}) => jsonEncode({
  'accessToken': 'local-test-access',
  'refreshToken': 'local-test-refresh',
  'expiresAt': DateTime.now()
      .add(Duration(hours: expired ? -1 : 1))
      .toUtc()
      .toIso8601String(),
});

class _ConnectionClient extends McpClient {
  _ConnectionClient({this.onConnect})
    : super(const Implementation(name: 'local-autoconnect-test', version: '1'));

  final Future<void> Function(StreamableHttpClientTransport)? onConnect;
  int connections = 0;
  int listings = 0;
  int closes = 0;
  int toolCalls = 0;
  bool _connected = false;
  StreamableHttpClientTransport? _transportForTest;
  final started = Completer<void>();

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect(dynamic transport) async {
    connections++;
    _transportForTest = transport as StreamableHttpClientTransport;
    if (!started.isCompleted) started.complete();
    await onConnect?.call(_transportForTest!);
    _connected = true;
  }

  @override
  Future<ListToolsResult> listTools({
    ListToolsRequest? params,
    RequestOptions? options,
  }) async {
    listings++;
    return ListToolsResult(
      tools: [
        Tool(
          name: 'text_to_speech',
          inputSchema: JsonSchema.fromJson({
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
            'required': ['text'],
          }),
        ),
      ],
    );
  }

  @override
  Future<CallToolResult> callTool(
    CallToolRequest params, {
    RequestOptions? options,
  }) async {
    toolCalls++;
    throw StateError('Restoring a connection must not call a tool');
  }

  void remoteClose() {
    _connected = false;
    onclose?.call();
  }

  @override
  Future<void> close() async {
    closes++;
    _connected = false;
    await _transportForTest?.close();
    onclose?.call();
  }
}

class _Fixture {
  _Fixture(this.service, this.clients, this.created);

  final FishMcpService service;
  final List<_ConnectionClient> clients;
  final List<_ConnectionClient> created;

  static Future<_Fixture> create(List<_ConnectionClient> clients) async {
    final directory = await Directory.systemTemp.createTemp('fish-restore-');
    final created = <_ConnectionClient>[];
    final service = FishMcpService.forTesting(
      client: null,
      downloadClient: MockClient((_) async {
        fail('Connection restoration must not download audio');
      }),
      temporaryDirectory: () async => directory,
      connectionClientFactory: () {
        if (created.length >= clients.length) {
          fail('Unexpected extra connection attempt');
        }
        final client = clients[created.length];
        created.add(client);
        return client;
      },
    );
    addTearDown(() async {
      await service.disconnect();
      service.dispose();
      for (final client in created) {
        await client.close();
      }
      await directory.delete(recursive: true);
    });
    return _Fixture(service, clients, created);
  }
}

/// Supplies only read-only initialize messages to the real transport. This
/// drives the production OAuth provider without exposing it or generating TTS.
Future<void> _initializeTransport(
  StreamableHttpClientTransport transport, {
  int requests = 1,
}) async {
  await transport.start();
  await Future.wait([
    for (var id = 1; id <= requests; id++)
      transport.send(
        JsonRpcRequest(
          id: id,
          method: 'initialize',
          params: const {
            'protocolVersion': '2025-11-25',
            'capabilities': <String, dynamic>{},
            'clientInfo': {'name': 'local-test', 'version': '1'},
          },
        ),
      ),
  ]);
}

http.Response _initialized(http.Request request) {
  expect(request.url.toString(), FishMcpService.endpoint);
  final message = jsonDecode(request.body) as Map;
  expect(message['method'], 'initialize');
  return http.Response(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': {
        'protocolVersion': '2025-11-25',
        'capabilities': <String, dynamic>{},
        'serverInfo': {'name': 'local-test', 'version': '1'},
      },
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      _credentialKey: _credential(),
      _clientIdKey: 'local-test-client',
    });
  });

  test(
    'without credentials restore performs no connection or network call',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final fixture = await _Fixture.create([]);
      await http.runWithClient(() async {
        expect(await fixture.service.restoreConnection(), isFalse);
        expect(await fixture.service.restoreConnection(), isFalse);
      }, () => MockClient((_) async => fail('No HTTP request was expected')));
      expect(fixture.created, isEmpty);
      expect(fixture.service.state, FishMcpConnectionState.disconnected);
      expect(fixture.service.lastAuthorizationUri, isNull);
    },
  );

  test(
    'ten simultaneous restores share one connection and tools list',
    () async {
      final release = Completer<void>();
      final client = _ConnectionClient(onConnect: (_) => release.future);
      final fixture = await _Fixture.create([client]);
      final restorations = [
        for (var index = 0; index < 10; index++)
          fixture.service.restoreConnection(),
      ];
      await client.started.future;
      expect(fixture.created, hasLength(1));
      expect(client.connections, 1);
      expect(client.listings, 0);
      release.complete();
      expect(await Future.wait(restorations), everyElement(isTrue));
      expect(client.listings, 1);
      expect(await fixture.service.restoreConnection(), isTrue);
      expect(client.connections, 1);
    },
  );

  test(
    'failed restore can recover on the next explicit restore attempt',
    () async {
      final failing = _ConnectionClient(
        onConnect: (_) async => throw StateError('local outage'),
      );
      final succeeding = _ConnectionClient();
      final fixture = await _Fixture.create([failing, succeeding]);
      expect(await fixture.service.restoreConnection(), isFalse);
      expect(fixture.service.state, FishMcpConnectionState.error);
      expect(failing.listings, 0);
      expect(await fixture.service.restoreConnection(), isTrue);
      expect(succeeding.connections, 1);
      expect(succeeding.listings, 1);
      expect(fixture.created, hasLength(2));
    },
  );

  for (final logout in [false, true]) {
    test(
      '${logout ? 'logout' : 'disconnect'} cancels an in-flight connection without reviving it',
      () async {
        final originalCredential = await _storage.read(key: _credentialKey);
        final release = Completer<void>();
        final client = _ConnectionClient(onConnect: (_) => release.future);
        final fixture = await _Fixture.create([client]);
        final restoration = fixture.service.restoreConnection();
        await client.started.future;
        if (logout) {
          await fixture.service.logout();
        } else {
          await fixture.service.disconnect();
        }
        expect(await fixture.service.restoreConnection(), isFalse);
        release.complete();
        expect(await restoration, isFalse);
        expect(fixture.service.isReady, isFalse);
        expect(fixture.service.state, FishMcpConnectionState.disconnected);
        expect(client.listings, 0);
        expect(
          await _storage.read(key: _credentialKey),
          logout ? isNull : originalCredential,
        );
        expect(
          await _storage.read(key: _clientIdKey),
          logout ? isNull : 'local-test-client',
        );
      },
    );
  }

  test('manual reconnect cannot revive a synthesis or restore waiting on the old connection', () async {
    final release = Completer<void>();
    final oldClient = _ConnectionClient(onConnect: (_) => release.future);
    final newClient = _ConnectionClient();
    final fixture = await _Fixture.create([oldClient, newClient]);
    final oldRestore = fixture.service.restoreConnection();
    final oldSynthesis = fixture.service
        .synthesize(text: 'local cancelled text')
        .then<Object>((value) => value, onError: (Object error) => error);
    await oldClient.started.future;
    await fixture.service.disconnect();
    await fixture.service.connect(launchLogin: false);
    expect(fixture.service.isReady, isTrue);
    expect(newClient.listings, 1);
    release.complete();
    expect(await oldRestore, isFalse);
    expect(
      await oldSynthesis,
      isA<FishMcpException>()
          .having((error) => error.code, 'code', 'connection_changed')
          .having((error) => error.stage, 'stage', 'cancelled')
          .having((error) => error.generationSubmitted, 'submitted', isFalse),
    );
    expect(fixture.service.isReady, isTrue);
    expect(oldClient.listings, 0);
    expect(oldClient.toolCalls, 0);
    expect(newClient.toolCalls, 0);
    expect(fixture.created, hasLength(2));
  });

  test(
    'remote close invalidates discovery and the next restore reconnects',
    () async {
      final first = _ConnectionClient();
      final second = _ConnectionClient();
      final fixture = await _Fixture.create([first, second]);
      expect(await fixture.service.restoreConnection(), isTrue);
      first.remoteClose();
      expect(fixture.service.isReady, isFalse);
      expect(fixture.service.tools, isEmpty);
      expect(fixture.service.state, FishMcpConnectionState.disconnected);
      expect(await fixture.service.restoreConnection(), isTrue);
      expect(second.connections, 1);
      expect(second.listings, 1);
    },
  );

  for (final manualFirst in [false, true]) {
    test(
      'manual connect ${manualFirst ? 'before' : 'during'} restore shares its handshake',
      () async {
        final release = Completer<void>();
        final client = _ConnectionClient(onConnect: (_) => release.future);
        final fixture = await _Fixture.create([client]);
        final Future<void> manual;
        final Future<bool> restoration;
        if (manualFirst) {
          manual = fixture.service.connect(launchLogin: false);
          await client.started.future;
          restoration = fixture.service.restoreConnection();
        } else {
          restoration = fixture.service.restoreConnection();
          await client.started.future;
          manual = fixture.service.connect(launchLogin: false);
        }
        release.complete();
        await manual;
        expect(await restoration, isTrue);
        expect(fixture.created, hasLength(1));
        expect(client.connections, 1);
        expect(client.listings, 1);
      },
    );
  }

  test(
    'silent authentication rejection never registers or opens authorization',
    () async {
      final requests = <http.Request>[];
      await http.runWithClient(
        () async {
          final client = _ConnectionClient(onConnect: _initializeTransport);
          final fixture = await _Fixture.create([client]);
          expect(await fixture.service.restoreConnection(), isFalse);
          expect(fixture.service.isReady, isFalse);
          expect(fixture.service.lastAuthorizationUri, isNull);
          expect(fixture.service.lastError?.code, 'authorization_required');
          expect(requests, hasLength(1));
          expect(requests.single.url.toString(), FishMcpService.endpoint);
          expect(client.listings, 0);
        },
        () => MockClient((request) async {
          requests.add(request);
          expect(request.url.toString(), FishMcpService.endpoint);
          return http.Response('Unauthorized', 401);
        }),
      );
    },
  );

  test(
    'parallel authenticated transport requests share one token refresh',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        _credentialKey: _credential(expired: true),
        _clientIdKey: 'local-test-client',
      });
      var refreshes = 0;
      var readOnlyRequests = 0;
      await http.runWithClient(
        () async {
          final client = _ConnectionClient(
            onConnect: (transport) =>
                _initializeTransport(transport, requests: 2),
          );
          final fixture = await _Fixture.create([client]);
          expect(await fixture.service.restoreConnection(), isTrue);
          expect(refreshes, 1);
          expect(readOnlyRequests, 2);
          final credentials =
              jsonDecode((await _storage.read(key: _credentialKey))!) as Map;
          expect(credentials['accessToken'], 'local-test-refreshed');
          expect(credentials['refreshToken'], 'local-test-rotated-refresh');
        },
        () => MockClient((request) async {
          if (request.url.path == '/oauth/token') {
            refreshes++;
            expect(request.bodyFields['grant_type'], 'refresh_token');
            return http.Response(
              jsonEncode({
                'access_token': 'local-test-refreshed',
                'refresh_token': 'local-test-rotated-refresh',
                'expires_in': 3600,
              }),
              200,
            );
          }
          readOnlyRequests++;
          expect(
            request.headers['Authorization'],
            'Bearer local-test-refreshed',
          );
          return _initialized(request);
        }),
      );
    },
  );

  for (final logout in [false, true]) {
    test(
      '${logout ? 'logout' : 'disconnect'} during token refresh rejects late credential writes',
      () async {
        final originalCredential = _credential(expired: true);
        FlutterSecureStorage.setMockInitialValues({
          _credentialKey: originalCredential,
          _clientIdKey: 'local-test-client',
        });
        final refreshStarted = Completer<void>();
        final finishRefresh = Completer<http.Response>();
        await http.runWithClient(
          () async {
            final client = _ConnectionClient(onConnect: _initializeTransport);
            final fixture = await _Fixture.create([client]);
            final restoration = fixture.service.restoreConnection();
            await refreshStarted.future;
            if (logout) {
              await fixture.service.logout();
            } else {
              await fixture.service.disconnect();
            }
            finishRefresh.complete(
              http.Response(
                jsonEncode({
                  'access_token': 'must-not-be-saved',
                  'refresh_token': 'must-not-be-saved-either',
                  'expires_in': 3600,
                }),
                200,
              ),
            );
            expect(await restoration, isFalse);
            // Let the canceled HTTP callback finish its generation check.
            await Future<void>.delayed(Duration.zero);
            expect(await fixture.service.restoreConnection(), isFalse);
            expect(
              await _storage.read(key: _credentialKey),
              logout ? isNull : originalCredential,
            );
            expect(fixture.service.state, FishMcpConnectionState.disconnected);
            expect(client.listings, 0);
          },
          () => MockClient((request) async {
            expect(request.url.path, '/oauth/token');
            expect(request.bodyFields['grant_type'], 'refresh_token');
            refreshStarted.complete();
            return finishRefresh.future;
          }),
        );
      },
    );
  }
}
