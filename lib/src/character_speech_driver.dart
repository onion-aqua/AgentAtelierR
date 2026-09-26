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
  CharacterPerformanceProfile._(
    this.drivers,
    this.aimBones,
    this.rollBones, [
    this.emotionProfiles = const {},
    this.decayRates = const {},
    this.ambientGaze = const {},
    this.attitudeDrivers = const {},
  ]);

  final List<Map<String, dynamic>> drivers;
  final Map<String, String> aimBones;
  final Map<String, String> rollBones;
  final Map<String, dynamic> emotionProfiles;
  final Map<String, dynamic> decayRates;
  final Map<String, dynamic> ambientGaze;
  final Map<String, List<Map<String, dynamic>>> attitudeDrivers;

  Iterable<Map<String, dynamic>> oneShotAttitudes(String attitude) =>
      (attitudeDrivers[attitude] ?? const []).where(
        (driver) =>
            driver['oneShotAnimation'] is String &&
            (driver['oneShotAnimation'] as String).isNotEmpty,
      );

  RigMotion constrainAmbient(RigMotion motion) {
    double limit(String key, double fallback) {
      final value = ambientGaze[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(-1.0, 1.0)
          : fallback;
    }

    final yaw = limit('yawLimit', 1).abs();
    final down = limit('pitchDownLimit', -1).clamp(-1.0, 0.0);
    final up = limit('pitchUpLimit', 1).clamp(0.0, 1.0);
    final minus = limit('rollMinusLimit', -1).clamp(-1.0, 0.0);
    final plus = limit('rollPlusLimit', 1).clamp(0.0, 1.0);
    return RigMotion(
      motion.yaw.clamp(-yaw, yaw),
      motion.pitch.clamp(down, up),
      motion.roll.clamp(minus, plus),
    );
  }

  Map<String, dynamic> tensionProfile(String emotion, String band) {
    final profile = emotionProfiles[emotion] ?? emotionProfiles['neutral'];
    if (profile is! Map) return const {};
    final bands = profile['tensionProfiles'];
    if (bands is! Map) return const {};
    final result = bands[band] ?? bands['low'] ?? bands['high'];
    return result is Map ? Map<String, dynamic>.from(result) : const {};
  }

  bool get hasResourceDrivers =>
      drivers.isNotEmpty || attitudeDrivers.isNotEmpty;

  /// No bone mappings are guessed when a resource lacks legacy DriverDefs.
  factory CharacterPerformanceProfile.fallback() =>
      CharacterPerformanceProfile._(const [], const {}, const {});

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
    final ambient = Map<String, dynamic>.from(
      (json['projectConfig'] as Map?)?['ambientGaze'] as Map? ?? {},
    );
    final patterns = <String, Map<String, dynamic>>{
      for (final row in gesture?['GesturePatternDefs'] as List? ?? const [])
        if (row is Map && row['patternId'] is String)
          row['patternId'] as String: Map<String, dynamic>.from(row),
    };
    final attitudes = <String, List<Map<String, dynamic>>>{};
    for (final row in gesture?['AttitudePatterns'] as List? ?? const []) {
      if (row is! Map || row['attitude'] is! String) continue;
      final weight = row['weight'];
      if (weight is! num || !weight.isFinite || weight <= 0) continue;
      final pattern = patterns[row['patternId']];
      if (pattern == null) continue;
      final attitude = row['attitude'] as String;
      attitudes
          .putIfAbsent(attitude, () => [])
          .add(
            _schemaFourDriver(pattern, Map<String, dynamic>.from(row), ambient),
          );
    }
    return CharacterPerformanceProfile._(
      drivers,
      bones('aimSlots'),
      bones('rollSlots'),
      Map<String, dynamic>.from(gesture?['EmotionProfilesV4'] as Map? ?? {}),
      Map<String, dynamic>.from(
        ((json['projectConfig'] as Map?)?['tensionConfig']
                    as Map?)?['decayRates']
                as Map? ??
            {},
      ),
      ambient,
      {
        for (final entry in attitudes.entries)
          entry.key: List.unmodifiable(entry.value),
      },
    );
  }
}

