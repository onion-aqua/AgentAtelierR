import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/speech_tempo.dart';

Uint8List _wav() {
  const rate = 16000;
  const frames = rate;
  final bytes = Uint8List(44 + frames * 2);
  final data = ByteData.sublistView(bytes);
  void id(int offset, String value) =>
      bytes.setRange(offset, offset + 4, value.codeUnits);
  id(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  id(8, 'WAVE');
  id(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  id(36, 'data');
  data.setUint32(40, frames * 2, Endian.little);
  for (var i = 0; i < frames; i++) {
    data.setInt16(
      44 + i * 2,
      (math.sin(i * 2 * math.pi * 220 / rate) * 10000).round(),
      Endian.little,
    );
  }
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('agent_atelier_r/speech_envelope');
  late Directory directory;
  final originalPlatform = debugDefaultTargetPlatformOverride;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('speech-tempo-test-');
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = originalPlatform;
    await directory.delete(recursive: true);
  });

  test(
    'WAV is processed off isolate with source retained and no intermediates',
    () async {
      final path = '${directory.path}/speech.wav';
      final source = _wav();
      await File(path).writeAsBytes(source);
      final result = await adjustSpeechFileTempo(path, speed: 0.9);
      expect(result, isNot(path));
      final output = await File(result).readAsBytes();
      expect(String.fromCharCodes(output.sublist(0, 4)), 'RIFF');
      expect(output.length, greaterThan(source.length));
      expect(await File(path).readAsBytes(), source);
      expect(directory.listSync(), hasLength(2));
      expect(directory.listSync().whereType<Directory>(), isEmpty);
    },
  );

  test('unit speed is an exact no-op without creating files', () async {
    final path = '${directory.path}/not-needed.wav';
    expect(await adjustSpeechFileTempo(path, speed: 1), path);
    expect(directory.listSync(), isEmpty);
  });

  test('invalid speed fails before accessing source', () async {
    for (final speed in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      await expectLater(
        adjustSpeechFileTempo('not-needed.wav', speed: speed),
        throwsA(
          isA<SpeechTempoException>().having(
            (error) => error.code,
            'code',
            'invalid_speed',
          ),
        ),
      );
    }
    expect(directory.listSync(), isEmpty);
  });

  test('cancellation before processing leaves only source', () async {
    final path = '${directory.path}/speech.wav';
    await File(path).writeAsBytes(_wav());
    await expectLater(
      adjustSpeechFileTempo(path, speed: 0.9, isCurrent: () => false),
      throwsA(
        isA<SpeechTempoException>().having(
          (error) => error.code,
          'code',
          'tempo_cancelled',
        ),
      ),
    );
    expect(directory.listSync(), hasLength(1));
  });

  test('unsupported desktop encoding fails explicitly instead of returning original speed', () async {
    final path = '${directory.path}/speech.mp3';
    await File(path).writeAsBytes(List.filled(100, 0x49));
    await expectLater(
      adjustSpeechFileTempo(path, speed: 0.9),
      throwsA(
        isA<SpeechTempoException>().having(
          (error) => error.code,
          'code',
          'tempo_decode_unsupported',
        ),
      ),
    );
    expect(directory.listSync(), hasLength(1));
  });

  test(
    'Android compressed audio uses one private decode and cleans decoded copy',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final path = '${directory.path}/speech.mp3';
      await File(path).writeAsBytes(List.filled(100, 0x49));
      var decodes = 0;
      String? decoded;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            decodes++;
            expect(call.method, 'decodeWav');
            final source = (call.arguments as Map)['path'] as String;
            expect(source, isNot(path));
            decoded = '$source.decoded.wav';
            await File(decoded!).writeAsBytes(_wav());
            return decoded;
          });
      final result = await adjustSpeechFileTempo(path, speed: 0.9);
      expect(decodes, 1);
      expect(await File(decoded!).exists(), isFalse);
      expect(await File(result).exists(), isTrue);
      expect(directory.listSync(), hasLength(2));
      expect(directory.listSync().whereType<Directory>(), isEmpty);
    },
  );

  test(
    'cancellation during Android decode removes all intermediate audio',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final path = '${directory.path}/speech.mp3';
      await File(path).writeAsBytes(List.filled(100, 0x49));
      var current = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final source = (call.arguments as Map)['path'] as String;
            await File('$source.decoded.wav').writeAsBytes(_wav());
            current = false;
            return '$source.decoded.wav';
          });
      await expectLater(
        adjustSpeechFileTempo(path, speed: 0.9, isCurrent: () => current),
        throwsA(
          isA<SpeechTempoException>().having(
            (error) => error.code,
            'code',
            'tempo_cancelled',
          ),
        ),
      );
      expect(directory.listSync(), hasLength(1));
    },
  );

  test(
    'decoder failure removes even partially written intermediate audio',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final path = '${directory.path}/speech.mp3';
      await File(path).writeAsBytes(List.filled(100, 0x49));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final source = (call.arguments as Map)['path'] as String;
            await File('$source.decoded.wav').writeAsBytes([1, 2, 3]);
            throw PlatformException(code: 'decode');
          });
      await expectLater(
        adjustSpeechFileTempo(path, speed: 0.9),
        throwsA(isA<PlatformException>()),
      );
      expect(directory.listSync(), hasLength(1));
    },
  );

  test(
    '64 MiB input limit is enforced before decoding or worker allocation',
    () async {
      final path = '${directory.path}/oversized.wav';
      final sparse = await File(path).open(mode: FileMode.write);
      await sparse.truncate(64 * 1024 * 1024 + 1);
      await sparse.close();
      await expectLater(
        adjustSpeechFileTempo(path, speed: 0.9),
        throwsA(
          isA<SpeechTempoException>().having(
            (error) => error.code,
            'code',
            'tempo_audio_size',
          ),
        ),
      );
      expect(directory.listSync(), hasLength(1));
    },
  );
}
