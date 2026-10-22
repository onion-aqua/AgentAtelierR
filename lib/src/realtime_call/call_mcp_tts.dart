import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter/services.dart';

import '../audio_envelope.dart';
import '../fish_drama3_tags.dart';
import '../fish_mcp_service.dart';
import '../tts_audio_quality.dart';
import '../tts_duration_guard.dart';
import '../tts_text_normalizer.dart';

/// The shared MCP client owns OAuth, Studio model routing, and paid-call rules.
/// This adapter only converts its completed local file to the call PCM format.
class FishMcpCallRequest {
  const FishMcpCallRequest({
    required this.text,
    required this.voice,
    required this.model,
    required this.language,
    required this.speed,
    required this.isCurrent,
  });

  final String text, voice, model, language;
  final double speed;
  final bool Function() isCurrent;
}

typedef FishMcpCallSynthesis = Future<String> Function(
  FishMcpCallRequest request,
);

class FishMcpCallTtsClient {
  FishMcpCallTtsClient({
    FishMcpService? service,
    FishMcpCallSynthesis? synthesizeFile,
    Future<String?> Function(String path)? decodeWav,
    bool Function()? isAndroid,
  }) : _synthesizeFile =
           synthesizeFile ??
           ((request) => (service ?? FishMcpService.instance).synthesize(
             text: request.text,
             voice: request.voice,
             model: request.model,
             language: request.language,
             format: 'wav',
             // The shared service sends speed only when its schema exposes it.
             speed: request.speed,
             isCurrent: request.isCurrent,
           )),
       _decodeWav =
           decodeWav ??
           ((path) =>
               const MethodChannel('agent_atelier_r/speech_envelope')
                   .invokeMethod<String>('decodeWav', {'path': path})),
       _isAndroid = isAndroid ?? (() => Platform.isAndroid);

  final FishMcpCallSynthesis _synthesizeFile;
  final Future<String?> Function(String path) _decodeWav;
  final bool Function() _isAndroid;

  FishMcpCallTtsStream synthesize({
    required String text,
    required String voiceId,
    required String model,
    required String language,
    double speed = 1,
    bool Function()? isCurrent,
  }) => FishMcpCallTtsStream._(
    text: text,
    voice: voiceId,
    model: model,
    language: language,
    speed: speed,
    synthesizeFile: _synthesizeFile,
    decodeWav: _decodeWav,
    isAndroid: _isAndroid,
    isCurrent: isCurrent,
  );
}

/// MCP returns a completed audio clip, not live PCM. Cancellation invalidates
/// it immediately without disconnecting the application's shared MCP session.
/// A submitted cloud generation may still cost credits; it is never repeated.
class FishMcpCallTtsStream {
  FishMcpCallTtsStream._({
    required String text,
    required String voice,
    required String model,
    required String language,
    required double speed,
    required this._synthesizeFile,
    required this._decodeWav,
    required this._isAndroid,
    bool Function()? isCurrent,
  }) : _externalCurrent = isCurrent {
    _request = FishMcpCallRequest(
      text: text,
      voice: voice,
      model: model,
      language: language,
      speed: speed,
      isCurrent: () => _current,
    );
    _output = StreamController<Uint8List>(
      onListen: () => unawaited(_run()),
      onPause: () => _resume ??= Completer<void>(),
      onResume: _releasePause,
      onCancel: cancel,
    );
  }

  final FishMcpCallSynthesis _synthesizeFile;
  final Future<String?> Function(String path) _decodeWav;
  final bool Function() _isAndroid;
  final bool Function()? _externalCurrent;
  late final FishMcpCallRequest _request;
  late final StreamController<Uint8List> _output;
  Completer<void>? _resume;
  bool _cancelled = false;

  Stream<Uint8List> get pcm => _output.stream;
  bool get _current => !_cancelled && (_externalCurrent?.call() ?? true);

  void _releasePause() {
    final resume = _resume;
    _resume = null;
    if (resume != null && !resume.isCompleted) resume.complete();
  }

  Future<void> cancel() async {
    _cancelled = true;
    _releasePause();
    if (!_output.isClosed) unawaited(_output.close());
  }

