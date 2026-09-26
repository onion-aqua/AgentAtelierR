import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Keeps the outgoing page visible while the next page prepares and fades in.
class PageTransitionSurface extends StatelessWidget {
  const PageTransitionSurface({
    super.key,
    required this.outgoing,
    required this.incoming,
    required this.collapseProgress,
    required this.revealProgress,
    required this.active,
    this.loadingIndicator,
  });

  final Widget outgoing;
  final Widget? incoming;
  final double collapseProgress;
  final double revealProgress;
  final bool active;
  final Widget? loadingIndicator;

  @override
  Widget build(BuildContext context) {
    final collapse = active ? collapseProgress.clamp(0.0, 1.0) : 0.0;
    final reveal = active ? revealProgress.clamp(0.0, 1.0) : 0.0;
    final outgoingEffect = collapse * (1 - reveal);
    final blur = 2.2 * outgoingEffect;
    final scrimAlpha = 0.38 * collapse * (1 - reveal);

    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF111718)),
        ClipRect(
          child: Transform.scale(
            key: const ValueKey('page-transition-outgoing'),
            scale: 1 - 0.02 * outgoingEffect,
            child: ImageFiltered(
              enabled: blur > 0.01,
              imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: outgoing,
            ),
          ),
        ),
        if (active)
          ColoredBox(
            key: const ValueKey('page-transition-scrim'),
            color: const Color(0xFF111718).withValues(alpha: scrimAlpha),
          ),
        if (active && loadingIndicator != null)
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 36),
                child: Opacity(
                  opacity: collapse * (1 - reveal),
                  child: loadingIndicator,
                ),
              ),
            ),
          ),
        if (incoming != null)
          Opacity(
            key: const ValueKey('page-transition-incoming'),
            opacity: reveal,
            child: Transform.scale(
              scale: 0.98 + 0.02 * reveal,
              child: incoming,
            ),
          ),
      ],
    );
  }
}
