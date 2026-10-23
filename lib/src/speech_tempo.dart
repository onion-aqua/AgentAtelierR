import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'speech_tempo_wav.dart';

typedef SpeechFileTempoProcessor = Future<String> Function(
  String path, {
  required double speed,
  bool Function()? isCurrent,
});

/// A local processing failure never authorizes another paid generation.
class SpeechTempoException implements Exception {
  const SpeechTempoException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'SpeechTempoException($code): $message';
}

const _maximumAudioBytes = 64 * 1024 * 1024;

/// Changes speech duration without shifting its pitch, off the UI isolate.
/// The source remains owned by the caller. Only a successful returned WAV is
/// transferred to the caller; all intermediate/partial files are removed here.
Future<String> adjustSpeechFileTempo(
  String path, {
  required double speed,
  bool Function()? isCurrent,
}) async {
  if (!speed.isFinite) {
    throw const SpeechTempoException('invalid_speed', '语速必须为有效的有限数值。');
  }
  speed = speed.clamp(0.5, 2.0);
  void ensureCurrent() {
    if (!(isCurrent?.call() ?? true)) {
      throw const SpeechTempoException('tempo_cancelled', '语速处理已取消。');
    }
  }

  ensureCurrent();
  if (speed == 1.0) return path;
  final source = File(path);
  final inputLength = await source.length();
  ensureCurrent();
  if (inputLength < 12 || inputLength > _maximumAudioBytes) {
    throw const SpeechTempoException(
      'tempo_audio_size',
      '音频文件大小不符合本地语速处理限制，未重新生成语音。',
    );
  }
  final working = await source.parent.createTemp('.speech-tempo-');
  final staged = '${working.path}/adjusted.wav';
  // The temporary directory suffix is unique even for concurrent processing.
  final suffix = working.path.split(Platform.pathSeparator).last;
  final output = '$path.$suffix.wav';
  var completed = false;
  try {
    ensureCurrent();
    var supported = await compute(_adjustFile, (path, staged, speed));
    ensureCurrent();
    if (!supported && defaultTargetPlatform == TargetPlatform.android) {
      // Decode a private copy so concurrent callers cannot overwrite/delete
      // each other's native `$path.decoded.wav` intermediate file.
      final decodeSource = '${working.path}/source.audio';
      await source.copy(decodeSource);
      ensureCurrent();
      final decoded = await const MethodChannel(
        'agent_atelier_r/speech_envelope',
      ).invokeMethod<String>('decodeWav', {'path': decodeSource});
      ensureCurrent();
      final expected = '$decodeSource.decoded.wav';
      if (decoded == null ||
          File(decoded).absolute.path != File(expected).absolute.path) {
        throw const SpeechTempoException(
          'tempo_decode_failed',
          '未获得可用于保音高变速的解码音频，未重新生成语音。',
        );
      }
      supported = await compute(_adjustFile, (decoded, staged, speed));
      ensureCurrent();
    }
    if (!supported) {
      throw const SpeechTempoException(
        'tempo_decode_unsupported',
        '当前平台无法将此音频编码转换为保音高变速所需的 WAV；请使用原速或 WAV 输出。未重新生成语音。',
      );
    }
    await File(staged).rename(output);
    ensureCurrent();
    completed = true;
    return output;
  } finally {
    if (!completed) await _deleteFile(output);
    try {
      if (await working.exists()) await working.delete(recursive: true);
    } on FileSystemException {
      // Cache cleanup does not replace the processing result or error.
    }
  }
}

Future<bool> _adjustFile((String, String, double) request) async {
  final source = File(request.$1);
  final length = await source.length();
  if (length < 12 || length > _maximumAudioBytes) {
    throw const SpeechTempoException('tempo_audio_size', '音频超过本地语速处理限制。');
  }
  final bytes = await source.readAsBytes();
  if (bytes.length > _maximumAudioBytes) {
    throw const SpeechTempoException('tempo_audio_size', '音频超过本地语速处理限制。');
  }
  final result = changeSpeechWavTempo(bytes, speed: request.$3);
  if (result == null) return false;
  if (result.length < 44 || result.length > _maximumAudioBytes) {
    throw const SpeechTempoException('tempo_audio_size', '变速结果超过音频大小限制。');
  }
  await File(request.$2).writeAsBytes(result, flush: true);
  return true;
}

Future<void> _deleteFile(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // Best effort cache cleanup.
  }
}
