import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Lightweight translucent glass. No runtime refraction shader or touch ticker.
/// Settings reuse their cached desktop; standalone surfaces use a small blur.
class LiquidGlassOptics extends StatelessWidget {
  const LiquidGlassOptics({
    super.key,
    this.enabled = true,
    required this.borderRadius,
    required this.dark,
    required this.blurSigma,
    required this.filterBackdrop,
    this.backdropGroupKey,
    required this.child,
  });

  final bool enabled;
  final BorderRadius borderRadius;
  final bool dark;
  final double blurSigma;
  final bool filterBackdrop;
  final BackdropKey? backdropGroupKey;
  final Widget child;

  @override
  Widget build(BuildContext context) => BackdropFilter(
    backdropGroupKey: backdropGroupKey,
    enabled: enabled && filterBackdrop,
    filter: ui.ImageFilter.blur(
      sigmaX: (blurSigma * .08).clamp(0.0, 1.2),
      sigmaY: (blurSigma * .08).clamp(0.0, 1.2),
      tileMode: TileMode.clamp,
    ),
    child: child,
  );
}
