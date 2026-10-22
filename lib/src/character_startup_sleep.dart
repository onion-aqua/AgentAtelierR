import 'dart:math' as math;

import 'character_expression.dart';
import 'character_speech_driver.dart';

/// Existing neutral face resources, with the authored eyes-closed variation.
/// Missing clips remain optional for imported skins; native Spine lookups must
/// never be given an invented animation or an empty bone/animation name.
class CharacterStartupSleepFace {
  const CharacterStartupSleepFace({this.eye, this.eyebrow, this.mouth});

  final String? eye;
  final String? eyebrow;
  final String? mouth;
}

CharacterStartupSleepFace resolveStartupSleepFace(
  String appearanceId,
  bool Function(String) hasAnimation,
) {
  final preset = characterExpressionPreset(
    appearanceId,
    CharacterExpression.neutral,
  );
  String? available(String name) => hasAnimation(name) ? name : null;
  String? closedEye;
  for (final detail in characterFacialDetails(
    appearanceId,
    CharacterExpression.neutral,
  )) {
    if (hasAnimation(detail.closedEye)) {
      closedEye = detail.closedEye;
      break;
    }
  }
  return CharacterStartupSleepFace(
    eye: closedEye,
    eyebrow: available(preset.eyebrow),
    mouth: available(preset.mouth),
  );
}

class CharacterStartupSleepFrame {
  const CharacterStartupSleepFrame({
    required this.blend,
    required this.head,
    required this.body,
  });

  /// One while asleep, then smoothly reaches zero after the wake interaction.
  final double blend;
  final RigMotion head;
  final RigMotion body;

  /// Uses the caller's existing procedural-rig snapshot/restore path. Only
  /// head/body controls breathe; the root, hips, limbs and authored base pose
  /// remain owned by Spine, and waking never snaps to an unrelated pose.
  Map<String, RigMotion> merge(Map<String, RigMotion> awake) {
    if (blend == 0) return awake;
    final asleep = {'head': head, 'body': body, 'eye': const RigMotion()};
    return {
      for (final part in {...awake.keys, ...asleep.keys})
        part: (awake[part] ?? const RigMotion()).blend(
          asleep[part] ?? const RigMotion(),
          blend,
        ),
    };
  }
}

/// Frame-delta driven sleeping pose. This deliberately does not pause the
/// drawable: its authored idle track, cloth/hair physics and breathing continue
/// advancing even when the chat input and automatic gestures are locked.
class CharacterStartupSleepMotion {
  static const breathPeriodSeconds = 4.6;
  static const wakeDurationSeconds = .65;

  bool? _previousSleeping;
  double _phase = 0;
  double _wakeElapsed = 0;
  double _wakeStartBlend = 0;
  double _blend = 0;

  CharacterStartupSleepFrame sample({
    required double delta,
    required bool sleeping,
  }) {
    final dt = delta.isFinite ? delta.clamp(0.0, .1) : 0.0;
    _phase = (_phase + dt / breathPeriodSeconds) % 1;
    if (sleeping) {
      // Start asleep on the first visible frame, without a blink-open prelude.
      _blend = 1;
      _wakeElapsed = 0;
    } else if (_previousSleeping == true) {
      _wakeStartBlend = _blend;
      _wakeElapsed = 0;
    }
    if (!sleeping && _blend > 0) {
      _wakeElapsed = math.min(wakeDurationSeconds, _wakeElapsed + dt);
      final t = _wakeElapsed / wakeDurationSeconds;
      final eased = t * t * (3 - 2 * t);
      _blend = _wakeStartBlend * (1 - eased);
    }
    _previousSleeping = sleeping;
    final breath = math.sin(_phase * 2 * math.pi);
    return CharacterStartupSleepFrame(
      blend: _blend,
      head: RigMotion(0, -.16 + breath * .014, .045 + breath * .004),
      body: RigMotion(0, .012 + breath * .035, 0),
    );
  }
}
