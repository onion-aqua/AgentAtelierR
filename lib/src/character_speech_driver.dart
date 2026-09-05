import 'dart:convert';
import 'dart:math';

/// Spine's native findBone aborts the process for an empty name.
T? resolveOptionalRigBone<T>(String? name, T? Function(String) findBone) {
  if (name == null || name.trim().isEmpty) return null;
  return findBone(name);
}

class RigMotion {
  const RigMotion([this.yaw = 0, this.pitch = 0, this.roll = 0]);
  final double yaw;
  final double pitch;
  final double roll;

  RigMotion scaled(double value) =>
      RigMotion(yaw * value, pitch * value, roll * value);

  RigMotion blend(RigMotion other, double t) => RigMotion(
    yaw + (other.yaw - yaw) * t,
    pitch + (other.pitch - pitch) * t,
    roll + (other.roll - roll) * t,
  );
}

class CharacterPerformanceProfile {
  CharacterPerformanceProfile._(this.drivers, this.aimBones, this.rollBones);

  final List<Map<String, dynamic>> drivers;
  final Map<String, String> aimBones;
  final Map<String, String> rollBones;

  factory CharacterPerformanceProfile.parse(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    final gesture = json['emotionalGesture'] as Map<String, dynamic>?;
    final rig = json['rigConfig'] as Map<String, dynamic>?;
    Map<String, String> bones(String key) => {
      for (final entry in (rig?[key] as Map<String, dynamic>? ?? {}).entries)
        if (entry.value is Map && (entry.value as Map)['bone'] is String)
          entry.key: (entry.value as Map)['bone'] as String,
    };
    final drivers = <Map<String, dynamic>>[];
    for (final entry in gesture?['DriverDefs'] as List? ?? const []) {
      if (entry is! Map || entry['Spec'] is! String) continue;
      try {
        final spec = jsonDecode(entry['Spec'] as String);
        if (spec is Map<String, dynamic> && spec['id'] is String) {
          drivers.add(spec);
        }
      } on FormatException {
        // One malformed optional driver must not disable all character motion.
      }
    }
    return CharacterPerformanceProfile._(
      drivers,
      bones('aimSlots'),
      bones('rollSlots'),
    );
  }
}

/// Samples local resource drivers with bounded, non-accumulating offsets.
class CharacterPerformanceDirector {
  CharacterPerformanceDirector(this.profile, {Random? random})
    : _random = random ?? Random();

  final CharacterPerformanceProfile profile;
  final Random _random;
  Map<String, dynamic>? _driver;
  String? _emotion;
  double _elapsed = 0;
  double _transition = 1;
  double _hold = 1;
  RigMotion _from = const RigMotion();
  RigMotion _target = const RigMotion();
  RigMotion _current = const RigMotion();
  final Map<String, RigMotion> _parts = {};

  double _number(Map value, String key, double fallback) {
    final number = value[key];
    return number is num && number.isFinite ? number.toDouble() : fallback;
  }

  double _range(
    Map value,
    String key,
    double fallback,
    double low,
    double high,
  ) {
    final a = _number(value, '${key}Min', fallback).clamp(low, high);
    final b = _number(value, '${key}Max', fallback).clamp(low, high);
    return min(a, b) + _random.nextDouble() * (a - b).abs();
  }

  Map<String, RigMotion> sample({
    required double delta,
    required String emotion,
    required bool speaking,
    required double energy,
    bool suppressed = false,
  }) {
    final dt = delta.clamp(0.0, 0.05).toDouble();
    if (_driver == null ||
        _emotion != emotion ||
        _elapsed >= _transition + _hold) {
      var candidates = profile.drivers
          .where((d) => (d['id'] as String).startsWith('${emotion}_n_'))
          .toList();
      if (candidates.isEmpty) {
        candidates = profile.drivers
            .where((d) => (d['id'] as String).startsWith('neutral_n_'))
            .toList();
      }
      final alternatives = candidates.where((d) => d != _driver).toList();
      if (alternatives.isNotEmpty) candidates = alternatives;
      if (candidates.isNotEmpty) {
        _driver = candidates[_random.nextInt(candidates.length)];
        _from = _current;
        _target = RigMotion(
          _range(_driver!, 'yaw', 0, -1, 1),
          _range(_driver!, 'pitch', 0, -1, 1),
          _range(_driver!, 'roll', 0, -1, 1),
        );
        _transition = _range(_driver!, 'transition', 1, 0.4, 4);
        _hold = _range(_driver!, 'hold', 1.5, 0.2, 5);
      }
      _emotion = emotion;
      _elapsed = 0;
    }
    _elapsed += dt;
    final t = (_elapsed / _transition).clamp(0.0, 1.0);
    _current = _from.blend(_target, t * t * (3 - 2 * t));
    final strength = suppressed
        ? 0.0
        : speaking
        ? 0.65 + energy * 0.35
        : 0.3;
    final desired = <String, RigMotion>{
      (_driver?['driver'] as String? ?? 'head'): _current.scaled(strength),
    };
    final delays = <String, double>{};
    for (final follower in _driver?['followers'] as List? ?? const []) {
      if (follower is! Map || follower['part'] is! String) continue;
      final part = follower['part'] as String;
      if (desired.containsKey(part)) continue;
      desired[part] = _current.scaled(
        strength * _number(follower, 'scale', 0).clamp(-1.0, 1.0),
      );
      delays[part] = _number(follower, 'delay', 0.3).clamp(0.06, 1.0);
    }
    for (final part in {'head', 'body', 'eye', ..._parts.keys}) {
      final response = suppressed ? 0.08 : delays[part] ?? 0.12;
      _parts[part] = (_parts[part] ?? const RigMotion()).blend(
        desired[part] ?? const RigMotion(),
        1 - exp(-dt / response),
      );
    }
    return Map.unmodifiable(_parts);
  }
}

/// Interpolates coarse player notifications, but stops extrapolating on stalls.
Duration interpolatedSpeechPosition(Duration anchor, Duration sinceAnchor) =>
    anchor + Duration(microseconds: min(sinceAnchor.inMicroseconds, 250000));