  Future<void> _run() async {
    final temporaryFiles = <String>{};
    var completedGeneration = false;
    try {
      if (!_current) return;
      final path = await _synthesizeFile(_request);
      completedGeneration = true;
      temporaryFiles.add(path);
      if (!_current) return;
      var pcm = await _readPcm(path);
      if (!_current) return;
      if (pcm == null) {
        if (!_isAndroid()) throw const FormatException();
        // Reuse the existing MediaCodec worker; do not request another clip.
        temporaryFiles.add('$path.decoded.wav');
        final decoded = await _decodeWav(path);
        if (decoded != null) temporaryFiles.add(decoded);
        if (!_current) return;
        if (decoded == null) throw const FormatException();
        pcm = await _readPcm(decoded);
        if (pcm == null) throw const FormatException();
      }
      // Each write is 80 ms of 24 kHz PCM16 mono. Honor consumer pauses so
      // AudioTrack backpressure does not enqueue a full clip in the stream.
      for (var offset = 0; offset < pcm.length; offset += 3840) {
        final resume = _resume;
        if (resume != null) await resume.future;
        if (!_current) return;
        _output.add(
          Uint8List.sublistView(
            pcm,
            offset,
            math.min(offset + 3840, pcm.length),
          ),
        );
        await Future<void>.value();
      }
    } on Object catch (error, stack) {
      if (_current && !_output.isClosed) {
        _output.addError(
          error is FishMcpException
              ? error
              : FishMcpException(
                  stage: 'call_audio_decode',
                  code: 'call_audio_decode_failed',
                  message: 'Fish MCP 通话语音无法转换为有效音频，未重新生成或回退 API。',
                  generationSubmitted: true,
                  outcomeUnknown: !completedGeneration,
                ),
          stack,
        );
      }
    } finally {
      for (final path in temporaryFiles) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // Cache cleanup cannot replace the generation result or error.
        }
      }
      if (!_output.isClosed) unawaited(_output.close());
    }
  }

  Future<Uint8List?> _readPcm(String path) async {
    final file = File(path);
    final length = await file.length();
    if (length < 44 || length > 64 * 1024 * 1024) {
      throw const FormatException();
    }
    final bytes = await file.readAsBytes();
    if (!_current) return null;
    return compute(_decodeCallPcm, (
      bytes: bytes,
      text: _request.text,
      language: _request.language,
    ));
  }
}

Uint8List? _decodeCallPcm(
  ({Uint8List bytes, String text, String language}) request,
) => mcpCallWavToPcm24k(
  request.bytes,
  text: request.text,
  language: request.language,
);

/// Existing WAV validation establishes the frame layout and exact duration.
/// Mono conversion averages channels; bounded rate conversion preserves time.
@visibleForTesting
Uint8List? mcpCallWavToPcm24k(
  Uint8List bytes, {
  required String text,
  required String language,
}) {
  final envelope = AudioAmplitudeEnvelope.tryParseWav(bytes);
  if (envelope == null) return null;
  validateSpeechSignal(envelope);
  final assessment = assessTtsAudioDuration(
    TtsDurationContext(
      text: stripFishDrama3Tags(normalizeFishAudioSynthesisText(text)),
      languageCode: language,
      effectiveSpeed: 1,
    ),
    envelope.duration!,
  );
  if (assessment.isOverlong ||
      envelope.duration! > const Duration(minutes: 2)) {
    throw FishMcpException(
      stage: 'audio_validation',
      code: 'audio_too_long',
      message: 'Fish MCP 返回的通话语音明显过长，已停止本段；未重新生成或回退 API。',
      generationSubmitted: true,
    );
  }

  final data = ByteData.sublistView(bytes);
  final riffEnd = data.getUint32(4, Endian.little) + 8;
  var format = 0, channels = 0, rate = 0, bits = 0, start = 0, length = 0;
  for (var offset = 12; offset + 8 <= riffEnd;) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      format = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      rate = data.getUint32(body + 4, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      start = body;
      length = size;
    }
    offset = body + size + (size & 1);
  }
  if (channels == 1 && rate == 24000 && format == 1 && bits == 16) {
    return Uint8List.fromList(bytes.sublist(start, start + length));
  }
  final sampleBytes = bits ~/ 8;
  final frames = length ~/ (sampleBytes * channels);
  final mono = Float32List(frames);
  for (var frame = 0; frame < frames; frame++) {
    var sum = 0.0;
    for (var channel = 0; channel < channels; channel++) {
      final at = start + (frame * channels + channel) * sampleBytes;
      final double sample;
      if (format == 3) {
        sample = data.getFloat32(at, Endian.little).clamp(-1.0, 1.0);
      } else if (bits == 8) {
        sample = (data.getUint8(at) - 128) / 128;
      } else if (bits == 16) {
        sample = data.getInt16(at, Endian.little) / 32768;
      } else if (bits == 24) {
        var value =
            data.getUint8(at) |
            (data.getUint8(at + 1) << 8) |
            (data.getUint8(at + 2) << 16);
        if ((value & 0x800000) != 0) value -= 0x1000000;
        sample = value / 8388608;
      } else {
        sample = data.getInt32(at, Endian.little) / 2147483648;
      }
      sum += sample;
    }
    mono[frame] = sum / channels;
  }
  final outputFrames = (frames * 24000 / rate).round();
  if (outputFrames <= 0) throw const FormatException();
  final output = Uint8List(outputFrames * 2);
  final destination = ByteData.sublistView(output);
  for (var frame = 0; frame < outputFrames; frame++) {
    double sample;
    if (rate > 24000) {
      // Weighted box filtering before decimation reduces high-frequency aliasing.
      final left = frame * rate / 24000;
      final right = math.min((frame + 1) * rate / 24000, frames.toDouble());
      var sum = 0.0;
      for (var source = left.floor(); source < right; source++) {
        final weight =
            math.min(right, source + 1.0) - math.max(left, source.toDouble());
        sum += mono[math.min(source, frames - 1)] * weight;
      }
      sample = sum / (right - left);
    } else {
      final position = (frame * rate / 24000).clamp(0.0, frames - 1.0);
      final lower = position.floor();
      final upper = math.min(lower + 1, frames - 1);
      sample = mono[lower] + (mono[upper] - mono[lower]) * (position - lower);
    }
    destination.setInt16(
      frame * 2,
      (sample * 32768).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return output;
}
