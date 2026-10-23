import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Adopt the slower Fish default once; keep other provider settings and user
/// speeds such as 0.8 or 1.2. Later explicit choices, including 1.0, survive.
class FishSpeechSpeedDefaults {
  static const speed = 0.9;
  static const preferenceKey = 'fish_speech_speed_default_v1';

  static bool _usesFish(Object? provider) =>
      provider == null || provider == 'fishAudio' || provider == 'fishAudioMcp';

  static double defaultForProvider(Object? provider) =>
      _usesFish(provider) && defaultTargetPlatform != TargetPlatform.windows
      ? speed
      : 1.0;

  static Future<void> migrate(SharedPreferences preferences) async {
    // Windows currently lacks the compressed-audio decoder used by the local
    // MCP processor. Preserve its working default until that path is available.
    if (defaultTargetPlatform == TargetPlatform.windows) return;
    if (preferences.getBool(preferenceKey) == true) return;
    final writes = <Future<bool>>[];
    if (_usesFish(preferences.getString('tts_provider')) &&
        (preferences.getDouble('fish_audio_speed') ?? 1.0) == 1.0) {
      writes.add(preferences.setDouble('fish_audio_speed', speed));
    }
    final raw = preferences.getString('character_sessions_v1');
    if (raw != null) {
      try {
        final sessions = jsonDecode(raw);
        if (sessions is Map) {
          var changed = false;
          for (final session in sessions.values) {
            if (session is! Map) continue;
            final settings = session['preferences'];
            if (settings is Map &&
                _usesFish(settings['ttsProvider']) &&
                (settings['fishAudioSpeed'] ?? 1.0) == 1.0) {
              settings['fishAudioSpeed'] = speed;
              changed = true;
            }
          }
          if (changed) {
            writes.add(
              preferences.setString(
                'character_sessions_v1',
                jsonEncode(sessions),
              ),
            );
          }
        }
      } on FormatException {
        // Leave damaged sessions to the application's existing recovery flow.
      }
    }
    if ((await Future.wait(writes)).any((saved) => !saved) ||
        !await preferences.setBool(preferenceKey, true)) {
      throw StateError('语速默认值未保存，请重新启动后重试');
    }
  }
}