Map<String, dynamic> _schemaFourDriver(
  Map<String, dynamic> pattern,
  Map<String, dynamic> attitude,
  Map<String, dynamic> ambient,
) {
  double setting(String key, double fallback) {
    final value = ambient[key];
    return value is num && value.isFinite ? value.toDouble() : fallback;
  }

  final size = switch (attitude['size']) {
    '小' => setting('sizeSmall', 0.6),
    '大' => setting('sizeLarge', 1),
    _ => setting('sizeMedium', 0.85),
  };
  final dwell = switch (attitude['dwell']) {
    '短' => setting('dwellShort', 0.6),
    '長' => setting('dwellLong', 4),
    _ => setting('dwellMedium', 1.5),
  };
  final speed = switch (attitude['moveSpeed']) {
    '速い' => setting('speedFast', 2),
    '遅い' => setting('speedSlow', 0.5),
    _ => setting('speedNormal', 1),
  };
  final directions = (pattern['directions'] as List? ?? const [])
      .whereType<String>()
      .toList();
  final horizontal = directions.any(
    (value) => value.contains('横') || value.contains('斜め'),
  );
  final up = directions.any((value) => value.contains('上'));
  final down = directions.any((value) => value.contains('下'));
  final yaw = horizontal ? setting('yawLimit', 0.8) * size : 0.0;
  final pitchUp = up ? setting('pitchUpLimit', 1).abs() * size : 0.0;
  final pitchDown = down ? setting('pitchDownLimit', -1).abs() * size : 0.0;
  double followScale(Object? value) => switch (value) {
    '追従（強）' => setting('followScaleStrong', 0.9),
    '追従（中）' => setting('followScaleMedium', 0.7),
    '追従（弱）' => setting('followScaleWeak', 0.5),
    '逆方向' => setting('followScaleOpposite', -0.2),
    _ => 0.0,
  };
  final headFollow = followScale(pattern['faceMovement']);
  final bodyFollow = followScale(pattern['bodyMovement']);
  final baseMove = setting('moveBaseSeconds', 0.15);
  return {
    'id': '${attitude['attitude']}_${pattern['patternId']}',
    'driver': 'eye',
    'weight': attitude['weight'],
    'yawMin': -yaw,
    'yawMax': yaw,
    'pitchMin': -pitchDown,
    'pitchMax': pitchUp,
    'rollMin': -setting('rollMinusLimit', -0.8).abs() * size * 0.3,
    'rollMax': setting('rollPlusLimit', 0.8).abs() * size * 0.3,
    'transitionMin': (baseMove / speed).clamp(0.12, 2.0),
    'transitionMax': (baseMove * 2 / speed).clamp(0.2, 3.0),
    'holdMin': dwell * 0.8,
    'holdMax': dwell * 1.2,
    'route': pattern['route'],
    'points': pattern['points'],
    'schemaFour': true,
    'directions': directions,
    'tilts': pattern['tilts'],
    'eyeMovement': pattern['eyeMovement'],
    'faceMovement': pattern['faceMovement'],
    'bodyTilt': pattern['bodyTilt'],
    'oneShotAnimation': attitude['oneShotAnimation'],
    'repeatMin': attitude['repeatMin'],
    'repeatMax': attitude['repeatMax'],
    'followers': [
      if (headFollow != 0)
        {
          'part': 'head',
          'scale': headFollow,
          'delay': setting('headFollowDelay', 0.1),
        },
      if (bodyFollow != 0)
        {
          'part': 'body',
          'scale': bodyFollow,
          'delay': setting('bodyFollowDelay', 0.6),
        },
    ],
  };
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
  double _strength = 0.3;
  double _tension = 0;
  String _band = 'low';
  String? _driverBand;
  String? _driverAttitude;
  int _repeatsLeft = 0;
  int _routeStepsLeft = 0;
  int _routeStep = 0;
  int _schemaRepeatsLeft = 0;
  bool _routeReverse = false;
  RigMotion _routeAnchor = const RigMotion();
  Map<String, dynamic>? _cuedDriver;
  bool _activeAttitudeCue = false;
  bool get hasActiveAttitudeCue => _cuedDriver != null || _activeAttitudeCue;

  void cueAttitude(Map<String, dynamic> driver) {
    _cuedDriver = driver;
    _driver = null;
  }

  bool _usingBindings = false;
  String get tensionBand => _band;
  Map<String, RigMotion> _from = {};
  Map<String, RigMotion> _target = {};
  final Map<String, double> _followerDelays = {};
  final Map<String, RigMotion> _parts = {};

  // Unsupported resource schemas use small, slow targets with actual rests,
  // never an extra oscillator layered over the resource's existing motion.
  static const _fallbackDriver = <String, dynamic>{
    'id': 'neutral_n_fallback',
    'driver': 'head',
    'yawMin': -0.08,
    'yawMax': 0.08,
    'pitchMin': -0.06,
    'pitchMax': 0.08,
    'rollMin': -0.035,
    'rollMax': 0.035,
    'transitionMin': 1.4,
    'transitionMax': 2.2,
    'holdMin': 2.8,
    'holdMax': 4.5,
    'followers': [
      {'part': 'eye', 'scale': 0.4, 'delay': 0.15},
      {'part': 'body', 'scale': 0.2, 'delay': 0.55},
    ],
  };

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

  RigMotion _schemaAnchor(Map<String, dynamic> driver) {
    final directions = (driver['directions'] as List? ?? const [])
        .whereType<String>()
        .toList();
    final direction = directions.isEmpty
        ? '正面'
        : directions[_random.nextInt(directions.length)];
    final yawWidth = _number(
      profile.ambientGaze,
      'widthRatioYaw',
      0.55,
    ).clamp(0.0, 1.0);
    final pitchWidth = _number(
      profile.ambientGaze,
      'widthRatioPitch',
      0.85,
    ).clamp(0.0, 1.0);
    final yaw = direction.contains('横') || direction.contains('斜め')
        ? _number(driver, 'yawMax', 0) *
              (1 - yawWidth + _random.nextDouble() * yawWidth) *
              (_random.nextBool() ? 1 : -1)
        : 0.0;
    final pitch = direction.contains('上')
        ? _number(driver, 'pitchMax', 0) *
              (1 - pitchWidth + _random.nextDouble() * pitchWidth)
        : direction.contains('下')
        ? _number(driver, 'pitchMin', 0) *
              (1 - pitchWidth + _random.nextDouble() * pitchWidth)
        : 0.0;
    final tilts = (driver['tilts'] as List? ?? const [])
        .whereType<String>()
        .toList();
    final tilt = tilts.isEmpty ? 'なし' : tilts[_random.nextInt(tilts.length)];
    final roll = tilt == '右'
        ? _number(driver, 'rollMax', 0)
        : tilt == '左'
        ? _number(driver, 'rollMin', 0)
        : 0.0;
    return profile.constrainAmbient(RigMotion(yaw, pitch, roll));
  }

  RigMotion _schemaRouteTarget(Map<String, dynamic> driver) {
    final route = driver['route'];
    if (route == '外して戻る' && _routeStep > 0) return const RigMotion();
    if (route == '往復' && _routeStep.isOdd) {
      return RigMotion(
        -_routeAnchor.yaw,
        _routeAnchor.pitch,
        -_routeAnchor.roll,
      );
    }
    if (route == '見回す') {
      final count = _number(driver, 'points', 1).round().clamp(2, 9);
      final sweep = -1 + 2 * _routeStep / (count - 1);
      return RigMotion(
        _number(driver, 'yawMax', 0) * sweep,
        _routeAnchor.pitch,
        _routeAnchor.roll * sweep,
      );
    }
    if (route == '散らす') return _schemaAnchor(driver);
    return _routeAnchor;
  }

  Map<String, RigMotion> sample({
    required double delta,
    required String emotion,
    required bool speaking,
    required double energy,
    bool suppressed = false,
  }) {
    final dt = delta.isFinite ? delta.clamp(0.0, 0.05).toDouble() : 0.0;
    final rate = _number(
      profile.decayRates,
      speaking ? 'high' : _band,
      0.022,
    ).clamp(0.001, 1.0);
    _tension += ((speaking ? 1 : 0) - _tension) * (1 - exp(-rate * 60 * dt));
    _band = _tension < 0.33
        ? 'low'
        : _tension < 0.66
        ? 'mid'
        : 'high';
    final bandProfile = profile.tensionProfile(emotion, _band);
    final attitude = '${speaking ? 'talk' : 'idle'}_$_band';
    if (_driver == null ||
        _emotion != emotion ||
        _driverBand != _band ||
        _driverAttitude != attitude ||
        _elapsed >= _transition + _hold) {
      final samePattern =
          _emotion == emotion &&
          _driverBand == _band &&
          _driverAttitude == attitude;
      final bindings = bandProfile['ambientBindings'];
      final authored = profile.attitudeDrivers[attitude] ?? const [];
      final continueRoute = samePattern && _routeStepsLeft > 0;
      _usingBindings = bindings is List || authored.isNotEmpty;
      if (_cuedDriver case final cue?) {
        _driver = cue;
        _cuedDriver = null;
        _activeAttitudeCue = true;
        _schemaRepeatsLeft = 0;
        _routeStep = 0;
        _routeStepsLeft = (_number(cue, 'points', 1).round() - 1).clamp(0, 8);
        _routeAnchor = _schemaAnchor(cue);
      } else if (continueRoute) {
        _routeStepsLeft--;
        _routeStep++;
        _routeReverse = !_routeReverse;
      } else if (samePattern &&
          _driver?['schemaFour'] == true &&
          _schemaRepeatsLeft > 0) {
        _schemaRepeatsLeft--;
        _routeStep = 0;
        _routeStepsLeft = (_number(_driver!, 'points', 1).round() - 1).clamp(
          0,
          8,
        );
        _routeAnchor = _schemaAnchor(_driver!);
      } else if (authored.isNotEmpty) {
        _activeAttitudeCue = false;
        var ticket =
            _random.nextDouble() *
            authored.fold<double>(
              0,
              (sum, row) => sum + _number(row, 'weight', 0),
            );
        _driver = authored.last;
        for (final row in authored) {
          ticket -= _number(row, 'weight', 0);
          if (ticket <= 0) {
            _driver = row;
            break;
          }
        }
        _routeStepsLeft = (_number(_driver!, 'points', 1).round() - 1).clamp(
          0,
          8,
        );
        _routeStep = 0;
        _routeAnchor = _schemaAnchor(_driver!);
        final repeatMin = _number(
          _driver!,
          'repeatMin',
          1,
        ).round().clamp(1, 12);
        final repeatMax = _number(
          _driver!,
          'repeatMax',
          repeatMin.toDouble(),
        ).round().clamp(repeatMin, 12);
        _schemaRepeatsLeft =
            repeatMin + _random.nextInt(repeatMax - repeatMin + 1) - 1;
        _routeReverse = false;
      } else if (bindings is List) {
        _activeAttitudeCue = false;
        _routeStepsLeft = 0;
        if (samePattern && _repeatsLeft > 0) {
          _repeatsLeft--;
        } else {
          final valid = bindings
              .whereType<Map>()
              .where(
                (b) =>
                    _number(b, 'weight', 0) > 0 &&
                    profile.drivers.any((d) => d['id'] == b['driverDefId']),
              )
              .toList();
          var ticket =
              _random.nextDouble() *
              valid.fold<double>(0, (sum, b) => sum + _number(b, 'weight', 0));
          Map? choice;
          for (final binding in valid) {
            ticket -= _number(binding, 'weight', 0);
            choice = binding;
            if (ticket <= 0) break;
          }
          _driver = choice == null
              ? const {'id': 'ambient_rest', 'driver': 'head'}
              : profile.drivers.firstWhere(
                  (d) => d['id'] == choice!['driverDefId'],
                );
          final lo = _number(choice ?? {}, 'repeatMin', 1).round().clamp(1, 12);
          final hi = _number(
            choice ?? {},
            'repeatMax',
            lo.toDouble(),
          ).round().clamp(lo, 12);
          _repeatsLeft = lo + _random.nextInt(hi - lo + 1) - 1;
        }
      } else {
        _activeAttitudeCue = false;
        _routeStepsLeft = 0;
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
        _driver = candidates.isEmpty
            ? _fallbackDriver
            : candidates[_random.nextInt(candidates.length)];
      }
      // A new lead part starts at its own current pose. Reusing one shared
      // head target here used to transfer it abruptly to the body or eyes.
      _from = Map.of(_parts);
      final schemaFour = _driver!['schemaFour'] == true;
      final motion = schemaFour
          ? _schemaRouteTarget(_driver!)
          : profile.constrainAmbient(
              RigMotion(
                _range(_driver!, 'yaw', 0, -1, 1) * (_routeReverse ? -1 : 1),
                _range(_driver!, 'pitch', 0, -1, 1),
                _range(_driver!, 'roll', 0, -1, 1),
              ),
            );
      _target = schemaFour
          ? {
              'eye': _driver!['eyeMovement'] == 'ユーザー注視'
                  ? const RigMotion()
                  : motion,
            }
          : {(_driver!['driver'] as String? ?? 'head'): motion};
      _followerDelays.clear();
      for (final follower in _driver!['followers'] as List? ?? const []) {
        if (follower is! Map || follower['part'] is! String) continue;
        final part = follower['part'] as String;
        if (_target.containsKey(part)) continue;
        final scale = _number(follower, 'scale', 0).clamp(-1.0, 1.0);
        _target[part] =
            schemaFour && part == 'head' && _driver!['faceMovement'] == '指定方向'
            ? motion
            : motion.scaled(scale);
        _followerDelays[part] = _number(
          follower,
          'delay',
          0.3,
        ).clamp(0.06, 1.0);
      }
      if (schemaFour && _driver!['faceMovement'] == '指定方向') {
        _target['head'] = motion;
        _followerDelays['head'] = _number(
          profile.ambientGaze,
          'headFollowDelay',
          0.1,
        );
      }
      if (schemaFour && _driver!['bodyTilt'] != '傾けない') {
        final body = _target['body'] ?? const RigMotion();
        final sign = _driver!['bodyTilt'] == '逆方向' ? -1.0 : 1.0;
        _target['body'] = RigMotion(body.yaw, body.pitch, motion.roll * sign);
        _followerDelays['body'] ??= _number(
          profile.ambientGaze,
          'bodyFollowDelay',
          0.6,
        );
      }
      final gaze = bandProfile['gaze'] as Map? ?? {};
      final modifiers = gaze['motionModifiers'] as Map? ?? {};
      final tempo = _number(modifiers, 'tempoScale', 1).clamp(0.5, 1.5);
      _transition = _range(_driver!, 'transition', 1, 0.4, 4) / tempo;
      _hold = _range(_driver!, 'hold', 1.5, 0.2, 12);
      _emotion = emotion;
      _driverBand = _band;
      _driverAttitude = attitude;
      _elapsed = 0;
    }
    _elapsed += dt;
    final t = (_elapsed / _transition).clamp(0.0, 1.0);
    final eased = t * t * (3 - 2 * t);
    // Idle motion should read as a living character's breathing and attention,
    // rather than a continuously animated puppet. Keep a visible but bounded
    // baseline so the character does not become a statue between interactions.
    final modifiers =
        (bandProfile['gaze'] as Map?)?['motionModifiers'] as Map? ?? {};
    final authoredStrength = _number(
      modifiers,
      'strengthScale',
      0.85,
    ).clamp(0.0, 1.2);
    final targetStrength = suppressed
        ? 0.0
        : speaking
        ? authoredStrength
        : _usingBindings
        ? 0.8
        : 0.30;
    // Mouth energy includes syllable-rate pulses, especially the Android
    // fallback envelope. It must not shake the head/body. Keep the argument
    // for callers that still use that same energy for lip sync, and ease only
    // the broad speaking state (350 ms attack, 500 ms release, 120 ms hide).
    final strengthResponse = suppressed
        ? 0.12
        : speaking
        ? 0.35
        : 0.9;
    _strength +=
        (targetStrength - _strength) * (1 - exp(-dt / strengthResponse));
    for (final part in {
      'head',
      'body',
      'eye',
      ..._parts.keys,
      ..._target.keys,
    }) {
      final desired = (_from[part] ?? const RigMotion()).blend(
        _target[part] ?? const RigMotion(),
        eased,
      );
      final response = _followerDelays[part] ?? 0.12;
      _parts[part] = (_parts[part] ?? const RigMotion()).blend(
        desired,
        1 - exp(-dt / response),
      );
    }
    return Map.unmodifiable({
      for (final entry in _parts.entries)
        entry.key: entry.value.scaled(_strength),
    });
  }
}

/// Interpolates coarse player notifications, but stops extrapolating on stalls.
Duration interpolatedSpeechPosition(Duration anchor, Duration sinceAnchor) =>
    anchor + Duration(microseconds: min(sinceAnchor.inMicroseconds, 250000));
