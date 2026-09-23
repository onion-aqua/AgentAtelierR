import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';

void main() {
  originalAppearanceTests();
  test('black and white stay exact in both brightness modes', () {
    for (final brightness in Brightness.values) {
      for (final choice in [AppTextColor.black, AppTextColor.white]) {
        final theme = withDialogueAppearance(
          atelierTheme(AppAccentTheme.jade, brightness),
          AppAccentTheme.rose,
          false,
          1.35,
          choice,
        );
        final color = choice == AppTextColor.black
            ? Colors.black
            : Colors.white;
        expect(theme.extension<DialogueAppearance>()!.textColor, color);
        final base = atelierTheme(AppAccentTheme.jade, brightness);
        expect(theme.colorScheme.onSurface, base.colorScheme.onSurface);
        expect(
          theme.textTheme.bodyMedium!.color,
          base.textTheme.bodyMedium!.color,
        );
        expect(theme.extension<DialogueAppearance>()!.fontScale, 1.35);
      }
    }
  });
  test('default text color still retains adjustable dialogue size', () {
    final theme = withDialogueAppearance(
      atelierTheme(AppAccentTheme.jade, Brightness.light),
      null,
      false,
      .85,
    );
    expect(theme.extension<DialogueAppearance>()!.fontScale, .85);
    expect(theme.extension<DialogueAppearance>()!.textColor, isNull);
  });
}

void originalAppearanceTests() {
  test(
    'translation display preserves original segments and playback indices',
    () {
      const segments = [
        ChatSegment(speaker: ChatSpeaker.ryza, text: 'こんにちは'),
        ChatSegment(speaker: ChatSpeaker.translation, text: '你好'),
        ChatSegment(
          speaker: ChatSpeaker.character,
          text: 'Hello',
          characterId: 'klaudia',
        ),
        ChatSegment(speaker: ChatSpeaker.translation, text: '您好'),
      ];
      expect(dialogueDisplayIndices(segments, true), [1, 3]);
      expect(dialogueDisplayIndices(segments, false), [0, 1, 2, 3]);
      expect(segments.first.text, 'こんにちは');
      expect(dialogueDisplayIndices(segments.take(1).toList(), true), [0]);
    },
  );

  test('seven text palettes are independent of accent and theme cache', () {
    final base = atelierTheme(AppAccentTheme.jade, Brightness.dark);
    expect(AppAccentTheme.values.length, 7);
    for (final palette in AppAccentTheme.values) {
      final themed = withDialogueAppearance(base, palette, true);
      expect(themed.extension<DialogueAppearance>()!.translationOnly, isTrue);
      expect(themed.textTheme, base.textTheme);
      expect(themed.colorScheme.onSurface, base.colorScheme.onSurface);
      expect(themed.colorScheme.primary, base.colorScheme.primary);
    }
    expect(base.extension<DialogueAppearance>(), isNull);
    expect(withDialogueAppearance(base, null, false).textTheme, base.textTheme);
  });
}
