import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:spine_flutter/spine_flutter.dart';

import 'protected_character_assets.dart';
import 'character_pelvis_region.dart';

/// A borrowed, cached silhouette. Callers must not dispose [image] directly.
/// Anchors use the same normalized image coordinates as the rendered body.
class CharacterStatusSilhouette {
  CharacterStatusSilhouette({
    required this.image,
    required Map<String, ui.Offset> normalizedAnchors,
  }) : normalizedAnchors = Map.unmodifiable(normalizedAnchors);

  final ui.Image image;
  final Map<String, ui.Offset> normalizedAnchors;
  bool _disposed = false;
  bool get isDisposed => _disposed;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    image.dispose();
  }
}

/// Makes one static, full-body Ryza image from the existing encrypted standing
/// rig. It does not switch the chat's active skin or write decrypted images.
abstract final class CharacterStatusSilhouettes {
  static const assetName = 'crf_skn_002_0001_99';
  static const _root = 'assets/character/ryza/$assetName/$assetName';
  static Future<CharacterStatusSilhouette>? _pending;
  static CharacterStatusSilhouette? _resolved;
  static int _generation = 0;

  static Future<CharacterStatusSilhouette> ryza() => _loadCached(_loadRyza);

  static Future<CharacterStatusSilhouette> _loadCached(
    Future<CharacterStatusSilhouette> Function() load,
  ) {
    final cached = _pending;
    if (cached != null) return cached;
    final generation = _generation;
    late final Future<CharacterStatusSilhouette> future;
    future = Future.sync(load).then(
      (result) {
        if (generation != _generation || !identical(_pending, future)) {
          result.dispose();
          throw StateError('Character status silhouette load was superseded');
        }
        _resolved = result;
        return result;
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_pending, future)) _pending = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
    _pending = future;
    return future;
  }

  /// Release only when no status view still borrows the cached image.
  /// A pending renderer is invalidated and disposes its image when it arrives.
  static void clearCache() {
    _generation++;
    _pending = null;
    _resolved?.dispose();
    _resolved = null;
  }

  @visibleForTesting
  static Future<CharacterStatusSilhouette> loadCachedForTest(
    Future<CharacterStatusSilhouette> Function() load,
  ) => _loadCached(load);

  static Future<CharacterStatusSilhouette> _loadRyza() async {
    await initSpineFlutter();
    final files = await ProtectedCharacterAssets.originalFilesFor(assetName);
    return fromBundle(ProtectedCharacterAssetBundle(files));
  }

  /// Independent loading keeps atlas/data ownership explicit even on errors.
  /// Tests can supply their owned local rig without accessing a build key.
  static Future<CharacterStatusSilhouette> fromBundle(
    AssetBundle bundle, {
    String atlasPath = '$_root.atlas',
    String skeletonPath = '$_root.skel',
  }) async {
    Atlas? atlas;
    SkeletonData? data;
    SkeletonDrawable? drawable;
    try {
      atlas = await Atlas.fromAsset(atlasPath, bundle: bundle);
      data = await SkeletonData.fromAsset(atlas, skeletonPath, bundle: bundle);
      drawable = SkeletonDrawable(atlas, data, true);
      return await renderFromDrawable(drawable);
    } finally {
      if (drawable != null) {
        drawable.dispose();
      } else {
        data?.dispose();
        atlas?.dispose();
      }
    }
  }

