import 'dart:math' as math;
import 'dart:typed_data';

/// Limits apply independently to the supplied file, decoded sample buffer and
/// resulting file. Peak owned buffers are therefore below 192 MiB, including
/// the caller's input; the small correlation/window buffers are also bounded.
const speechTempoMaximumBytes = 64 * 1024 * 1024;
const speechTempoMaximumDuration = Duration(minutes: 10);

/// Changes speech tempo with waveform similarity overlap/add (WSOLA).
///
/// The sample rate stays unchanged. All channels share one alignment search and
/// crossfade, preserving their separation and relative phase. A 40 ms waveform
/// window, 20 ms overlap and bounded 12 ms alignment search retain voice pitch;
/// this does not obtain slower speech by lowering the sample rate. Very short
/// clips use proportionally smaller windows; clips of only a few samples have
/// no resolvable pitch. The first and last waveform windows are anchored so the
/// final syllable is not dropped or replaced by a loop of an earlier fragment.
///
/// Accepts little endian PCM 8/16/24/32 or IEEE float32 WAV, 1–8 channels and
/// 8–192 kHz. Returns a standard PCM16 WAV, or null for an unsupported/damaged
/// file or a limit violation. Valid PCM16 at speed 1 is returned unchanged.
/// Input/output durations must each be at most ten minutes, and the input,
/// decoded float buffer and output are each capped at 64 MiB. Processing is
/// synchronous; file wrappers should run it outside Flutter's UI isolate.
Uint8List? changeSpeechWavTempo(Uint8List bytes, {required double speed}) {
  if (!speed.isFinite || speed < .5 || speed > 2) {
    throw ArgumentError.value(speed, 'speed', 'Must be finite and within .5–2');
  }
  final wav = _TempoWav.parse(bytes);
  if (wav == null) return null;
  final frames = wav.frames;
  final targetFrames = math.max(1, (frames / speed).round());
  final sampleCount = frames * wav.channels;
  final outputLength = 44 + targetFrames * wav.channels * 2;
  if (frames * 1000 > wav.rate * speechTempoMaximumDuration.inMilliseconds ||
      targetFrames * 1000 >
          wav.rate * speechTempoMaximumDuration.inMilliseconds ||
      sampleCount * 4 > speechTempoMaximumBytes ||
      outputLength > speechTempoMaximumBytes) {
    return null;
  }
  if (speed == 1 && wav.format == 1 && wav.bits == 16) return bytes;

  final source = wav.decode(bytes);
  if (source == null) return null;
  final output = Uint8List(outputLength);
  final destination = ByteData.sublistView(output);
  _writeHeader(destination, targetFrames, wav.channels, wav.rate);

  void writeSample(int frame, int channel, double value) {
    destination.setInt16(
      44 + (frame * wav.channels + channel) * 2,
      (value * 32768).round().clamp(-32768, 32767),
      Endian.little,
    );
  }

  if (speed == 1) {
    for (var frame = 0; frame < frames; frame++) {
      for (var channel = 0; channel < wav.channels; channel++) {
        writeSample(frame, channel, source[frame * wav.channels + channel]);
      }
    }
    return output;
  }

  // Keep at least two grains for short clips, while using a speech-sized grain
  // for normal audio. Even one-sample clips remain bounded and well defined.
  final minimumFrames = math.min(frames, targetFrames);
  final window = math.min(
    (wav.rate * .04).round(),
    math.max(1, minimumFrames ~/ 2),
  );
  final overlap = window ~/ 2;
  final hop = math.max(1, window - overlap);
  final lastOutputStart = targetFrames - window;
  final lastSourceStart = frames - window;
  final searchRadius = math.min(
    (wav.rate * .012).round(),
    math.max(1, window ~/ 2),
  );
  // Only the alignment score is decimated; actual audio is never decimated.
  // Coarse/fine search keeps candidate counts bounded as sample rate grows.
  final coarseStep = math.max(1, wav.rate ~/ 6000);
  final scoreStride = math.max(1, overlap ~/ 64);
  final reference = Float32List(
    ((overlap + scoreStride - 1) ~/ scoreStride) * wav.channels,
  );
  final normalFade = _crossfade(overlap);

  void addWindow(int sourceStart, int outputStart, int overlapFrames) {
    final fade = overlapFrames == overlap
        ? normalFade
        : _crossfade(overlapFrames);
    for (var frame = 0; frame < window; frame++) {
      final sourceOffset = (sourceStart + frame) * wav.channels;
      for (var channel = 0; channel < wav.channels; channel++) {
        var sample = source[sourceOffset + channel].toDouble();
        if (frame < overlapFrames) {
          final old =
              destination.getInt16(
                44 + ((outputStart + frame) * wav.channels + channel) * 2,
                Endian.little,
              ) /
              32768;
          sample = old + (sample - old) * fade[frame];
        }
        writeSample(outputStart + frame, channel, sample);
      }
    }
  }

  int chooseStart(int nominal, int outputStart, int previousSourceStart) {
    if (overlap == 0) return nominal;
    var count = 0;
    var referenceEnergy = 0.0;
    for (var frame = 0; frame < overlap; frame += scoreStride) {
      for (var channel = 0; channel < wav.channels; channel++) {
        final value =
            destination.getInt16(
              44 + ((outputStart + frame) * wav.channels + channel) * 2,
              Endian.little,
            ) /
            32768;
        reference[count++] = value;
        referenceEnergy += value * value;
      }
    }
    // Silence has no phase to align. Following the nominal position prevents
    // arbitrary jumps through quiet sections and needless correlation work.
    if (referenceEnergy < count * 1e-10) {
      return math.max(previousSourceStart, nominal);
    }
    final lower = math.max(previousSourceStart, nominal - searchRadius);
    final upper = math.min(lastSourceStart, nominal + searchRadius);
    var best = nominal.clamp(lower, upper);
    var bestScore = -double.infinity;

    void assess(int candidate) {
      var dot = 0.0;
      var energy = 0.0;
      var index = 0;
      for (var frame = 0; frame < overlap; frame += scoreStride) {
        final at = (candidate + frame) * wav.channels;
        for (var channel = 0; channel < wav.channels; channel++) {
          final sample = source[at + channel];
          dot += reference[index++] * sample;
          energy += sample * sample;
        }
      }
      if (energy <= 1e-20) return;
      // Prefer the expected time when multiple periodic alignments are equal.
      // This also stops a sustained vowel pulling later words off the timeline.
      final score =
          dot / math.sqrt(referenceEnergy * energy) -
          (candidate - nominal).abs() / (searchRadius + 1) * .015;
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }

    assess(best);
    for (var candidate = lower; candidate <= upper; candidate += coarseStep) {
      assess(candidate);
    }
    assess(upper);
    final coarseBest = best;
    for (
      var candidate = math.max(lower, coarseBest - coarseStep);
      candidate <= math.min(upper, coarseBest + coarseStep);
      candidate++
    ) {
      assess(candidate);
    }
    return best;
  }

  addWindow(0, 0, 0);
  var previousOutputStart = 0;
  var previousSourceStart = 0;
  for (
    var outputStart = hop;
    outputStart < lastOutputStart;
    outputStart += hop
  ) {
    // Map both endpoints exactly rather than repeatedly clamping source time
    // near the end, which would otherwise repeat the final vowel when slowed.
    final nominal = (outputStart * lastSourceStart / lastOutputStart).round();
    final sourceStart = chooseStart(nominal, outputStart, previousSourceStart);
    addWindow(sourceStart, outputStart, overlap);
    previousSourceStart = sourceStart;
    previousOutputStart = outputStart;
  }
  if (lastOutputStart > 0) {
    final finalOverlap = math.max(
      0,
      previousOutputStart + window - lastOutputStart,
    );
    addWindow(lastSourceStart, lastOutputStart, finalOverlap);
  }
  return output;
}

