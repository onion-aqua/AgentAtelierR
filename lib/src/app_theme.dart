import 'package:flutter/material.dart';

import 'app_localization.dart';

enum AppAccentTheme { jade, amber, ocean, lavender, rose, champagne, graphite }

enum AppTextColor { theme, black, white }

extension AppAccentThemeData on AppAccentTheme {
  String label(AppLanguage language) => switch (this) {
    AppAccentTheme.jade => language.text('翡翠绿', 'Jade', '翡翠'),
    AppAccentTheme.amber => language.text('琥珀橙', 'Amber', '琥珀'),
    AppAccentTheme.ocean => language.text('星海蓝', 'Ocean', '星海'),
    AppAccentTheme.lavender => language.text('薰衣紫', 'Lavender', 'ラベンダー'),
    AppAccentTheme.rose => language.text('蔷薇粉', 'Rose', 'ローズ'),
    AppAccentTheme.champagne => language.text('香槟金', 'Champagne', 'シャンパン'),
    AppAccentTheme.graphite => language.text('石墨灰', 'Graphite', 'グラファイト'),
  };

  Color get color => switch (this) {
    AppAccentTheme.jade => const Color(0xFF287363),
    AppAccentTheme.amber => const Color(0xFFAF4C20),
    AppAccentTheme.ocean => const Color(0xFF316AA1),
    AppAccentTheme.lavender => const Color(0xFF79549E),
    AppAccentTheme.rose => const Color(0xFFAD4A70),
    AppAccentTheme.champagne => const Color(0xFF84651E),
    AppAccentTheme.graphite => const Color(0xFF59636D),
  };
}

final _themes = <(AppAccentTheme, Brightness), ThemeData>{};

class DialogueAppearance extends ThemeExtension<DialogueAppearance> {
  const DialogueAppearance({
    this.translationOnly = false,
    this.textColor,
    this.fontScale = 1,
  });
  final double fontScale;
  final bool translationOnly;
  final Color? textColor;
  @override
  DialogueAppearance copyWith({bool? translationOnly, Color? textColor}) =>
      DialogueAppearance(
        translationOnly: translationOnly ?? this.translationOnly,
        textColor: textColor ?? this.textColor,
        fontScale: fontScale,
      );
  @override
  DialogueAppearance lerp(covariant DialogueAppearance? other, double t) =>
      other == null
      ? this
      : DialogueAppearance(
          translationOnly: other.translationOnly,
          textColor: Color.lerp(textColor, other.textColor, t),
          fontScale: fontScale + (other.fontScale - fontScale) * t,
        );
}

ThemeData withDialogueAppearance(
  ThemeData theme,
  AppAccentTheme? text,
  bool translationOnly, [
  double fontScale = 1.0,
  AppTextColor textChoice = AppTextColor.theme,
]) {
  final color = textChoice == AppTextColor.black
      ? Colors.black
      : textChoice == AppTextColor.white
      ? Colors.white
      : text == null
      ? null
      : theme.brightness == Brightness.dark
      ? Color.lerp(text.color, Colors.white, 0.65)!
      : text.color;
  return theme.copyWith(
    // Dialogue text preferences must not recolor settings and dialogs.
    extensions: [
      ...theme.extensions.values,
      DialogueAppearance(
        translationOnly: translationOnly,
        textColor: color,
        fontScale: fontScale,
      ),
    ],
  );
}

ThemeData atelierTheme(
  AppAccentTheme accent,
  Brightness brightness,
) => _themes.putIfAbsent((accent, brightness), () {
  final dark = brightness == Brightness.dark;
  final primary = dark
      ? Color.lerp(accent.color, Colors.white, 0.52)!
      : accent.color;
  final surface = Color.lerp(
    dark ? const Color(0xFF191C1D) : const Color(0xFFF7F6F2),
    accent.color,
    dark ? 0.04 : 0.025,
  )!;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: accent.color,
        brightness: brightness,
        surface: surface,
      ).copyWith(
        primary: primary,
        onPrimary: dark ? const Color(0xFF171A1A) : Colors.white,
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: surface,
    appBarTheme: AppBarTheme(
      // Shell menu: 8 px top inset + 48 px button + 8 px bottom inset.
      // Keep titles and back buttons on that same 32 px center line.
      toolbarHeight: 64,
      backgroundColor: surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xE624282C) : const Color(0xD9F1F3F4),
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: dark ? .40 : .18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: InputBorder.none,
      isDense: true,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? null
            : states.contains(WidgetState.selected)
            ? scheme.onPrimary
            : scheme.outline,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? null
            : states.contains(WidgetState.selected)
            ? primary
            : scheme.surfaceContainerHighest,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: primary),
  );
});