  /// Renders the authored standing idle to white alpha on transparent pixels.
  /// The caller retains ownership of [drawable]; no native objects are cached.
  static Future<CharacterStatusSilhouette> renderFromDrawable(
    SkeletonDrawable drawable,
  ) async {
    const idle = 'motion_A_001_idle';
    if (drawable.skeletonData.findAnimation(idle) == null) {
      throw const FormatException('Standing silhouette idle is unavailable');
    }
    drawable.animationState.clearTracks();
    drawable.skeleton.setToSetupPose();
    drawable.animationState.setAnimationByName(0, idle, true);
    for (var i = 0; i < 30; i++) {
      drawable.update(1 / 60);
    }
    final nativeBounds = drawable.skeleton.getBounds();
    final bounds = ui.Rect.fromLTWH(
      nativeBounds.x,
      nativeBounds.y,
      nativeBounds.width,
      nativeBounds.height,
    );
    if (!bounds.isFinite || bounds.width <= 0 || bounds.height <= 0) {
      throw const FormatException('Standing silhouette bounds are invalid');
    }

    const width = 512;
    const height = 1024;
    const padding = 20.0;
    final scale = math.min(
      (width - padding * 2) / bounds.width,
      (height - padding * 2) / bounds.height,
    );
    final center = const ui.Offset(width / 2, height / 2);
    ui.Offset normalized(ui.Offset point) {
      final pixel = center + (point - bounds.center) * scale;
      return ui.Offset(pixel.dx / width, pixel.dy / height);
    }

    final anchors = <String, ui.Offset>{};
    for (final entry in const {
      'BB_head': 'head',
      'BB_body': 'body',
      'BB_arm_L': 'arm_l',
      'BB_arm_R': 'arm_r',
      'BB_weast': 'weast',
      'BB_breast': 'breast',
    }.entries) {
      final slot = drawable.skeleton.findSlot(entry.key);
      final attachment = slot?.getAttachment();
      if (slot == null || attachment is! BoundingBoxAttachment) continue;
      final vertices = attachment.computeWorldVertices(slot);
      if (vertices.length < 6 || vertices.length.isOdd) continue;
      var x = 0.0;
      var y = 0.0;
      for (var i = 0; i < vertices.length; i += 2) {
        x += vertices[i];
        y += vertices[i + 1];
      }
      anchors[entry.value] = normalized(
        ui.Offset(x / (vertices.length / 2), y / (vertices.length / 2)),
      );
    }

    ui.Offset relative(double x, double y) => normalized(
      ui.Offset(bounds.left + bounds.width * x, bounds.top + bounds.height * y),
    );
    anchors['head'] ??= relative(.5, .16);
    anchors['chest'] = anchors['breast'] ?? relative(.5, .34);
    anchors['abdomen'] =
        anchors['body'] ?? anchors['weast'] ?? relative(.5, .48);
    anchors['arm'] = anchors['arm_l'] ?? anchors['arm_r'] ?? relative(.24, .45);
    final waist = drawable.skeleton.findBone('weast');
    anchors['waist'] = waist == null
        ? anchors['body'] ?? relative(.5, .40)
        : normalized(ui.Offset(waist.getWorldX(), waist.getWorldY()));
    final pelvis = CharacterPelvisRegion.fromSkeleton(drawable.skeleton);
    if (pelvis != null) anchors['intimate'] = normalized(pelvis.center);
    // Bounds-relative legs remain stable for this fixed, authored standing rig.
    anchors['legs'] = relative(.55, .78);
    final hand = drawable.skeleton.findSlot('101_arm_01');
    final handAttachment = hand?.getAttachment();
    final handVertices = hand == null
        ? const <double>[]
        : handAttachment is MeshAttachment
        ? handAttachment.computeWorldVertices(hand)
        : handAttachment is RegionAttachment
        ? handAttachment.computeWorldVertices(hand)
        : const <double>[];
    if (handVertices.length >= 6 && handVertices.length.isEven) {
      var x = 0.0, y = 0.0;
      for (var i = 0; i < handVertices.length; i += 2) {
        x += handVertices[i];
        y += handVertices[i + 1];
      }
      anchors['hands'] = normalized(
        ui.Offset(x * 2 / handVertices.length, y * 2 / handVertices.length),
      );
    } else {
      anchors['hands'] = relative(.12, .43);
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    ui.Picture? picture;
    try {
      canvas.saveLayer(
        const ui.Rect.fromLTWH(0, 0, 512, 1024),
        ui.Paint()
          ..colorFilter = const ui.ColorFilter.mode(
            ui.Color(0xFFFFFFFF),
            ui.BlendMode.srcIn,
          ),
      );
      canvas.translate(center.dx, center.dy);
      canvas.scale(scale);
      canvas.translate(-bounds.center.dx, -bounds.center.dy);
      drawable.renderToCanvas(canvas);
      canvas.restore();
      picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      return CharacterStatusSilhouette(
        image: image,
        normalizedAnchors: anchors,
      );
    } finally {
      (picture ?? recorder.endRecording()).dispose();
    }
  }
}
