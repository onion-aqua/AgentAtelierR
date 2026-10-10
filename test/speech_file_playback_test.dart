import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/runtime_log.dart';
import 'package:ryza_chat_mvp/src/speech_file_playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final events = _NativeEvents();
  setUpAll(() async {
    events.install();
    await AudioPlayer.global.ensureInitialized();
  });
  tearDownAll(events.uninstall);
  late Directory directory;
  late File speech;
  late _Player player;
  final original = _stereoWav();

  setUp(() async {
    events.reset();
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    directory = await Directory.systemTemp.createTemp('speech-file-test-');
    speech = File('${directory.path}/clip.wav');
    await speech.writeAsBytes(original);
    player = _Player();
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await directory.delete(recursive: true);
  });

  test(
    'readable speech uses the local file with the requested volume',
    () async {
      expect(await playSpeechFile(player, speech.path, volume: .6), isTrue);
      expect(player.volumes, [.6]);
      expect(player.sources.single, isA<DeviceFileSource>());
      expect((player.sources.single as DeviceFileSource).path, speech.path);
      expect(player.releaseCount, 0);
      expect(player.resumeCount, 1);
    },
  );

  test(
    'Android source error retries once with identical stereo bytes',
    () async {
      player.sourceErrors.add(_androidError);
      expect(await playSpeechFile(player, speech.path, volume: .4), isTrue);
      expect(player.sources, [isA<DeviceFileSource>(), isA<BytesSource>()]);
      expect((player.sources.last as BytesSource).bytes, original);
      expect(player.releaseCount, 1);
      expect(player.resumeCount, 1);
      expect(player.volumes, [.4]);
      expect(await speech.readAsBytes(), original);
    },
  );

  test(
    'fallback diagnostic omits private path and native error payload',
    () async {
      player.sourceErrors.add(
        PlatformException(
          code: 'AndroidAudioError',
          message: 'Secret source at ${speech.path}',
          details: 'private audio content and service token',
        ),
      );
      expect(await playSpeechFile(player, speech.path), isTrue);
      final message = RuntimeLog.instance.entries.last.message;
      expect(message, contains('file=clip.wav'));
      expect(message, contains('bytes=${original.length}'));
      expect(message, contains('code=AndroidAudioError'));
      expect(message, isNot(contains(directory.path)));
      expect(message, isNot(contains('Secret')));
      expect(message, isNot(contains('service token')));
    },
  );

  test('failed byte fallback propagates without looping or playing', () async {
    final second = PlatformException(code: 'AndroidAudioError');
    player.sourceErrors.addAll([_androidError, second]);
    await expectLater(
      playSpeechFile(player, speech.path),
      throwsA(same(second)),
    );
    expect(player.sources, hasLength(2));
    expect(player.releaseCount, 1);
    expect(player.resumeCount, 0);
  });

  test('non-Android source errors propagate without a byte fallback', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    player.sourceErrors.add(_androidError);
    await expectLater(
      playSpeechFile(player, speech.path),
      throwsA(same(_androidError)),
    );
    expect(player.sources, hasLength(1));
    expect(player.releaseCount, 0);
    expect(player.resumeCount, 0);
  });

  test(
    'unrelated platform errors do not activate the Android fallback',
    () async {
      final error = PlatformException(code: 'Unexpected AndroidAudioError');
      player.sourceErrors.add(error);
      await expectLater(
        playSpeechFile(player, speech.path),
        throwsA(same(error)),
      );
      expect(player.sources, hasLength(1));
      expect(player.releaseCount, 0);
      expect(player.resumeCount, 0);
    },
  );

  test('missing and empty caches fail before mutating the player', () async {
    await speech.delete();
    await expectLater(
      playSpeechFile(player, speech.path, volume: .5),
      throwsA(isA<FileSystemException>()),
    );
    await speech.writeAsBytes([]);
    await expectLater(
      playSpeechFile(player, speech.path, volume: .5),
      throwsA(isA<FileSystemException>()),
    );
    expect(player.sources, isEmpty);
    expect(player.volumes, isEmpty);
    expect(player.releaseCount, 0);
    expect(player.resumeCount, 0);
  });

  test(
    'oversized caches fail before loading them or mutating the player',
    () async {
      final handle = await speech.open(mode: FileMode.write);
      await handle.truncate(64 * 1024 * 1024 + 1);
      await handle.close();
      await expectLater(
        playSpeechFile(player, speech.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(player.sources, isEmpty);
      expect(player.resumeCount, 0);
    },
  );

  test('already cancelled speech does not touch the player', () async {
    expect(
      await playSpeechFile(player, speech.path, isCurrent: () => false),
      isFalse,
    );
    expect(player.sources, isEmpty);
    expect(player.resumeCount, 0);
  });

  test(
    'cancellation while setting volume never prepares or restarts speech',
    () async {
      var active = true;
      final pending = Completer<void>();
      player.onVolume = (_) => pending.future;
      final playing = playSpeechFile(
        player,
        speech.path,
        volume: .5,
        isCurrent: () => active,
      );
      await _until(() => player.volumes.isNotEmpty);
      active = false;
      pending.complete();
      expect(await playing, isFalse);
      expect(player.sources, isEmpty);
      expect(player.resumeCount, 0);
    },
  );

  for (final fallback in [false, true]) {
    test(
      'stop during ${fallback ? 'byte fallback' : 'file'} preparation never resumes',
      () async {
        var active = true;
        final pending = Completer<void>();
        if (fallback) player.sourceErrors.add(_androidError);
        player.onSource = (_) => pending.future;
        final playing = playSpeechFile(
          player,
          speech.path,
          isCurrent: () => active,
        );
        await _until(() => player.sources.length == (fallback ? 2 : 1));
        active = false;
        pending.complete();
        expect(await playing, isFalse);
        expect(player.resumeCount, 0);
        expect(player.releaseCount, fallback ? 1 : 0);
      },
    );
  }

  test('cancelled source failure does not release or retry', () async {
    var active = true;
    player.onSource = (_) async {
      active = false;
      throw _androidError;
    };
    expect(
      await playSpeechFile(player, speech.path, isCurrent: () => active),
      isFalse,
    );
    expect(player.sources, hasLength(1));
    expect(player.releaseCount, 0);
    expect(player.resumeCount, 0);
  });

  test(
    'stop during player release cancels the fallback before source and resume',
    () async {
      var active = true;
      player.sourceErrors.add(_androidError);
      player.onRelease = () async => active = false;
      expect(
        await playSpeechFile(player, speech.path, isCurrent: () => active),
        isFalse,
      );
      expect(player.sources, hasLength(1));
      expect(player.resumeCount, 0);
    },
  );

  test(
    'resume errors propagate and do not retry an already prepared source',
    () async {
      player.onResume = () async => throw _androidError;
      await expectLater(
        playSpeechFile(player, speech.path),
        throwsA(same(_androidError)),
      );
      expect(player.sources, hasLength(1));
      expect(player.releaseCount, 0);
      expect(player.resumeCount, 1);
    },
  );

  test(
    'native source error also reaches a completion listener without onError',
    () async {
      final oldLogLevel = AudioLogger.logLevel;
      AudioLogger.logLevel = AudioLogLevel.none;
      final escapedErrors = <Object>[];
      final finished = Completer<void>();
      runZonedGuarded(() async {
        final realPlayer = AudioPlayer();
        realPlayer.positionUpdater = null;
        final complete = realPlayer.onPlayerComplete.listen((_) {});
        try {
          expect(await playSpeechFile(realPlayer, speech.path), isTrue);
          expect(events.resumes, 1);
        } finally {
          await complete.cancel();
          await realPlayer.dispose();
          finished.complete();
        }
      }, (error, stack) => escapedErrors.add(error));
      try {
        await finished.future.timeout(const Duration(seconds: 5));
        expect(escapedErrors, hasLength(1));
        expect(escapedErrors.single, isA<PlatformException>());
        expect(
          (escapedErrors.single as PlatformException).code,
          'AndroidAudioError',
        );
      } finally {
        AudioLogger.logLevel = oldLogLevel;
      }
    },
  );

  test('completion error handler lets byte recovery complete, and receives later playback failure', () async {
    final oldLogLevel = AudioLogger.logLevel;
    AudioLogger.logLevel = AudioLogLevel.none;
    final realPlayer = AudioPlayer();
    realPlayer.positionUpdater = null;
    var preparing = true;
    var preparationErrors = 0;
    final completed = Completer<void>();
    final playbackErrors = <Object>[];
    final subscription = realPlayer.onPlayerComplete.listen(
      (_) => completed.complete(),
      onError: (Object error, StackTrace stack) {
        if (preparing) {
          preparationErrors++;
        } else {
          playbackErrors.add(error);
        }
      },
    );
    try {
      expect(await playSpeechFile(realPlayer, speech.path), isTrue);
      preparing = false;
      expect(preparationErrors, 1);
      expect(events.byteSource, original);
      expect(events.resumes, 1);
      await events.complete(realPlayer.playerId);
      await completed.future.timeout(const Duration(seconds: 5));
      await events.error(realPlayer.playerId);
      await _until(() => playbackErrors.isNotEmpty);
      expect(playbackErrors.single, isA<PlatformException>());
    } finally {
      await subscription.cancel();
      await realPlayer.dispose();
      AudioLogger.logLevel = oldLogLevel;
    }
  });
}

final _androidError = PlatformException(
  code: 'AndroidAudioError',
  message: 'Failed to set source',
  details: 'MEDIA_ERROR_UNKNOWN {what:13}, MEDIA_ERROR_SYSTEM',
);

/// Avoid native initialization while exercising the real file guard, bounded
/// recovery and cancellation logic. Delayed operations represent platform awaits.
class _Player implements AudioPlayer {
  final volumes = <double>[];
  final sources = <Source>[];
  final sourceErrors = <Object>[];
  int releaseCount = 0;
  int resumeCount = 0;
  Future<void> Function(double)? onVolume;
  Future<void> Function(Source)? onSource;
  Future<void> Function()? onRelease;
  Future<void> Function()? onResume;

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    await onVolume?.call(volume);
  }

  @override
  Future<void> setSource(Source source) async {
    sources.add(source);
    if (sourceErrors.isNotEmpty) throw sourceErrors.removeAt(0);
    await onSource?.call(source);
  }

  @override
  Future<void> release() async {
    releaseCount++;
    await onRelease?.call();
  }

  @override
  Future<void> resume() async {
    resumeCount++;
    await onResume?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _until(bool Function() ready) async {
  for (var count = 0; count < 1000 && !ready(); count++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(ready(), isTrue, reason: 'The fake platform operation did not begin');
}

Uint8List _stereoWav() {
  final bytes = Uint8List(60);
  final data = ByteData.sublistView(bytes);
  for (final item in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    bytes.setRange(item.key, item.key + 4, item.value.codeUnits);
  }
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, 24000, Endian.little);
  data.setUint32(28, 96000, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, 16, Endian.little);
  for (var frame = 0; frame < 4; frame++) {
    data.setInt16(44 + frame * 4, 1000 + frame * 500, Endian.little);
    data.setInt16(46 + frame * 4, -800 - frame * 250, Endian.little);
  }
  return bytes;
}

/// Real AudioPlayer/EventChannel fan-out; only the native media backend is
/// replaced. Source errors must arrive as native event errors, not only as a
/// rejected method call, to cover all subscriptions seeing that same error.
class _NativeEvents {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <String>{
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers.global/events',
    'xyz.luan/audioplayers',
  };
  Uint8List? byteSource;
  int resumes = 0;

  void reset() {
    byteSource = null;
    resumes = 0;
  }

  void install() {
    for (final name in channels) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        final args = call.arguments as Map;
        final playerId = args['playerId'] as String;
        switch (call.method) {
          case 'create':
            final channel = 'xyz.luan/audioplayers/events/$playerId';
            channels.add(channel);
            messenger.setMockMethodCallHandler(
              MethodChannel(channel),
              (_) async => null,
            );
          case 'setSourceUrl':
            await error(playerId);
          case 'setSourceBytes':
            byteSource = args['bytes'] as Uint8List;
            await _event(playerId, {
              'event': 'audio.onPrepared',
              'value': true,
            });
          case 'resume':
            resumes++;
          case 'getCurrentPosition':
            return 0;
        }
        return null;
      },
    );
  }

  Future<void> complete(String playerId) =>
      _event(playerId, {'event': 'audio.onComplete'});

  Future<void> error(String playerId) => messenger.handlePlatformMessage(
    'xyz.luan/audioplayers/events/$playerId',
    const StandardMethodCodec().encodeErrorEnvelope(
      code: 'AndroidAudioError',
      message: 'Failed to set source',
      details: 'MEDIA_ERROR_UNKNOWN {what:13}, MEDIA_ERROR_SYSTEM',
    ),
    (_) {},
  );

  Future<void> _event(String playerId, Map<String, Object> value) =>
      messenger.handlePlatformMessage(
        'xyz.luan/audioplayers/events/$playerId',
        const StandardMethodCodec().encodeSuccessEnvelope(value),
        (_) {},
      );

  void uninstall() {
    for (final name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  }
}
