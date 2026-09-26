import 'dart:convert';

import 'package:alarm/alarm.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'character_runtime_profile.dart';

abstract class CharacterAlarmAccess {
  Future<List<AlarmSettings>> getAlarms();
  Future<bool> set(AlarmSettings settings);
  Future<bool> stop(int id);
}

class PluginCharacterAlarmAccess implements CharacterAlarmAccess {
  const PluginCharacterAlarmAccess();

  @override
  Future<List<AlarmSettings>> getAlarms() => Alarm.getAlarms();

  @override
  Future<bool> set(AlarmSettings settings) =>
      Alarm.set(alarmSettings: settings);

  @override
  Future<bool> stop(int id) => Alarm.stop(id);
}

class CharacterAlarmCoordinator {
  CharacterAlarmCoordinator(
    this._preferences, {
    this.access = const PluginCharacterAlarmAccess(),
  });

  static const _pausedRyzaAlarmsKey = 'paused_ryza_voice_alarms_v1';
  static const ryzaVoicePayload = 'character:ryza';
  static const _legacyRyzaVoicePath = 'assets/audio/alarm/voices/';

  final SharedPreferences _preferences;
  final CharacterAlarmAccess access;
  Future<void> _pending = Future<void>.value();

  Future<void> syncForCharacter(String characterId) {
    final next = _pending.then(
      (_) => characterId == CharacterRuntimeIds.ryza
          ? _restoreRyzaAlarms()
          : _pauseRyzaAlarms(),
    );
    _pending = next.catchError((Object _, StackTrace _) {});
    return next;
  }

  static bool isRyzaVoiceAlarm(AlarmSettings settings) =>
      settings.payload == ryzaVoicePayload ||
      (settings.assetAudioPath?.startsWith(_legacyRyzaVoicePath) ?? false);

  List<AlarmSettings> _readPausedAlarms() {
    final stored = _preferences.getString(_pausedRyzaAlarmsKey);
    if (stored == null || stored.isEmpty) return const [];
    final decoded = jsonDecode(stored);
    if (decoded is! List) {
      throw const FormatException('Paused voice alarm data is invalid');
    }
    return decoded
        .map(
          (entry) =>
              AlarmSettings.fromJson(Map<String, dynamic>.from(entry as Map)),
        )
        .toList(growable: false);
  }

  Future<void> _writePausedAlarms(List<AlarmSettings> alarms) async {
    final written = await _preferences.setString(
      _pausedRyzaAlarmsKey,
      jsonEncode(alarms.map((alarm) => alarm.toJson()).toList()),
    );
    if (!written) throw StateError('Could not save paused voice alarms');
  }

  Future<void> _pauseRyzaAlarms() async {
    final scheduled = (await access.getAlarms())
        .where(isRyzaVoiceAlarm)
        .toList(growable: false);
    if (scheduled.isEmpty) return;
    final paused = {
      for (final alarm in _readPausedAlarms()) alarm.id: alarm,
      for (final alarm in scheduled) alarm.id: alarm,
    }.values.toList(growable: false);
    await _writePausedAlarms(paused);
    try {
      for (final alarm in scheduled) {
        if (!await access.stop(alarm.id)) {
          throw StateError('Could not pause voice alarm ${alarm.id}');
        }
      }
    } on Object {
      try {
        await _restoreRyzaAlarms();
      } on Object {
        // Keep the persisted snapshot so a later Ryza sync can retry recovery.
      }
      rethrow;
    }
  }

  Future<void> _restoreRyzaAlarms() async {
    final paused = _readPausedAlarms();
    if (paused.isEmpty) return;
    final now = DateTime.now();
    final remaining = <AlarmSettings>[];
    Object? failure;
    for (final alarm in paused) {
      if (!alarm.dateTime.isAfter(now)) continue;
      try {
        if (!await access.set(
          alarm.copyWith(allowSameSecondScheduling: true),
        )) {
          remaining.add(alarm);
          failure ??= StateError('Could not restore voice alarm ${alarm.id}');
        }
      } on Object catch (error) {
        remaining.add(alarm);
        failure ??= error;
      }
    }
    await _writePausedAlarms(remaining);
    if (failure != null) throw failure;
  }
}
