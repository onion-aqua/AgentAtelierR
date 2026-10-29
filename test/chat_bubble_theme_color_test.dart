import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/chat_bubble.dart';
import 'package:ryza_chat_mvp/src/chat_glass_surface.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';

Future<void> _mount(
  WidgetTester tester, {
  required AppAccentTheme accent,
  required Brightness brightness,
  bool globalGlass = false,
  bool bubbleGlass = false,
  Color? textColor,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: atelierTheme(accent, brightness),
      home: GlassStyleScope(
        enabled: globalGlass,
        child: Scaffold(
          body: Column(
            children: [
              for (final isUser in [false, true])
                ChatBubble(
                  messageKey: isUser ? 'user' : 'character',
                  isUser: isUser,
                  originalText: isUser ? 'User text' : 'Character text',
                  translationText: 'Translation',
                  speakerLabel: isUser ? 'You' : 'Ryza',
                  liquidGlass: bubbleGlass,
                  textStyle: textColor == null
                      ? null
                      : TextStyle(color: textColor),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _bubble(bool user) =>
    find.byKey(ValueKey('chat-bubble-${user ? 'user' : 'character'}'));

ChatGlassSurface _surface(WidgetTester tester, bool user) =>
    tester.widget<ChatGlassSurface>(
      find.descendant(
        of: _bubble(user),
        matching: find.byType(ChatGlassSurface),
      ),
    );

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return (first > second
      ? (first + .05) / (second + .05)
      : (second + .05) / (first + .05));
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name} plain bubbles follow accent and retain readable colors',
      (tester) async {
        final backgrounds = <bool, List<Color>>{false: [], true: []};
        for (final accent in AppAccentTheme.values) {
          await _mount(tester, accent: accent, brightness: brightness);
          final colors = atelierTheme(accent, brightness).colorScheme;
          for (final user in [false, true]) {
            final surface = _surface(tester, user);
            final expectedBackground = user
                ? colors.primaryContainer
                : colors.surfaceContainerHigh;
            final expectedText = user
                ? colors.onPrimaryContainer
                : colors.onSurface;
            expect(
              surface.fallbackColor,
              expectedBackground.withValues(alpha: .84),
            );
            backgrounds[user]!.add(surface.fallbackColor);
            final source = tester.widget<Text>(
              find.descendant(
                of: _bubble(user),
                matching: find.text(user ? 'User text' : 'Character text'),
              ),
            );
            expect(source.style!.color, expectedText);
            // The scene may be bright or dark: check both extremes beneath
            // the translucent fallback, rather than an opaque color swatch.
            for (final scene in [Colors.black, Colors.white]) {
              final actualBackground = Color.alphaBlend(
                surface.fallbackColor,
                scene,
              );
              expect(
                _contrast(expectedText, actualBackground),
                greaterThan(4.5),
              );
            }
            final divider = tester.widget<Divider>(
              find.descendant(
                of: _bubble(user),
                matching: find.byType(Divider),
              ),
            );
            expect(divider.color, expectedText.withValues(alpha: .30));
            final name = tester.widget<Text>(
              find.byKey(
                ValueKey('chat-bubble-speaker-${user ? 'user' : 'character'}'),
              ),
            );
            expect(name.style!.color, expectedText);
            expect(name.textAlign, user ? TextAlign.right : TextAlign.left);
          }
        }
        for (final colors in backgrounds.values) {
          expect(colors.first, isNot(colors.last));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('global glass preference overrides the local bubble preference', (
    tester,
  ) async {
    const accent = AppAccentTheme.lavender;
    const brightness = Brightness.dark;
    await _mount(
      tester,
      accent: accent,
      brightness: brightness,
      globalGlass: false,
      bubbleGlass: true,
    );
    final text = find.text('User text');
    final colors = atelierTheme(accent, brightness).colorScheme;
    expect(tester.widget<Text>(text).style!.color, colors.onPrimaryContainer);
    await _mount(
      tester,
      accent: accent,
      brightness: brightness,
      globalGlass: true,
      bubbleGlass: false,
    );
    expect(tester.widget<Text>(text).style!.color, const Color(0xFFF2F6F3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'theme changes preserve explicitly selected dialogue text color',
    (tester) async {
      const custom = Color(0xFF1A4770);
      for (final accent in [AppAccentTheme.ocean, AppAccentTheme.rose]) {
        await _mount(
          tester,
          accent: accent,
          brightness: Brightness.light,
          textColor: custom,
        );
        expect(
          tester.widget<Text>(find.text('User text')).style!.color,
          custom,
        );
        expect(
          tester.widget<Text>(find.text('Character text')).style!.color,
          custom,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
}
