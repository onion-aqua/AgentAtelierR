import 'package:flutter/material.dart';

import 'glass_ui.dart';

enum ChatGlassVariant { standard, bubble, menu }

/// Only the disjoint message bubbles share a sample. Menus and scene controls
/// remain outside this group because they can overlap the message viewport.
class ChatBubbleBackdropGroup extends StatefulWidget {
  const ChatBubbleBackdropGroup({super.key, required this.child});
  final Widget child;

  @override
  State<ChatBubbleBackdropGroup> createState() =>
      _ChatBubbleBackdropGroupState();
}

class _ChatBubbleBackdropGroupState extends State<ChatBubbleBackdropGroup> {
  final _key = BackdropKey();

  @override
  Widget build(BuildContext context) =>
      BackdropGroup(backdropKey: _key, child: widget.child);
}

/// Native adaptation of Lens's clear centre and directional bevel. Only the
/// existing bounded backdrop filter samples the scene; the highlights are
/// vector paint, with no WebView, refraction shader, or idle animation.
class ChatGlassSurface extends StatefulWidget {
  const ChatGlassSurface({
    super.key,
    required this.liquidGlass,
    required this.child,
    required this.fallbackColor,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
    this.denseContent = false,
    this.variant = ChatGlassVariant.standard,
  });

  final bool liquidGlass;
  final Widget child;
  final Color fallbackColor;
  final BorderRadius borderRadius;
  final bool denseContent;
  final ChatGlassVariant variant;

  @override
  State<ChatGlassSurface> createState() => _ChatGlassSurfaceState();
}

class _ChatGlassSurfaceState extends State<ChatGlassSurface> {
  final _contact = ValueNotifier<Offset?>(null);
  final _atRest = ValueNotifier(false);
  int? _pointer;

  void _clearContact() {
    _pointer = null;
    _contact.value = null;
  }

  @override
  void dispose() {
    _contact.dispose();
    _atRest.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: widget.variant == ChatGlassVariant.bubble
        ? (Scrollable.maybeOf(context)?.position.isScrollingNotifier ?? _atRest)
        : _atRest,
    builder: (context, scrolling, _) => _buildSurface(context, scrolling),
  );

  Widget _buildSurface(BuildContext context, bool scrolling) {
    final enabled = GlassStyleScope.resolve(
      context,
      fallback: widget.liquidGlass,
    );
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;
    final detailed = widget.variant != ChatGlassVariant.standard;
    final interactive =
        enabled &&
        detailed &&
        !scrolling &&
        !MediaQuery.disableAnimationsOf(context);
    final strength = switch (widget.variant) {
      ChatGlassVariant.standard =>
        widget.denseContent ? .72 : (dark ? .68 : .62),
      ChatGlassVariant.bubble => dark ? .60 : .52,
      ChatGlassVariant.menu => dark ? .82 : .78,
    };
    // Listener observes the touch without entering the gesture arena. Moving
    // more than 10px clears the glint, so scrolling adds no repaint ticker.
    return Listener(
      onPointerDown: interactive
          ? (event) {
              if (_pointer != null) return;
              _pointer = event.pointer;
              _contact.value = event.localPosition;
            }
          : null,
      onPointerMove: interactive
          ? (event) {
              final origin = _contact.value;
              if (event.pointer == _pointer &&
                  origin != null &&
                  (event.localPosition - origin).distanceSquared > 100) {
                _clearContact();
              }
            }
          : null,
      onPointerUp: (event) {
        if (event.pointer == _pointer) _clearContact();
      },
      onPointerCancel: (event) {
        if (event.pointer == _pointer) _clearContact();
      },
      child: CustomPaint(
        foregroundPainter: enabled
            ? _ChatGlassRim(widget.borderRadius, dark, detailed: detailed)
            : null,
        child: GlassSurface(
          liquidGlass: widget.liquidGlass,
          borderRadius: widget.borderRadius,
          blurSigma: widget.variant == ChatGlassVariant.menu ? 14 : 10,
          // Keep the clear tint and bevel while a list is moving. Disabling
          // just the blur avoids repeated backdrop passes during a fling.
          backdropBlur: widget.variant != ChatGlassVariant.bubble || !scrolling,
          backdropGroupKey: widget.variant == ChatGlassVariant.bubble
              ? BackdropGroup.of(context)?.backdropKey
              : null,
          readableText: true,
          fillOpacity: enabled ? strength : 1,
          fallbackColor: widget.fallbackColor,
          child: CustomPaint(
            painter: enabled && detailed
                ? _ChatGlassReflection(
                    radius: widget.borderRadius,
                    dark: dark,
                    accent: accent,
                    contact: interactive ? _contact : null,
                  )
                : null,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _ChatGlassRim extends CustomPainter {
  const _ChatGlassRim(this.radius, this.dark, {required this.detailed});
  final BorderRadius radius;
  final bool dark;
  final bool detailed;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = (Offset.zero & size).deflate(.5);
    if (rect.isEmpty) return;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = detailed ? .65 : .7
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: detailed ? .72 : (dark ? .32 : .55)),
          Colors.white.withValues(alpha: detailed ? .07 : .08),
          Colors.black.withValues(alpha: dark ? .10 : .07),
          if (detailed) Colors.white.withValues(alpha: .34),
        ],
        stops: detailed ? const [0, .40, .68, 1] : const [0, .55, 1],
      ).createShader(rect);
    canvas.drawRRect(radius.toRRect(rect), stroke);
    if (!detailed) return;
    // The inward dark edge and opposing highlight imply a shallow curved
    // bevel. They never sample or distort the text in the foreground.
    final inner = radius.toRRect(Offset.zero & size).deflate(1.6);
    if (inner.isEmpty) return;
    canvas.drawRRect(
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .55
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: dark ? .11 : .32),
            Colors.transparent,
            Colors.black.withValues(alpha: dark ? .23 : .12),
            Colors.white.withValues(alpha: .18),
          ],
          stops: const [0, .38, .75, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_ChatGlassRim oldDelegate) =>
      radius != oldDelegate.radius ||
      dark != oldDelegate.dark ||
      detailed != oldDelegate.detailed;
}

class _ChatGlassReflection extends CustomPainter {
  _ChatGlassReflection({
    required this.radius,
    required this.dark,
    required this.accent,
    required this.contact,
  }) : super(repaint: contact);

  final BorderRadius radius;
  final bool dark;
  final Color accent;
  final ValueNotifier<Offset?>? contact;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final lens = radius.toRRect(rect).deflate(.8);
    if (lens.isEmpty) return;
    // Weak broad reflection, independent of the text and without a mask layer.
    canvas.drawRRect(
      lens,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: dark ? .10 : .16),
            Colors.white.withValues(alpha: .02),
            Colors.transparent,
            accent.withValues(alpha: dark ? .045 : .025),
            Colors.white.withValues(alpha: .045),
          ],
          stops: const [0, .22, .46, .79, 1],
        ).createShader(rect),
    );
    final point = contact?.value;
    if (point == null) return;
    canvas.drawRRect(
      lens,
      Paint()
        ..shader = RadialGradient(
          center: Alignment(
            point.dx / size.width * 2 - 1,
            point.dy / size.height * 2 - 1,
          ),
          radius: 1.2,
          colors: [Colors.white.withValues(alpha: .16), Colors.transparent],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_ChatGlassReflection oldDelegate) =>
      radius != oldDelegate.radius ||
      dark != oldDelegate.dark ||
      accent != oldDelegate.accent ||
      contact != oldDelegate.contact;
}
