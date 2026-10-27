import 'dart:math' as math;
import 'dart:ui';

import 'package:spine_flutter/spine_flutter.dart';

import 'character_touch_hit_mask.dart';
import 'character_body_touch_part.dart';
import 'character_pelvis_region.dart';
import 'character_touch_physics.dart';
import 'runtime_log.dart';

/// Excites only physical bones influencing the visible touched triangle.
/// Never stretches body meshes or changes local bones/animation parameters.
class CharacterTouchPhysicsRig {
  final dynamics = CharacterTouchPhysicsDynamics();
  Skeleton? _skeleton;
  List<PhysicsConstraint> _constraints = const [];
  List<List<int>> _boneConstraints = const [];
  final Map<int, List<Map<int, double>>> _meshWeights = {};
  final Set<int> _excited = {};
  CharacterTouchHitMask? _hitMask;
  int _prepareGeneration = 0;
  double _referenceWidth = 0;
  Map<int, double> _targets = const {};
  bool _pointerDown = false;
  bool _pendingTap = false;
  String? _touchedBodyPart;

  bool get isTouching => _pointerDown;
  bool get active => dynamics.active || _pendingTap;

  /// The foremost opaque body surface hit by the most recent begin/move.
  /// This can be set even when the surface has no physical spring to excite.
  String? get touchedBodyPart => _touchedBodyPart;
  bool get bodyPartHitTestReady => _hitMask != null;

  /// Cache alpha masks once, outside pointer/render callbacks. Atlas images
  /// are cloned before awaiting, so a replaced drawable can be freed safely.
  Future<void> prepare(SkeletonDrawable drawable) async {
    _bind(drawable.skeleton);
    final generation = ++_prepareGeneration;
    _hitMask = null;
    try {
      final mask = await CharacterTouchHitMask.fromAtlas(drawable.atlas);
      if (generation == _prepareGeneration &&
          identical(_skeleton, drawable.skeleton)) {
        _hitMask = mask;
      }
    } on Object catch (error, stack) {
      if (generation == _prepareGeneration) {
        RuntimeLog.instance.error('CharacterTouchPhysics', error, stack);
      }
    }
  }

  void _bind(Skeleton skeleton) {
    if (identical(skeleton, _skeleton)) return;
    reset(resetNative: false);
    _skeleton = skeleton;
    _hitMask = null;
    _meshWeights.clear();
    _constraints = skeleton.getPhysicsConstraints();
    final bones = skeleton.getBones();
    final direct = <int, List<int>>{};
    for (var i = 0; i < _constraints.length; i++) {
      final bone = _constraints[i].getBone().getData().getIndex();
      (direct[bone] ??= []).add(i);
    }
    // Resolve to the nearest physical ancestor. Searching descendants or
    // nearby bones would excite unrelated body parts.
    _boneConstraints = [
      for (final bone in bones) _nearestConstraints(bone, direct),
    ];
    final face = skeleton
        .getSlots()
        .where(
          (slot) => RegExp(r'(?:^|_)face$').hasMatch(slot.getData().getName()),
        )
        .firstOrNull;
    final vertices = face == null ? const <double>[] : _worldVertices(face);
    _referenceWidth = _bounds(vertices)?.width ?? 300;
    if (!_referenceWidth.isFinite || _referenceWidth <= 1) {
      _referenceWidth = 300;
    }
  }

  bool begin(Skeleton skeleton, Offset point) {
    _bind(skeleton);
    dynamics.reset();
    _pendingTap = false;
    _pointerDown = point.dx.isFinite && point.dy.isFinite;
    _targets = _constraintsAt(point);
    if (_targets.isEmpty) return false;
    dynamics.begin();
    _pendingTap = true;
    return true;
  }

  void move(Offset position, Offset normalizedVelocity) {
    if (!_pointerDown) return;
    if (!position.dx.isFinite || !position.dy.isFinite) {
      _touchedBodyPart = null;
      release();
      return;
    }
    final targets = _constraintsAt(position);
    if (!_sameParts(_targets, targets)) {
      // Old native springs settle normally, but their accumulated input must
      // not be carried onto a newly touched part or across empty space.
      dynamics.reset();
      _pendingTap = false;
      if (targets.isNotEmpty) dynamics.begin();
    }
    _targets = targets;
    if (targets.isNotEmpty) dynamics.move(normalizedVelocity);
  }

  /// Ordinary release retains spring history on the touched part.
  void release() {
    _pointerDown = false;
    dynamics.release();
  }

  /// After animation/procedural pose, before the single Physics.update.
  void apply(double delta) {
    if (!active) return;
    if (!delta.isFinite || delta < 0 || delta > .2) {
      reset();
      return;
    }
    if (delta == 0) return;
    var normalizedImpulse = dynamics.advance(delta);
    if (_pendingTap) {
      normalizedImpulse += const Offset(
        CharacterTouchPhysicsDynamics.pressImpulse,
        0,
      );
      _pendingTap = false;
    }
    if (normalizedImpulse.distanceSquared < 1e-16) return;
    final impulse = normalizedImpulse * _referenceWidth;
    for (final target in _targets.entries) {
      final constraint = _constraints[target.key];
      if (!constraint.isActive() || constraint.getMix() <= .001) continue;
      constraint.translate(
        impulse.dx * target.value,
        impulse.dy * target.value,
      );
      _excited.add(target.key);
    }
  }

