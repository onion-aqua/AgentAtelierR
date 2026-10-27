import 'dart:math' as math;
import 'dart:ui';

import 'package:spine_flutter/spine_flutter.dart';

/// A small local region attached to the authored hip controls. It only refines
/// an already-confirmed visible torso surface; it never performs hit testing
/// through clothing or substitutes for the actual attachment's alpha mask.
class CharacterPelvisRegion {
  const CharacterPelvisRegion({
    required this.center,
    required this.across,
    required this.down,
    required this.halfWidth,
    required this.halfHeight,
  });

  final Offset center;
  final Offset across;
  final Offset down;
  final double halfWidth;
  final double halfHeight;

  bool contains(Offset point) {
    if (!point.dx.isFinite || !point.dy.isFinite) return false;
    final relative = point - center;
    final x = (relative.dx * across.dx + relative.dy * across.dy) / halfWidth;
    final y = (relative.dx * down.dx + relative.dy * down.dy) / halfHeight;
    return x * x + y * y <= 1;
  }

  static CharacterPelvisRegion? fromSkeleton(Skeleton skeleton) {
    final standing = skeleton.findBone('weast');
    final waist = standing ?? skeleton.findBone('waist');
    final upper = skeleton.findBone('body2');
    final left = skeleton.findBone('leg_L');
    final right = skeleton.findBone('leg_R');
    if (waist == null || upper == null || left == null || right == null) {
      return null;
    }
    Offset at(Bone bone) => Offset(bone.getWorldX(), bone.getWorldY());
    final origin = at(waist);
    final axis = origin - at(upper);
    final length = axis.distance;
    if (!length.isFinite || length <= 1) return null;
    final down = axis / length;
    final across = Offset(down.dy, -down.dx);
    final hips = at(left) - at(right);
    final span = (hips.dx * across.dx + hips.dy * across.dy).abs();
    if (!span.isFinite || span <= 1) return null;
    final width = (span * .22).clamp(length * .15, length * .48);
    final height = length * .22;
    return CharacterPelvisRegion(
      center: origin + down * length * (standing == null ? .12 : .62),
      across: across,
      down: down,
      halfWidth: math.max(1, width),
      halfHeight: math.max(1, height),
    );
  }
}
