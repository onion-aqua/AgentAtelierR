import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/speech_spatial.dart';
import 'package:ryza_chat_mvp/src/tts_spatial_settings.dart';

const _rate = 16000;

Uint8List _wave(
  double Function(int frame, int channel) sample, {
  int frames = _rate,
  int channels = 1,
  int rate = _rate,
}) {
  final bytes = Uint8List(44 + frames * channels * 2);
  final data = ByteData.sublistView(bytes);
  for (final item in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    bytes.setRange(item.key, item.key + 4, item.value.codeUnits);
  }
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, bytes.length - 44, Endian.little);
  for (var frame = 0; frame < frames; frame++) {
    for (var channel = 0; channel < channels; channel++) {
      data.setInt16(
        44 + (frame * channels + channel) * 2,
        (sample(frame, channel) * 32768).round().clamp(-32768, 32767),
        Endian.little,
      );
    }
  }
  return bytes;
}

List<double> _channel(Uint8List wave, int channel) {
  final data = ByteData.sublistView(wave);
  final channels = data.getUint16(22, Endian.little);
  return [
    for (var frame = 0; frame < (wave.length - 44) ~/ (channels * 2); frame++)
      data.getInt16(44 + (frame * channels + channel) * 2, Endian.little) /
          32768,
  ];
}

double _rms(Iterable<double> samples) {
  var squares = 0.0;
  var count = 0;
  for (final sample in samples) {
    squares += sample * sample;
    count++;
  }
  return sqrt(squares / count);
}

double _correlation(List<double> a, List<double> b) {
  var aa = 0.0, bb = 0.0, ab = 0.0;
  for (var frame = 0; frame < a.length; frame++) {
    aa += a[frame] * a[frame];
    bb += b[frame] * b[frame];
    ab += a[frame] * b[frame];
  }
  return ab / sqrt(aa * bb);
}

double _voice(int frame) {
  final time = frame / _rate;
  final envelope = .2 + .15 * sin(2 * pi * 3 * time).abs();
  return envelope *
      (.6 * sin(2 * pi * 230 * time) +
          .25 * sin(2 * pi * 1270 * time) +
          .15 * sin(2 * pi * 3710 * time));
}

