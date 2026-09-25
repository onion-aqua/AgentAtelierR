import 'dart:convert';
import 'dart:math';

/// Speaking may reuse authored torso beats, but must not invent arm/leg gestures
/// or ignore a pose-specific zero weight.
bool isSpeakingTorsoMotion(String occupancy, double? authoredWeight) =>
    occupancy.isNotEmpty &&
    occupancy.split('').every((part) => part == 'E' || part == 'H') &&
    authoredWeight != null &&
    authoredWeight.isFinite &&
    authoredWeight > 0;

/// These leg groups can play under speech; other C groups change posture.
bool isSpeakingLegMotion(String occupancy, String groupId) {
  if (occupancy != 'C') return false;
  final normalized = groupId.trim().toLowerCase();
  return normalized == 'grp_c_01' || normalized == 'grp_c_03';
}

double speakingLegAmbientWeight(String occupancy, String groupId) {
  if (!isSpeakingLegMotion(occupancy, groupId)) return 0;
  return groupId.trim().toLowerCase() == 'grp_c_01' ? 0.45 : 0.15;
}

/// New resources scope torso motion to the current base pose type. An empty
/// authored map disables motion; only a missing map uses the legacy schema.
Map<String, double>? idleTorsoWeights(
  Map<String, dynamic> band,
  Iterable<String> poseTypes,
) {
  final byPose = band['torsoWaistGroupWeightsByPoseType'];
  Object? selected;
  if (byPose is Map) {
    for (final type in poseTypes) {
      if (byPose[type] is Map) {
        selected = byPose[type];
        break;
      }
    }
    selected ??= byPose[''];
  }
  selected ??= band['torsoWaistGroupWeights'];
  if (selected is! Map) return null;
  return {
    for (final entry in selected.entries)
      if (entry.key is String && entry.value is num)
        entry.key as String: (entry.value as num).toDouble(),
  };
}

/// Restores only missing ambient driver data. Costume-specific poses, groups,
/// expressions and explicit empty bindings remain authoritative.
String restoreMissingIdleDrivers(String source, String reference) {
  final current = jsonDecode(source) as Map<String, dynamic>;
  final original = jsonDecode(reference) as Map<String, dynamic>;
  final gesture = current['emotionalGesture'] as Map<String, dynamic>?;
  final fallback = original['emotionalGesture'] as Map<String, dynamic>?;
  if (gesture == null || fallback == null) return source;
  if (fallback['DriverDefs'] is! List) return source;
  gesture.putIfAbsent('DriverDefs', () => fallback['DriverDefs']);
  final profiles = gesture['EmotionProfilesV4'] as Map? ?? {};
  final originalProfiles = fallback['EmotionProfilesV4'] as Map? ?? {};
  for (final entry in profiles.entries) {
    final bands = (entry.value as Map)['tensionProfiles'] as Map? ?? {};
    final originalBands =
        (originalProfiles[entry.key] as Map?)?['tensionProfiles'] as Map? ?? {};
    for (final band in bands.entries) {
      final target = band.value as Map;
      final bindings = (originalBands[band.key] as Map?)?['ambientBindings'];
      if (!target.containsKey('ambientBindings') && bindings is List) {
        target['ambientBindings'] = bindings;
      }
    }
  }
  return jsonEncode(current);
}

class CharacterBlinkBeat {
  const CharacterBlinkBeat({
    required this.gap,
    required this.closedFor,
    required this.fast,
  });
  final double gap;
  final double closedFor;
  final bool fast;
}

/// Resource-weighted eye modes, also active while the character is silent.
CharacterBlinkBeat chooseCharacterBlink(
  Map<String, dynamic> band,
  Random random,
) {
  final gaze = band['gaze'] as Map? ?? {};
  final entries = (gaze['eyeModeEntries'] as List? ?? [])
      .whereType<Map>()
      .where(
        (entry) =>
            ['blink', 'blinkFast', 'closed'].contains(entry['mode']) &&
            _number(entry['weight'], 0) > 0,
      )
      .toList();
  if (entries.isEmpty) {
    return CharacterBlinkBeat(
      gap: 2.4 + random.nextDouble() * 3.2,
      closedFor: 0.12,
      fast: false,
    );
  }
  var ticket =
      random.nextDouble() *
      entries.fold<double>(0, (sum, e) => sum + _number(e['weight'], 0));
  var selected = entries.last;
  for (final entry in entries) {
    ticket -= _number(entry['weight'], 0);
    if (ticket <= 0) {
      selected = entry;
      break;
    }
  }
  final fast = selected['mode'] == 'blinkFast';
  final closed = selected['mode'] == 'closed';
  final interval = _number(
    selected['intervalSeconds'],
    closed
        ? 5.5
        : fast
        ? 1.4
        : 3,
  );
  final jitter = _number(
    selected['jitterSeconds'],
    closed ? 1.5 : 0,
  ).clamp(0.0, 5.0);
  return CharacterBlinkBeat(
    gap:
        ((interval + (random.nextDouble() * 2 - 1) * jitter) *
                (fast ? 0.55 : 1))
            .clamp(0.6, 12.0),
    closedFor: closed
        ? _number(selected['durationSeconds'], 1.5).clamp(0.15, 2.0)
        : fast
        ? 0.08
        : 0.12,
    fast: fast,
  );
}

double _number(Object? value, double fallback) =>
    value is num && value.isFinite ? value.toDouble() : fallback;
