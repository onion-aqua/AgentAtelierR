import 'dart:math';
import 'dart:typed_data';

import 'tts_spatial_settings.dart';

/// Adds a fixed headphone image to mono speech without moving the voice between
/// phrases. Call after loudness balancing, which supplies standard PCM16 WAV.
/// Genuine stereo is returned unchanged; unsupported or damaged WAV returns null.
Uint8List? spatializeSpeechWav(
  Uint8List bytes, {
  TtsStereoPosition position = TtsStereoPosition.center,
  bool asmr = false,
}) {
  final wave = _readPcm16(bytes);
  if (wave == null) return null;
  final input = ByteData.sublistView(bytes);
  if (wave.channels == 2 && !_isDualMono(input, wave)) return bytes;

  // Limit allocations as well as input size; long/unsupported speech can retain
  // its original playable file rather than exhausting the worker isolate.
  final outputLength = 44 + wave.frames * 4;
  if (outputLength > 64 * 1024 * 1024) return null;
  final output = Uint8List(outputLength);
  final data = ByteData.sublistView(output);
  _writeHeader(output, data, wave.rate, wave.frames);
  final center = position == TtsStereoPosition.center;
  final pan = center ? 0.0 : (asmr ? .72 : .45);
  final nearGain = center ? sqrt(.5) : cos((1 - pan) * pi / 4);
  final farGain = center ? nearGain : sin((1 - pan) * pi / 4);
  final reflectionMix = asmr ? .028 : .018;
  final reflectionLeft = _FractionalDelay(wave.rate * (asmr ? .0014 : .0011));
  final reflectionRight = _FractionalDelay(wave.rate * (asmr ? .0021 : .0017));
  final farDelay = _FractionalDelay(wave.rate * (asmr ? .00038 : .00018));
  final reflectionFilter = _LowPass(wave.rate, asmr ? 3200 : 4200);
  final farFilter = _LowPass(wave.rate, asmr ? 4000 : 6000);
  final farFilterMix = asmr ? .36 : .22;

  for (var frame = 0; frame < wave.frames; frame++) {
    final at = wave.start + frame * wave.channels * 2;
    final sample = wave.channels == 1
        ? input.getInt16(at, Endian.little) / 32768
        : (input.getInt16(at, Endian.little) +
                  input.getInt16(at + 2, Endian.little)) /
              65536;
    final double left;
    final double right;
    if (center) {
      // The same direct voice dominates both ears. These very quiet, fixed early
      // reflections give width while keeping the apparent speaker in the center.
      final reflected = reflectionFilter.next(sample);
      final direct = sample * (1 - reflectionMix);
      left =
          nearGain * (direct + reflectionMix * reflectionLeft.next(reflected));
      right =
          nearGain * (direct + reflectionMix * reflectionRight.next(reflected));
    } else {
      final delayed = farDelay.next(sample);
      final distant =
          delayed * (1 - farFilterMix) + farFilter.next(delayed) * farFilterMix;
      final near = sample * nearGain;
      final far = distant * farGain;
      left = position == TtsStereoPosition.left ? near : far;
      right = position == TtsStereoPosition.left ? far : near;
    }
    // All processing weights are convex and gains <= 1, so input peaks cannot
    // clip. Clamp only protects conversion against floating point roundoff.
    data.setInt16(44 + frame * 4, _pcm16(left), Endian.little);
    data.setInt16(46 + frame * 4, _pcm16(right), Endian.little);
  }
  return output;
}

int _pcm16(double value) => (value * 32768).round().clamp(-32768, 32767);

bool _isDualMono(ByteData data, _PcmWave wave) {
  var differenceEnergy = 0.0;
  var monoEnergy = 0.0;
  for (var frame = 0; frame < wave.frames; frame++) {
    final at = wave.start + frame * 4;
    final left = data.getInt16(at, Endian.little);
    final right = data.getInt16(at + 2, Endian.little);
    final difference = left - right;
    // Be conservative: even a small real stereo difference should retain the
    // provider's original sound field. Allow only negligible PCM quantization.
    if (difference.abs() > 2) return false;
    differenceEnergy += difference * difference;
    final mono = (left + right) / 2;
    monoEnergy += mono * mono;
  }
  return differenceEnergy == 0 || differenceEnergy <= monoEnergy * 1e-6;
}

_PcmWave? _readPcm16(Uint8List bytes) {
  if (bytes.length < 44 || bytes.length > 64 * 1024 * 1024) return null;
  final data = ByteData.sublistView(bytes);
  String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
  final end = 8 + data.getUint32(4, Endian.little);
  if (end < 44 || end > bytes.length) return null;
  int? channels, rate, start, length;
  for (var offset = 12; offset + 8 <= end;) {
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (body + size > end) return null;
    final type = tag(offset);
    if (type == 'fmt ') {
      if (size < 16 || channels != null) return null;
      channels = data.getUint16(body + 2, Endian.little);
      rate = data.getUint32(body + 4, Endian.little);
      if (data.getUint16(body, Endian.little) != 1 ||
          !const [1, 2].contains(channels) ||
          rate < 8000 ||
          rate > 192000 ||
          data.getUint16(body + 14, Endian.little) != 16 ||
          data.getUint16(body + 12, Endian.little) != channels * 2 ||
          data.getUint32(body + 8, Endian.little) != rate * channels * 2) {
        return null;
      }
    } else if (type == 'data') {
      if (start != null) return null;
      start = body;
      length = size;
    }
    offset = body + size + (size & 1);
    if (offset > end) return null;
  }
  if (channels == null ||
      rate == null ||
      start == null ||
      length == null ||
      length == 0 ||
      length % (channels * 2) != 0) {
    return null;
  }
  final frames = length ~/ (channels * 2);
  if (frames > rate * 600) return null;
  return _PcmWave(channels, rate, start, frames);
}

void _writeHeader(Uint8List bytes, ByteData data, int rate, int frames) {
  for (final item in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    bytes.setRange(item.key, item.key + 4, item.value.codeUnits);
  }
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, frames * 4, Endian.little);
}

class _PcmWave {
  const _PcmWave(this.channels, this.rate, this.start, this.frames);
  final int channels;
  final int rate;
  final int start;
  final int frames;
}

class _LowPass {
  _LowPass(int rate, double cutoff)
    : coefficient = 1 - exp(-2 * pi * cutoff / rate);
  final double coefficient;
  double value = 0;

  double next(double input) => value += coefficient * (input - value);
}

class _FractionalDelay {
  _FractionalDelay(this.delay) : buffer = Float64List(delay.ceil() + 2);
  final double delay;
  final Float64List buffer;
  int cursor = 0;

  double next(double value) {
    buffer[cursor] = value;
    final index = (cursor - delay) % buffer.length;
    final before = index.floor();
    final fraction = index - before;
    final result =
        buffer[before] * (1 - fraction) +
        buffer[(before + 1) % buffer.length] * fraction;
    cursor = (cursor + 1) % buffer.length;
    return result;
  }
}
