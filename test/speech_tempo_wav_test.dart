import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/speech_tempo_wav.dart';

Uint8List _wave({
  int rate = 24000,
  int channels = 1,
  int bits = 16,
  bool floating = false,
  int? frames,
  double seconds = 1,
  double Function(int frame, int channel)? sample,
}) {
  frames ??= (rate * seconds).round();
  final block = channels * (bits ~/ 8);
  final length = frames * block;
  final bytes = Uint8List(44 + length + (length & 1));
  final data = ByteData.sublistView(bytes);
  for (final entry in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    bytes.setRange(entry.key, entry.key + 4, entry.value.codeUnits);
  }
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, floating ? 3 : 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * block, Endian.little);
  data.setUint16(32, block, Endian.little);
  data.setUint16(34, bits, Endian.little);
  data.setUint32(40, length, Endian.little);
  for (var frame = 0; frame < frames; frame++) {
    for (var channel = 0; channel < channels; channel++) {
      final value =
          sample?.call(frame, channel) ??
          .4 * math.sin(2 * math.pi * 220 * frame / rate);
      final offset = 44 + (frame * channels + channel) * (bits ~/ 8);
      if (floating) {
        data.setFloat32(offset, value, Endian.little);
      } else if (bits == 8) {
        data.setUint8(offset, (value * 128 + 128).round().clamp(0, 255));
      } else if (bits == 16) {
        data.setInt16(
          offset,
          (value * 32768).round().clamp(-32768, 32767),
          Endian.little,
        );
      } else if (bits == 24) {
        final integer = (value * 8388608).round().clamp(-8388608, 8388607);
        data.setUint8(offset, integer & 255);
        data.setUint8(offset + 1, (integer >> 8) & 255);
        data.setUint8(offset + 2, (integer >> 16) & 255);
      } else {
        data.setInt32(
          offset,
          (value * 2147483648).round().clamp(-2147483648, 2147483647),
          Endian.little,
        );
      }
    }
  }
  return bytes;
}

int _frames(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return data.getUint32(40, Endian.little) ~/
      (2 * data.getUint16(22, Endian.little));
}

int _sample(Uint8List bytes, int frame, [int channel = 0]) {
  final data = ByteData.sublistView(bytes);
  final channels = data.getUint16(22, Endian.little);
  return data.getInt16(44 + (frame * channels + channel) * 2, Endian.little);
}

double _frequency(Uint8List bytes, [int channel = 0]) {
  final frames = _frames(bytes);
  final rate = ByteData.sublistView(bytes).getUint32(24, Endian.little);
  final first = (frames * .1).round();
  final last = (frames * .9).round();
  var crossings = 0;
  for (var frame = first + 1; frame < last; frame++) {
    if (_sample(bytes, frame - 1, channel) <= 0 &&
        _sample(bytes, frame, channel) > 0) {
      crossings++;
    }
  }
  return crossings * rate / (last - first);
}

void _expectPcm16(Uint8List bytes, {int channels = 1, int rate = 24000}) {
  final data = ByteData.sublistView(bytes);
  expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
  expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
  expect(data.getUint32(4, Endian.little), bytes.length - 8);
  expect(data.getUint16(20, Endian.little), 1);
  expect(data.getUint16(22, Endian.little), channels);
  expect(data.getUint32(24, Endian.little), rate);
  expect(data.getUint16(34, Endian.little), 16);
  expect(data.getUint32(40, Endian.little), bytes.length - 44);
}

