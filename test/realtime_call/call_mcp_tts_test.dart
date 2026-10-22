import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_protocol.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_mcp_tts.dart';

Uint8List _wave({
  int rate = 24000,
  int channels = 1,
  int bits = 16,
  bool floating = false,
  double seconds = 0.1,
  double Function(int frame, int channel)? value,
}) {
  final frames = (rate * seconds).round();
  final bytesPerSample = bits ~/ 8;
  final bytes = Uint8List(44 + frames * channels * bytesPerSample);
  final data = ByteData.sublistView(bytes);
  for (final entry in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    bytes.setRange(entry.key, entry.key + 4, entry.value.codeUnits);
  }
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, floating ? 3 : 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * channels * bytesPerSample, Endian.little);
  data.setUint16(32, channels * bytesPerSample, Endian.little);
  data.setUint16(34, bits, Endian.little);
  data.setUint32(40, bytes.length - 44, Endian.little);
  for (var frame = 0; frame < frames; frame++) {
    for (var channel = 0; channel < channels; channel++) {
      final sample =
          value?.call(frame, channel) ?? sin(frame * 2 * pi * 300 / rate) * .2;
      final offset = 44 + (frame * channels + channel) * bytesPerSample;
      if (floating) {
        data.setFloat32(offset, sample, Endian.little);
      } else if (bits == 8) {
        data.setUint8(offset, (sample * 128 + 128).round().clamp(0, 255));
      } else if (bits == 16) {
        data.setInt16(
          offset,
          (sample * 32768).round().clamp(-32768, 32767),
          Endian.little,
        );
      } else if (bits == 24) {
        final integer = (sample * 8388608).round().clamp(-8388608, 8388607);
        data.setUint8(offset, integer & 0xff);
        data.setUint8(offset + 1, (integer >> 8) & 0xff);
        data.setUint8(offset + 2, (integer >> 16) & 0xff);
      } else {
        data.setInt32(
          offset,
          (sample * 2147483648).round().clamp(-2147483648, 2147483647),
          Endian.little,
        );
      }
    }
  }
  return bytes;
}

Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

