import 'package:flutter/material.dart';

import 'chat_glass_surface.dart';
import 'glass_ui.dart';

/// The panel becomes quieter as it is shortened, without losing its handle.
double resizeHandleOpacity(double fraction, {bool fullscreen = false}) {
  if (fullscreen) return 1;
  if (!fraction.isFinite) return .10;
  return (.10 + ((fraction - .22) / (.68 - .22)).clamp(0, 1) * .90)
      .clamp(.10, 1)
      .toDouble();
}

/// A transparent layout shell; the scene is visible between message surfaces.
class ChatConversationBackdrop extends StatelessWidget {
  const ChatConversationBackdrop({
    super.key,
    required this.child,
    this.color,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;
  final Color? color;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) => SizedBox.expand(child: child);
}

/// Uses the same lightweight glass switch as other scene controls. The plain
/// fallback is uniform translucent tint, without a position-based alpha ramp.
class ChatBubbleBackground extends StatelessWidget {
  const ChatBubbleBackground({
    super.key,
    required this.color,
    required this.borderRadius,
    required this.child,
    this.liquidGlass = false,
  });

  final Color color;
  final BorderRadius borderRadius;
  final Widget child;
  final bool liquidGlass;

  @override
  Widget build(BuildContext context) => ChatGlassSurface(
    liquidGlass: liquidGlass,
    variant: ChatGlassVariant.bubble,
    borderRadius: borderRadius,
    fallbackColor: color.withValues(alpha: color.a * .84),
    child: child,
  );
}

/// A compact messenger-style bubble. Translation visibility affects display
/// only; callers retain the original message and voice playback targets.
class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.messageKey,
    required this.isUser,
    required this.originalText,
    this.speakerLabel = '',
    this.avatar,
    this.translationText = '',
    this.translationOnly = false,
    this.onLongPressStart,
    this.onTap,
    this.active = false,
    this.child,
    this.textStyle,
    this.liquidGlass = false,
  });

  final String messageKey;
  final bool isUser;
  final String originalText;
  final String speakerLabel;
  final Widget? avatar;
  final String translationText;
  final bool translationOnly;
  final GestureLongPressStartCallback? onLongPressStart;
  final VoidCallback? onTap;
  final bool active;
  final Widget? child;
  final TextStyle? textStyle;
  final bool liquidGlass;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final colors = theme.colorScheme;
    final glassEnabled = GlassStyleScope.resolve(
      context,
      fallback: liquidGlass,
    );
    final background = isUser
        ? colors.primaryContainer
        : colors.surfaceContainerHigh;
    final foreground = glassEnabled
        ? (dark ? const Color(0xFFF2F6F3) : const Color(0xFF203830))
        : (isUser ? colors.onPrimaryContainer : colors.onSurface);
    final hasTranslation = translationText.trim().isNotEmpty;
    final showOriginal = !translationOnly || !hasTranslation;
    final bilingual =
        showOriginal && originalText.trim().isNotEmpty && hasTranslation;
    final preferredTextColor = textStyle?.color;
    final textColor = preferredTextColor ?? foreground;
    final textShadow = Shadow(
      color: textColor.computeLuminance() > .45
          ? const Color(0xB3000000)
          : const Color(0xD9FFFFFF),
      blurRadius: 3,
    );
    final style = TextStyle(
      color: foreground,
      fontSize: 14,
      height: 1.43,
    ).merge(textStyle).copyWith(shadows: [textShadow]);
    final bubble = LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final maxRowWidth = (available * (bilingual ? .90 : .84)).clamp(
          0.0,
          available,
        );
        final avatarSpace = avatar == null ? 0.0 : 38.0;
        final maxWidth = (maxRowWidth - avatarSpace).clamp(0.0, available);
        final contents = <Widget>[
          if (showOriginal && originalText.trim().isNotEmpty)
            Text(originalText, style: style),
          if (bilingual)
            Divider(
              key: ValueKey('chat-bubble-translation-divider-$messageKey'),
              color: foreground.withValues(alpha: .30),
              height: 18,
              thickness: .5,
            ),
          if (hasTranslation) Text(translationText, style: style),
          if (child != null) ...[
            if ((showOriginal && originalText.trim().isNotEmpty) ||
                hasTranslation)
              const SizedBox(height: 8),
            child!,
          ],
        ];
        final content = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: onLongPressStart,
          onTap: onTap,
          child: ChatBubbleBackground(
            color: background,
            liquidGlass: liquidGlass,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(isUser ? 18 : 4),
              topRight: Radius.circular(isUser ? 4 : 18),
              bottomLeft: const Radius.circular(18),
              bottomRight: const Radius.circular(18),
            ),
            child: Container(
              key: ValueKey('chat-bubble-content-$messageKey'),
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(isUser ? 18 : 4),
                  topRight: Radius.circular(isUser ? 4 : 18),
                  bottomLeft: const Radius.circular(18),
                  bottomRight: const Radius.circular(18),
                ),
                border: active
                    ? Border.all(
                        color: Theme.of(context).colorScheme.primary
                            .withValues(alpha: .55),
                        width: .5,
                      )
                    : null,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: contents,
              ),
            ),
          ),
        );
        final avatarWidget = avatar == null
            ? null
            : SizedBox.square(
                key: ValueKey('chat-bubble-avatar-$messageKey'),
                dimension: 28,
                child: avatar,
              );
        final name = speakerLabel.trim().isEmpty
            ? null
            : Text(
                speakerLabel,
                key: ValueKey('chat-bubble-speaker-$messageKey'),
                textAlign: isUser ? TextAlign.right : TextAlign.left,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  shadows: [textShadow],
                ),
              );
        final messageColumn = Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: isUser
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (name != null) ...[
                Align(
                  key: ValueKey('chat-bubble-header-$messageKey'),
                  alignment: isUser
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  widthFactor: 1,
                  child: name,
                ),
                const SizedBox(height: 6),
              ],
              content,
            ],
          ),
        );
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxRowWidth),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isUser && avatarWidget != null) ...[
                  avatarWidget,
                  const SizedBox(width: 10),
                ],
                messageColumn,
                if (isUser && avatarWidget != null) ...[
                  const SizedBox(width: 10),
                  avatarWidget,
                ],
              ],
            ),
          ),
        );
      },
    );
    return Padding(
      key: ValueKey('chat-bubble-$messageKey'),
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: bubble,
    );
  }
}