void main() {
  test('invalid speeds are rejected before reading input', () {
    for (final speed in [
      double.nan,
      double.infinity,
      -double.infinity,
      0.0,
      -.5,
      .49,
      2.01,
    ]) {
      expect(
        () => changeSpeechWavTempo(Uint8List(0), speed: speed),
        throwsArgumentError,
      );
    }
  });

  test('normal speed leaves valid PCM16 unchanged', () {
    final input = _wave();
    expect(identical(changeSpeechWavTempo(input, speed: 1), input), isTrue);
  });

  for (final speed in [.5, .9, 1.25, 2.0]) {
    test('$speed tempo retains 220 Hz pitch at the original sample rate', () {
      final input = _wave(seconds: 2);
      final output = changeSpeechWavTempo(input, speed: speed)!;
      _expectPcm16(output);
      expect(_frames(output), (48000 / speed).round());
      expect(_frequency(output), closeTo(220, 2.5));
      expect(_sample(output, 0), _sample(input, 0));
      expect(_sample(output, _frames(output) - 1), _sample(input, 47999));
    });
  }

  test('stereo channels retain separate tones and a shared timeline', () {
    final input = _wave(
      seconds: 2,
      channels: 2,
      sample: (frame, channel) =>
          (channel == 0 ? .4 : .2) *
          math.sin(2 * math.pi * (channel == 0 ? 220 : 440) * frame / 24000),
    );
    final output = changeSpeechWavTempo(input, speed: .9)!;
    _expectPcm16(output, channels: 2);
    expect(_frames(output), (48000 / .9).round());
    expect(_frequency(output, 0), closeTo(220, 2.5));
    expect(_frequency(output, 1), closeTo(440, 3));
  });

  test(
    'shared stereo search preserves anti-phase instead of downmixing it',
    () {
      final input = _wave(
        channels: 2,
        sample: (frame, channel) =>
            (channel == 0 ? 1 : -1) *
            .3 *
            math.sin(2 * math.pi * 180 * frame / 24000),
      );
      final output = changeSpeechWavTempo(input, speed: .9)!;
      var maximum = 0;
      for (var frame = 0; frame < _frames(output); frame++) {
        expect(
          (_sample(output, frame, 0) + _sample(output, frame, 1)).abs(),
          lessThanOrEqualTo(1),
        );
        maximum = math.max(maximum, _sample(output, frame, 0).abs());
      }
      expect(maximum, greaterThan(9000));
    },
  );

  test(
    'an inactive channel stays silent and receives no cross-channel signal',
    () {
      final output = changeSpeechWavTempo(
        _wave(
          channels: 2,
          sample: (frame, channel) =>
              channel == 0 ? .3 * math.sin(frame / 20) : 0,
        ),
        speed: .9,
      )!;
      for (var frame = 0; frame < _frames(output); frame++) {
        expect(_sample(output, frame, 1), 0);
      }
    },
  );

  test(
    'anchored endpoints preserve first and last transients at both speeds',
    () {
      final input = _wave(
        sample: (frame, _) => frame == 0
            ? .8
            : frame == 23999
            ? -.7
            : .1 * math.sin(frame / 20),
      );
      for (final speed in [.5, .9, 1.3, 2.0]) {
        final output = changeSpeechWavTempo(input, speed: speed)!;
        expect(_sample(output, 0), _sample(input, 0));
        expect(_sample(output, _frames(output) - 1), _sample(input, 23999));
        expect(_sample(output, _frames(output) - 1), lessThan(-22000));
      }
    },
  );

  test('tiny clips and silence produce finite bounded complete files', () {
    for (final frames in [1, 2, 3, 7, 32, 100, 479, 960]) {
      for (final speed in [.5, .9, 2.0]) {
        final input = _wave(frames: frames, sample: (_, _) => 0);
        final output = changeSpeechWavTempo(input, speed: speed)!;
        _expectPcm16(output);
        expect(_frames(output), math.max(1, (frames / speed).round()));
        expect(output.sublist(44).every((byte) => byte == 0), isTrue);
      }
    }
  });

  for (final bits in [8, 24, 32]) {
    test('PCM$bits is converted to PCM16 without changing pitch', () {
      final output = changeSpeechWavTempo(_wave(bits: bits), speed: .9)!;
      _expectPcm16(output);
      expect(_frequency(output), closeTo(220, 3));
    });
  }

  test(
    'float32 is converted, clipped safely, and rejects non-finite values',
    () {
      final output = changeSpeechWavTempo(
        _wave(bits: 32, floating: true),
        speed: .9,
      )!;
      _expectPcm16(output);
      expect(_frequency(output), closeTo(220, 3));
      final clipped = changeSpeechWavTempo(
        _wave(bits: 32, floating: true, frames: 8, sample: (_, _) => 2),
        speed: 1,
      )!;
      expect(_sample(clipped, 0), 32767);
      final broken = _wave(bits: 32, floating: true);
      ByteData.sublistView(broken).setFloat32(44, double.nan, Endian.little);
      expect(changeSpeechWavTempo(broken, speed: .9), isNull);
    },
  );

  test('invalid formats, alignment and truncated chunks are rejected', () {
    expect(changeSpeechWavTempo(Uint8List(44), speed: .9), isNull);
    final good = _wave(frames: 80);
    for (var length = 0; length < 44; length++) {
      expect(
        changeSpeechWavTempo(Uint8List.sublistView(good, 0, length), speed: .9),
        isNull,
      );
    }
    for (final change in <void Function(ByteData)>[
      (data) => data.setUint32(4, 0xffffffff, Endian.little),
      (data) => data.setUint32(40, 0xffffffff, Endian.little),
      (data) => data.setUint32(40, 159, Endian.little),
      (data) => data.setUint16(20, 6, Endian.little),
      (data) => data.setUint16(22, 0, Endian.little),
      (data) => data.setUint16(22, 9, Endian.little),
      (data) => data.setUint32(24, 0, Endian.little),
      (data) => data.setUint16(32, 3, Endian.little),
      (data) => data.setUint32(28, 1, Endian.little),
      (data) => data.setUint16(34, 12, Endian.little),
    ]) {
      final broken = Uint8List.fromList(good);
      change(ByteData.sublistView(broken));
      expect(changeSpeechWavTempo(broken, speed: .9), isNull);
    }
  });

  test('input and expanded output must satisfy duration and memory limits', () {
    expect(
      changeSpeechWavTempo(Uint8List(speechTempoMaximumBytes + 1), speed: .9),
      isNull,
    );
    final input = _wave(rate: 8000, seconds: 301, sample: (_, _) => 0);
    expect(changeSpeechWavTempo(input, speed: .5), isNull);
  });

  test('ten second 24 kHz processing benchmark', () {
    final input = _wave(seconds: 10);
    final watch = Stopwatch()..start();
    final output = changeSpeechWavTempo(input, speed: .9)!;
    watch.stop();
    expect(_frames(output), (240000 / .9).round());
    // Measured evidence, not a timing assertion that depends on machine load.
    // ignore: avoid_print
    print('WSOLA 10s / 24kHz mono / 0.9x: ${watch.elapsedMilliseconds} ms');
  });
}
