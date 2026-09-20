import 'dart:convert';
import 'dart:math';

import 'character_motion_dynamics.dart';

/// The legacy gesture resource's authored dialogue behavior.
///
/// Animation names are kept verbatim: some eye/mouth names are stems and must
/// be resolved against the active skeleton before they can be played.
class CharacterResourceBehavior {
  const CharacterResourceBehavior._(
    this.profiles, {
    this.fixedBasePoseMode = true,
    this.lockSittingAxis = true,
    this.transitions,
    this.windAnimationPrefix = 'effect_wind',
    this.restGroupsBySitting = const {},
    this.intensityProfiles = const {},
    this.effectAnimations = const {},
  });

  final Map<String, CharacterResourceEmotionProfile> profiles;
  final Map<String, String> effectAnimations;
  final Map<String, Map<String, CharacterResourceEmotionProfile>>
  intensityProfiles;

  CharacterResourceEmotionProfile? profile(String emotion, String intensity) =>
      intensityProfiles[emotion]?[intensity] ?? profiles[emotion];
  final bool fixedBasePoseMode;
  final bool lockSittingAxis;
  final CharacterMotionTransitions? transitions;
  final String windAnimationPrefix;
  final Map<String, String> restGroupsBySitting;

  factory CharacterResourceBehavior.parse(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return const CharacterResourceBehavior._({});
    }
    final root = _map(decoded);
    final emotions = _map(_map(root['emotionalGesture'])['EmotionProfilesV4']);
    final config = _map(root['projectConfig']);
    final closedEye = _text(config['closedEyeAnimation']);
    final result = <String, CharacterResourceEmotionProfile>{};
    final variants = <String, Map<String, CharacterResourceEmotionProfile>>{};
    for (final entry in emotions.entries) {
      final name = entry.key.trim().toLowerCase();
      final data = _map(entry.value);
      if (name.isEmpty || data.isEmpty) continue;
      result[name] = CharacterResourceEmotionProfile._parse(data, closedEye);
      variants[name] = Map.unmodifiable({
        for (final level in ['weak', 'normal', 'strong'])
          if (_map(data['intensityProfiles']).containsKey(level))
            level: CharacterResourceEmotionProfile._parse(
              data,
              closedEye,
              level,
            ),
      });
    }
    return CharacterResourceBehavior._(
      Map.unmodifiable(result),
      intensityProfiles: Map.unmodifiable(variants),
      effectAnimations: Map.unmodifiable({
        for (final entry in _map(config['fxOnAnimNames']).entries)
          if (entry.value is String) entry.key: entry.value as String,
      }),
      fixedBasePoseMode: config['fixedBasePoseMode'] != false,
      lockSittingAxis: config['lockSittingAxis'] != false,
      transitions: CharacterMotionTransitions(root),
      restGroupsBySitting: {
        for (final entry in _map(
          _map(_map(config['armInOutPartConfig'])['idleGroupIds'])['byPosture'],
        ).entries)
          if (entry.value is String) entry.key: entry.value as String,
      },
      windAnimationPrefix: _text(config['windAnimationPrefix']).isEmpty
          ? 'effect_wind'
          : _text(config['windAnimationPrefix']),
    );
  }
}

class CharacterResourceEmotionProfile {
  const CharacterResourceEmotionProfile._({
    this.effectSets = const [],
    required this.expressionSets,
    required this.basePoses,
    required this.mixDurationEye,
    required this.mixDurationEyebrow,
    required this.lipSyncScrubClip,
    required this.baseAnimTimeScale,
    required this.mixDurationMin,
    required this.mixDurationMax,
    required this.poseRerollIntervalMin,
    required this.poseRerollIntervalMax,
    required this.fixedGestureBindingsByAttitude,
  });

  final List<ResourceExpressionSet> expressionSets;
  final List<List<String>> effectSets;
  final List<ResourceBasePose> basePoses;
  final double mixDurationEye;
  final double mixDurationEyebrow;
  final String? lipSyncScrubClip;
  final double baseAnimTimeScale;
  final double mixDurationMin;
  final double mixDurationMax;
  final double poseRerollIntervalMin;
  final double poseRerollIntervalMax;
  final Map<String, List<ResourceAttitudeBinding>>
  fixedGestureBindingsByAttitude;

