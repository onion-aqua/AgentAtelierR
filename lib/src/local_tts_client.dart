import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_localization.dart';
import 'local_tts_models.dart';
import 'local_tts_japanese.dart';

class LocalTtsClient {
  LocalTtsClient._();

  static final instance = LocalTtsClient._();

  Future<String> synthesize({
    required String text,
    required AppLanguage preferredLanguage,
    String? voiceProfileId,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('CosyVoice 3 当前仅支持 Android');
    }
    if (localTtsLanguageForText(text, preferredLanguage) == null) {
      throw const FormatException('本地语音目前只支持中文和日文台词');
    }
    var selected = voiceProfileId?.trim() ?? '';
    LocalTtsVoice? selectedVoice;
    if (selected.isNotEmpty) {
      final status = await LocalTtsModelStore.instance.status();
      selectedVoice = status.voices
          .where((voice) => voice.id == selected)
          .firstOrNull;
      if (selectedVoice == null) {
        final builtIns = status.voices.where((voice) => voice.builtIn);
        if (builtIns.isEmpty) {
          throw const FormatException('已保存的音色不存在，且没有可用的内置音色');
        }
        selectedVoice = builtIns.first;
        selected = selectedVoice.id;
      }
    }
    final language = localTtsLanguageForText(text, preferredLanguage);
    final speechText = language == LocalTtsLanguage.japanese
        ? await normalizeJapaneseForCosyVoice3(
            text,
            preferredLanguage: preferredLanguage,
          )
        : text.trim();
    String? voicePromptText;
    final promptText = selectedVoice?.promptText;
    if (language == LocalTtsLanguage.japanese &&
        promptText != null &&
        containsJapaneseKana(promptText)) {
      voicePromptText = await normalizeJapaneseForCosyVoice3(
        promptText,
        preferredLanguage: preferredLanguage,
      );
    }
    final path = await LocalTtsModelStore.channel.invokeMethod<String>(
      'synthesize',
      {
        'text': speechText,
        if (selected.isNotEmpty) 'voiceId': selected,
        if (voicePromptText != null &&
            voicePromptText != selectedVoice?.promptText)
          'voicePromptText': voicePromptText,
      },
    );
    if (path == null || path.isEmpty) {
      throw const FormatException('CosyVoice 3 未返回音频文件');
    }
    final output = File(path);
    if (!await output.exists() || await output.length() < 44) {
      throw const FormatException('CosyVoice 3 未生成有效音频');
    }
    return path;
  }
}
