import 'dart:math';

import 'package:spine_flutter/spine_flutter.dart';

/// Some scenes reserve a transparent middle band between far_bg and floor.
/// Fit the actual backdrop, not the union of these independently placed layers.
class SceneBackdropBounds extends BoundsProvider {
  const SceneBackdropBounds();

  @override
  Bounds computeBounds(SkeletonDrawable drawable) {
    final slot = drawable.skeleton.findSlot('far_bg');
    final attachment = slot?.getAttachment();
    final vertices = slot == null
        ? const <double>[]
        : switch (attachment) {
            RegionAttachment a => a.computeWorldVertices(slot),
            VertexAttachment a => a.computeWorldVertices(slot),
            _ => const <double>[],
          };
    if (vertices.length < 8 || vertices.any((v) => !v.isFinite)) {
      return drawable.skeleton.getBounds();
    }
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (var i = 0; i + 1 < vertices.length; i += 2) {
      left = min(left, vertices[i]);
      right = max(right, vertices[i]);
      top = min(top, vertices[i + 1]);
      bottom = max(bottom, vertices[i + 1]);
    }
    if (right <= left || bottom <= top) return drawable.skeleton.getBounds();
    return Bounds(left, top, right - left, bottom - top);
  }
}
