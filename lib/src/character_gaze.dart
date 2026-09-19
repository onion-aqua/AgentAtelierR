import 'dart:math';

import 'package:flutter/material.dart';

const Duration characterGazeHoldDuration = Duration(milliseconds: 1500);
const Duration characterGazeReleaseDuration = Duration(milliseconds: 700);

typedef GazeBoneOffset = ({Offset translation, double rotation});

/// Only these authored controls and shoulder joints are changed. Root, hips,
/// feet and hand/finger bones remain owned by the pose and its constraints.
const characterBodyGazeBones = {
  'control_aim_head',
  'control_aim_body',
  'control_roll_head',
  'control_roll_neck',
  'control_roll_body_upper',
  'control_roll_body_lower',
  'shoulder_L',
  'shoulder_R',
};

class CharacterBodyGaze {
  Offset _head = Offset.zero;
  Offset _body = Offset.zero;
  Offset _arms = Offset.zero;

  void reset() {
    _head = Offset.zero;
    _body = Offset.zero;
    _arms = Offset.zero;
  }

  Map<String, GazeBoneOffset> sample({
    required Offset direction,
    required double delta,
    required double influence,
    required bool standing,
    required bool crossLegged,
    required bool allowShoulders,
    required bool busy,
    required bool tapReaction,
  }) {
    if (influence <= 0) {
      reset();
      return const {};
    }
    final target = direction.distance > 1
        ? direction / direction.distance
        : direction;
    final dt = delta.isFinite ? delta.clamp(0.0, 0.05) : 0.0;
    Offset follow(Offset current, Offset goal, double seconds) =>
        Offset.lerp(current, goal, 1 - exp(-dt / seconds))!;
    final weight = tapReaction
        ? 0.0
        : busy
        ? 0.45
        : 1.0;
    _head = follow(_head, target * (tapReaction ? 0 : 1), 0.10);
    _body = follow(_body, target * weight, 0.20);
    _arms = follow(
      _arms,
      allowShoulders && !busy && !tapReaction ? target : Offset.zero,
      0.28,
    );
    final fade = influence.clamp(0.0, 1.0);
    final head = _head * fade;
    final body = _body * fade;
    final arms = _arms * fade;
    final torsoScale = standing
        ? 1.0
        : crossLegged
        ? 0.6
        : 0.8;
    final lowerScale = standing
        ? 1.0
        : crossLegged
        ? 0.18
        : 0.32;
    final armScale = standing
        ? 1.0
        : crossLegged
        ? 0.0
        : 0.55;
    GazeBoneOffset offset(double x, double y, [double rotation = 0]) =>
        (translation: Offset(x, y), rotation: rotation);
    return {
      'control_aim_head': offset(head.dx * 48, head.dy * 34),
      'control_aim_body': offset(
        body.dx * 55 * torsoScale,
        body.dy * 38 * torsoScale,
      ),
      // These are IK targets: rotating the target has no effect. Translating
      // it lets the authored constraints rotate the corresponding body chain.
      'control_roll_head': offset(head.dx * 40, 0),
      'control_roll_neck': offset(head.dx * 20, 0),
      'control_roll_body_upper': offset(body.dx * 80 * torsoScale, 0),
      'control_roll_body_lower': offset(body.dx * 32 * lowerScale, 0),
      'shoulder_L': offset(0, 0, (arms.dx * 3 + arms.dy * 1.5) * armScale),
      'shoulder_R': offset(0, 0, (arms.dx * 3 - arms.dy * 1.5) * armScale),
    };
  }
}

Offset gazeControlOffset({
  required Offset face,
  required Offset pointer,
  double maxDistance = 514.7,
  double maxOffset = 140,
}) {
  final delta = pointer - face;
  if (maxDistance <= 0 || maxOffset <= 0) return Offset.zero;
  return delta / max(maxDistance, delta.distance) * maxOffset;
}

double characterGazeInfluence(Duration elapsed) {
  if (elapsed <= Duration.zero) return 1;
  if (elapsed <= characterGazeHoldDuration) return 1;
  final releaseElapsed = elapsed - characterGazeHoldDuration;
  if (releaseElapsed >= characterGazeReleaseDuration) return 0;
  final progress =
      releaseElapsed.inMicroseconds /
      characterGazeReleaseDuration.inMicroseconds;
  final remaining = 1 - progress;
  return remaining * remaining * (3 - 2 * remaining);
}

Offset directionalGazeTarget({
  required Offset origin,
  required Offset pointer,
  required double radius,
}) {
  final delta = pointer - origin;
  final distance = sqrt(delta.dx * delta.dx + delta.dy * delta.dy);
  if (distance < 0.001 || radius <= 0) return origin;
  return origin + delta / distance * radius;
}
