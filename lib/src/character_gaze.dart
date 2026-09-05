import 'dart:math';

import 'package:flutter/material.dart';

const Duration characterGazeHoldDuration = Duration(milliseconds: 1500);
const Duration characterGazeReleaseDuration = Duration(milliseconds: 700);

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
