import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'relay_protocol.dart';
import 'relay_store.dart';
import 'relay_transport.dart';
import 'relay_push.dart';
import 'relay_history_codec.dart';
import 'relay_server_config.dart';

/// Separate from role chat and its exports. All network mutations originate in
/// explicit user interaction; the role LLM has no reference to this service.
class RelayService extends ChangeNotifier {
  RelayService({
    required this.store,
    required this.transport,
    RelayPushProvider? push,
    DateTime Function()? now,
    RelayServerConfig serverConfig = const RelayServerConfig.unrestricted(),
    Future<RelayServerConfig> Function()? serverConfigLoader,
  }) : push = push ?? DisabledRelayPush(),
       now = now ?? DateTime.now,
       // Keep the injectable public name with read-only public access.
       // ignore: prefer_initializing_formals
       _serverConfig = serverConfig,
       _serverConfigLoader = serverConfigLoader,
       _serverConfigReady = serverConfigLoader == null;
  factory RelayService.production() => RelayService(
    store: SecureRelayStore(),
    transport: HttpsRelayTransport(),
    push: configuredPushProvider(),
    serverConfigLoader: RelayServerConfig.fromEnvironment,
  );
  final RelayStore store;
  final RelayTransport transport;
  final RelayPushProvider push;
  final DateTime Function() now;
  RelayServerConfig _serverConfig;
  final Future<RelayServerConfig> Function()? _serverConfigLoader;
  bool _serverConfigReady;
  RelayServerConfig get serverConfig => _serverConfig;
  List<Json> _profiles = [];
  List<Json> get profiles => List.unmodifiable(_profiles);
  final Map<String, String> connections = {};
  final Map<String, String> errors = {};
  final Set<String> ready = {};
  final Map<String, RelaySocket> _sockets = {};
  final Map<String, DateTime> _lastReceived = {};
  final Map<String, DateTime> _retryAt = {};
  final Map<String, int> _attempts = {};
  final Set<String> _scheduled = {};
  final List<StreamSubscription<dynamic>> _pushListeners = [];
  Future<void> _tail = Future.value();
  Timer? _timer;
  bool foreground = false;
  bool initialized = false;
  bool _disposed = false;
  String? startupError;
  String? focusProfile;
  String? focusRequest;
  String? pushToken;
  bool pushEnabled = false;
  String pushStatus = '未启用后台推送';
  int _tick = 0;

  Json? profile(String id) =>
      _profiles.where((p) => p['device_id'] == id).firstOrNull;
  Uri verifyPairingServer(PairingQr qr) => _allowedOrigin(qr.origin);

  Uri _allowedOrigin(Uri origin) {
    if (!_serverConfigReady) {
      throw const FormatException('联动服务器配置未能安全载入，已停用联网。');
    }
    return _serverConfig.requireAllowed(origin);
  }

  Uri _origin(Json p) =>
      _allowedOrigin(secureOrigin(p['server_base_url'] as String));

  bool _profileCanConnect(Json p) {
    try {
      _origin(p);
      return true;
    } on Object {
      return false;
    }
  }

  void _markServerDisabled(Json p) {
    final id = p['device_id'] as String;
    _disconnect(id);
    ready.remove(id);
    connections[id] = 'server_disabled';
    errors[id] = '此绑定的服务器不属于当前固定版本，已停用连接。';
  }

  String _token(Json p) => p['device_token'] as String;
  Json _cache(Json p) => object(p['cache']);
  List<Json> collection(Json p, String key) => objects(_cache(p)[key] ?? []);
  String pcName(Json p) {
    final pc = collection(
      p,
      'devices',
    ).where((d) => d['device_id'] == p['pc_id']).firstOrNull;
    return pc?['device_name'] as String? ?? p['pc_id'] as String? ?? '待确认 PC';
  }