  factory CharacterResourceEmotionProfile._parse(
    Map<String, Object?> data,
    String closedEyeFallback, [
    String intensity = 'normal',
  ]) {
    final normal = _map(_map(data['intensityProfiles'])[intensity]);
    final expressions = <ResourceExpressionSet>[];
    for (final value in _list(normal['expressionSets'])) {
      final expression = ResourceExpressionSet._parse(
        _map(value),
        closedEyeFallback,
      );
      if (expression != null) expressions.add(expression);
    }
    // Base fields provide a conservative fallback only when no complete
    // expression was authored. Never mix components from different sets.
    if (expressions.isEmpty && _list(normal['expressionSets']).isEmpty) {
      final base = ResourceExpressionSet._parse({
        'id': 'base',
        'eyeOpen': normal['eyeBase'],
        'eyebrow': normal['eyebrowBase'],
        'mouth': normal['mouthBase'],
      }, closedEyeFallback);
      if (base != null) expressions.add(base);
    }
    final poses = <ResourceBasePose>[];
    for (final value in _list(normal['basePoses'])) {
      final pose = ResourceBasePose._parse(_map(value));
      if (pose != null) poses.add(pose);
    }
    final attitudes = <String, List<ResourceAttitudeBinding>>{};
    for (final entry in _map(data['fixedGestureBindingsByAttitude']).entries) {
      final attitude = entry.key.trim().toLowerCase();
      if (attitude.isEmpty) continue;
      final bindings = <ResourceAttitudeBinding>[];
      for (final value in _list(entry.value)) {
        final binding = ResourceAttitudeBinding._parse(_map(value), attitude);
        if (binding != null) bindings.add(binding);
      }
      attitudes[attitude] = List.unmodifiable(bindings);
    }
    final mixMin = _nonNegative(data['mixDurationMin'], 1);
    final mixMax = _nonNegative(data['mixDurationMax'], 2);
    final rerollMin = _positive(normal['poseRerollIntervalMin'], 5);
    final rerollMax = _positive(normal['poseRerollIntervalMax'], 8);
    final lipSync = _text(data['lipSyncScrubClip']);
    return CharacterResourceEmotionProfile._(
      effectSets: List.unmodifiable([
        for (final value in _list(normal['effectSets']))
          if (_weight(_map(value)) > 0)
            List<String>.unmodifiable(_strings(_map(value)['names'])),
      ]),
      expressionSets: List.unmodifiable(expressions),
      basePoses: List.unmodifiable(poses),
      mixDurationEye: _nonNegative(normal['mixDurationEye'], 0.45),
      mixDurationEyebrow: _nonNegative(normal['mixDurationEyebrow'], 0.45),
      lipSyncScrubClip: lipSync.isEmpty ? null : lipSync,
      baseAnimTimeScale: _positive(data['baseAnimTimeScale'], 1),
      mixDurationMin: min(mixMin, mixMax),
      mixDurationMax: max(mixMin, mixMax),
      poseRerollIntervalMin: min(rerollMin, rerollMax),
      poseRerollIntervalMax: max(rerollMin, rerollMax),
      fixedGestureBindingsByAttitude: Map.unmodifiable(attitudes),
    );
  }
}

class ResourceExpressionSet {
  const ResourceExpressionSet({
    required this.id,
    required this.eyeOpen,
    required this.eyeClosed,
    required this.eyebrow,
    required this.mouth,
    this.weight = 1,
  });

  final String id;
  final String eyeOpen;
  final String eyeClosed;
  final String eyebrow;
  final String mouth;
  final double weight;

  static ResourceExpressionSet? _parse(
    Map<String, Object?> data,
    String closedEyeFallback,
  ) {
    final eye = _text(data['eyeOpen']);
    final brow = _text(data['eyebrow']);
    final mouth = _text(data['mouth']);
    final weight = _weight(data);
    if (eye.isEmpty || brow.isEmpty || mouth.isEmpty || weight <= 0) {
      return null;
    }
    final closedEye = _text(data['eyeClosed']);
    return ResourceExpressionSet(
      id: _text(data['id']),
      eyeOpen: eye,
      eyeClosed: closedEye.isEmpty ? closedEyeFallback : closedEye,
      eyebrow: brow,
      mouth: mouth,
      weight: weight,
    );
  }
}

