import 'package:flutter/material.dart';

import 'glass_ui.dart';

/// Shared phone back control. Pages with drawers place this in their AppBar
/// so the drawer and its scrim paint above the control.
class VirtualPhoneBackButton extends StatelessWidget {
  const VirtualPhoneBackButton({
    super.key = const ValueKey('virtual-phone-back'),
    required this.onPressed,
    this.tooltip,
  });

  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      container: true,
      child: Tooltip(
        message: tooltip ?? MaterialLocalizations.of(context).backButtonTooltip,
        child: GlassSurface(
          liquidGlass: GlassStyleScope.resolve(context),
          backdropBlur: false,
          tone: dark ? GlassTone.dark : GlassTone.light,
          fallbackColor: dark
              ? const Color(0xAA25272A)
              : const Color(0xCDE2E6E5),
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox.square(
              dimension: 48,
              child: Icon(
                Icons.chevron_left_rounded,
                color: dark ? Colors.white : Colors.black,
                size: 32,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
