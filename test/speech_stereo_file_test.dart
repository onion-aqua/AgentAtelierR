import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/speech_envelope_loader.dart';
import 'package:ryza_chat_mvp/src/speech_loudness.dart';
import 'package:ryza_chat_mvp/src/tts_spatial_settings.dart';

const _sampleRate = 16000;
const _sampleFrames = _sampleRate * 2 + 117;

Uint8List _wave({int channels = 1}) {
  final bytes = Uint8List(44 + _sampleFrames * channels * 2);
  final data = ByteData.sublistView(bytes);
  for (final item in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    bytes.setRange(item.key, item.key + 4, item.value.codeUnits);
  }
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, _sampleRate, Endian.little);
  data.setUint32(28, _sampleRate * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, bytes.length - 44, Endian.little);
  for (var frame = 0; frame < _sampleFrames; frame++) {
    for (var channel = 0; channel < channels; channel++) {
      // Different envelope/phase per ear creates a genuine existing sound field.
      final time = (frame + channel * 3) / _sampleRate;
      final strength =
          (frame < _sampleRate ? .06 : .5) * (channel == 0 ? 1 : .45);
      final value =
          strength *
          (.75 * sin(2 * pi * 230 * time) + .25 * sin(2 * pi * 1250 * time));
      data.setInt16(
        44 + (frame * channels + channel) * 2,
        (value * 32767).round(),
        Endian.little,
      );
    }
  }
  return bytes;
}

