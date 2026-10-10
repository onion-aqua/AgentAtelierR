import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'runtime_log.dart';

const _maximumSpeechBytes = 64 * 1024 * 1024;

/// Prepare and start cached speech, checking cancellation between each await.
/// Android's file source can fail on some devices even for a readable WAV;
/// retry that preparation once through MediaDataSource with the same bytes.
/// The caller owns the player's lifetime and the file's cleanup.
/// [onPrepared] runs before resuming so callers can handle playback errors
/// emitted while the native resume call is still in progress.
Future<bool> playSpeechFile(
  AudioPlayer player,
  String path, {
  double? volume,
  bool Function()? isCurrent,
  VoidCallback? onPrepared,
}) async {
  bool current() => isCurrent?.call() ?? true;
  if (!current()) return false;
  final file = File(path);
  final exists = await file.exists();
  if (!current()) return false;
  if (!exists) {
    throw const FileSystemException('语音缓存不存在，请重新生成语音');
  }
  final length = await file.length();
  if (!current()) return false;
  if (length == 0 || length > _maximumSpeechBytes) {
    throw const FileSystemException('语音缓存为空或超出大小限制，请重新生成语音');
  }
  if (volume != null) {
    await player.setVolume(volume);
    if (!current()) return false;
  }
  try {
    await player.setSource(DeviceFileSource(path));
  } on PlatformException catch (error) {
    if (!current()) return false;
    if (defaultTargetPlatform != TargetPlatform.android ||
        error.code != 'AndroidAudioError') {
      rethrow;
    }
    final name = path.split(RegExp(r'[/\\]')).last;
    RuntimeLog.instance.warning(
      'TTS playback',
      '本地语音来源准备失败，使用音频字节重试：file=$name, bytes=$length, '
          'code=${error.code}',
    );
    await player.release();
    if (!current()) return false;
    final bytes = await file.readAsBytes();
    if (!current()) return false;
    if (bytes.isEmpty || bytes.length > _maximumSpeechBytes) {
      throw const FileSystemException('语音缓存为空或超出大小限制，请重新生成语音');
    }
    await player.setSource(BytesSource(bytes));
  }
  if (!current()) return false;
  onPrepared?.call();
  if (!current()) return false;
  await player.resume();
  return current();
}