class ChatNarration extends StatelessWidget {
  const ChatNarration({
    super.key,
    required this.text,
    this.textStyle,
    this.onLongPressStart,
  });

  final String text;
  final TextStyle? textStyle;
  final GestureLongPressStartCallback? onLongPressStart;

  @override
  Widget build(BuildContext context) {
    final base = const TextStyle(
      color: Colors.white,
      fontSize: 14,
      fontWeight: FontWeight.w600,
      fontStyle: FontStyle.normal,
      height: 1.5,
    ).merge(textStyle).copyWith(fontStyle: FontStyle.normal);
    final lightText = (base.color ?? Colors.white).computeLuminance() > .45;
    final outline = lightText
        ? const Color(0xC9000000)
        : const Color(0xD9FFFFFF);
    final style = DefaultTextStyle.of(context).style
        .merge(base)
        .copyWith(
          shadows: [
            for (final offset in const [
              Offset(-.65, 0),
              Offset(.65, 0),
              Offset(0, -.65),
              Offset(0, .65),
              Offset(-.45, -.45),
              Offset(.45, -.45),
              Offset(-.45, .45),
              Offset(.45, .45),
            ])
              Shadow(color: outline, offset: offset),
            Shadow(color: outline, blurRadius: 3.5, offset: const Offset(0, 1)),
          ],
        );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: onLongPressStart,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
        child: Center(
          child: CustomPaint(
            key: const ValueKey('chat-narration-halo'),
            painter: _NarrationHalo(
              text: text,
              style: style,
              textScaler: MediaQuery.textScalerOf(context),
              direction: Directionality.of(context),
              lightText: lightText,
            ),
            child: Text(
              text,
              key: const ValueKey('chat-narration-subtitle-text'),
              textAlign: TextAlign.center,
              style: style,
            ),
          ),
        ),
      ),
    );
  }
}

/// Each line gets a faint, feathered glow rather than a rectangular panel.
class _NarrationHalo extends CustomPainter {
  const _NarrationHalo({
    required this.text,
    required this.style,
    required this.textScaler,
    required this.direction,
    required this.lightText,
  });

  final String text;
  final TextStyle style;
  final TextScaler textScaler;
  final TextDirection direction;
  final bool lightText;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || text.isEmpty) return;
    final measure = TextPainter(
      text: TextSpan(
        text: text,
        style: style.copyWith(shadows: const []),
      ),
      textAlign: TextAlign.center,
      textDirection: direction,
      textScaler: textScaler,
    )..layout(maxWidth: size.width);
    try {
      final glow = Paint()
        ..color = lightText ? const Color(0x38000000) : const Color(0x38FFFFFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
      for (final line in measure.computeLineMetrics()) {
        if (line.width <= 0) continue;
        final rect = Rect.fromLTWH(
          line.left - 5,
          line.baseline - line.ascent + 2,
          line.width + 10,
          line.ascent + line.descent,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(12)),
          glow,
        );
      }
    } finally {
      measure.dispose();
    }
  }

  @override
  bool shouldRepaint(_NarrationHalo oldDelegate) =>
      text != oldDelegate.text ||
      style != oldDelegate.style ||
      textScaler != oldDelegate.textScaler ||
      direction != oldDelegate.direction ||
      lightText != oldDelegate.lightText;
}
