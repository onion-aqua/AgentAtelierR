import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'mimo_tts_config.dart';
import 'qwen_tts_config.dart';

/// Retires saved voice overrides once, without discarding provider settings or
/// local reference audio. Backups carry the revision so later user overrides
/// survive exports, imports and character switches.
class TtsVoiceSettingsMigration {
  static const revision = 1;
  static const preferenceKey = 'tts_voice_settings_revision_v1';
  static const backupKey = 'voiceSettingsRevision';

  static String defaultQwenVoice(String model) {
    if (!QwenTtsConfig.isModernModel(model)) return 'Cherry';
    final voices = QwenTtsConfig.voicesForModel(model);
    return voices.isEmpty ? '' : voices.first;
  }

  static Future<void> migratePreferences(SharedPreferences preferences) async {
    if ((preferences.getInt(preferenceKey) ?? 0) >= revision) return;

    final writes = <Future<bool>>[
      for (final key in const [
        'fish_audio_reference_id',
        'fish_audio_asmr_reference_id',
        'fish_mcp_voice',
        'fish_mcp_asmr_voice',
        'dashscope_tts_asmr_voice',
        'generic_tts_voice',
        'generic_tts_asmr_voice',
      ])
        if (preferences.containsKey(key)) preferences.remove(key),
      preferences.setString(
        'dashscope_tts_voice',
        defaultQwenVoice(
          preferences.getString('dashscope_tts_model') ?? 'qwen3-tts-flash',
        ),
      ),
    ];
    final rawMimo = preferences.getString('mimo_tts_config');
    if (rawMimo != null) {
      try {
        final decoded = jsonDecode(rawMimo);
        if (decoded is Map) {
          writes.add(
            preferences.setString(
              'mimo_tts_config',
              jsonEncode({...decoded, 'voice': const MimoTtsConfig().voice}),
            ),
          );
        }
      } on FormatException {
        // The regular restore path already handles damaged provider JSON.
      }
    }
    final rawSessions = preferences.getString('character_sessions_v1');
    if (rawSessions != null) {
      try {
        final sessions = jsonDecode(rawSessions);
        if (sessions is Map) {
          writes.add(
            preferences.setString(
              'character_sessions_v1',
              jsonEncode({
                for (final entry in sessions.entries)
                  entry.key: entry.value is Map
                      ? normalizeBackup(
                          Map<String, dynamic>.from(entry.value as Map),
                        )
                      : entry.value,
              }),
            ),
          );
        }
      } on FormatException {
        // Preserve damaged session data for the normal recovery path.
      }
    }
    final rawCalls = preferences.getString('realtime_call_settings_v1');
    if (rawCalls != null) {
      try {
        final calls = jsonDecode(rawCalls);
        if (calls is Map && calls.containsKey('voiceOverrides')) {
          writes.add(
            preferences.setString(
              'realtime_call_settings_v1',
              jsonEncode({...calls, 'voiceOverrides': <String, String>{}}),
            ),
          );
        }
      } on FormatException {
        // Leave damaged call JSON to the existing settings recovery path.
      }
    }
    if ((await Future.wait(writes)).any((saved) => !saved)) {
      throw StateError('音色设置迁移未保存，请重新启动后重试');
    }
    if (!await preferences.setInt(preferenceKey, revision)) {
      throw StateError('音色设置迁移标记未保存，请重新启动后重试');
    }
  }

  static Map<String, dynamic> normalizeBackup(Map<String, dynamic> data) {
    final savedRevision = data[backupKey];
    if (savedRevision is int && savedRevision >= revision) return data;
    final rawPreferences = data['preferences'];
    // Keep the import validator responsible for rejecting malformed settings.
    if (rawPreferences != null && rawPreferences is! Map) return data;
    final preferences = rawPreferences is Map
        ? Map<String, dynamic>.from(rawPreferences)
        : <String, dynamic>{};
    final model = preferences['dashScopeTtsModel'];
    preferences.addAll({
      'fishAudioReferenceId': '',
      'fishAudioAsmrReferenceId': '',
      'fishMcpVoice': '',
      'fishMcpAsmrVoice': '',
      'dashScopeTtsVoice': defaultQwenVoice(
        model is String ? model : 'qwen3-tts-flash',
      ),
      'dashScopeTtsAsmrVoice': '',
      'genericTtsVoice': 'alloy',
      'genericTtsAsmrVoice': '',
    });
    final mimo = preferences['mimoTts'];
    if (mimo is Map) {
      preferences['mimoTts'] = {...mimo, 'voice': const MimoTtsConfig().voice};
    }
    return {...data, backupKey: revision, 'preferences': preferences};
  }
}
