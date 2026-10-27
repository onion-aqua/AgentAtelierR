import 'app_localization.dart';

enum BodySensitivityPart {
  head,
  chest,
  abdomen,
  leftArm,
  rightArm,
  hands,
  legs,
  waist,
  intimate,
}

extension BodySensitivityPartData on BodySensitivityPart {
  String label(AppLanguage language) => switch (this) {
    BodySensitivityPart.head => language.text('头部', 'Head', '頭部'),
    BodySensitivityPart.chest => language.text('胸部', 'Chest', '胸部'),
    BodySensitivityPart.abdomen => language.text('腹部', 'Abdomen', '腹部'),
    BodySensitivityPart.leftArm => language.text('左臂', 'Left arm', '左腕'),
    BodySensitivityPart.rightArm => language.text('右臂', 'Right arm', '右腕'),
    BodySensitivityPart.hands => language.text('手部', 'Hands', '手'),
    BodySensitivityPart.legs => language.text('腿部', 'Legs', '脚'),
    BodySensitivityPart.waist => language.text('腰部', 'Waist', '腰部'),
    BodySensitivityPart.intimate => language.text(
      '私处',
      'Private area',
      'デリケートゾーン',
    ),
  };
}

/// Save-owned touch sensitivity, separate from LLM mood/energy proposals.
/// Values are immutable and bounded; a missing legacy field starts at 50.
final class BodySensitivityState {
  BodySensitivityState({
    Map<BodySensitivityPart, int> values = const {},
    Iterable<BodySensitivityPart>? unlocked,
  }) : values = Map.unmodifiable({
         for (final part in BodySensitivityPart.values)
           part: _validated(values[part] ?? defaultValue),
       }),
       unlocked = Set.unmodifiable(unlocked ?? initiallyUnlocked);

  static const defaultValue = 50;
  static const initiallyUnlocked = {
    BodySensitivityPart.head,
    BodySensitivityPart.chest,
    BodySensitivityPart.abdomen,
    BodySensitivityPart.leftArm,
    BodySensitivityPart.rightArm,
    BodySensitivityPart.hands,
    BodySensitivityPart.legs,
    BodySensitivityPart.waist,
  };
  final Map<BodySensitivityPart, int> values;
  final Set<BodySensitivityPart> unlocked;

  int valueFor(BodySensitivityPart part) => values[part]!;
  bool isUnlocked(BodySensitivityPart part) => unlocked.contains(part);

  BodySensitivityState unlock(BodySensitivityPart part) => isUnlocked(part)
      ? this
      : BodySensitivityState(values: values, unlocked: {...unlocked, part});

  BodySensitivityState withValue(BodySensitivityPart part, int value) {
    _validated(value);
    if (!isUnlocked(part)) {
      throw StateError('Body sensitivity is locked: ${part.name}');
    }
    if (valueFor(part) == value) return this;
    return BodySensitivityState(
      values: {...values, part: value},
      unlocked: unlocked,
    );
  }

  static int _validated(int value) {
    if (value < 0 || value > 100) {
      throw RangeError.range(value, 0, 100, 'sensitivity');
    }
    return value;
  }

  Map<String, dynamic> toJson() => {
    'version': 2,
    'values': {
      for (final part in BodySensitivityPart.values) part.name: valueFor(part),
    },
    'unlocked': [
      for (final part in BodySensitivityPart.values)
        if (isUnlocked(part)) part.name,
    ],
  };

  factory BodySensitivityState.fromJson(Object? raw) {
    if (raw == null) return BodySensitivityState();
    if (raw is! Map ||
        raw['version'] is! int ||
        !const {1, 2}.contains(raw['version']) ||
        raw['values'] is! Map) {
      throw const FormatException('身体敏感度数据格式无效');
    }
    final values = raw['values'] as Map;
    final legacy = raw['version'] == 1;
    final parts = legacy ? initiallyUnlocked : BodySensitivityPart.values;
    final names = parts.map((part) => part.name).toSet();
    if (values.length != names.length ||
        values.keys.any((key) => !names.contains(key)) ||
        values.values.any(
          (value) => value is! int || value < 0 || value > 100,
        )) {
      throw const FormatException('身体敏感度数值无效');
    }
    Set<BodySensitivityPart> unlocked;
    if (legacy) {
      // Older saves knew only these eight parts. Adding the new stat must not
      // manufacture a prior deliberate unlock or change their existing values.
      unlocked = initiallyUnlocked;
    } else {
      final rawUnlocked = raw['unlocked'];
      if (rawUnlocked is! List ||
          rawUnlocked.any((part) => part is! String || !names.contains(part)) ||
          rawUnlocked.toSet().length != rawUnlocked.length) {
        throw const FormatException('身体敏感度解锁记录无效');
      }
      unlocked = {
        for (final name in rawUnlocked)
          BodySensitivityPart.values.byName(name as String),
      };
    }
    return BodySensitivityState(
      values: {for (final part in parts) part: values[part.name] as int},
      unlocked: unlocked,
    );
  }

  /// Hit-box names are inherited from the authored rig, including "weast".
  static BodySensitivityPart? partForHit(String hitPart) => switch (hitPart) {
    'head' => BodySensitivityPart.head,
    'breast' || 'chest' => BodySensitivityPart.chest,
    'body' || 'abdomen' => BodySensitivityPart.abdomen,
    'arm_l' || 'leftArm' => BodySensitivityPart.leftArm,
    'arm_r' || 'rightArm' => BodySensitivityPart.rightArm,
    'hands' || 'hand' || 'hand_l' || 'hand_r' => BodySensitivityPart.hands,
    'legs' || 'leg' || 'leg_l' || 'leg_r' => BodySensitivityPart.legs,
    'weast' || 'waist' => BodySensitivityPart.waist,
    'intimate' || 'pelvis' => BodySensitivityPart.intimate,
    _ => null,
  };
}
