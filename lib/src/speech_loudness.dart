import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'runtime_log.dart';

/// Process once before playback/cache; decoding and sample loops stay off the UI
/// isolate. A failed/unsupported decode leaves the original speech playable.
Future<String> balanceSpeechLoudness(String path, {bool asmr = false}) async {
  final output = '$path.balanced.wav';
  final decoded = '$path.decoded.wav';
  try {
    if (await compute(_balanceFile, (path, output, asmr))) return output;
    if (Platform.isAndroid) {
      final wav = await const MethodChannel('agent_atelier_r/speech_envelope')
          .invokeMethod<String>('decodeWav', {'path': path});
      if (wav != null && await compute(_balanceFile, (wav, output, asmr))) {
        return output;
      }
    }
    RuntimeLog.instance.warning('TTS', '响度均衡未支持此音频编码，使用原始语音');
  } on Object catch (error, stack) {
    RuntimeLog.instance.error('TTS loudness', error, stack);
  } finally {
    try {
      final file = File(decoded);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Temporary cache cleanup is best effort.
    }
  }
  try {
    final file = File(output);
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // A write failure must not prevent speech playback.
  }
  return path;
}

Future<bool> _balanceFile((String, String, bool) request) async {
  final file = File(request.$1);
  if (await file.length() > 64 * 1024 * 1024) return false;
  final result = balanceSpeechWav(await file.readAsBytes(), asmr: request.$3);
  if (result == null) return false;
  await File(request.$2).writeAsBytes(result, flush: true);
  return true;
}

/// Gentle windowed compression with bounded makeup gain, a silence gate and
/// linked stereo gain. This balances perceived speech levels, not EQ/frequency.
/// Returns standard PCM16 WAV with the original channels/rate/frame count.
Uint8List? balanceSpeechWav(Uint8List bytes, {bool asmr = false}) {
  if (bytes.length < 44 || bytes.length > 64 * 1024 * 1024) return null;
  String id(int offset) =>
      String.fromCharCodes(bytes.sublist(offset, offset + 4));
  if (id(0) != 'RIFF' || id(8) != 'WAVE') return null;
  final data = ByteData.sublistView(bytes);
  int? format, channels, rate, bits, block, start, length;
  for (var offset = 12; offset + 8 <= bytes.length;) {
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id(offset) == 'fmt ' && size >= 16 && body + size <= bytes.length) {
      format = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      rate = data.getUint32(body + 4, Endian.little);
      block = data.getUint16(body + 12, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
    } else if (id(offset) == 'data') {
      start = body;
      length = min(size, bytes.length - body);
    }
    offset = body + size + (size & 1);
  }
  if (channels == null ||
      channels < 1 ||
      channels > 8 ||
      rate == null ||
      rate < 8000 ||
      rate > 192000 ||
      bits == null ||
      start == null ||
      length == null ||
      !((format == 1 && const [8, 16, 24, 32].contains(bits)) ||
          (format == 3 && bits == 32))) {
    return null;
  }
  final sampleBytes = bits ~/ 8;
  if (block != channels * sampleBytes || length % block! != 0) return null;
  final frames = length ~/ block;
  if (frames == 0 || frames > rate * 600) return null;
  final samples = Float32List(frames * channels);
  for (var i = 0; i < samples.length; i++) {
    final at = start + i * sampleBytes;
    final double value;
    if (format == 3) {
      value = data.getFloat32(at, Endian.little);
    } else {
      value = switch (bits) {
        8 => (data.getUint8(at) - 128) / 128,
        16 => data.getInt16(at, Endian.little) / 32768,
        24 =>
          ((bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16)).toSigned(
                24,
              )) /
              8388608,
        _ => data.getInt32(at, Endian.little) / 2147483648,
      };
    }
    if (!value.isFinite) return null;
    samples[i] = value.clamp(-1.0, 1.0);
  }
  final window = max(1, (rate * .02).round());
  final count = (frames / window).ceil();
  final peaks = Float64List(count);
  final gains = Float64List(count);
  var previous = 1.0;
  for (var w = 0; w < count; w++) {
    final first = w * window * channels;
    final end = min(samples.length, first + window * channels);
    var sum = 0.0;
    for (var i = first; i < end; i++) {
      sum += samples[i] * samples[i];
      peaks[w] = max(peaks[w], samples[i].abs());
    }
    final rms = sqrt(sum / (end - first));
    // Below -50 dBFS do not chase silence or amplify background noise.
    if (rms >= .0031623) {
      previous = pow(
        (asmr ? .065 : .12) / rms,
        asmr ? .4 : .65,
      ).toDouble().clamp(.25, asmr ? 1.5 : 2.5);
    }
    gains[w] = previous;
  }
  // Look ahead and smooth both directions to avoid gain jumps at syllables.
  for (var w = count - 2; w >= 0; w--) {
    gains[w] = min(
      gains[w],
      gains[w + 1] + .2 * (gains[w] - gains[w + 1]).abs(),
    );
  }
  for (var w = 1; w < count; w++) {
    final factor = gains[w] < gains[w - 1] ? .35 : .1;
    gains[w] = gains[w - 1] + factor * (gains[w] - gains[w - 1]);
  }
  // Each interpolation endpoint protects peaks in both adjacent windows.
  // This avoids sample clipping without flattening individual waveform peaks.
  for (var w = 0; w < count; w++) {
    final peak = max(
      peaks[w],
      max(peaks[max(0, w - 1)], peaks[min(count - 1, w + 1)]),
    );
    if (peak > 0) gains[w] = min(gains[w], .95 / peak);
  }
  final output = Uint8List(44 + samples.length * 2);
  final out = ByteData.sublistView(output);
  void tag(int at, String text) => output.setRange(at, at + 4, text.codeUnits);
  tag(0, 'RIFF');
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  tag(36, 'data');
  out.setUint32(4, output.length - 8, Endian.little);
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little);
  out.setUint16(22, channels, Endian.little);
  out.setUint32(24, rate, Endian.little);
  out.setUint32(28, rate * channels * 2, Endian.little);
  out.setUint16(32, channels * 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  out.setUint32(40, samples.length * 2, Endian.little);
  for (var f = 0; f < frames; f++) {
    final w = f ~/ window;
    final fraction = (f % window) / window;
    final gain =
        gains[w] + (gains[min(count - 1, w + 1)] - gains[w]) * fraction;
    for (var c = 0; c < channels; c++) {
      final i = f * channels + c;
      out.setInt16(
        44 + i * 2,
        (samples[i] * gain * 32767).round().clamp(-32768, 32767),
        Endian.little,
      );
    }
  }
  return output;
}
