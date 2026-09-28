import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_localization.dart';
import 'local_tts_japanese.dart';

enum LocalTtsLanguage { chinese, japanese }

LocalTtsLanguage? localTtsLanguageForText(String text, AppLanguage preferred) {
  if (RegExp(r'[\u3040-\u30ff]').hasMatch(text)) {
    return LocalTtsLanguage.japanese;
  }
  if (RegExp(r'[\u3400-\u9fff]').hasMatch(text)) {
    return preferred == AppLanguage.japanese
        ? LocalTtsLanguage.japanese
        : LocalTtsLanguage.chinese;
  }
  return null;
}

class LocalTtsVoice {
  const LocalTtsVoice({
    required this.id,
    required this.name,
    required this.builtIn,
    this.promptText,
  });

  final String id;
  final String name;
  final bool builtIn;
  final String? promptText;

  factory LocalTtsVoice.fromPlatform(Object? value) {
    if (value is! Map) throw const FormatException('音色数据格式不正确');
    final id = value['id'];
    final name = value['name'];
    final builtIn = value['builtIn'];
    if (id is! String || id.isEmpty || name is! String || builtIn is! bool) {
      throw const FormatException('音色数据不完整');
    }
    final promptText = value['promptText'];
    return LocalTtsVoice(
      id: id,
      name: name,
      builtIn: builtIn,
      promptText: promptText is String && promptText.isNotEmpty
          ? promptText
          : null,
    );
  }
}

class LocalTtsStatus {
  const LocalTtsStatus({
    required this.supported,
    required this.modelReady,
    required this.enrollmentReady,
    required this.modelBytes,
    required this.voices,
    required this.selectedVoiceId,
  });

  final bool supported;
  final bool modelReady;
  final bool enrollmentReady;
  final int modelBytes;
  final List<LocalTtsVoice> voices;
  final String selectedVoiceId;

  factory LocalTtsStatus.fromPlatform(Object? value) {
    if (value is! Map) throw const FormatException('模型状态格式不正确');
    final supported = value['supported'];
    final modelReady = value['modelReady'];
    final enrollmentReady = value['enrollmentReady'];
    final modelBytes = value['modelBytes'];
    final voices = value['voices'];
    final selectedVoiceId = value['selectedVoiceId'];
    if ((supported != null && supported is! bool) ||
        modelReady is! bool ||
        enrollmentReady is! bool ||
        modelBytes is! num ||
        voices is! List ||
        selectedVoiceId is! String) {
      throw const FormatException('模型状态不完整');
    }
    return LocalTtsStatus(
      supported: supported as bool? ?? true,
      modelReady: modelReady,
      enrollmentReady: enrollmentReady,
      modelBytes: modelBytes.toInt(),
      voices: List.unmodifiable(voices.map(LocalTtsVoice.fromPlatform)),
      selectedVoiceId: selectedVoiceId,
    );
  }
}

class LocalTtsProgress {
  const LocalTtsProgress({required this.stage, required this.progress});

  final String stage;
  final double progress;

  factory LocalTtsProgress.fromPlatform(Object? value) {
    if (value is! Map ||
        value['stage'] is! String ||
        value['progress'] is! num) {
      throw const FormatException('模型下载进度格式不正确');
    }
    return LocalTtsProgress(
      stage: value['stage'] as String,
      progress: (value['progress'] as num).toDouble().clamp(0.0, 1.0),
    );
  }
}

class LocalTtsModelStore {
  LocalTtsModelStore._();

  static final instance = LocalTtsModelStore._();
  static const channel = MethodChannel('agent_atelier_r/cosyvoice3');
  static const progressChannel = EventChannel(
    'agent_atelier_r/cosyvoice3_progress',
  );
  Future<void>? _legacyCleanup;

  static void _requireAndroid() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('CosyVoice 3 当前仅支持 Android');
    }
  }

  Stream<LocalTtsProgress> get progress => progressChannel
      .receiveBroadcastStream()
      .map(LocalTtsProgress.fromPlatform);

  Future<LocalTtsStatus> status() async {
    _requireAndroid();
    final result = LocalTtsStatus.fromPlatform(
      await channel.invokeMethod('status'),
    );
    if (Platform.isAndroid && result.modelReady) {
      _legacyCleanup ??= _removeLegacyModels();
      unawaited(_legacyCleanup!);
    }
    return result;
  }

  Future<bool> isReadyFor(String text, AppLanguage preferred) async {
    if (defaultTargetPlatform != TargetPlatform.android ||
        localTtsLanguageForText(text, preferred) == null) {
      return false;
    }
    return (await status()).modelReady;
  }

  Future<void> downloadModel() async {
    _requireAndroid();
    await channel.invokeMethod<Object?>('downloadModel');
  }

  Future<void> downloadEnrollment() async {
    _requireAndroid();
    await channel.invokeMethod<Object?>('downloadEnrollment');
  }

  Future<void> importModel(String path) async {
    _requireAndroid();
    await channel.invokeMethod<Object?>('importModel', {'path': path});
  }

  Future<void> importEnrollment(String path) async {
    _requireAndroid();
    await channel.invokeMethod<Object?>('importEnrollment', {'path': path});
  }

  Future<LocalTtsVoice> enroll({
    required String audioPath,
    required double startSeconds,
    required double endSeconds,
    required String promptText,
    required String name,
    AppLanguage preferredLanguage = AppLanguage.chinese,
  }) async {
    _requireAndroid();
    if (endSeconds - startSeconds < 3 || endSeconds - startSeconds > 5) {
      throw const FormatException('参考音频片段须为 3–5 秒');
    }
    if (promptText.trim().isEmpty || name.trim().isEmpty) {
      throw const FormatException('请填写参考音频文本和音色名称');
    }
    final normalizedPrompt =
        localTtsLanguageForText(promptText, preferredLanguage) ==
            LocalTtsLanguage.japanese
        ? await normalizeJapaneseForCosyVoice3(
            promptText,
            preferredLanguage: preferredLanguage,
          )
        : promptText.trim();
    return LocalTtsVoice.fromPlatform(
      await channel.invokeMethod('enroll', {
        'audioPath': audioPath,
        'startSeconds': startSeconds,
        'endSeconds': endSeconds,
        'promptText': normalizedPrompt,
        'name': name.trim(),
      }),
    );
  }

  Future<void> selectVoice(String id) async {
    _requireAndroid();
    await channel.invokeMethod<Object?>('selectVoice', {'id': id});
  }

  Future<void> deleteVoice(String id) async {
    _requireAndroid();
    await channel.invokeMethod<Object?>('deleteVoice', {'id': id});
  }

  Future<void> deleteModel() async {
    _requireAndroid();
    await channel.invokeMethod<Object?>('deleteModel');
  }

  Future<void> deleteEnrollment() async {
    _requireAndroid();
    await channel.invokeMethod<Object?>('deleteEnrollment');
  }

  Future<void> _removeLegacyModels() async {
    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory(
        '${support.path}${Platform.pathSeparator}local_tts',
      );
      for (final name in const [
        'kokoro-int8-multi-lang-v1_1',
        'sherpa-onnx-supertonic-3-tts-int8-2026-05-11',
      ]) {
        final directory = Directory(
          '${root.path}${Platform.pathSeparator}$name',
        );
        final marker = File(
          '${directory.path}${Platform.pathSeparator}.installed',
        );
        if (await marker.exists() &&
            (await marker.readAsString()).trim() == name) {
          await directory.delete(recursive: true);
        }
      }
    } on Object {
      // A failed cleanup must not prevent synthesis.
    }
  }
}
