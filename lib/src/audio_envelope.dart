import 'dart:math';
import 'dart:typed_data';

class AudioAmplitudeEnvelope {
  const AudioAmplitudeEnvelope({
    required this.frameDuration,
    required this.values,
    this.rawRms = const [],
  });

  final Duration frameDuration;
  final List<double> values;
  final List<double> rawRms;

  double valueAt(Duration position) {
    if (values.isEmpty || position.isNegative) return 0;
    final frameMicros = frameDuration.inMicroseconds;
    if (frameMicros <= 0) return 0;
    if (position.inMicroseconds >= frameMicros * values.length) return 0;
    final exact = position.inMicroseconds / frameMicros;
    final lower = exact.floor().clamp(0, values.length - 1);
    final upper = (lower + 1).clamp(0, values.length - 1);
    final fraction = exact - exact.floor();
    return values[lower] + (values[upper] - values[lower]) * fraction;
  }

  static AudioAmplitudeEnvelope? tryParseWav(
    Uint8List bytes, {
    Duration frameDuration = const Duration(milliseconds: 20),
  }) {
    if (bytes.length < 44 ||
        _ascii(bytes, 0, 4) != 'RIFF' ||
        _ascii(bytes, 8, 4) != 'WAVE') {
      return null;
    }

    final data = ByteData.sublistView(bytes);
    var offset = 12;
    int? format;
    int? channels;
    int? sampleRate;
    int? bitsPerSample;
    int? dataOffset;
    int? dataLength;
    while (offset + 8 <= bytes.length) {
      final id = _ascii(bytes, offset, 4);
      final length = data.getUint32(offset + 4, Endian.little);
      final start = offset + 8;
      final end = min(start + length, bytes.length);
      if (id == 'fmt ' && end - start >= 16) {
        format = data.getUint16(start, Endian.little);
        channels = data.getUint16(start + 2, Endian.little);
        sampleRate = data.getUint32(start + 4, Endian.little);
        bitsPerSample = data.getUint16(start + 14, Endian.little);
      } else if (id == 'data') {
        dataOffset = start;
        dataLength = end - start;
      }
      offset = start + length + (length.isOdd ? 1 : 0);
    }

    if (format == null ||
        channels == null ||
        channels <= 0 ||
        sampleRate == null ||
        sampleRate <= 0 ||
        bitsPerSample == null ||
        dataOffset == null ||
        dataLength == null ||
        (format != 1 && format != 3)) {
      return null;
    }
    final bytesPerSample = (bitsPerSample / 8).ceil();
    if (bytesPerSample <= 0 || bytesPerSample > 4) return null;
    final bytesPerFrame = bytesPerSample * channels;
    final sampleFrames = dataLength ~/ bytesPerFrame;
    final samplesPerEnvelopeFrame = max(
      1,
      (sampleRate * frameDuration.inMicroseconds / 1000000).round(),
    );
    final raw = <double>[];
    for (
      var frameStart = 0;
      frameStart < sampleFrames;
      frameStart += samplesPerEnvelopeFrame
    ) {
      final frameEnd = min(frameStart + samplesPerEnvelopeFrame, sampleFrames);
      var sumSquares = 0.0;
      var count = 0;
      for (var frame = frameStart; frame < frameEnd; frame++) {
        for (var channel = 0; channel < channels; channel++) {
          final sampleOffset =
              dataOffset + frame * bytesPerFrame + channel * bytesPerSample;
          final sample = _readSample(data, sampleOffset, format, bitsPerSample);
          if (sample == null) return null;
          sumSquares += sample * sample;
          count += 1;
        }
      }
      raw.add(count == 0 ? 0 : sqrt(sumSquares / count));
    }
    if (raw.isEmpty) return null;

    return AudioAmplitudeEnvelope.fromRms(raw, frameDuration: frameDuration);
  }

  factory AudioAmplitudeEnvelope.fromRms(
    List<double> samples, {
    Duration frameDuration = const Duration(milliseconds: 20),
  }) {
    final raw = samples.map((v) => v.isFinite ? max(0.0, v) : 0.0).toList();
    if (raw.isEmpty) {
      return AudioAmplitudeEnvelope(
        frameDuration: frameDuration,
        values: const [],
      );
    }

    final sorted = [...raw]..sort();
    final peak =
        sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
    final noise = min(
      peak * 0.15,
      sorted[(sorted.length * 0.12).floor().clamp(0, sorted.length - 1)],
    );
    final range = max(peak - noise, 0.000001);
    final normalized = raw
        .map(
          (value) =>
              pow(((value - noise) / range).clamp(0.0, 1.0), 0.72).toDouble(),
        )
        .toList(growable: false);

    var smoothed = 0.0;
    final values = <double>[];
    for (final value in normalized) {
      // Mirrors the source gesture profile: fast attack and slower release.
      final factor = value > smoothed ? 0.85 : 0.65;
      smoothed += (value - smoothed) * factor;
      if (value < 0.02 && smoothed < 0.08) smoothed = 0;
      values.add(smoothed.clamp(0.0, 1.0));
    }
    return AudioAmplitudeEnvelope(
      frameDuration: frameDuration,
      // Follow real amplitude troughs; do not invent periodic silent frames.
      values: List<double>.unmodifiable(values),
      rawRms: List<double>.unmodifiable(raw),
    );
  }

  static double? _readSample(
    ByteData data,
    int offset,
    int format,
    int bitsPerSample,
  ) {
    if (format == 3 && bitsPerSample == 32) {
      return data.getFloat32(offset, Endian.little).clamp(-1.0, 1.0);
    }
    if (format != 1) return null;
    return switch (bitsPerSample) {
      8 => (data.getUint8(offset) - 128) / 128,
      16 => data.getInt16(offset, Endian.little) / 32768,
      24 => _readInt24(data, offset) / 8388608,
      32 => data.getInt32(offset, Endian.little) / 2147483648,
      _ => null,
    };
  }

  static int _readInt24(ByteData data, int offset) {
    var value =
        data.getUint8(offset) |
        (data.getUint8(offset + 1) << 8) |
        (data.getUint8(offset + 2) << 16);
    if ((value & 0x800000) != 0) value |= ~0xffffff;
    return value;
  }

  static String _ascii(Uint8List bytes, int offset, int length) =>
      String.fromCharCodes(bytes.sublist(offset, offset + length));
}