  String sessionName(Json p, Object? sessionId) =>
      collection(
            p,
            'sessions',
          ).where((s) => s['session_id'] == sessionId).firstOrNull?['title']
          as String? ??
      sessionId?.toString() ??
      '新会话';
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _serial<T>(Future<T> Function() fn) {
    final result = _tail.then((_) {
      if (_disposed) throw const RelayFailure('CLOSED');
      return fn();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _commit(List<Json> value) async {
    // A failed secure write must not advance the in-memory cursor either.
    await store.write(
      jsonEncode({'v': 1, 'profiles': value, 'push_enabled': pushEnabled}),
    );
    _profiles = value;
    _notify();
  }

  Future<void> _replace(Json value) async {
    final id = value['device_id'];
    await _commit([
      for (final p in _profiles)
        if (p['device_id'] != id) p else value,
    ]);
  }

  Json _copy(Json p) => object(jsonDecode(jsonEncode(p)));
  static Json emptyCache() => {
    'cursor': 0,
    'events': <Json>[],
    'seen': <String>[],
    'requests': <Json>[],
    'tasks': <Json>[],
    'actions': <Json>[],
    'devices': <Json>[],
    'workspaces': <Json>[],
    'sessions': <Json>[],
    'history': <Json>[],
    'outbox': <Json>[],
    'presented': <String>[],
  };

  Future<void> initialize() async {
    if (initialized) return;
    if (_serverConfigLoader != null && !_serverConfigReady) {
      try {
        _serverConfig = await _serverConfigLoader();
        _serverConfigReady = true;
      } on Object {
        startupError = '联动服务器配置无法安全载入，已停用联网；请重新安装正确的构建版本。';
        _notify();
        return;
      }
    }
    try {
      final saved = await store.read();
      if (saved != null) {
        final data = object(jsonDecode(saved));
        if (data['v'] != 1) throw const FormatException('Unsupported registry');
        _profiles = objects(data['profiles']);
        pushEnabled = data['push_enabled'] == true;
        for (final p in _profiles) {
          // Corrupt persisted origins remain storage errors; only a valid old
          // server that differs from the pinned build is retained as disabled.
          secureOrigin(p['server_base_url'] as String);
          _cache(p);
          if (!_profileCanConnect(p)) _markServerDisabled(p);
        }
      }
      if (_disposed) return;
      initialized = true;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        _notify(); // expiration countdown / closing expired questions
        if (!foreground) return;
        _tick++;
        for (final p in profiles) {
          final id = p['device_id'] as String;
          if (p['device_token'] == null || !_profileCanConnect(p)) continue;
          if (_tick % 15 == 0 ||
              (p['state'] != 'confirmed' && _tick % 5 == 0)) {
            _scheduleSync(id);
          }
          if (_tick % 20 == 0 && _sockets.containsKey(id)) {
            if (now().difference(_lastReceived[id] ?? now()).inSeconds > 55) {
              _disconnect(id);
              _scheduleSync(id);
            } else {
              try {
                _sockets[id]?.send({'v': 1, 'type': 'ping'});
              } on Object {
                _disconnect(id);
              }
            }
          }
        }
      });
      if (foreground) await setForeground(true);
      if (pushEnabled) await enablePush();
    } on Object {
      startupError = '联动安全存储读取失败；未覆盖原数据，请重启后重试';
    }
    _notify();
  }

  Future<void> setForeground(bool value) async {
    if (_disposed) return;
    foreground = value;
    ready.clear();
    if (!value) {
      for (final id in _sockets.keys.toList()) {
        _disconnect(id);
      }
      _notify();
      return;
    }
    if (!initialized) return;
    for (final p in profiles) {
      if (p['device_token'] != null && _profileCanConnect(p)) {
        await sync(p['device_id'] as String, snapshot: true);
      }
    }
    _notify();
  }

  Future<String> pair(
    PairingQr qr,
    String deviceName, {
    required bool trustedByUser,
  }) => _serial(() async {
    if (!initialized || !trustedByUser) {
      throw const RelayFailure('UNTRUSTED_SERVER');
    }
    final origin = verifyPairingServer(qr);
    if (deviceName.trim().isEmpty || deviceName.length > 80) {
      throw const FormatException('请填写不超过80字的手机名称');
    }
    var p = _profiles
        .where(
          (p) =>
              _profileCanConnect(p) &&
              _origin(p) == origin &&
              p['pairing_id'] == qr.pairingId &&
              p['device_token'] != null,
        )
        .firstOrNull;
    if (p?['state'] == 'confirmed') return p!['device_id'] as String;
    if (p == null) {
      p = {
        'server_base_url': origin.toString(),
        'pairing_id': qr.pairingId,
        'device_id': newUuid(),
        'device_token': newDeviceToken(),
        'device_name': deviceName.trim(),
        'state': 'pending_confirmation',
        'pc_id': null,
        'capabilities': <String>[],
        'cache': emptyCache(),
      };
      await _commit([..._profiles, p]); // BEFORE claim; never store qr.secret
    }
    final id = p['device_id'] as String;
    try {
      final response = await transport.request(
        origin,
        'POST',
        '/v1/pairings/claim',
        body: {
          'pairing_id': qr.pairingId,
          'pairing_secret': qr.secret,
          'device_id': id,
          'device_name': p['device_name'],
          'device_token_hash': await tokenDigest(_token(p)),
        },
      );
      final next = _copy(p)..['expires_at'] = response['expires_at'];
      await _replace(next);
      await _pairStatus(id);
    } on RelayFailure catch (e) {
      if ({
        'PAIRING_USED',
        'PAIRING_EXPIRED',
        'PAIRING_NOT_FOUND',
        'DEVICE_EXISTS',
      }.contains(e.code)) {
        await _terminal(
          id,
          e.code == 'PAIRING_EXPIRED' ? 'expired' : 'rejected',
        );
      }
      errors[id] = e.toString();
      rethrow;
    }
    return id;
  });

  Future<void> _pairStatus(String id) async {
    final p = profile(id)!;
    final response = await transport.request(
      _origin(p),
      'GET',
      '/v1/pairings/${Uri.encodeComponent(p['pairing_id'] as String)}/status',
      token: _token(p),
    );
    final state = response['state'];
    if (state == 'rejected' || state == 'expired') {
      await _terminal(id, state as String);
      return;
    }
    if (state != 'confirmed' && state != 'pending_confirmation') {
      throw const FormatException('配对状态无效');
    }
    if (response['device_id'] != null && response['device_id'] != id) {
      throw const FormatException('配对设备不匹配');
    }
    if (state == 'confirmed' &&
        (response['pc_id'] is! String ||
            !uuidPattern.hasMatch(response['pc_id'] as String))) {
      throw const FormatException('PC身份缺失');
    }
    final capabilities = relayCapabilities(response['capabilities']);
    final historyRead = response['history_read'] == true;
    if (p['state'] == state &&
        p['pc_id'] == response['pc_id'] &&
        p['expires_at'] == response['expires_at'] &&
        jsonEncode(p['capabilities']) == jsonEncode(capabilities) &&
        p['history_read'] == historyRead &&
        (historyRead || collection(p, 'history').isEmpty)) {
      return;
    }
    final next = _copy(p)
      ..['state'] = state
      ..['pc_id'] = response['pc_id']
      ..['expires_at'] = response['expires_at']
      ..['capabilities'] = capabilities
      ..['history_read'] = historyRead;
    if (next['history_read'] != true) {
      next['cache'] = object(next['cache'])..['history'] = <Json>[];
    }
    await _replace(next);
  }

  Future<void> _terminal(String id, String state) async {
    _disconnect(id);
    ready.remove(id);
    final p = profile(id);
    if (p == null) return;
    final next = _copy(p)
      ..remove('device_token')
      ..remove('push_subscription_id')
      ..remove('push_registration_token')
      ..['state'] = state
      ..['cache'] = emptyCache();
    await _replace(next);
    connections[id] = state;
  }

  Future<void> unpair(String id) => _serial(() async {
    final p = profile(id);
    if (p == null) return;
    _origin(p); // A fixed build cannot remotely revoke a different server.
    if (p['device_token'] != null) {
      // Pending profiles cannot access DELETE devices; they may be forgotten
      // locally and approved accidentally later, so require PC rejection first.
      if (p['state'] != 'confirmed') {
        throw const FormatException('请先在 PC 拒绝此待确认配对，或等待二维码过期后同步');
      }
      try {
        await _unregisterPush(p);
        await transport.request(
          _origin(p),
          'DELETE',
          '/v1/devices/$id',
          token: _token(p),
        );
      } on RelayFailure catch (e) {
        if (e.code != 'DEVICE_REVOKED' && e.code != 'UNAUTHORIZED') rethrow;
      }
    }
    _disconnect(id);
    ready.remove(id);
    await _commit(_profiles.where((p) => p['device_id'] != id).toList());
  });

  void _scheduleSync(String id) {
    final p = profile(id);
    if (!foreground ||
        _disposed ||
        p == null ||
        !_profileCanConnect(p) ||
        !_scheduled.add(id)) {
      return;
    }
    unawaited(sync(id).whenComplete(() => _scheduled.remove(id)));
  }

  Future<void> sync(String id, {bool snapshot = false}) => _serial(() async {
    var p = profile(id);
    if (p == null || p['device_token'] == null) return;
    if (!_profileCanConnect(p)) {
      _markServerDisabled(p);
      _notify();
      return;
    }
    try {
      // PC approval may narrow capabilities after pairing. Refresh the server
      // authority before presenting questions or retrying any queued action.
      await _pairStatus(id);
      p = profile(id)!;
      if (p['state'] != 'confirmed') return;
      connections[id] = 'connecting';
      if (snapshot || _cache(p)['cursor'] == 0) await _snapshot(id);
      try {
        await _pull(id);
      } on RelayFailure catch (e) {
        if (e.code != 'CURSOR_EXPIRED') rethrow;
        await _snapshot(id);
        await _pull(id);
      }
      p = profile(id)!;
      if (p['device_token'] == null) return;
      await _reconcileActions(id);
      await _refreshHistoryAccess(id);
      final historyFeature = object(
        _cache(profile(id)!)['history_feature'] ?? {},
      );
      if (historyFeature['supported'] == true &&
          historyFeature['permission'] == true) {
        try {
          await _refreshSessionList(id);
        } on RelayFailure catch (e) {
          if (e.code == 'DEVICE_REVOKED' || e.code == 'UNAUTHORIZED') rethrow;
          // History list availability must not block questions or task actions.
        }
      }
      try {
        await _registerPush(id);
      } on RelayFailure catch (e) {
        if (e.code == 'DEVICE_REVOKED' || e.code == 'UNAUTHORIZED') rethrow;
        pushStatus = '推送注册失败；前台同步可用';
      }
      if (foreground) ready.add(id);
      connections[id] = 'online';
      errors.remove(id);
      if (foreground &&
          !_sockets.containsKey(id) &&
          !now().isBefore(_retryAt[id] ?? DateTime(0))) {
        await _connect(id);
      }
    } on RelayFailure catch (e) {
      p = profile(id);
      if (e.code == 'DEVICE_REVOKED' ||
          (e.code == 'UNAUTHORIZED' && p?['state'] == 'confirmed')) {
        await _terminal(id, 'revoked');
      } else if (e.code == 'PAIRING_NOT_FOUND') {
        await _terminal(id, 'expired');
      } else {
        connections[id] = e.code == 'FORBIDDEN' ? 'forbidden' : 'offline';
      }
      ready.remove(id);
      errors[id] = e.toString();
    } on Object {
      ready.remove(id);
      connections[id] = 'offline';
      errors[id] = '同步失败，已保留本地游标和待发送操作；稍后重试';
    }
    _notify();
  });

  Future<void> _snapshot(String id) async {
    final p = profile(id)!;
    final data = await transport.request(
      _origin(p),
      'GET',
      '/v1/state',
      token: _token(p),
    );
    if (data['snapshot_seq'] is! int || (data['snapshot_seq'] as int) < 0) {
      throw const FormatException('无效快照游标');
    }
    if ((data['snapshot_seq'] as int) < (_cache(p)['cursor'] as int)) {
      throw const FormatException('服务器快照游标回退，保留当前状态');
    }
    final next = _copy(p);
    final cache = object(next['cache']);
    for (final key in [
      'devices',
      'workspaces',
      'sessions',
      'requests',
      'tasks',
      'actions',
    ]) {
      final rows = objects(data[key]);
      cache[key] = key == 'actions'
          ? rows.map(mobileActionSummary).toList()
          : rows;
    }
    final ownDevice = objects(cache['devices'])
        .where(
          (d) =>
              d['device_id'] == id &&
              d['role'] == 'mobile' &&
              d['pc_id'] == next['pc_id'],
        )
        .firstOrNull;
    if (ownDevice != null) {
      next['capabilities'] = relayCapabilities(ownDevice['capabilities']);
      next['history_read'] = ownDevice['history_read'] == true;
    }
    _pruneHistory(next, cache);
    cache['cursor'] = data['snapshot_seq'];
    cache['events'] = <Json>[];
    next['cache'] = cache;
    await _replace(next);
    await _ack(id);
  }

  Future<void> _ack(String id) async {
    final p = profile(id)!;
    if (p['device_token'] == null) return;
    final seq = _cache(p)['cursor'];
    await transport.request(
      _origin(p),
      'POST',
      '/v1/events/ack',
      token: _token(p),
      body: {'seq': seq},
    );
    try {
      _sockets[id]?.send({'v': 1, 'type': 'ack', 'seq': seq});
    } on Object {
      _disconnect(id);
    }
  }

  Future<void> _pull(String id) async {
    for (var page = 0; page < 100; page++) {
      final p = profile(id)!;
      final cursor = _cache(p)['cursor'] as int;
      final data = await transport.request(
        _origin(p),
        'GET',
        '/v1/events?after_seq=$cursor&limit=100',
        token: _token(p),
      );
      final events = objects(data['events']).map(validateEvent).toList()
        ..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
      final next = _copy(p);
      final cache = object(next['cache']);
      var seq = cursor;
      var redacted = false;
      final seen = List<String>.from(cache['seen'] as List);
      for (final event in events) {
        final n = event['seq'] as int;
        if (event['type'] == 'scope.redacted' &&
            (n <= seq || seen.contains(event['event_id']))) {
          // Revocation projections override a formerly cached event, even
          // when its ID/sequence has already been seen and acknowledged.
          _applyEvent(cache, event);
          redacted = true;
        }
        if (n <= seq) continue;
        if (n != seq + 1) {
          throw const RelayFailure('EVENT_GAP', retryable: true);
        }
        if (!seen.contains(event['event_id'])) {
          _applyEvent(cache, event);
          seen.add(event['event_id'] as String);
        }
        seq = n;
        if (event['type'] == 'device.revoked') {
          await _terminal(id, 'revoked');
          return;
        }
      }
      cache['seen'] = seen.reversed.take(2000).toList().reversed.toList();
      cache['cursor'] = seq;
      _pruneHistory(next, cache);
      next['cache'] = cache;
      if (seq != cursor || redacted) await _replace(next);
      await _ack(id);
      if (data['has_more'] != true) return;
      if (seq == cursor) throw const RelayFailure('EVENT_GAP', retryable: true);
    }
    throw const RelayFailure('SYNC_LIMIT', retryable: true);
  }

  void _upsert(Json cache, String key, String idKey, Json row) {
    if (row[idKey] == null) throw const FormatException('状态标识缺失');
    final rows = objects(cache[key]);
    final index = rows.indexWhere((r) => r[idKey] == row[idKey]);
    if (index < 0) {
      rows.add(row);
    } else {
      rows[index] = {...rows[index], ...row};
    }
    cache[key] = rows;
  }

  void _applyEvent(Json cache, Json e) {
    final type = e['type'] as String;
    final payload = type == 'action.result'
        ? mobileActionSummary(e['payload'])
        : object(e['payload']);
    if (type == 'scope.redacted') {
      final previous = objects(cache['events'])
          .where((old) => old['event_id'] == e['event_id'])
          .firstOrNull;
      if (previous != null) {
        if (previous['request_id'] != null) {
          cache['requests'] = objects(cache['requests'])
              .where((r) => r['request_id'] != previous['request_id'])
              .toList();
        }
        final taskId = object(previous['payload'])['task_id'];
        if (taskId != null) {
          cache['tasks'] = objects(cache['tasks'])
              .where((t) => t['task_id'] != taskId)
              .toList();
        }
      }
      cache['events'] = objects(cache['events'])
          .where((old) => old['event_id'] != e['event_id'])
          .toList();
    }
    if (type.startsWith('question.') || type.startsWith('approval.')) {
      final old = objects(cache['requests'])
          .where((r) => r['request_id'] == e['request_id'])
          .firstOrNull;
      _upsert(cache, 'requests', 'request_id', {
        ...?old,
        'request_id': e['request_id'],
        'pc_id': e['pc_id'],
        'session_id': e['session_id'],
        'kind': type.split('.').first,
        'state': payload['state'],
        'created_at': old?['created_at'] ?? e['created_at'],
        'expires_at': e['expires_at'] ?? old?['expires_at'],
        'payload': {
          if (old?['payload'] is Map) ...object(old!['payload']),
          ...payload,
        },
      });
    } else if (type == 'task.updated') {
      _upsert(cache, 'tasks', 'task_id', {
        ...payload,
        'pc_id': e['pc_id'],
        'session_id': e['session_id'],
      });
    } else if (type == 'action.result') {
      final summary = mobileActionSummary(payload);
      _upsert(cache, 'actions', 'action_id', summary);
      final outbox = objects(cache['outbox']);
      for (final a in outbox) {
        if (a['action_id'] == payload['action_id']) {
          a['local_status'] = payload['status'];
          a['result'] = summary;
        }
      }
      cache['outbox'] = outbox;
    } else if (type == 'pc.state.updated') {
      for (final key in ['workspaces', 'sessions']) {
        cache[key] = [
          ...objects(cache[key]).where((r) => r['pc_id'] != e['pc_id']),
          ...objects(payload[key]),
        ];
      }
      _pruneHistoryScope(cache, e['pc_id']);
    } else if (type == 'session.history.updated') {
      final session = objects(cache['sessions'])
          .where(
            (s) =>
                s['session_id'] == e['session_id'] && s['pc_id'] == e['pc_id'],
          )
          .firstOrNull;
      if (session != null && payload['history_revision'] is int) {
        _upsert(cache, 'sessions', 'session_id', {
          ...session,
          'history_revision': payload['history_revision'],
          'history_state': payload['history_state'],
        });
      }
    }
    cache['events'] = [
      ...objects(cache['events']),
      {...e, 'payload': payload},
    ].reversed.take(300).toList().reversed.toList();
  }

  void _pruneHistoryScope(Json cache, Object? pcId) {
    final allowed = objects(cache['sessions'])
        .where((s) => s['pc_id'] == pcId)
        .map((s) => s['session_id'])
        .toSet();
    cache['history'] = objects(cache['history'] ?? [])
        .where((h) => allowed.contains(h['session_id']))
        .toList();
    // Old events must not keep titles or questions for a removed scope.
    cache['events'] = objects(cache['events'])
        .where(
          (e) =>
              e['pc_id'] != pcId ||
              e['session_id'] == null ||
              allowed.contains(e['session_id']),
        )
        .toList();
  }

  void _pruneHistory(Json p, Json cache) {
    if (p['history_read'] != true) {
      cache['history'] = <Json>[];
    } else {
      _pruneHistoryScope(cache, p['pc_id']);
    }
  }

  /// Feature discovery is backward compatible. A missing old endpoint never
  /// disables the existing question/task transport.
  Future<void> _refreshHistoryAccess(String id) async {
    final p = profile(id)!;
    _origin(p);
    Json feature;
    try {
      final response = await transport.request(
        _origin(p),
        'GET',
        '/v1/features',
        token: _token(p),
      );
      feature = object(object(response['features'])['session_history']);
      if (response['protocol_version'] != 1 ||
          response['pc_id'] != p['pc_id'] ||
          feature['version'] != 1 ||
          feature['supported'] is! bool ||
          feature['permission'] is! bool ||
          !{
            'unsupported',
            'forbidden',
            'syncing',
            'ready',
          }.contains(feature['state'])) {
        throw const RelayFailure('PROTOCOL_ERROR');
      }
    } on RelayFailure catch (e) {
      if (e.code == 'DEVICE_REVOKED' || e.code == 'UNAUTHORIZED') rethrow;
      if (!{
        'HISTORY_UNSUPPORTED',
        'NOT_FOUND',
        'HTTP_ERROR',
        'PROTOCOL_ERROR',
      }.contains(e.code)) {
        return; // A network failure preserves the last authenticated cache.
      }
      feature = {
        'version': 1,
        'supported': false,
        'permission': p['history_read'] == true,
        'state': 'unsupported',
      };
    } on Object {
      // Older/test transports may have no feature route at all.
      feature = {
        'version': 1,
        'supported': false,
        'permission': p['history_read'] == true,
        'state': 'unsupported',
      };
    }
    if (p['history_read'] == (feature['permission'] == true) &&
        jsonEncode(_cache(p)['history_feature']) == jsonEncode(feature) &&
        (p['history_read'] == true || collection(p, 'history').isEmpty)) {
      return;
    }
    final next = _copy(profile(id)!);
    final cache = object(next['cache']);
    cache['history_feature'] = feature;
    cache['history'] ??= <Json>[];
    next['history_read'] = feature['permission'] == true;
    if (next['history_read'] != true) cache['history'] = <Json>[];
    next['cache'] = cache;
    await _replace(next);
  }

  Future<void> _refreshSessionList(String id) async {
    final p = profile(id)!;
    final sessions = <Json>[];
    final cursors = <String>{};
    String? cursor;
    for (var page = 0; page < 1000; page++) {
      final path = Uri(
        path: '/v1/sessions',
        queryParameters: {
          'limit': '100',
          'pc_id': p['pc_id'] as String,
          'cursor': ?cursor,
        },
      ).toString();
      final response = await transport.request(
        _origin(p),
        'GET',
        path,
        token: _token(p),
      );
      if (response['pc_id'] != p['pc_id'] ||
          response['snapshot_seq'] is! int ||
          (response['snapshot_seq'] as int) < 0 ||
          response['has_more'] is! bool) {
        throw const RelayFailure('PROTOCOL_ERROR');
      }
      final rows = objects(response['sessions']);
      if (rows.any(
        (s) =>
            s['pc_id'] != p['pc_id'] ||
            s['session_id'] is! String ||
            (s['session_id'] as String).isEmpty,
      )) {
        throw const RelayFailure('PROTOCOL_ERROR');
      }
      sessions.addAll(rows);
      final nextCursor = response['next_cursor'];
      if (response['has_more'] != true) {
        final next = _copy(profile(id)!);
        final cache = object(next['cache']);
        final byId = {for (final s in sessions) s['session_id']: s};
        final rows = byId.values.toList();
        if (jsonEncode(cache['sessions']) == jsonEncode(rows)) return;
        cache['sessions'] = rows;
        _pruneHistory(next, cache);
        next['cache'] = cache;
        await _replace(next); // snapshot_seq here must NEVER advance ACK.
        return;
      }
      if (nextCursor is! String ||
          nextCursor.isEmpty ||
          !cursors.add(nextCursor)) {
        throw const RelayFailure('PROTOCOL_ERROR');
      }
      cursor = nextCursor;
    }
    throw const RelayFailure('SYNC_LIMIT', retryable: true);
  }

  /// Load a complete readable revision, then atomically replace old messages.
  /// The protocol pages forwards, so partial fragments are never published as
  /// complete messages. The UI's older argument is reserved for an adapter
  /// offering reverse pagination; v1 always reads a whole revision.
  Future<void> refreshSessionHistory(
    String id,
    String sessionId, {
    bool older = false,
  }) async {
    var p = profile(id);
    if (p == null || p['state'] != 'confirmed' || p['device_token'] == null) {
      return;
    }
    _origin(p);
    try {
      await _serial(() => _refreshHistoryAccess(id));
      p = profile(id);
      if (p == null || p['device_token'] == null || p['state'] != 'confirmed') {
        return;
      }
      final feature = object(_cache(p)['history_feature'] ?? {});
      if (feature['permission'] != true || feature['supported'] != true) {
        await _historyStatus(
          id,
          sessionId,
          feature['permission'] != true ? 'forbidden' : 'unsupported',
        );
        return;
      }
      var session = collection(p, 'sessions')
          .where(
            (s) => s['session_id'] == sessionId && s['pc_id'] == p!['pc_id'],
          )
          .firstOrNull;
      if (session == null) {
        // An accepted new action can precede pc.state.updated in the inbox.
        await _serial(() => _refreshSessionList(id));
        p = profile(id)!;
        session = collection(p, 'sessions')
            .where(
              (s) => s['session_id'] == sessionId && s['pc_id'] == p!['pc_id'],
            )
            .firstOrNull;
      }
      if (session == null || session['workspace_id'] is! String) {
        await _historyStatus(id, sessionId, 'forbidden');
        return;
      }
      for (var attempt = 0; attempt < 3; attempt++) {
        final assembler = RelayHistoryAssembler(
          pcId: p['pc_id'] as String,
          sessionId: sessionId,
          workspaceId: session['workspace_id'] as String,
        );
        final cursors = <String>{};
        try {
          for (var page = 0; page < 1000; page++) {
            final current = profile(id);
            if (current == null ||
                current['device_token'] != p['device_token'] ||
                current['history_read'] != true ||
                !foreground) {
              return;
            }
            final path =
                Uri.parse(
                      '/v1/sessions/${Uri.encodeComponent(sessionId)}/messages',
                    )
                    .replace(
                      queryParameters: {
                        'limit': '100',
                        'pc_id': p['pc_id'] as String,
                        if (assembler.nextCursor != null)
                          'cursor': assembler.nextCursor!,
                        if (assembler.revision != null)
                          'revision': '${assembler.revision}',
                      },
                    )
                    .toString();
            final response = await transport.request(
              _origin(p),
              'GET',
              path,
              token: _token(p),
            );
            assembler.addPage(response);
            final latest = profile(id);
            if (latest == null ||
                latest['device_token'] != p['device_token'] ||
                latest['history_read'] != true) {
              return;
            }
            final cached = collection(
              latest,
              'history',
            ).where((h) => h['session_id'] == sessionId).firstOrNull;
            if (page == 0 &&
                cached?['availability'] == 'available' &&
                cached?['revision'] == assembler.revision &&
                cached?['connection_state'] == assembler.connectionState &&
                cached?['sync_state'] == response['sync_state']) {
              return; // An unchanged full revision needs no repeated body transfer.
            }
            if (!assembler.hasMore) {
              final messages = assembler.messages();
              await _serial(() async {
                final active = profile(id);
                if (active == null ||
                    active['state'] != 'confirmed' ||
                    active['device_token'] != p!['device_token'] ||
                    active['history_read'] != true ||
                    !collection(active, 'sessions').any(
                      (s) =>
                          s['session_id'] == sessionId &&
                          s['pc_id'] == p!['pc_id'] &&
                          s['workspace_id'] == session!['workspace_id'],
                    )) {
                  return;
                }
                final next = _copy(active);
                final cache = object(next['cache']);
                final saved = objects(cache['history'])
                    .where((h) => h['session_id'] == sessionId)
                    .firstOrNull;
                if (saved?['revision'] is int &&
                    (saved!['revision'] as int) > assembler.revision!) {
                  return;
                }
                _upsert(cache, 'history', 'session_id', {
                  'session_id': sessionId,
                  'messages': messages,
                  'availability': 'available',
                  'has_more': false,
                  'revision': assembler.revision,
                  'connection_state': assembler.connectionState,
                  'sync_state': response['sync_state'],
                  'error': null,
                });
                next['cache'] = cache;
                await _replace(
                  next,
                ); // Entire revision, edits/deletions included.
              });
              return;
            }
            if (!cursors.add(assembler.nextCursor!)) {
              throw const RelayFailure('PROTOCOL_ERROR');
            }
          }
          throw const RelayFailure('SYNC_LIMIT', retryable: true);
        } on RelayFailure catch (e) {
          if (e.code != 'HISTORY_CHANGED' || attempt == 2) rethrow;
          // Discard only this in-flight assembly and restart without a cursor.
        }
      }
    } on RelayFailure catch (e) {
      if (e.code == 'DEVICE_REVOKED' || e.code == 'UNAUTHORIZED') {
        await _serial(() => _terminal(id, 'revoked'));
      } else if (e.code == 'FORBIDDEN') {
        await _historyStatus(id, sessionId, 'forbidden');
      } else if (e.code == 'HISTORY_UNSUPPORTED') {
        await _historyStatus(id, sessionId, 'unsupported');
      } else if (e.code == 'HISTORY_NOT_READY') {
        await _historyStatus(id, sessionId, 'not_ready');
      } else {
        rethrow;
      }
    }
  }

  Future<void> _historyStatus(
    String id,
    String sessionId,
    String availability,
  ) => _serial(() async {
    final p = profile(id);
    if (p == null || p['state'] != 'confirmed' || p['device_token'] == null) {
      return;
    }
    final next = _copy(p);
    final cache = object(next['cache']);
    _upsert(cache, 'history', 'session_id', {
      'session_id': sessionId,
      'messages': <Json>[],
      'availability': availability,
      'has_more': false,
      'error': null,
    });
    next['cache'] = cache;
    await _replace(next);
  });

  Future<void> _connect(String id) async {
    final p = profile(id)!;
    try {
      final socket = await transport.connect(_origin(p), _token(p));
      if (!foreground || _disposed) {
        await socket.close();
        return;
      }
      _sockets[id] = socket;
      _lastReceived[id] = now();
      socket.messages.listen(
        (raw) {
          if (_disposed || !identical(_sockets[id], socket)) return;
          _lastReceived[id] = now();
          try {
            final data = object(raw);
            if (data['v'] != 1) return;
            if (data['type'] == 'ping') {
              socket.send({'v': 1, 'type': 'pong'});
            }
            if (data['type'] == 'pong' || data['type'] == 'event') {
              _attempts[id] = 0;
            }
            // REST is the authoritative contiguous inbox. A WSS frame is a wakeup;
            // it cannot skip a missing sequence or advance ACK before storage.
            if (data['type'] == 'event') _scheduleSync(id);
            if (data['error'] is Map &&
                data['error']['code'] == 'CURSOR_EXPIRED') {
              _scheduleSync(id);
            }
          } on Object {
            _disconnect(id);
          }
        },
        onError: (Object _) {
          if (identical(_sockets[id], socket)) _disconnect(id);
        },
        onDone: () {
          if (identical(_sockets[id], socket)) _disconnect(id);
        },
      );
      socket.send({'v': 1, 'type': 'resume', 'after_seq': _cache(p)['cursor']});
    } on Object {
      _disconnect(id);
    }
  }

  void _disconnect(String id) {
    final socket = _sockets.remove(id);
    if (socket != null) unawaited(socket.close().catchError((Object _) {}));
    final attempt = min((_attempts[id] ?? 0) + 1, 6);
    _attempts[id] = attempt;
    _retryAt[id] = now().add(
      Duration(seconds: min(60, 1 << attempt) + Random().nextInt(3)),
    );
    if (connections[id] == 'online') connections[id] = 'offline';
  }

  Json? actionForRequest(Json p, String requestId) => collection(
    p,
    'outbox',
  ).where((a) => object(a['body'])['request_id'] == requestId).lastOrNull;
  bool requestCanSend(Json p, Json request) {
    final capability = request['kind'] == 'approval'
        ? 'approval.respond'
        : 'question.answer';
    if (!relayCapabilities(p['capabilities']).contains(capability) ||
        !ready.contains(p['device_id']) ||
        !isPending(request, now())) {
      return false;
    }
    final action = actionForRequest(p, request['request_id'] as String);
    return action == null ||
        {'rejected', 'conflict', 'expired'}.contains(action['local_status']);
  }

  Future<void> markPresented(String id, String key) => _serial(() async {
    final next = _copy(profile(id)!);
    final cache = object(next['cache']);
    cache['presented'] = {
      ...List<String>.from(cache['presented'] as List),
      key,
    }.toList();
    next['cache'] = cache;
    await _replace(next);
  });

  Future<String> answer(
    String id,
    String requestId, {
    List<String> selected = const [],
    String text = '',
    String? decision,
  }) => _serial(() async {
    final p = profile(id)!;
    final request = collection(
      p,
      'requests',
    ).where((r) => r['request_id'] == requestId).first;
    if (!relayCapabilities(p['capabilities']).contains(
      request['kind'] == 'approval' ? 'approval.respond' : 'question.answer',
    )) {
      throw const RelayFailure('FORBIDDEN');
    }
    if (!requestCanSend(p, request)) {
      throw const RelayFailure('REQUEST_RESOLVED');
    }
    final payload = object(request['payload']);
    final approval = request['kind'] == 'approval';
    Json answer;
    if (approval) {
      if (!(payload['allowed_decisions'] as List? ?? []).contains(decision) ||
          !{'approve', 'reject'}.contains(decision)) {
        throw const FormatException('请选择允许的审批决定');
      }
      answer = {'decision': decision};
    } else {
      final input = object(payload['input']);
      final kind = input['kind'];
      final options = objects(input['options'] ?? [])
          .map((o) => o['id'])
          .toSet();
      if (selected.toSet().length != selected.length ||
          selected.any((v) => !options.contains(v)) ||
          (kind == 'text' && selected.isNotEmpty) ||
          (kind == 'single_choice' && selected.length > 1) ||
          (kind != 'text' &&
              input['allow_text'] != true &&
              text.trim().isNotEmpty) ||
          (selected.isEmpty && text.trim().isEmpty) ||
          text.length > 20000 ||
          !{'text', 'single_choice', 'multi_choice'}.contains(kind)) {
        throw const FormatException('请按问题要求填写回答');
      }
      answer = {'selected_option_ids': selected, 'text': text.trim()};
    }
    return _queueAction(
      p,
      approval ? 'approval.respond' : 'question.answer',
      request['session_id'] as String?,
      requestId,
      request['expires_at'] as String?,
      answer,
    );
  });
  Future<String> startTask(
    String id, {
    required String prompt,
    String? sessionId,
    String? workspaceId,
  }) => _serial(() async {
    final p = profile(id)!;
    if (prompt.trim().isEmpty || prompt.length > 20000) {
      throw const FormatException('请填写有效任务内容');
    }
    if (sessionId == null) {
      if (!collection(p, 'workspaces').any(
        (w) => w['workspace_id'] == workspaceId && w['pc_id'] == p['pc_id'],
      )) {
        throw const FormatException('请选择 PC 授权的工作区');
      }
    } else {
      final session = collection(p, 'sessions')
          .where(
            (s) => s['session_id'] == sessionId && s['pc_id'] == p['pc_id'],
          )
          .firstOrNull;
      if (session == null ||
          (workspaceId != null && session['workspace_id'] != workspaceId)) {
        throw const FormatException('会话与工作区不匹配');
      }
    }
    return _queueAction(
      p,
      'task.start',
      sessionId,
      null,
      relayTimestamp(now().add(const Duration(minutes: 5))),
      {'prompt': prompt.trim(), 'workspace_id': ?workspaceId},
    );
  });
  Future<String> cancelTask(String id, String taskId) => _serial(() async {
    final p = profile(id)!;
    final task = collection(
      p,
      'tasks',
    ).where((t) => t['task_id'] == taskId).first;
    final related = collection(
      p,
      'actions',
    ).where((a) => a['task_id'] == taskId).lastOrNull;
    final session = task['session_id'] ?? related?['session_id'];
    if (session is! String || !{'queued', 'running'}.contains(task['status'])) {
      throw const FormatException('任务会话未知或任务不能取消，请刷新');
    }
    return _queueAction(
      p,
      'task.cancel',
      session,
      null,
      relayTimestamp(now().add(const Duration(minutes: 5))),
      {'task_id': taskId},
    );
  });
  Future<String> _queueAction(
    Json p,
    String type,
    String? session,
    String? request,
    String? expires,
    Json payload,
  ) async {
    _origin(p);
    if (p['state'] != 'confirmed' ||
        !ready.contains(p['device_id']) ||
        !relayCapabilities(p['capabilities']).contains(type)) {
      throw const RelayFailure('FORBIDDEN');
    }
    if (type == 'task.cancel') {
      final previous = collection(p, 'outbox')
          .where(
            (a) =>
                object(a['body'])['type'] == type &&
                object(object(a['body'])['payload'])['task_id'] ==
                    payload['task_id'] &&
                !{
                  'rejected',
                  'expired',
                  'conflict',
                }.contains(a['local_status']),
          )
          .lastOrNull;
      if (previous != null) return previous['action_id'] as String;
    }
    final id = newUuid();
    final body = {
      'action_id': id,
      'type': type,
      'target_pc_id': p['pc_id'],
      'session_id': session,
      'request_id': request,
      'expires_at': expires,
      'payload': payload,
    };
    final next = _copy(p);
    final cache = object(next['cache']);
    cache['outbox'] = [
      ...objects(cache['outbox']),
      {'action_id': id, 'body': body, 'local_status': 'sending'},
    ];
    next['cache'] = cache;
    await _replace(next); // stable ID/body durably saved before sending
    await _sendAction(p['device_id'] as String, id);
    return id;
  }

  Future<void> retryAction(String id, String actionId) => _serial(() async {
    final p = profile(id);
    if (p != null) _origin(p);
    final action = p == null
        ? null
        : collection(
            p,
            'outbox',
          ).where((a) => a['action_id'] == actionId).firstOrNull;
    final body = action == null ? null : object(action['body']);
    final expiresAt = DateTime.tryParse(body?['expires_at']?.toString() ?? '');
    // An old action may have been accepted before its response was lost. Once
    // its deadline has passed, first reconcile the durable server record by
    // GET; POST would be rejected by a strict relay before idempotency lookup.
    if (expiresAt != null && !expiresAt.isAfter(now().toUtc())) {
      try {
        if (await _refreshAction(id, actionId)) return;
      } on Object {
        // Fall through to the regular idempotent POST when the relay has no
        // readable record (or the GET itself is temporarily unavailable).
      }
    }
    await _sendAction(id, actionId);
  });

  Future<bool> _refreshAction(String id, String actionId) async {
    final p = profile(id)!;
    final result = await transport.request(
      _origin(p),
      'GET',
      '/v1/actions/$actionId',
      token: _token(p),
    );
    final raw = result['action'] is Map ? result['action'] : result;
    final summary = mobileActionSummary(raw);
    final returnedId = summary['action_id'];
    final status = summary['status'];
    if (returnedId != actionId ||
        status is! String ||
        !actionStatuses.contains(status)) {
      throw const RelayFailure('PROTOCOL_ERROR');
    }
    final next = _copy(profile(id)!);
    final cache = object(next['cache']);
    _upsert(cache, 'actions', 'action_id', summary);
    final outbox = objects(cache['outbox']);
    final local = outbox.firstWhere((a) => a['action_id'] == actionId);
    local['result'] = summary;
    local['local_status'] = status;
    cache['outbox'] = outbox;
    next['cache'] = cache;
    await _replace(next);
    errors.remove(id);
    return true;
  }

  Future<void> _sendAction(String id, String actionId) async {
    final p = profile(id)!;
    final action = collection(
      p,
      'outbox',
    ).firstWhere((a) => a['action_id'] == actionId);
    if (!{'sending', 'retry'}.contains(action['local_status'])) return;
    String status;
    try {
      if (p['state'] != 'confirmed' ||
          !relayCapabilities(p['capabilities'])
              .contains(object(action['body'])['type'])) {
        throw const RelayFailure('FORBIDDEN');
      }
      final result = await transport.request(
        _origin(p),
        'POST',
        '/v1/actions',
        token: _token(p),
        body: object(action['body']),
      );
      // A transport timeout can happen after the relay has durably accepted
      // an action. A retry with the same action_id is idempotent and may
      // therefore return the current action status (for example `accepted`
      // or `unknown`) instead of another `queued` response. Treat every
      // protocol-defined status as authoritative and keep it in the cache.
      final summary = result['action'] is Map
          ? mobileActionSummary(result['action'])
          : mobileActionSummary(result);
      final returnedId = summary['action_id'];
      final returnedStatus = summary['status'];
      if (returnedId != actionId ||
          returnedStatus is! String ||
          !actionStatuses.contains(returnedStatus)) {
        throw const RelayFailure('PROTOCOL_ERROR');
      }
      status = returnedStatus;

      final next = _copy(profile(id)!);
      final cache = object(next['cache']);
      _upsert(cache, 'actions', 'action_id', summary);
      final outbox = objects(cache['outbox']);
      final local = outbox.firstWhere((a) => a['action_id'] == actionId);
      local['result'] = summary;
      local['local_status'] = status;
      cache['outbox'] = outbox;
      next['cache'] = cache;
      await _replace(next);
      errors.remove(id);
      return;
    } on RelayFailure catch (e) {
      if (e.code == 'DEVICE_REVOKED' || e.code == 'UNAUTHORIZED') {
        await _terminal(id, 'revoked');
        return;
      }
      status = switch (e.code) {
        'REQUEST_EXPIRED' => 'expired',
        'REQUEST_RESOLVED' || 'IDEMPOTENCY_CONFLICT' => 'conflict',
        'FORBIDDEN' => 'rejected',
        _ => 'retry',
      };
      errors[id] = e.toString();
    }
    final next = _copy(profile(id)!);
    final cache = object(next['cache']);
    final outbox = objects(cache['outbox']);
    outbox.firstWhere((a) => a['action_id'] == actionId)['local_status'] =
        status;
    cache['outbox'] = outbox;
    next['cache'] = cache;
    await _replace(next);
  }

  Future<void> _reconcileActions(String id) async {
    for (final local in collection(profile(id)!, 'outbox')) {
      final aid = local['action_id'] as String;
      final authoritative = collection(
        profile(id)!,
        'actions',
      ).where((a) => a['action_id'] == aid).firstOrNull;
      if (authoritative != null &&
          actionTerminal.contains(authoritative['status'])) {
        final next = _copy(profile(id)!);
        final cache = object(next['cache']);
        final outbox = objects(cache['outbox']);
        outbox.firstWhere((a) => a['action_id'] == aid)['local_status'] =
            authoritative['status'];
        cache['outbox'] = outbox;
        next['cache'] = cache;
        await _replace(next);
        continue;
      }
      if ({'sending', 'retry'}.contains(local['local_status'])) {
        final body = object(local['body']);
        final expiresAt = DateTime.tryParse(
          body['expires_at']?.toString() ?? '',
        );
        if (local['local_status'] == 'retry' &&
            expiresAt != null &&
            !expiresAt.isAfter(now().toUtc())) {
          // Do not hammer a strict relay with an expired body every sync tick.
          // A user initiated retry attempts GET reconciliation first.
        } else {
          await _sendAction(id, aid);
        }
      } else if ({'queued', 'delivered'}.contains(local['local_status'])) {
        final p = profile(id)!;
        final result = await transport.request(
          _origin(p),
          'GET',
          '/v1/actions/$aid',
          token: _token(p),
        );
        final remote = mobileActionSummary(result['action']);
        if (remote['action_id'] != aid) throw const FormatException('动作不匹配');
        final next = _copy(p);
        final cache = object(next['cache']);
        _upsert(cache, 'actions', 'action_id', remote);
        final outbox = objects(cache['outbox']);
        outbox.firstWhere((a) => a['action_id'] == aid)['local_status'] =
            remote['status'];
        cache['outbox'] = outbox;
        next['cache'] = cache;
        await _replace(next);
      }
      if (profile(id)?['device_token'] == null) return;
    }
  }

  Future<void> enablePush() async {
    if (!_serverConfigReady) {
      pushStatus = '联动服务器配置未能安全载入，已停用联网。';
      _notify();
      return;
    }
    try {
      await _serial(() async {
        pushEnabled = true;
        await _commit(_profiles);
      });
      pushToken = await push.initialize();
      if (_pushListeners.isEmpty) {
        _pushListeners.add(
          push.tokenChanges.listen((token) {
            pushToken = token;
            for (final p in profiles) {
              _scheduleSync(p['device_id'] as String);
            }
          }),
        );
        _pushListeners.add(
          push.hints.listen((hint) {
            unawaited(handlePush(hint));
          }),
        );
      }
      pushStatus = pushToken == null
          ? '渠道未配置或通知权限未授权'
          : '已取得推送凭证，等待注册；到达能力需真机验证';
      final initial = await push.initialHint();
      if (initial != null) await handlePush(initial);
      for (final p in profiles) {
        if (p['state'] == 'confirmed') await sync(p['device_id'] as String);
      }
    } on Object {
      pushStatus = '推送初始化失败或未配置；前台补拉仍可用';
    }
    _notify();
  }

  Future<void> _registerPush(String id) async {
    final p = profile(id)!;
    _origin(p);
    if (!pushEnabled ||
        pushToken == null ||
        p['state'] != 'confirmed' ||
        p['push_registration_token'] == pushToken) {
      return;
    }
    await _unregisterPush(p);
    final cleared = _copy(p)
      ..remove('push_subscription_id')
      ..remove('push_registration_token');
    await _replace(cleared);
    final result = await transport.request(
      _origin(p),
      'POST',
      '/v1/push/subscriptions',
      token: _token(p),
      body: {'provider': push.name, 'registration_token': pushToken},
    );
    // v1 omits the subscription response schema; require subscription_id rather
    // than inventing a deletion path. Deployment must confirm this field.
    if (result['subscription_id'] is! String) {
      pushStatus = '服务器未返回 subscription_id，推送注册待协议确认';
      return;
    }
    final next = _copy(profile(id)!)
      ..['push_subscription_id'] = result['subscription_id']
      ..['push_registration_token'] = pushToken;
    await _replace(next);
    pushStatus = '已注册 ${push.name}；后台到达尚需真机验证';
  }

  Future<void> _unregisterPush(Json p) async {
    if (p['push_subscription_id'] is String) {
      await transport.request(
        _origin(p),
        'DELETE',
        '/v1/push/subscriptions/${Uri.encodeComponent(p['push_subscription_id'] as String)}',
        token: _token(p),
      );
    }
  }

  Future<void> disablePush() => _serial(() async {
    for (final p in profiles) {
      if (p['device_token'] == null || !_profileCanConnect(p)) continue;
      await _unregisterPush(p);
      final next = _copy(p)
        ..remove('push_subscription_id')
        ..remove('push_registration_token');
      await _replace(next);
    }
    pushEnabled = false;
    await _commit(_profiles);
    await push.deleteToken();
    pushToken = null;
    pushStatus = '已解绑推送';
    _notify();
  });
  Future<void> handlePush(PushHint hint) async {
    if (!uuidPattern.hasMatch(hint.eventId) ||
        !uuidPattern.hasMatch(hint.pcId)) {
      return;
    }
    for (final candidate in profiles.where(
      (p) =>
          p['pc_id'] == hint.pcId &&
          p['state'] == 'confirmed' &&
          _profileCanConnect(p),
    )) {
      final id = candidate['device_id'] as String;
      await _serial(() async {
        final p = profile(id);
        if (p == null || p['device_token'] == null) return;
        try {
          final response = await transport.request(
            _origin(p),
            'GET',
            '/v1/events/${hint.eventId}',
            token: _token(p),
          );
          final event = validateEvent(response['event']);
          if (event['event_id'] != hint.eventId ||
              event['pc_id'] != p['pc_id']) {
            return;
          }
          if (hint.opened) {
            focusProfile = id;
            focusRequest = event['request_id'] as String?;
          }
        } on RelayFailure catch (e) {
          if (e.code == 'DEVICE_REVOKED' || e.code == 'UNAUTHORIZED') {
            await _terminal(id, 'revoked');
          }
        } on Object {
          /* No untrusted notification body or raw error in logs. */
        }
      });
      if (foreground) await sync(id, snapshot: true);
    }
    _notify();
  }

  void clearFocus() {
    focusProfile = null;
    focusRequest = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    foreground = false;
    for (final id in _sockets.keys.toList()) {
      _disconnect(id);
    }
    for (final subscription in _pushListeners) {
      unawaited(subscription.cancel());
    }
    push.dispose();
    transport.dispose();
    super.dispose();
  }
}
