import 'dart:math';

/// Preserve authored easing and prevent distance-based estimates snapping
/// between nearby poses. Also bound malformed imported resource durations.
double smoothCharacterGestureMix(double estimated, double authored) {
  final base = authored.isFinite ? authored.clamp(0.45, 1.2) : 0.6;
  return estimated.isFinite ? max(base, estimated).clamp(0.45, 2.0) : base;
}

/// Transition policies adapted from zeroa234/ryza-ai-revive (MIT).
/// See docs/animation_dynamics.md for provenance and runtime differences.
class CharacterMotionTransitions {
  CharacterMotionTransitions(Map<String, Object?> root)
    : _config = _map(root['projectConfig']),
      _poses = _map(
        _map(_map(root['emotionalGesture'])['MixDurationPoses'])['animPoses'],
      );

  final Map<String, Object?> _config;
  final Map<String, Object?> _poses;
  static final _controls = RegExp(
    r'control_|_IK|template_|aim_|roll_',
    caseSensitive: false,
  );

  double poseMix(
    String? from,
    String to, {
    required double minimum,
    required double maximum,
  }) {
    final lo = min(minimum, maximum).clamp(0.12, 3.0);
    final hi = max(minimum, maximum).clamp(lo, 3.0);
    final a = _map(_poses[from]);
    final b = _map(_poses[to]);
    var total = 0.0;
    var count = 0;
    for (final bone in a.keys) {
      if (_controls.hasMatch(bone)) continue;
      final p = a[bone];
      final q = b[bone];
      if (p is! List || q is! List || p.length < 2 || q.length < 2) continue;
      if (p.take(2).any((v) => v is! num || !v.isFinite) ||
          q.take(2).any((v) => v is! num || !v.isFinite)) {
        continue;
      }
      final dx = (p[0] as num) - (q[0] as num);
      final dy = (p[1] as num) - (q[1] as num);
      total += sqrt(dx * dx + dy * dy);
      count++;
    }
    // Missing poses must not masquerade as a zero-distance transition.
    if (count == 0) return lo;
    final saturation = _number(
      _config['mixDurationSaturationRatio'],
      0.1,
    ).clamp(0.05, 1.0);
    final close = max(0.12, lo * saturation);
    return close + (1 - exp(-total / count / 180)) * (hi - close);
  }

  double groupMix(String? from, String? to, {required double fallback}) {
    final config = _map(_config['armInOutPartConfig']);
    final groups = _map(config['byGroupId']);
    if ((to != null && !groups.containsKey(to)) ||
        (to == null && !groups.containsKey(from))) {
      return fallback.clamp(0.28, 3.0);
    }
    final positions = _map(config['rankPositions']);
    double rank(String? id, String side) =>
        _number(positions['${_map(groups[id])[side]}'], 0);
    final distance = max(
      (rank(from, 'left') - rank(to, 'left')).abs(),
      (rank(from, 'right') - rank(to, 'right')).abs(),
    );
    final lo = _number(config['minSeconds'], 0.4).clamp(0.28, 3.0);
    final hi = _number(config['maxSeconds'], 1).clamp(lo, 3.0);
    final reference = max(
      0.01,
      _number(config['pairStartDelayReferenceDistance'], 0.35),
    );
    return lo + (distance / reference).clamp(0.0, 1.0) * (hi - lo);
  }
}

/// Wind intensity is a scene art choice, not original game weather metadata.
/// Stable stage IDs keep it independent of UI language and audio settings.
double characterWindForStage(String stageId) {
  const exposed = {
    'stage_01_001_02',
    'stage_01_003_01',
    'stage_01_010_01',
    'stage_01_013_02',
    'stage_01_013_03',
    'stage_05_003_01',
  };
  const sheltered = {
    'stage_01_001_01',
    'stage_01_001_05',
    'stage_01_001_06',
    'stage_01_001_08',
    'stage_01_002_01',
    'stage_01_002_02',
    'stage_01_002_03',
    'stage_01_002_04',
    'stage_01_003_02',
    'stage_01_003_03',
    'stage_01_003_04',
    'stage_01_003_05',
    'stage_01_008_01',
    'stage_01_008_02',
    'stage_05_001_01',
    'stage_05_010_01',
  };
  if (exposed.contains(stageId)) return 0.5;
  if (sheltered.contains(stageId)) return 0.24;
  if (stageId.startsWith('stage_01_009_') ||
      stageId.startsWith('stage_03_004_')) {
    return 0.4;
  }
  // Workshops, houses, mines and unknown stages do not get speculative wind.
  return 0;
}

class CharacterWindEnvelope {
  double strength = 0;

  double advance(double delta, double target) {
    if (!delta.isFinite || delta <= 0) return strength;
    target = target.isFinite ? target.clamp(0.0, 0.65) : 0;
    strength += (target - strength) * (1 - exp(-delta.clamp(0.0, 0.05) / 0.8));
    if (target == 0 && strength < 0.001) strength = 0;
    return strength;
  }
}

Map<String, Object?> _map(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : const {};
double _number(Object? value, double fallback) {
  final parsed = value is num ? value.toDouble() : double.tryParse('$value');
  return parsed != null && parsed.isFinite ? parsed : fallback;
}
