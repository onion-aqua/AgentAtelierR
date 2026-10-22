import 'package:flutter/material.dart';

/// Scoped to settings so chat composers keep their own decoration.
class SettingsFormTheme extends StatelessWidget {
  const SettingsFormTheme({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    OutlineInputBorder border(Color color, [double width = 0]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: color, width: width),
        );
    return Theme(
      data: theme.copyWith(
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: colors.surfaceContainerHighest.withValues(alpha: .55),
          isDense: false,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          border: border(colors.outlineVariant),
          enabledBorder: border(colors.outlineVariant),
          disabledBorder: border(colors.outlineVariant.withValues(alpha: .4)),
          focusedBorder: border(colors.primary, 1),
          errorBorder: border(colors.error),
          focusedErrorBorder: border(colors.error, 1),
          helperMaxLines: 6,
          errorMaxLines: 4,
        ),
        expansionTileTheme: theme.expansionTileTheme.copyWith(
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 8),
          childrenPadding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
        ),
      ),
      child: child,
    );
  }
}

class SettingsSectionHeading extends StatelessWidget {
  const SettingsSectionHeading(this.title, {super.key, this.description});
  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (description != null) ...[
          const SizedBox(height: 4),
          Text(
            description!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );
}
