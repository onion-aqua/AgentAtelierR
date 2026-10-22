import 'package:flutter/material.dart';

import 'liquid_glass_optics.dart';

enum GlassTone { dark, light }

/// A page/route has already sampled its backdrop. Descendant cards only need
/// their tint and sheen; sampling the same full screen again is expensive.
class GlassBackdropScope extends InheritedWidget {
  const GlassBackdropScope({
    super.key,
    required this.active,
    this.persistentRouteBackdrop = false,
    required super.child,
  });
  final bool active;
  final bool persistentRouteBackdrop;
  static bool persistsAcrossRoutes(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<GlassBackdropScope>()
          ?.persistentRouteBackdrop ??
      false;
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<GlassBackdropScope>()
          ?.active ??
      false;
  @override
  bool updateShouldNotify(GlassBackdropScope oldWidget) =>
      active != oldWidget.active ||
      persistentRouteBackdrop != oldWidget.persistentRouteBackdrop;
}

/// Keeps surfaces in open routes and dialogs in sync with the global switch.
/// Placing the scope above the Navigator avoids capturing a stale preference
/// when a page is opened or a confirmation dialog is constructed.
class GlassStyleScope extends InheritedWidget {
  const GlassStyleScope({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  static bool resolve(BuildContext context, {bool fallback = false}) =>
      context.dependOnInheritedWidgetOfExactType<GlassStyleScope>()?.enabled ??
      fallback;

  @override
  bool updateShouldNotify(GlassStyleScope oldWidget) =>
      enabled != oldWidget.enabled;
}

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
    this.tone,
    this.blurSigma = 16,
    this.backdropBlur = true,
    this.transparentFill = false,
    this.readableText = false,
    this.fillOpacity = 1,
  });

  final bool liquidGlass;
  final Widget child;
  final BorderRadius borderRadius;
  final Color fallbackColor;
  final List<BoxShadow> boxShadow;

  /// Null follows the theme; scene controls with white labels opt into dark.
  final GlassTone? tone;
  final double blurSigma;
  final bool backdropBlur;
  final bool transparentFill;

  /// Text panels over arbitrary scene images need a contrast tint. Optical
  /// refraction stays enabled; decorative glass can keep the lighter tint.
  final bool readableText;
  final double fillOpacity;

  @override
  Widget build(BuildContext context) {
    final liquidGlass = GlassStyleScope.resolve(
      context,
      fallback: this.liquidGlass,
    );
    final accent = Theme.of(context).colorScheme.primary;
    final inheritedBackdrop = GlassBackdropScope.of(context);
    final needsBackdrop = backdropBlur && blurSigma > 0 && !inheritedBackdrop;
    final darkMode = tone == null
        ? Theme.of(context).brightness == Brightness.dark
        : tone == GlassTone.dark;
    final surfaceTint = Color.lerp(
      darkMode
          ? (readableText ? const Color(0xFF111518) : const Color(0xFF384348))
          : Colors.white,
      accent,
      .035,
    )!;
    final material = DecoratedBox(
      decoration: BoxDecoration(
        color: transparentFill
            ? Colors.transparent
            : liquidGlass
            ? surfaceTint.withValues(
                alpha:
                    (readableText
                        ? (darkMode ? .80 : .78)
                        : (darkMode ? .16 : .14)) *
                    fillOpacity,
              )
            : fallbackColor.withValues(alpha: fallbackColor.a * fillOpacity),
        borderRadius: borderRadius,
        // Flutter paints a zero-width solid border as a one-physical-pixel line.
        border: Border.all(
          color: liquidGlass
              ? Colors.white.withValues(alpha: darkMode ? .16 : .30)
              : Colors.white.withValues(alpha: .20),
          width: 0,
        ),
        // Keep scrolling surfaces flat: no per-card shadow blur passes.
        boxShadow: null,
      ),
      // Colour and gradient in one BoxDecoration multiply their alphas. Draw
      // the sheen separately so the tint keeps its intended contrast.
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          gradient: liquidGlass && !transparentFill
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors:
                      (darkMode
                              ? [
                                  Colors.white.withValues(alpha: 0.10),
                                  Color.lerp(
                                    const Color(0xFF65747A),
                                    accent,
                                    0.10,
                                  )!.withValues(alpha: 0.045),
                                  const Color(0xFF364249)
                                      .withValues(alpha: 0.12),
                                ]
                              : [
                                  Colors.white.withValues(alpha: 0.26),
                                  Color.lerp(
                                    const Color(0xFFF1F3F2),
                                    accent,
                                    0.06,
                                  )!.withValues(alpha: 0.08),
                                  Color.lerp(
                                    const Color(0xFFE3E8E6),
                                    accent,
                                    0.08,
                                  )!.withValues(alpha: 0.14),
                                ])
                          .map(
                            (color) =>
                                color.withValues(alpha: color.a * fillOpacity),
                          )
                          .toList(),
                )
              : null,
        ),
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: boxShadow,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        // Keep the content at the same element path when the preference
        // changes. Replacing this wrapper discards forms, focus and scrolls.
        child: LiquidGlassOptics(
          enabled: liquidGlass,
          borderRadius: borderRadius,
          dark: darkMode,
          blurSigma: blurSigma,
          filterBackdrop: needsBackdrop,
          child: GlassBackdropScope(
            active: inheritedBackdrop || (liquidGlass && needsBackdrop),
            persistentRouteBackdrop: GlassBackdropScope.persistsAcrossRoutes(
              context,
            ),
            child: material,
          ),
        ),
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
      tone: GlassTone.dark,
      blurSigma: 10,
      borderRadius: BorderRadius.circular(size / 2),
      fallbackColor: Colors.black.withValues(alpha: 0.38),
      // Give each tooltip anchor its own accessible group. Flutter 3.47's
      // OverlayPortal semantics cache can otherwise retain a sibling node
      // after a tooltip is hidden (upstream flutter/flutter#190431).
      child: Semantics(
        container: true,
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
      ),
    );
  }
}
