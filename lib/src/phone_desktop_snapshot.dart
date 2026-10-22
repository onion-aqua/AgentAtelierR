import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

/// A small, already blurred image. No backdrop readback is needed while the
/// settings list scrolls. Each app opening owns a new snapshot of its desktop.
ui.Image? capturePhoneDesktop(
  RenderRepaintBoundary boundary,
  RenderBox viewport,
) {
  if (!boundary.hasSize || !viewport.hasSize || boundary.debugNeedsPaint) {
    return null;
  }
  final origin = boundary.globalToLocal(viewport.localToGlobal(Offset.zero));
  final bounds = origin & viewport.size;
  // Blur hides high frequency detail; physical display resolution adds cost
  // without visible benefit. Limit even desktop windows to a small texture.
  final ratio = (640 / viewport.size.longestSide).clamp(.1, 1.0);
  final source = boundary.toImageSync(pixelRatio: ratio);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final rect = ui.Rect.fromLTWH(
    0,
    0,
    (viewport.size.width * ratio).ceilToDouble(),
    (viewport.size.height * ratio).ceilToDouble(),
  );
  canvas.saveLayer(
    rect,
    ui.Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: 24 * ratio,
        sigmaY: 24 * ratio,
        tileMode: ui.TileMode.clamp,
      ),
  );
  canvas.drawImageRect(
    source,
    ui.Rect.fromLTWH(
      bounds.left * ratio,
      bounds.top * ratio,
      bounds.width * ratio,
      bounds.height * ratio,
    ),
    rect,
    ui.Paint(),
  );
  canvas.restore();
  final picture = recorder.endRecording();
  try {
    return picture.toImageSync(rect.width.toInt(), rect.height.toInt());
  } finally {
    picture.dispose();
    source.dispose();
  }
}
