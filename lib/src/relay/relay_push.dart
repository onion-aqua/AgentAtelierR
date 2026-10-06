import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'relay_protocol.dart';

class PushHint {
  const PushHint(this.eventId, this.pcId, this.kind, {this.opened = false});
  final String eventId, pcId, kind;
  final bool opened;
  static PushHint? parse(Map data, {bool opened = false}) {
    if (data['event_id'] is! String ||
        data['pc_id'] is! String ||
        data['kind'] is! String) {
      return null;
    }
    return PushHint(
      data['event_id'] as String,
      data['pc_id'] as String,
      data['kind'] as String,
      opened: opened,
    );
  }
}

abstract interface class RelayPushProvider {
  String get name;
  Future<String?> initialize();
  Stream<String> get tokenChanges;
  Stream<PushHint> get hints;
  Future<PushHint?> initialHint();
  Future<void> deleteToken();
  void dispose();
}

class DisabledRelayPush implements RelayPushProvider {
  @override
  String get name => 'unconfigured';
  @override
  Future<String?> initialize() async => null;
  @override
  Stream<String> get tokenChanges => const Stream.empty();
  @override
  Stream<PushHint> get hints => const Stream.empty();
  @override
  Future<PushHint?> initialHint() async => null;
  @override
  Future<void> deleteToken() async {}
  @override
  void dispose() {}
}

RelayPushProvider configuredPushProvider() {
  const provider = String.fromEnvironment('RELAY_PUSH_PROVIDER');
  if (provider == 'fcm') return FcmRelayPush();
  if (const {
    'huawei',
    'xiaomi',
    'oppo',
    'vivo',
    'honor',
    'jpush',
    'getui',
  }.contains(provider)) {
    return NativeRelayPush(provider);
  }
  return DisabledRelayPush();
}

/// Optional real FCM integration. No Firebase project is bundled. The relay
/// server must send a generic notification + data message for OS presentation
/// while the app is stopped; data-only delivery is not guaranteed on Android.
class FcmRelayPush implements RelayPushProvider {
  final _hints = StreamController<PushHint>.broadcast();
  final _tokens = StreamController<String>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  FirebaseMessaging? _messaging;
  @override
  String get name => 'fcm';
  @override
  Stream<String> get tokenChanges => _tokens.stream;
  @override
  Stream<PushHint> get hints => _hints.stream;
  @override
  Future<String?> initialize() async {
    if (!Platform.isAndroid) return null;
    const apiKey = String.fromEnvironment('RELAY_FCM_API_KEY');
    const appId = String.fromEnvironment('RELAY_FCM_APP_ID');
    const sender = String.fromEnvironment('RELAY_FCM_SENDER_ID');
    const project = String.fromEnvironment('RELAY_FCM_PROJECT_ID');
    if ([apiKey, appId, sender, project].any((s) => s.isEmpty)) return null;
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: apiKey,
          appId: appId,
          messagingSenderId: sender,
          projectId: project,
        ),
      );
    }
    _messaging = FirebaseMessaging.instance;
    await const MethodChannel('agent_atelier_r/relay_push')
        .invokeMethod<void>('createPrivateChannel');
    final permission = await _messaging!.requestPermission();
    if (permission.authorizationStatus == AuthorizationStatus.denied) {
      return null;
    }
    await _messaging!.setAutoInitEnabled(true);
    if (_subscriptions.isEmpty) {
      _subscriptions.add(
        _messaging!.onTokenRefresh.listen(_tokens.add, onError: (Object _) {}),
      );
      _subscriptions.add(
        FirebaseMessaging.onMessage.listen((m) {
          final h = PushHint.parse(m.data);
          if (h != null) _hints.add(h);
        }),
      );
      _subscriptions.add(
        FirebaseMessaging.onMessageOpenedApp.listen((m) {
          final h = PushHint.parse(m.data, opened: true);
          if (h != null) _hints.add(h);
        }),
      );
    }
    return _messaging!.getToken();
  }

  @override
  Future<PushHint?> initialHint() async {
    final message = await _messaging?.getInitialMessage();
    return message == null ? null : PushHint.parse(message.data, opened: true);
  }

  @override
  Future<void> deleteToken() async {
    await _messaging?.setAutoInitEnabled(false);
    await _messaging?.deleteToken();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_hints.close());
    unawaited(_tokens.close());
  }
}

/// Adapter boundary for signed vendor SDKs. Until the Android host installs an
/// adapter, initialize explicitly returns unavailable, never a fake push token.
class NativeRelayPush implements RelayPushProvider {
  NativeRelayPush(this.name);
  @override
  final String name;
  static const channel = MethodChannel('agent_atelier_r/relay_push');
  final _tokens = StreamController<String>.broadcast();
  final _hints = StreamController<PushHint>.broadcast();
  @override
  Stream<String> get tokenChanges => _tokens.stream;
  @override
  Stream<PushHint> get hints => _hints.stream;
  @override
  Future<String?> initialize() async {
    if (!Platform.isAndroid) return null;
    await channel.invokeMethod<void>('createPrivateChannel');
    if (!await Permission.notification.request().isGranted) return null;
    channel.setMethodCallHandler((call) async {
      final data = object(call.arguments);
      if (data['provider'] != name) return;
      if (call.method == 'tokenChanged' &&
          data['registration_token'] is String) {
        _tokens.add(data['registration_token'] as String);
      }
      if (call.method == 'pushHint') {
        final hint = PushHint.parse(data, opened: data['opened'] == true);
        if (hint != null) _hints.add(hint);
      }
    });
    final data = await channel.invokeMapMethod<String, dynamic>('register', {
      'provider': name,
    });
    return data?['available'] == true
        ? (data?['registration_token'] as String?)
        : null;
  }

  @override
  Future<PushHint?> initialHint() async {
    final data = await channel.invokeMapMethod<String, dynamic>('initialHint', {
      'provider': name,
    });
    return data == null ? null : PushHint.parse(data, opened: true);
  }

  @override
  Future<void> deleteToken() async {
    await channel.invokeMethod<void>('unregister', {'provider': name});
  }

  @override
  void dispose() {
    channel.setMethodCallHandler(null);
    unawaited(_tokens.close());
    unawaited(_hints.close());
  }
}
