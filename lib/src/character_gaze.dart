import 'dart:math';

import 'package:flutter/material.dart';

const Duration characterGazeHoldDuration = Duration(milliseconds: 1500);
const Duration characterGazeReleaseDuration = Duration(milliseconds: 700);

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