double _sample(Uint8List bytes, int frame, int channel, int channels) =>
    ByteData.sublistView(bytes)
        .getInt16(44 + (frame * channels + channel) * 2, Endian.little) /
    32768;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tts_stereo_file_test_');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'disabled stereo keeps mono and its existing cache path and source',
    () async {
      final source = File('${directory.path}/speech.wav');
      final original = _wave();
      await source.writeAsBytes(original);
      final output = await balanceSpeechLoudness(
        source.path,
        stereoEnabled: false,
        stereoPosition: TtsStereoPosition.right,
      );
      expect(output, '${source.path}.balanced.wav');
      final bytes = await File(output).readAsBytes();
      expect(ByteData.sublistView(bytes).getUint16(22, Endian.little), 1);
      expect(bytes.length, original.length);
      expect(bytes, isNot(original));
      expect(await source.readAsBytes(), original);
      expect(await File('${source.path}.decoded.wav').exists(), isFalse);
    },
  );

  test(
    'stereo file paths remain distinct and lip sync follows the processed file',
    () async {
      final source = File('${directory.path}/speech.wav');
      final original = _wave();
      await source.writeAsBytes(original);
      for (final asmr in [false, true]) {
        for (final position in TtsStereoPosition.values) {
          final output = await balanceSpeechLoudness(
            source.path,
            stereoEnabled: true,
            stereoPosition: position,
            asmr: asmr,
          );
          expect(output, '${source.path}.balanced-stereo-${position.name}.wav');
          final bytes = await File(output).readAsBytes();
          final data = ByteData.sublistView(bytes);
          expect(data.getUint16(22, Endian.little), 2);
          expect(data.getUint32(24, Endian.little), _sampleRate);
          final frames = data.getUint32(40, Endian.little) ~/ 4;
          expect(frames, _sampleFrames);
          expect(bytes.length, 44 + _sampleFrames * 4);
          final envelope = await loadSpeechEnvelope(output, bytes);
          expect(envelope, isNotNull);
          expect(envelope!.frameDuration, const Duration(milliseconds: 20));
          expect(envelope.values.length, 101);
          expect(envelope.rawRms.length, 101);
          final soundDuration = frames / _sampleRate;
          final envelopeDuration =
              envelope.values.length *
              envelope.frameDuration.inMicroseconds /
              1000000;
          expect(envelopeDuration, greaterThanOrEqualTo(soundDuration));
          expect(envelopeDuration - soundDuration, lessThan(.02));
          expect(
            envelope.values.every((x) => x.isFinite && x >= 0 && x <= 1),
            isTrue,
          );
          // Measure each stereo sample directly, so an envelope using the original
          // mono bytes or doubling duration by counting channels cannot pass.
          for (var window = 0; window < envelope.rawRms.length; window++) {
            final first = window * 320;
            final end = min(_sampleFrames, first + 320);
            var sum = 0.0;
            for (var frame = first; frame < end; frame++) {
              for (final channel in [0, 1]) {
                final value = _sample(bytes, frame, channel, 2);
                sum += value * value;
              }
            }
            expect(
              envelope.rawRms[window],
              closeTo(sqrt(sum / ((end - first) * 2)), 1e-12),
            );
          }
          expect(envelope.rawRms.last, greaterThan(0));
          expect(envelope.valueAt(const Duration(milliseconds: 2020)), 0);
          expect(await source.readAsBytes(), original);
          expect(await File('${source.path}.decoded.wav').exists(), isFalse);
        }
      }
      // Changing position or disabling stereo must select the corresponding
      // processed file instead of reusing an earlier stereo cache variant.
      final mono = await balanceSpeechLoudness(source.path);
      expect(mono, '${source.path}.balanced.wav');
      expect(
        ByteData.sublistView(await File(mono).readAsBytes())
            .getUint16(22, Endian.little),
        1,
      );
    },
  );

  test(
    'native stereo keeps its sound field and shared loudness gain',
    () async {
      final source = File('${directory.path}/native_stereo.wav');
      final original = _wave(channels: 2);
      await source.writeAsBytes(original);
      final balancedPath = await balanceSpeechLoudness(source.path);
      final balanced = await File(balancedPath).readAsBytes();
      for (final position in TtsStereoPosition.values) {
        final stereoPath = await balanceSpeechLoudness(
          source.path,
          stereoEnabled: true,
          stereoPosition: position,
        );
        final result = await File(stereoPath).readAsBytes();
        // Existing stereo only receives the established linked loudness stage,
        // regardless of the new user-selected synthetic position.
        expect(result, balanced);
        for (var frame = 1; frame < _sampleFrames; frame += 79) {
          final left = _sample(original, frame, 0, 2);
          final right = _sample(original, frame, 1, 2);
          if (left.abs() < .025 || right.abs() < .025) continue;
          final leftGain = _sample(result, frame, 0, 2) / left;
          final rightGain = _sample(result, frame, 1, 2) / right;
          expect(leftGain, closeTo(rightGain, .002));
        }
      }
      expect(await source.readAsBytes(), original);
    },
  );

  test('decode temp cleanup runs even on a valid direct WAV path', () async {
    final source = File('${directory.path}/speech.wav');
    await source.writeAsBytes(_wave());
    final decoded = File('${source.path}.decoded.wav');
    await decoded.writeAsBytes(_wave());
    final output = await balanceSpeechLoudness(
      source.path,
      stereoEnabled: true,
    );
    expect(await File(output).exists(), isTrue);
    expect(await decoded.exists(), isFalse);
  });

  test(
    'unsupported audio falls back and removes partial output and decode temp',
    () async {
      final source = File('${directory.path}/unsupported.bin');
      final original = Uint8List.fromList([1, 4, 8, 16, 32, 64]);
      await source.writeAsBytes(original);
      final decoded = File('${source.path}.decoded.wav');
      final partial = File('${source.path}.balanced-stereo-left.wav');
      await decoded.writeAsBytes(_wave());
      await partial.writeAsBytes([7, 8, 9]);
      final output = await balanceSpeechLoudness(
        source.path,
        stereoEnabled: true,
        stereoPosition: TtsStereoPosition.left,
      );
      expect(output, source.path);
      expect(await source.readAsBytes(), original);
      expect(await decoded.exists(), isFalse);
      expect(await partial.exists(), isFalse);
    },
  );
}