Future<Uint8List> _collect(Stream<Uint8List> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    expect(chunk.length, lessThanOrEqualTo(3840));
    expect(chunk.length.isEven, isTrue);
    builder.add(chunk);
  }
  return builder.takeBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'MCP file request keeps voice, model, language and current callback',
    () async {
      final directory = await Directory.systemTemp.createTemp('call-mcp-');
      final file = File('${directory.path}/clip.wav');
      final wave = _wave();
      await file.writeAsBytes(wave);
      FishMcpCallRequest? request;
      var calls = 0;
      final client = FishMcpCallTtsClient(
        synthesizeFile: (value) async {
          calls++;
          request = value;
          return file.path;
        },
      );
      final speech = client.synthesize(
        text: 'こんにちは。',
        voiceId: 'voice-a',
        model: 'drama-3',
        language: 'ja',
        speed: .8,
      );
      expect(calls, 0);
      expect(await _collect(speech.pcm), orderedEquals(wave.sublist(44)));
      expect(calls, 1);
      expect(request!.text, 'こんにちは。');
      expect(request!.voice, 'voice-a');
      expect(request!.model, 'drama-3');
      expect(request!.language, 'ja');
      expect(request!.speed, .8);
      await _until(() => !file.existsSync());
      await speech.cancel();
      expect(request!.isCurrent(), isFalse);
      await directory.delete(recursive: true);
    },
  );

  test('valid stereo WAV becomes 24 kHz mono without changing duration', () {
    for (final rate in [16000, 22050, 24000, 44100, 48000]) {
      final pcm = mcpCallWavToPcm24k(
        _wave(
          rate: rate,
          channels: 2,
          value: (_, channel) => channel == 0 ? .2 : .6,
        ),
        text: '你好。',
        language: 'zh',
      )!;
      expect(pcm.length, 4800);
      final data = ByteData.sublistView(pcm);
      for (var offset = 0; offset < pcm.length; offset += 2) {
        expect(data.getInt16(offset, Endian.little), closeTo(13107, 2));
      }
    }
  });

  test('WAV integer widths and float PCM preserve normalized amplitude', () {
    for (final bits in [8, 16, 24, 32]) {
      for (final floating in bits == 32 ? [false, true] : [false]) {
        final pcm = mcpCallWavToPcm24k(
          _wave(
            rate: 48000,
            channels: 2,
            bits: bits,
            floating: floating,
            value: (_, _) => -.25,
          ),
          text: 'こんにちは。',
          language: 'ja',
        )!;
        expect(pcm.length, 4800);
        expect(
          ByteData.sublistView(pcm).getInt16(100, Endian.little),
          closeTo(-8192, 2),
        );
      }
    }
  });

  test('compressed returned file uses existing decodeWav once and deletes both files', () async {
    final directory = await Directory.systemTemp.createTemp('call-mcp-');
    final mp3 = File('${directory.path}/clip.mp3');
    await mp3.writeAsBytes(
      Uint8List.fromList([73, 68, 51, ...List.filled(80, 0)]),
    );
    final decoded = File('${mp3.path}.decoded.wav');
    var decodes = 0, calls = 0;
    final client = FishMcpCallTtsClient(
      synthesizeFile: (_) async {
        calls++;
        return mp3.path;
      },
      isAndroid: () => true,
      decodeWav: (path) async {
        expect(path, mp3.path);
        decodes++;
        await decoded.writeAsBytes(_wave(rate: 44100, channels: 2));
        return decoded.path;
      },
    );
    final speech = client.synthesize(
      text: 'こんにちは。',
      voiceId: 'v',
      model: 'drama-3',
      language: 'ja',
    );
    expect((await _collect(speech.pcm)).length, 4800);
    expect(calls, 1);
    expect(decodes, 1);
    expect(await mp3.exists(), isFalse);
    expect(await decoded.exists(), isFalse);
    await directory.delete(recursive: true);
  });

  test('cancel before listening performs no MCP generation', () async {
    var calls = 0;
    final speech = FishMcpCallTtsClient(
      synthesizeFile: (_) async {
        calls++;
        throw StateError('Must not synthesize');
      },
    ).synthesize(text: '你好。', voiceId: 'v', model: 'drama-3', language: 'zh');
    await speech.cancel();
    expect(await speech.pcm.toList(), isEmpty);
    expect(calls, 0);
  });

  test('cancel closes immediately while MCP generation is held and removes late audio', () async {
    final directory = await Directory.systemTemp.createTemp('call-mcp-');
    final file = File('${directory.path}/late.wav');
    final pending = Completer<String>();
    FishMcpCallRequest? request;
    final speech = FishMcpCallTtsClient(
      synthesizeFile: (value) {
        request = value;
        return pending.future;
      },
    ).synthesize(text: '你好。', voiceId: 'v', model: 'drama-3', language: 'zh');
    final done = speech.pcm.toList();
    await _until(() => request != null);
    await speech.cancel().timeout(const Duration(milliseconds: 100));
    expect(await done.timeout(const Duration(milliseconds: 100)), isEmpty);
    expect(request!.isCurrent(), isFalse);
    await file.writeAsBytes(_wave());
    pending.complete(file.path);
    await _until(() => !file.existsSync());
    await directory.delete(recursive: true);
  });

  test(
    'cancel during native decode discards and cleans late decoded audio',
    () async {
      final directory = await Directory.systemTemp.createTemp('call-mcp-');
      final file = File('${directory.path}/clip.mp3');
      final decoded = File('${file.path}.decoded.wav');
      await file.writeAsBytes(Uint8List(80));
      final pending = Completer<String?>();
      var decoding = false;
      final speech = FishMcpCallTtsClient(
        synthesizeFile: (_) async => file.path,
        isAndroid: () => true,
        decodeWav: (_) {
          decoding = true;
          return pending.future;
        },
      ).synthesize(text: '你好。', voiceId: 'v', model: 'drama-3', language: 'zh');
      final done = speech.pcm.toList();
      await _until(() => decoding);
      await speech.cancel();
      expect(await done.timeout(const Duration(milliseconds: 100)), isEmpty);
      await decoded.writeAsBytes(_wave());
      pending.complete(decoded.path);
      await _until(() => !file.existsSync() && !decoded.existsSync());
      await directory.delete(recursive: true);
    },
  );

  test(
    'MCP submitted unknown errors preserve identity and never retry',
    () async {
      final original = FishMcpException(
        stage: 'studio_result',
        code: 'studio_not_completed',
        message: '未知',
        generationSubmitted: true,
        outcomeUnknown: true,
      );
      var calls = 0;
      final speech = FishMcpCallTtsClient(
        synthesizeFile: (_) async {
          calls++;
          throw original;
        },
      ).synthesize(text: '你好。', voiceId: 'v', model: 'drama-3', language: 'zh');
      await expectLater(speech.pcm.toList(), throwsA(same(original)));
      expect(calls, 1);
    },
  );

  test(
    'consumer cancellation invalidates a held MCP request without waiting',
    () async {
      final pending = Completer<String>();
      FishMcpCallRequest? request;
      final speech = FishMcpCallTtsClient(
        synthesizeFile: (value) {
          request = value;
          return pending.future;
        },
      ).synthesize(text: '你好。', voiceId: 'v', model: '', language: 'zh');
      final subscription = speech.pcm.listen(
        (_) => fail('Cancelled clip played'),
      );
      await _until(() => request != null);
      await subscription.cancel().timeout(const Duration(milliseconds: 100));
      expect(request!.isCurrent(), isFalse);
      pending.completeError(
        FishMcpException(
          stage: 'studio_result',
          code: 'unknown',
          message: 'unknown',
          generationSubmitted: true,
          outcomeUnknown: true,
        ),
      );
      // The late failure is observed internally, not an unhandled async error.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    },
  );

  test(
    'consumer pauses bound PCM delivery and cancellation cleans buffered clip',
    () async {
      final directory = await Directory.systemTemp.createTemp('call-mcp-');
      final file = File('${directory.path}/clip.wav');
      await file.writeAsBytes(_wave(seconds: 1));
      final speech =
          FishMcpCallTtsClient(synthesizeFile: (_) async => file.path)
              .synthesize(
                text: 'こんにちは。',
                voiceId: 'v',
                model: 'drama-3',
                language: 'ja',
              );
      final iterator = StreamIterator(speech.pcm);
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current.length, 3840);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // No full clip can drain ahead while the AudioTrack consumer is paused.
      expect(await file.exists(), isTrue);
      await iterator.cancel().timeout(const Duration(milliseconds: 100));
      await _until(() => !file.existsSync());
      await directory.delete(recursive: true);
    },
  );

  test('malformed or silent completed audio is rejected without retry or leaked decoder paths', () async {
    for (final silent in [false, true]) {
      final directory = await Directory.systemTemp.createTemp(
        'call-mcp-private-',
      );
      final file = File('${directory.path}/clip.wav');
      await file.writeAsBytes(
        silent ? _wave(value: (_, _) => 0) : Uint8List(80),
      );
      var calls = 0;
      final speech = FishMcpCallTtsClient(
        synthesizeFile: (_) async {
          calls++;
          return file.path;
        },
        isAndroid: () => false,
      ).synthesize(text: '你好。', voiceId: 'v', model: 'drama-3', language: 'zh');
      await expectLater(
        speech.pcm.toList(),
        throwsA(
          isA<FishMcpException>()
              .having((e) => e.generationSubmitted, 'submitted', isTrue)
              .having((e) => e.outcomeUnknown, 'unknown', isFalse)
              .having(
                (e) => e.toString(),
                'safe error',
                isNot(contains(directory.path)),
              ),
        ),
      );
      expect(calls, 1);
      await _until(() => !file.existsSync());
      await directory.delete(recursive: true);
    }
  });

  test(
    'grossly excessive completed MCP audio is not played or regenerated',
    () {
      expect(
        () => mcpCallWavToPcm24k(
          _wave(rate: 8000, seconds: 30),
          text: 'はい。',
          language: 'ja',
        ),
        throwsA(
          isA<FishMcpException>().having(
            (e) => e.code,
            'code',
            'audio_too_long',
          ),
        ),
      );
    },
  );
}