class ResourceBasePose {
  const ResourceBasePose({
    required this.id,
    this.weight = 1,
    this.poseTypeIds = const [],
    this.applicableSittingIds = const [],
  });

  final String id;

  /// This is the pose's explicit weight, not a PoseTypeSets transition weight.
  final double weight;
  final List<String> poseTypeIds;
  final List<String> applicableSittingIds;

  bool supportsSitting(String sittingId) =>
      applicableSittingIds.isEmpty || applicableSittingIds.contains(sittingId);

  static ResourceBasePose? _parse(Map<String, Object?> data) {
    final id = _text(data['id']);
    final weight = _weight(data);
    if (id.isEmpty || weight <= 0) return null;
    return ResourceBasePose(
      id: id,
      weight: weight,
      poseTypeIds: _strings(data['poseTypeIds']),
      applicableSittingIds: _strings(data['applicableSittingIds']),
    );
  }
}

class ResourceAttitudeBinding {
  const ResourceAttitudeBinding({
    required this.attitude,
    required this.oneShotAnimation,
    required this.fixedGestureId,
    required this.eye,
    this.weight = 1,
  });

  final String attitude;
  final String oneShotAnimation;
  final String fixedGestureId;
  final String eye;
  final double weight;

  static ResourceAttitudeBinding? _parse(
    Map<String, Object?> data,
    String attitude,
  ) {
    final animation = _text(data['oneShotAnimation']);
    final gesture = _text(data['fixedGestureId']);
    final weight = _weight(data);
    if ((animation.isEmpty && gesture.isEmpty) || weight <= 0) return null;
    return ResourceAttitudeBinding(
      attitude: attitude,
      oneShotAnimation: animation,
      fixedGestureId: gesture,
      eye: _text(data['eye']),
      weight: weight,
    );
  }
}

/// Returns null for no eligible entries. Zero weights remain disabled, even
/// when every entry is disabled. The caller may filter skeleton compatibility
/// before passing candidates to this function.
T? chooseResourceWeighted<T>(
  Iterable<T> items,
  double Function(T item) weightOf,
  Random random,
) {
  final candidates = <(T, double)>[];
  var maximum = 0.0;
  for (final item in items) {
    final weight = weightOf(item);
    if (!weight.isFinite || weight <= 0) continue;
    candidates.add((item, weight));
    maximum = max(maximum, weight);
  }
  if (candidates.isEmpty) return null;
  // Normalize before summing so valid, very large weights cannot overflow.
  final total = candidates.fold<double>(
    0,
    (sum, item) => sum + item.$2 / maximum,
  );
  var draw = random.nextDouble() * total;
  for (final candidate in candidates) {
    draw -= candidate.$2 / maximum;
    if (draw < 0) return candidate.$1;
  }
  return candidates.last.$1;
}

Map<String, Object?> _map(Object? value) => value is Map
    ? {
        for (final entry in value.entries)
          if (entry.key is String) entry.key as String: entry.value,
      }
    : const {};

List<Object?> _list(Object? value) => value is List ? value : const [];

String _text(Object? value) => value is String ? value.trim() : '';

List<String> _strings(Object? value) =>
    List.unmodifiable(_list(value).map(_text).where((item) => item.isNotEmpty));

double? _number(Object? value) {
  final result = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value.trim())
      : null;
  return result != null && result.isFinite ? result : null;
}

double _weight(Map<String, Object?> data) =>
    data.containsKey('weight') ? max(0, _number(data['weight']) ?? 0) : 1;

double _nonNegative(Object? value, double fallback) {
  final number = _number(value);
  return number != null && number >= 0 ? number : fallback;
}

double _positive(Object? value, double fallback) {
  final number = _number(value);
  return number != null && number > 0 ? number : fallback;
}
