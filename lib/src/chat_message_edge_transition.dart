import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Softens only the top edge of the message viewport, never the composer.
///
/// Plain messages fade within their own layer. Glass messages must sample the
/// scene behind them, so they use only a small blur at the upper edge instead.
/// There is one message child and one blur confined to a narrow top strip.
class ChatMessageEdgeTransition extends StatelessWidget {
  const ChatMessageEdgeTransition({
    super.key,
    required this.child,
    this.edgeExtent = 32,
    this.blurSigma = 1.2,
    this.allowSceneBackdrop = false,
  });

  final Widget child;
  final double edgeExtent;
  final double blurSigma;
  final bool allowSceneBackdrop;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final height = constraints.maxHeight;
      if (!height.isFinite || height <= 0 || edgeExtent <= 0) return child;
      final extent = edgeExtent.clamp(0.0, height).toDouble();
      return ClipRect(
        child: _MessageEdgeMask(
          extent: extent,
          enabled: !allowSceneBackdrop,
          child: Stack(
            fit: StackFit.expand,
            children: [
              child,
              if (blurSigma > 0)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: extent * .75,
                  child: IgnorePointer(
                    child: ClipRect(
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(
                          sigmaX: blurSigma.clamp(0, 1.2).toDouble(),
                          sigmaY: blurSigma.clamp(0, 1.2).toDouble(),
                          tileMode: ui.TileMode.decal,
                        ),
                        blendMode: allowSceneBackdrop
                            ? BlendMode.srcOver
                            : BlendMode.src,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Keep the child at one element path when the glass preference changes.
class _MessageEdgeMask extends SingleChildRenderObjectWidget {
  const _MessageEdgeMask({
    required this.extent,
    required this.enabled,
    required super.child,
  });

  final double extent;
  final bool enabled;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMessageEdgeMask(extent, enabled);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProxyBox renderObject,
  ) {
    (renderObject as _RenderMessageEdgeMask)
      ..extent = extent
      ..enabled = enabled;
  }
}

class _RenderMessageEdgeMask extends RenderProxyBox {
  _RenderMessageEdgeMask(this._extent, this._enabled);

  double _extent;
  bool _enabled;

  set extent(double value) {
    if (_extent == value) return;
    _extent = value;
    markNeedsPaint();
  }

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => _enabled && child != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_enabled || child == null) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    final mask = (layer ??= ShaderMaskLayer()) as ShaderMaskLayer;
    mask
      ..blendMode = BlendMode.dstIn
      ..maskRect = offset & size
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.white],
      ).createShader(Rect.fromLTWH(0, 0, size.width, _extent));
    context.pushLayer(mask, super.paint, offset);
  }
}
