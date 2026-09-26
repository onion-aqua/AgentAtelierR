import 'dart:math';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/speech_loudness.dart';
import 'package:ryza_chat_mvp/src/speech_envelope_loader.dart';

const rate = 16000;

Uint8List wave(
  double Function(int frame, int channel) sample, {
  int frames = rate * 3,
  int channels = 1,
  int bits = 16,
  bool floating = false,
}) {
  final bytes = Uint8List(44 + frames * channels * (bits ~/ 8));
  final data = ByteData.sublistView(bytes);
  for (final entry in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    bytes.setRange(entry.key, entry.key + 4, entry.value.codeUnits);
  }
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, floating ? 3 : 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * channels * (bits ~/ 8), Endian.little);
  data.setUint16(32, channels * (bits ~/ 8), Endian.little);
  data.setUint16(34, bits, Endian.little);
  data.setUint32(40, bytes.length - 44, Endian.little);
  for (var f = 0; f < frames; f++) {
    for (var c = 0; c < channels; c++) {
      final at = 44 + (f * channels + c) * (bits ~/ 8);
      final value = sample(f, c);
      if (floating) {
        data.setFloat32(at, value, Endian.little);
      } else if (bits == 8) {
        data.setUint8(at, (value * 127 + 128).round());
      } else if (bits == 16) {
        data.setInt16(at, (value * 32767).round(), Endian.little);
      } else if (bits == 24) {
        final n = (value * 8388607).round();
        bytes[at] = n & 255;
        bytes[at + 1] = (n >> 8) & 255;
        bytes[at + 2] = (n >> 16) & 255;
      } else {
        data.setInt32(at, (value * 2147483647).round(), Endian.little);
      }
    }
  }
  return bytes;
}

double tone(int frame) => sin(2 * pi * 200 * frame / rate);
double rms(
  Uint8List wav,
  int first,
  int end, {
  int channels = 1,
  int channel = 0,
}) {
  final data = ByteData.sublistView(wav);
  var sum = 0.0;
  for (var f = first; f < end; f++) {
    final x =
        data.getInt16(44 + (f * channels + channel) * 2, Endian.little) / 32768;
    sum += x * x;
  }
  return sqrt(sum / (end - first));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'file processing and lip sync use the balanced audio off the UI isolate',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tts_loudness_test_',
      );
      try {
        final file = File('${directory.path}/speech.wav');
        final original = wave(
          (f, _) => f < rate ? .03 * tone(f) : .5 * tone(f),
        );
        await file.writeAsBytes(original);
        final path = await balanceSpeechLoudness(file.path);
        expect(path, isNot(file.path));
        expect(await file.readAsBytes(), original);
        final bytes = await File(path).readAsBytes();
        final envelope = await loadSpeechEnvelope(path, bytes);
        expect(envelope, isNotNull);
        expect(envelope!.values.length, 150);
        expect(envelope.frameDuration, const Duration(milliseconds: 20));
        expect(await File('${file.path}.decoded.wav').exists(), isFalse);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test('reduces within-sentence loudness jumps while preserving duration', () {
    final input = wave((f, _) => tone(f) * (f < rate ? .04 : .65));
    final output = balanceSpeechWav(input)!;
    final ratio =
        rms(output, rate * 2, rate * 3) / rms(output, rate ~/ 4, rate ~/ 2);
    expect(ratio, lessThan(4)); // Original amplitude ratio is 16.25.
    expect(output.length, input.length);
    final data = ByteData.sublistView(output);
    for (var at = 44; at < output.length; at += 2) {
      expect(data.getInt16(at, Endian.little).abs(), lessThanOrEqualTo(31130));
    }
  });

  test('balances separate segments toward a common level', () {
    final quiet = balanceSpeechWav(wave((f, _) => .08 * tone(f)))!;
    final loud = balanceSpeechWav(wave((f, _) => .8 * tone(f)))!;
    expect(
      rms(loud, rate, rate * 2) / rms(quiet, rate, rate * 2),
      lessThan(2.5),
    );
  });

  test('silence and sub-gate noise are not boosted', () {
    final silence = balanceSpeechWav(wave((_, _) => 0))!;
    expect(rms(silence, 0, rate * 3), 0);
    final noise = wave((f, _) => .001 * tone(f));
    final result = balanceSpeechWav(noise)!;
    expect(rms(result, 0, rate), closeTo(rms(noise, 0, rate), .00004));
  });

  test('ASMR uses less makeup gain than normal speech', () {
    final input = wave((f, _) => .02 * tone(f));
    final asmr = balanceSpeechWav(input, asmr: true)!;
    final normal = balanceSpeechWav(input)!;
    expect(rms(asmr, rate, rate * 2), lessThan(rms(normal, rate, rate * 2)));
    expect(
      rms(asmr, rate, rate * 2) / rms(input, rate, rate * 2),
      lessThanOrEqualTo(1.501),
    );
  });

  test('stereo stays linked and transient peaks do not clip', () {
    final input = wave(
      (f, c) => (f == rate ? 1.0 : .04 * tone(f)) * (c == 0 ? 1 : .5),
      channels: 2,
    );
    final output = balanceSpeechWav(input)!;
    expect(
      rms(output, rate, rate * 2, channels: 2) /
          rms(output, rate, rate * 2, channels: 2, channel: 1),
      closeTo(2, .005),
    );
    final data = ByteData.sublistView(output);
    expect(
      data.getInt16(44 + rate * 4, Endian.little).abs(),
      lessThanOrEqualTo(31130),
    );
    expect(data.getUint16(22, Endian.little), 2);
    expect(data.getUint32(24, Endian.little), rate);
  });

  test('handles PCM bit depths and float WAV', () {
    for (final bits in [8, 16, 24, 32]) {
      final result = balanceSpeechWav(
        wave((f, _) => .2 * tone(f), bits: bits, frames: 401),
      );
      expect(result, isNotNull);
      expect(result!.length, 44 + 401 * 2);
    }
    expect(
      balanceSpeechWav(wave((f, _) => .2 * tone(f), bits: 32, floating: true)),
      isNotNull,
    );
  });

  test('rejects invalid audio safely', () {
    expect(balanceSpeechWav(Uint8List(3)), isNull);
    final bad = wave((_, _) => 0);
    ByteData.sublistView(bad).setUint16(32, 0, Endian.little);
    expect(balanceSpeechWav(bad), isNull);
    expect(
      balanceSpeechWav(wave((_, _) => double.nan, bits: 32, floating: true)),
      isNull,
    );
  });
}