  void reset({bool resetNative = true}) {
    if (resetNative) {
      for (final index in _excited) {
        _constraints[index].resetFully();
      }
    } else {
      ++_prepareGeneration;
    }
    dynamics.reset();
    _targets = const {};
    _pointerDown = false;
    _pendingTap = false;
    _excited.clear();
    _touchedBodyPart = null;
  }

  Map<int, double> _constraintsAt(Offset point) {
    _touchedBodyPart = null;
    final skeleton = _skeleton;
    final mask = _hitMask;
    if (skeleton == null ||
        mask == null ||
        !point.dx.isFinite ||
        !point.dy.isFinite) {
      return const {};
    }
    // Respect live draw order and clipping. A nonphysical opaque surface also
    // occludes physical attachments behind it; there is no through-body hit.
    final visible = <Slot>[];
    int? clipEnd;
    bool? insideClip;
    for (final slot in skeleton.getDrawOrder()) {
      final index = slot.getData().getIndex();
      final attachment = slot.getAttachment();
      // Match SkeletonRenderer: clip attachments still start clipping when
      // their slot is transparent or its bone is inactive.
      if (attachment is ClippingAttachment) {
        if (insideClip == null) {
          insideClip = _insidePolygon(
            point,
            attachment.computeWorldVertices(slot),
          );
          clipEnd = attachment.getEndSlot()?.getIndex();
        }
        continue;
      }
      if (slot.getBone().isActive() &&
          insideClip != false &&
          slot.getColor().a > .01) {
        visible.add(slot);
      }
      if (index == clipEnd) {
        insideClip = null;
        clipEnd = null;
      }
    }
    for (final slot in visible.reversed) {
      final attachment = slot.getAttachment();
      final List<double> vertices;
      final List<int> triangles;
      final List<double> uvs;
      final TextureRegion? region;
      if (attachment is MeshAttachment && attachment.getColor().a > .01) {
        vertices = attachment.computeWorldVertices(slot);
        triangles = attachment.getTriangles();
        uvs = attachment.getUVs();
        region = attachment.getRegion();
      } else if (attachment is RegionAttachment &&
          attachment.getColor().a > .01) {
        vertices = attachment.computeWorldVertices(slot);
        triangles = const [0, 1, 2, 2, 3, 0];
        uvs = attachment.getUVs();
        region = attachment.getRegion();
      } else {
        continue;
      }
      if (region == null) continue;
      final hit = _triangleAt(point, vertices, triangles);
      if (hit == null) continue;
      var u = 0.0, v = 0.0;
      for (var i = 0; i < 3; i++) {
        final vertex = hit.indices[i] * 2;
        if (vertex + 1 >= uvs.length) return const {};
        u += uvs[vertex] * hit.weights[i];
        v += uvs[vertex + 1] * hit.weights[i];
      }
      // This runtime's texture pointer encodes the atlas page (0 is valid).
      // Transparent padding must not steal the hit from a lower visible part.
      if (!mask.opaqueAt(region.getTexture().address, u, v)) continue;
      _touchedBodyPart = characterBodyTouchPart(
        slotName: slot.getData().getName(),
        boneName: slot.getBone().getData().getName(),
        attachmentPath: attachment is MeshAttachment
            ? attachment.getPath()
            : (attachment as RegionAttachment).getPath(),
      );
      if (_touchedBodyPart == 'body') {
        _touchedBodyPart = _torsoPartAt(skeleton, point) ?? 'body';
      }
      // The large authored BB_weast extends over both thighs. Only refine a
      // visible, recognized torso surface inside the small hip-local region.
      // Hands, legs and opaque foreground clothes must keep their own result.
      if ((_touchedBodyPart == 'body' || _touchedBodyPart == 'weast') &&
          (CharacterPelvisRegion.fromSkeleton(skeleton)?.contains(point) ??
              false)) {
        _touchedBodyPart = 'intimate';
      }
      if (attachment is! MeshAttachment || attachment.getBones().isEmpty) {
        return _resolveWeights({slot.getBone().getData().getIndex(): 1});
      }
      final weights = _meshWeights.putIfAbsent(
        attachment.runtimeIdentity,
        () => _decodeWeights(attachment),
      );
      final interpolated = <int, double>{};
      for (var i = 0; i < 3; i++) {
        if (hit.indices[i] >= weights.length) return const {};
        for (final entry in weights[hit.indices[i]].entries) {
          interpolated.update(
            entry.key,
            (value) => value + entry.value * hit.weights[i],
            ifAbsent: () => entry.value * hit.weights[i],
          );
        }
      }
      return _resolveWeights(interpolated);
    }
    return const {};
  }

