import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/android_companion_runtime.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_audio.dart';

class _FakeRuntime extends AndroidCompanionRuntime {
  _FakeRuntime() : super(enabled: false);

  final activeChanges = <bool>[];
  bool interrupted = false;
  bool systemCall = false;

  @override
  bool get muted => interrupted;

  @override
  bool get callActive => systemCall;

  @override
  Future<void> setPlayerActive(Object player, bool active) async {
    activeChanges.add(active);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/realtime_pcm');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('releases audio focus when native start fails', () async {
    final runtime = _FakeRuntime();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        throw PlatformException(code: 'pcm_start', message: 'failed');
      }
      return null;
    });
    final output = AndroidCallPcmOutput(
      runtime: runtime,
      channel: channel,
      isAndroid: () => true,
    );

    await expectLater(output.start(), throwsA(isA<PlatformException>()));

    expect(runtime.activeChanges, [true, false]);
  });

  test(
    'does not call native start while system audio is interrupted',
    () async {
      final runtime = _FakeRuntime()
        ..interrupted = true
        ..systemCall = true;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return null;
      });
      final output = AndroidCallPcmOutput(
        runtime: runtime,
        channel: channel,
        isAndroid: () => true,
      );

      await expectLater(output.start(), throwsA(isA<FormatException>()));

      expect(methods, isEmpty);
      expect(runtime.activeChanges, [true, false]);
    },
  );

  test('focus loss does not reject the in-app call', () async {
    final runtime = _FakeRuntime()..interrupted = true;
    var nativeStart = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') nativeStart++;
      return null;
    });
    final output = AndroidCallPcmOutput(
      runtime: runtime,
      channel: channel,
      isAndroid: () => true,
    );

    await output.start();
    expect(nativeStart, 1);
    await output.stop();
  });

  test('a real native call still blocks in-app playback', () async {
    final runtime = _FakeRuntime()..systemCall = true;
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return null;
    });
    final output = AndroidCallPcmOutput(
      runtime: runtime,
      channel: channel,
      isAndroid: () => true,
    );

    await expectLater(output.start(), throwsA(isA<FormatException>()));
    expect(methods, isEmpty);
  });

  test('releases audio focus even when native stop fails', () async {
    final runtime = _FakeRuntime();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'stop') {
        throw PlatformException(code: 'pcm_stop', message: 'failed');
      }
      return null;
    });
    final output = AndroidCallPcmOutput(
      runtime: runtime,
      channel: channel,
      isAndroid: () => true,
    );
    await output.start();

    await expectLater(output.stop(), throwsA(isA<PlatformException>()));

    expect(runtime.activeChanges, [true, false]);
  });

  test('late native start completion cannot retain audio focus', () async {
    final runtime = _FakeRuntime();
    final started = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') await started.future;
      return null;
    });
    final output = AndroidCallPcmOutput(
      runtime: runtime,
      channel: channel,
      isAndroid: () => true,
    );

    final starting = output.start();
    await Future<void>.delayed(Duration.zero);
    await output.stop();
    started.complete();
    await starting;

    expect(runtime.activeChanges.first, isTrue);
    expect(runtime.activeChanges.last, isFalse);
  });
}
