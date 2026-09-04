import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

enum GlassTone { dark, light }

class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.liquidGlass,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
    this.fallbackColor = const Color(0xCC201D1B),
    this.boxShadow = const [],
    this.tone = GlassTone.dark,
  });

  final bool liquidGlass;
  final Widget child;
  final BorderRadius borderRadius;
  final Color fallbackColor;
  final List<BoxShadow> boxShadow;
  final GlassTone tone;

  @override
  Widget build(BuildContext context) {
    final material = DecoratedBox(
      decoration: BoxDecoration(
        color: liquidGlass ? null : fallbackColor,
        gradient: liquidGlass
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: tone == GlassTone.dark
                    ? [
                        Colors.white.withValues(alpha: 0.24),
                        const Color(0xFF3B2F2A).withValues(alpha: 0.46),
                        const Color(0xFF171514).withValues(alpha: 0.54),
                      ]
                    : [
                        Colors.white.withValues(alpha: 0.82),
                        const Color(0xFFE8F2EF).withValues(alpha: 0.72),
                        const Color(0xFFD8E8E4).withValues(alpha: 0.66),
                      ],
              )
            : null,
        borderRadius: borderRadius,
        border: Border.all(
          color: Colors.white.withValues(alpha: liquidGlass ? 0.34 : 0.20),
        ),
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: boxShadow,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: liquidGlass
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: material,
              )
            : material,
      ),
    );
  }
}

class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.liquidGlass,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 42,
    this.iconWidget,
  });

  final bool liquidGlass;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final Widget? iconWidget;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      liquidGlass: liquidGlass,
      borderRadius: BorderRadius.circular(size / 2),
      fallbackColor: Colors.black.withValues(alpha: 0.38),
      child: SizedBox.square(
        dimension: size,
        child: IconButton(
          onPressed: onPressed,
          tooltip: tooltip,
          color: Colors.white,
          disabledColor: Colors.white38,
          icon: iconWidget ?? Icon(icon, size: size * 0.5),
        ),
      ),
    );
  }
}