Float32List _crossfade(int length) => Float32List.fromList([
  for (var frame = 0; frame < length; frame++)
    length == 1 ? .5 : .5 - .5 * math.cos(math.pi * frame / (length - 1)),
]);

void _writeHeader(ByteData data, int frames, int channels, int rate) {
  void id(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      data.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  id(0, 'RIFF');
  data.setUint32(4, data.lengthInBytes - 8, Endian.little);
  id(8, 'WAVE');
  id(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  id(36, 'data');
  data.setUint32(40, frames * channels * 2, Endian.little);
}

class _TempoWav {
  const _TempoWav({
    required this.format,
    required this.channels,
    required this.rate,
    required this.bits,
    required this.start,
    required this.length,
  });

  final int format, channels, rate, bits, start, length;
  int get frames => length ~/ (channels * (bits ~/ 8));

  static _TempoWav? parse(Uint8List bytes) {
    if (bytes.length < 44 || bytes.length > speechTempoMaximumBytes) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    bool id(int offset, String text) {
      for (var index = 0; index < text.length; index++) {
        if (bytes[offset + index] != text.codeUnitAt(index)) return false;
      }
      return true;
    }

    if (!id(0, 'RIFF') || !id(8, 'WAVE')) return null;
    final riffEnd = data.getUint32(4, Endian.little) + 8;
    if (riffEnd < 44 || riffEnd > bytes.length) return null;
    int? format, channels, rate, bits, start, length;
    var offset = 12;
    while (offset + 8 <= riffEnd) {
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      final end = body + size;
      if (end > riffEnd) return null;
      if (id(offset, 'fmt ')) {
        if (format != null || size < 16) return null;
        format = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        rate = data.getUint32(body + 4, Endian.little);
        bits = data.getUint16(body + 14, Endian.little);
        if (channels < 1 || channels > 8 || rate < 8000 || rate > 192000) {
          return null;
        }
        if (!(format == 1 && const [8, 16, 24, 32].contains(bits)) &&
            !(format == 3 && bits == 32)) {
          return null;
        }
        final block = channels * (bits ~/ 8);
        if (data.getUint16(body + 12, Endian.little) != block ||
            data.getUint32(body + 8, Endian.little) != rate * block) {
          return null;
        }
      } else if (id(offset, 'data')) {
        if (start != null || size == 0) return null;
        start = body;
        length = size;
      }
      offset = end + (size & 1);
    }
    if (offset != riffEnd ||
        format == null ||
        channels == null ||
        rate == null ||
        bits == null ||
        start == null ||
        length == null ||
        length % (channels * (bits ~/ 8)) != 0) {
      return null;
    }
    return _TempoWav(
      format: format,
      channels: channels,
      rate: rate,
      bits: bits,
      start: start,
      length: length,
    );
  }

  Float32List? decode(Uint8List bytes) {
    final count = frames * channels;
    final samples = Float32List(count);
    final data = ByteData.sublistView(bytes);
    final sampleBytes = bits ~/ 8;
    for (var index = 0; index < count; index++) {
      final offset = start + index * sampleBytes;
      double value;
      if (format == 3) {
        value = data.getFloat32(offset, Endian.little);
        if (!value.isFinite) return null;
        value = value.clamp(-1.0, 1.0);
      } else if (bits == 8) {
        value = (data.getUint8(offset) - 128) / 128;
      } else if (bits == 16) {
        value = data.getInt16(offset, Endian.little) / 32768;
      } else if (bits == 24) {
        var integer =
            data.getUint8(offset) |
            (data.getUint8(offset + 1) << 8) |
            (data.getUint8(offset + 2) << 16);
        if ((integer & 0x800000) != 0) integer -= 0x1000000;
        value = integer / 8388608;
      } else {
        value = data.getInt32(offset, Endian.little) / 2147483648;
      }
      samples[index] = value;
    }
    return samples;
  }
}