  String? _torsoPartAt(Skeleton skeleton, Offset point) {
    String? part;
    var smallest = double.infinity;
    for (final entry in const {
      'BB_breast': 'breast',
      'BB_body': 'body',
      'BB_weast': 'weast',
    }.entries) {
      final slot = skeleton.findSlot(entry.key);
      final attachment = slot?.getAttachment();
      if (slot == null || attachment is! BoundingBoxAttachment) continue;
      final vertices = attachment.computeWorldVertices(slot);
      if (!_insidePolygon(point, vertices)) continue;
      final bounds = _bounds(vertices);
      if (bounds == null) continue;
      final area = bounds.width * bounds.height;
      if (area < smallest) {
        smallest = area;
        part = entry.value;
      }
    }
    return part;
  }

  Map<int, double> _resolveWeights(Map<int, double> weights) {
    final targets = <int, double>{};
    for (final entry in weights.entries) {
      if (entry.key < 0 ||
          entry.key >= _boneConstraints.length ||
          entry.value < .02) {
        continue;
      }
      for (final index in _boneConstraints[entry.key]) {
        final constraint = _constraints[index];
        if (!constraint.isActive() || constraint.getMix() <= .001) continue;
        targets.update(
          index,
          (weight) => weight + entry.value,
          ifAbsent: () => entry.value,
        );
      }
    }
    if (targets.isEmpty) return const {};
    final peak = targets.values.reduce(math.max);
    return {for (final entry in targets.entries) entry.key: entry.value / peak};
  }
}

List<int> _nearestConstraints(Bone bone, Map<int, List<int>> direct) {
  for (Bone? current = bone; current != null; current = current.getParent()) {
    final constraints = direct[current.getData().getIndex()];
    if (constraints != null) return constraints;
  }
  return const [];
}

bool _sameParts(Map<int, double> a, Map<int, double> b) =>
    a.length == b.length && a.keys.every(b.containsKey);

List<Map<int, double>> _decodeWeights(MeshAttachment mesh) {
  final bones = mesh.getBones();
  final vertices = mesh.getVertices();
  final weights = <Map<int, double>>[];
  var offset = 0;
  for (var i = 0; i < bones.length;) {
    final count = bones[i++];
    if (count < 0 ||
        i + count > bones.length ||
        offset + count * 3 > vertices.length) {
      return const [];
    }
    final vertex = <int, double>{};
    for (var j = 0; j < count; j++) {
      final index = bones[i++];
      final weight = vertices[offset + 2];
      offset += 3;
      if (weight.isFinite && weight > 0) {
        vertex.update(index, (value) => value + weight, ifAbsent: () => weight);
      }
    }
    weights.add(vertex);
  }
  return weights;
}

List<double> _worldVertices(Slot slot) {
  final attachment = slot.getAttachment();
  if (attachment is VertexAttachment) {
    return attachment.computeWorldVertices(slot);
  }
  if (attachment is RegionAttachment) {
    return attachment.computeWorldVertices(slot);
  }
  return const [];
}

Rect? _bounds(List<double> vertices) {
  if (vertices.length < 2) return null;
  var left = double.infinity, top = double.infinity;
  var right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (var i = 0; i + 1 < vertices.length; i += 2) {
    left = math.min(left, vertices[i]);
    right = math.max(right, vertices[i]);
    top = math.min(top, vertices[i + 1]);
    bottom = math.max(bottom, vertices[i + 1]);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

({List<int> indices, List<double> weights})? _triangleAt(
  Offset p,
  List<double> vertices,
  List<int> triangles,
) {
  final bounds = _bounds(vertices);
  if (bounds == null || !bounds.contains(p)) return null;
  Offset at(int i) => Offset(vertices[i * 2], vertices[i * 2 + 1]);
  double cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;
  for (var i = 0; i + 2 < triangles.length; i += 3) {
    final a = triangles[i], b = triangles[i + 1], c = triangles[i + 2];
    if (a < 0 ||
        b < 0 ||
        c < 0 ||
        [a, b, c].any((v) => v * 2 + 1 >= vertices.length)) {
      continue;
    }
    final aa = at(a), ab = at(b) - aa, ac = at(c) - aa;
    final denominator = cross(ab, ac);
    if (denominator.abs() < 1e-8) continue;
    final bWeight = cross(p - aa, ac) / denominator;
    final cWeight = cross(ab, p - aa) / denominator;
    final aWeight = 1 - bWeight - cWeight;
    if (aWeight < -1e-6 || bWeight < -1e-6 || cWeight < -1e-6) continue;
    final weights = [
      aWeight,
      bWeight,
      cWeight,
    ].map((w) => w.clamp(0.0, 1.0)).toList();
    final sum = weights.fold(0.0, (a, b) => a + b);
    return (indices: [a, b, c], weights: weights.map((w) => w / sum).toList());
  }
  return null;
}

bool _insidePolygon(Offset p, List<double> vertices) {
  if (vertices.length < 6) return false;
  var inside = false;
  for (var i = 0, j = vertices.length - 2; i < vertices.length; j = i, i += 2) {
    final xi = vertices[i], yi = vertices[i + 1];
    final xj = vertices[j], yj = vertices[j + 1];
    if ((yi > p.dy) != (yj > p.dy) &&
        p.dx < (xj - xi) * (p.dy - yi) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}
