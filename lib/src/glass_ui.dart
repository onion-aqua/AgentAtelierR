import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

enum GlassTone { dark, light }

/// Match the page fallback glass at the title bar while keeping labels clear.
Color glassPageHeaderColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xD91C2222)
    : const Color(0xE0EEF2F0);

/// The same translucent surface used by the main scene, for secondary pages.
class GlassPageSurface extends StatelessWidget {
  const GlassPageSurface({
    super.key,
    required this.liquidGlass,
    required this.child,
  });

  final bool liquidGlass;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return GlassSurface(
      liquidGlass: liquidGlass,
      tone: dark ? GlassTone.dark : GlassTone.light,
      borderRadius: BorderRadius.zero,
      fallbackColor: dark ? const Color(0xD91C2222) : const Color(0xB8EEF2F0),
      child: child,
    );
  }
}

/// Lightweight nested card: the page itself already blurs the backdrop.
class GlassContentCard extends StatelessWidget {
  const GlassContentCard({
    super.key,
    required this.liquidGlass,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
  });

  final bool liquidGlass;
  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return GlassSurface(
      liquidGlass: liquidGlass,
      backdropBlur: false,
      tone: dark ? GlassTone.dark : GlassTone.light,
      borderRadius: borderRadius,
      fallbackColor: dark ? const Color(0xB8202428) : const Color(0xB8F1F3F4),
      child: child,
    );
  }
}

class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.liquidGlass,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
    this.fallbackColor = const Color(0xCC201D1B),
    this.boxShadow = const [],
    this.tone = GlassTone.dark,
    this.blurSigma = 16,
    this.backdropBlur = true,
    this.transparentFill = false,
    this.fillOpacity = 1,
  });

  final bool liquidGlass;
  final Widget child;
  final BorderRadius borderRadius;
  final Color fallbackColor;
  final List<BoxShadow> boxShadow;
  final GlassTone tone;
  final double blurSigma;
  final bool backdropBlur;
  final bool transparentFill;
  final double fillOpacity;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final darkMode = Theme.of(context).brightness == Brightness.dark;
    final surfaceTint = Color.lerp(
      darkMode ? const Color(0xFF111518) : Colors.white,
      accent,
      darkMode ? .08 : .045,
    )!;
    final material = DecoratedBox(
      decoration: BoxDecoration(
        color: transparentFill
            ? Colors.transparent
            : liquidGlass
            ? surfaceTint.withValues(
                alpha: (darkMode ? .42 : .34) * fillOpacity,
              )
            : fallbackColor.withValues(alpha: fallbackColor.a * fillOpacity),
        gradient: liquidGlass && !transparentFill
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors:
                    (tone == GlassTone.dark
                            ? [
                                Colors.white.withValues(alpha: 0.24),
                                Color.lerp(
                                  const Color(0xFF303536),
                                  accent,
                                  0.10,
                                )!.withValues(alpha: 0.46),
                                const Color(0xFF171B1C).withValues(alpha: 0.54),
                              ]
                            : [
                                Colors.white.withValues(alpha: 0.82),
                                Color.lerp(
                                  const Color(0xFFF1F3F2),
                                  accent,
                                  0.06,
                                )!.withValues(alpha: 0.72),
                                Color.lerp(
                                  const Color(0xFFE3E8E6),
                                  accent,
                                  0.08,
                                )!.withValues(alpha: 0.66),
                              ])
                        .map(
                          (color) =>
                              color.withValues(alpha: color.a * fillOpacity),
                        )
                        .toList(),
              )
            : null,
        borderRadius: borderRadius,
        border: Border.all(
          color: Colors.white.withValues(alpha: liquidGlass ? 0.42 : 0.20),
          width: liquidGlass ? 1.1 : 1,
        ),
        boxShadow: liquidGlass
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: darkMode ? .25 : .10),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(
                  color: Colors.white.withValues(alpha: darkMode ? .08 : .22),
                  blurRadius: 1,
                  spreadRadius: .5,
                ),
              ]
            : null,
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
        child: liquidGlass && backdropBlur && blurSigma > 0
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    material,
                    IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(
                                alpha: darkMode ? .10 : .28,
                              ),
                              Colors.transparent,
                              Colors.black.withValues(
                                alpha: darkMode ? .10 : .04,
                              ),
                            ],
                            stops: const [0, .22, 1],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
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
    this.onLongPress,
  });

  final bool liquidGlass;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final Widget? iconWidget;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      liquidGlass: liquidGlass,
      blurSigma: 10,
      borderRadius: BorderRadius.circular(size / 2),
      fallbackColor: Colors.black.withValues(alpha: 0.38),
      child: Tooltip(
        message: tooltip,
        triggerMode: onLongPress == null
            ? TooltipTriggerMode.longPress
            : TooltipTriggerMode.manual,
        child: SizedBox.square(
          dimension: size,
          child: GestureDetector(
            onLongPress: onLongPress,
            child: IconButton(
              onPressed: onPressed,
              color: Colors.white,
              disabledColor: Colors.white38,
              icon: iconWidget ?? Icon(icon, size: size * 0.5),
            ),
          ),
        ),
      ),
    );
  }
}