void main() {
  test(
    'mono becomes PCM16 stereo without changing frames, rate or duration',
    () {
      for (final rate in [8000, 16000, 44100, 48000, 192000]) {
        final input = _wave(
          (f, _) => .2 * sin(2 * pi * 200 * f / rate),
          rate: rate,
          frames: 1003,
        );
        final output = spatializeSpeechWav(input)!;
        final data = ByteData.sublistView(output);
        expect(output.length, 44 + 1003 * 4);
        expect(data.getUint16(20, Endian.little), 1);
        expect(data.getUint16(22, Endian.little), 2);
        expect(data.getUint16(34, Endian.little), 16);
        expect(data.getUint32(24, Endian.little), rate);
        expect(data.getUint32(28, Endian.little), rate * 4);
        expect(data.getUint32(40, Endian.little) ~/ 4, 1003);
        expect(data.getUint32(4, Endian.little), output.length - 8);
      }
    },
  );

  test(
    'center is reproducible, narrow and stable throughout changing speech',
    () {
      final input = _wave((f, _) => _voice(f));
      for (final asmr in [false, true]) {
        final output = spatializeSpeechWav(input, asmr: asmr)!;
        expect(spatializeSpeechWav(input, asmr: asmr), output);
        final left = _channel(output, 0);
        final right = _channel(output, 1);
        final width = [
          for (var frame = 0; frame < left.length; frame++)
            left[frame] - right[frame],
        ];
        expect(_rms(width), greaterThan(.00001));
        expect(_rms(width) / _rms(left), lessThan(.05));
        expect(_correlation(left, right), greaterThan(.998));
        // The foreground speaker stays centered at every 50 ms interval, rather
        // than only averaging to the center across a moving whole sentence.
        for (var first = 0; first < _rate; first += _rate ~/ 20) {
          final ratio =
              _rms(left.sublist(first, first + _rate ~/ 20)) /
              _rms(right.sublist(first, first + _rate ~/ 20));
          expect(ratio, inInclusiveRange(.98, 1.02));
        }
        final mono = _channel(input, 0);
        final folded = [
          for (var frame = 0; frame < left.length; frame++)
            (left[frame] + right[frame]) / 2,
        ];
        expect(_correlation(mono, folded), greaterThan(.9998));
        // Spatial processing must not pump volume or destroy mono intelligibility.
        expect(_rms(folded) / _rms(mono), inInclusiveRange(.67, .73));
      }
    },
  );

  test(
    'fixed left and right positions are exact mirrors with consistent bias',
    () {
      final input = _wave((f, _) => _voice(f));
      for (final asmr in [false, true]) {
        final leftWave = spatializeSpeechWav(
          input,
          position: TtsStereoPosition.left,
          asmr: asmr,
        )!;
        final rightWave = spatializeSpeechWav(
          input,
          position: TtsStereoPosition.right,
          asmr: asmr,
        )!;
        final near = _channel(leftWave, 0);
        final far = _channel(leftWave, 1);
        expect(near, _channel(rightWave, 1));
        expect(far, _channel(rightWave, 0));
        for (var first = 0; first < _rate; first += _rate ~/ 10) {
          expect(
            _rms(near.sublist(first, first + _rate ~/ 10)) /
                _rms(far.sublist(first, first + _rate ~/ 10)),
            greaterThan(asmr ? 3.5 : 1.8),
          );
        }
        final folded = [
          for (var frame = 0; frame < near.length; frame++)
            (near[frame] + far[frame]) / 2,
        ];
        expect(_correlation(_channel(input, 0), folded), greaterThan(.93));
        expect(_rms(folded) / _rms(_channel(input, 0)), greaterThan(.45));
      }
    },
  );

  test('far ear has only a submillisecond delay and no audible long echo', () {
    const onset = 100;
    final input = _wave((f, _) => f == onset ? .9 : 0, frames: 1000);
    for (final asmr in [false, true]) {
      final output = spatializeSpeechWav(
        input,
        position: TtsStereoPosition.left,
        asmr: asmr,
      )!;
      final near = _channel(output, 0);
      final far = _channel(output, 1);
      expect(near.indexWhere((x) => x.abs() > .0001), onset);
      final farOnset = far.indexWhere((x) => x.abs() > .0001);
      expect(farOnset - onset, inInclusiveRange(1, (_rate * .0006).ceil()));
      expect(
        _rms(far.sublist(onset + (_rate * .005).ceil())),
        lessThan(.00001),
      );
    }
  });

  test(
    'far-ear filtering attenuates highs gently rather than muting speech',
    () {
      double channelRatio(double frequency) {
        final input = _wave((f, _) => .3 * sin(2 * pi * frequency * f / _rate));
        final output = spatializeSpeechWav(
          input,
          position: TtsStereoPosition.left,
          asmr: true,
        )!;
        return _rms(_channel(output, 1).skip(100)) /
            _rms(_channel(output, 0).skip(100));
      }

      final low = channelRatio(300);
      final high = channelRatio(5000);
      expect(high, lessThan(low * .9));
      expect(high, greaterThan(low * .3));
    },
  );

  test('silence remains silent and full-scale transients never clip', () {
    final silent = _wave((_, _) => 0, frames: 1000);
    final loud = _wave((f, _) => f % 13 < 6 ? 1 : -1, frames: 1000);
    for (final position in TtsStereoPosition.values) {
      for (final asmr in [false, true]) {
        final silence = spatializeSpeechWav(
          silent,
          position: position,
          asmr: asmr,
        )!;
        expect(_rms(_channel(silence, 0)), 0);
        expect(_rms(_channel(silence, 1)), 0);
        final output = spatializeSpeechWav(
          loud,
          position: position,
          asmr: asmr,
        )!;
        for (final channel in [0, 1]) {
          expect(_channel(output, channel).every((x) => x.abs() < .99), isTrue);
        }
      }
    }
  });

  test('identical and negligible dual mono receive space, true stereo stays intact', () {
    final mono = _wave((f, _) => _voice(f));
    final dual = _wave((f, _) => _voice(f), channels: 2);
    expect(spatializeSpeechWav(dual), spatializeSpeechWav(mono));
    final almostDual = _wave(
      (f, c) => _voice(f) + (c == 0 ? 0 : 1 / 32768),
      channels: 2,
    );
    final widened = spatializeSpeechWav(almostDual)!;
    expect(_channel(widened, 0), isNot(_channel(widened, 1)));
    for (final input in [
      _wave((f, c) => _voice(f) * (c == 0 ? 1 : .99), channels: 2),
      _wave((f, c) => _voice(f + c * 4), channels: 2),
      _wave((f, c) => _voice(f) * (c == 0 ? 1 : -1), channels: 2),
    ]) {
      for (final position in TtsStereoPosition.values) {
        expect(
          identical(spatializeSpeechWav(input, position: position), input),
          isTrue,
        );
        expect(
          identical(
            spatializeSpeechWav(input, position: position, asmr: true),
            input,
          ),
          isTrue,
        );
      }
    }
  });

  test(
    'unknown WAV chunks are parsed and existing stereo metadata is preserved',
    () {
      Uint8List addChunk(Uint8List input) {
        final bytes = Uint8List(input.length + 12);
        bytes.setRange(0, 36, input);
        bytes.setRange(36, 40, 'JUNK'.codeUnits);
        ByteData.sublistView(bytes).setUint32(40, 3, Endian.little);
        bytes.setRange(44, 47, [1, 2, 3]);
        bytes.setRange(48, bytes.length, input.sublist(36));
        ByteData.sublistView(bytes)
            .setUint32(4, bytes.length - 8, Endian.little);
        return bytes;
      }

      final mono = _wave((f, _) => _voice(f), frames: 1000);
      expect(spatializeSpeechWav(addChunk(mono)), spatializeSpeechWav(mono));
      final stereo = addChunk(_wave((f, c) => _voice(f + c * 3), channels: 2));
      expect(identical(spatializeSpeechWav(stereo), stereo), isTrue);
    },
  );

  test('invalid, truncated, empty and unsupported audio fails safely', () {
    expect(spatializeSpeechWav(Uint8List(10)), isNull);
    expect(spatializeSpeechWav(_wave((_, _) => 0, frames: 0)), isNull);
    expect(spatializeSpeechWav(_wave((_, _) => 0, channels: 3)), isNull);
    final good = _wave((f, _) => _voice(f), frames: 1000);
    expect(spatializeSpeechWav(good.sublist(0, good.length - 2)), isNull);
    for (final field in [20, 24, 28, 32, 34, 40]) {
      final bad = Uint8List.fromList(good);
      if ([24, 28, 40].contains(field)) {
        ByteData.sublistView(bad).setUint32(field, 1, Endian.little);
      } else {
        ByteData.sublistView(bad).setUint16(field, 3, Endian.little);
      }
      expect(
        spatializeSpeechWav(bad),
        isNull,
        reason: 'Invalid WAV field $field',
      );
    }
    final badChunk = Uint8List.fromList(good);
    ByteData.sublistView(badChunk).setUint32(16, 0xffffffff, Endian.little);
    expect(spatializeSpeechWav(badChunk), isNull);
  });
}
