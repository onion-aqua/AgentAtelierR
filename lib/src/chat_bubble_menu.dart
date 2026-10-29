import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chat_glass_surface.dart';

class ChatBubbleMenuAction<T> {
  const ChatBubbleMenuAction({
    required this.key,
    required this.value,
    required this.icon,
    required this.label,
    this.enabled = true,
  });

  final Key key;
  final T value;
  final IconData icon;
  final String label;
  final bool enabled;
}

/// A single, bounded glass surface: rows share the backdrop sample and the
/// underlying conversation remains visible while the menu is open.
Future<T?> showChatBubbleMenu<T>({
  required BuildContext context,
  required Offset position,
  required bool liquidGlass,
  required List<ChatBubbleMenuAction<T>> actions,
}) {
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final local = overlay.globalToLocal(position);
  final anchor = Offset(
    local.dx / overlay.size.width,
    local.dy / overlay.size.height,
  );
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: false,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 140),
    pageBuilder: (routeContext, animation, secondaryAnimation) => themes.wrap(
      _BubbleMenuLayout<T>(
        anchor: anchor,
        liquidGlass: liquidGlass,
        actions: actions,
        animation: animation,
        onSelected: (value) => Navigator.of(routeContext).pop(value),
      ),
    ),
    // Animate only the menu. A transform keeps the scene available to the
    // backdrop filter instead of isolating it inside an opacity saveLayer.
    transitionBuilder: (_, animation, secondaryAnimation, child) => child,
  );
}

class _BubbleMenuLayout<T> extends StatelessWidget {
  const _BubbleMenuLayout({
    required this.anchor,
    required this.liquidGlass,
    required this.actions,
    required this.animation,
    required this.onSelected,
  });

  final Offset anchor;
  final bool liquidGlass;
  final List<ChatBubbleMenuAction<T>> actions;
  final Animation<double> animation;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final safe = EdgeInsets.fromLTRB(
      math.max(media.padding.left, media.viewInsets.left) + 12,
      math.max(media.padding.top, media.viewInsets.top) + 12,
      math.max(media.padding.right, media.viewInsets.right) + 12,
      math.max(media.padding.bottom, media.viewInsets.bottom) + 12,
    );
    return CustomSingleChildLayout(
      delegate: _BubbleMenuPosition(anchor, safe),
      child: ScaleTransition(
        scale: animation.drive(
          Tween<double>(
            begin: .97,
            end: 1,
          ).chain(CurveTween(curve: Curves.easeOutCubic)),
        ),
        child: Semantics(
          scopesRoute: true,
          namesRoute: true,
          label: MaterialLocalizations.of(context).popupMenuLabel,
          explicitChildNodes: true,
          child: FocusTraversalGroup(
            child: ChatGlassSurface(
              key: const ValueKey('chat-message-glass-menu'),
              variant: ChatGlassVariant.menu,
              liquidGlass: liquidGlass,
              denseContent: true,
              borderRadius: BorderRadius.circular(22),
              fallbackColor: theme.colorScheme.surface,
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context)
                    .copyWith(scrollbars: false),
                child: SingleChildScrollView(
                  primary: false,
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var index = 0; index < actions.length; index++) ...[
                        if (index > 0)
                          Divider(
                            height: 1,
                            thickness: .5,
                            indent: 42,
                            endIndent: 12,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: dark ? .13 : .10,
                            ),
                          ),
                        _MenuRow<T>(
                          action: actions[index],
                          onSelected: onSelected,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow<T> extends StatelessWidget {
  const _MenuRow({required this.action, required this.onSelected});
  final ChatBubbleMenuAction<T> action;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = action.enabled
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurface.withValues(alpha: .38);
    return Semantics(
      button: true,
      enabled: action.enabled,
      child: InkWell(
        key: action.key,
        onTap: action.enabled ? () => onSelected(action.value) : null,
        borderRadius: BorderRadius.circular(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 50),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(action.icon, color: color, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    action.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w500,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BubbleMenuPosition extends SingleChildLayoutDelegate {
  const _BubbleMenuPosition(this.anchor, this.safe);
  final Offset anchor;
  final EdgeInsets safe;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.max(0.0, constraints.maxWidth - safe.horizontal);
    return BoxConstraints(
      minWidth: math.min(316, width),
      maxWidth: math.min(316, width),
      maxHeight: math.max(0, constraints.maxHeight - safe.vertical),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final point = Offset(size.width * anchor.dx, size.height * anchor.dy);
    final maxX = math.max(safe.left, size.width - safe.right - childSize.width);
    final maxY = math.max(
      safe.top,
      size.height - safe.bottom - childSize.height,
    );
    final preferredX = point.dx > size.width / 2
        ? point.dx - childSize.width
        : point.dx;
    final below = point.dy + 8;
    final preferredY = below + childSize.height <= size.height - safe.bottom
        ? below
        : point.dy - childSize.height - 8;
    return Offset(
      preferredX.clamp(safe.left, maxX),
      preferredY.clamp(safe.top, maxY),
    );
  }

  @override
  bool shouldRelayout(_BubbleMenuPosition oldDelegate) =>
      anchor != oldDelegate.anchor || safe != oldDelegate.safe;
}
