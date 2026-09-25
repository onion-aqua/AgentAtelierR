import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/appearance_picker_page.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/skin_import_controls.dart';

void main() {
  Future<void> showPicker(
    WidgetTester tester, {
    required Size size,
    required ValueChanged<CharacterAppearance> onSelected,
    List<CharacterAppearance>? appearances,
    String? selectedId,
    bool liquidGlass = false,
  }) async {
    final items = appearances ?? characterAppearances.take(3).toList();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: AppearancePickerPage(
          appearances: items,
          selectedId: selectedId ?? items.first.id,
          language: AppLanguage.chinese,
          liquidGlass: liquidGlass,
          previewBuilder: (_) => const ColoredBox(color: Colors.white24),
          onSelected: onSelected,
          onTextureChanged: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('swiping browses cards and only the equip button selects', (
    tester,
  ) async {
    CharacterAppearance? selected;
    await showPicker(
      tester,
      size: const Size(390, 760),
      onSelected: (appearance) => selected = appearance,
    );

    expect(find.text('1 / 3'), findsOneWidget);
    await tester.drag(find.byType(AppearancePickerPage), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    expect(selected, isNull);
    expect(
      tester
          .widget<SkinImportControls>(find.byType(SkinImportControls))
          .appearance
          .id,
      characterAppearances[1].id,
    );

    await tester.tap(
      find.byKey(ValueKey('outfit-equip-${characterAppearances[1].id}')),
    );
    expect(selected?.id, characterAppearances[1].id);
  });

  testWidgets(
    'exposed card is tappable and import actions stay at lower left',
    (tester) async {
      await showPicker(tester, size: const Size(320, 568), onSelected: (_) {});

      await tester.tapAt(const Offset(300, 260));
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);
      final zip = find.text('导入皮肤 ZIP');
      final texture = find.text('导入贴图');
      expect(zip, findsOneWidget);
      expect(texture, findsOneWidget);
      expect(tester.getTopLeft(zip).dx, lessThan(160));
      expect(tester.getTopLeft(texture).dx, lessThan(160));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('landscape picker keeps controls on screen', (tester) async {
    await showPicker(tester, size: const Size(640, 360), onSelected: (_) {});
    expect(find.text('导入皮肤 ZIP'), findsOneWidget);
    expect(find.text('导入贴图'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('right card paints over the focused card', (
    tester,
  ) async {
    await showPicker(
      tester,
      size: const Size(390, 760),
      appearances: characterAppearances.take(6).toList(),
      selectedId: characterAppearances[4].id,
      onSelected: (_) {},
    );

    expect(find.text('5 / 6'), findsOneWidget);
    final cards = tester
        .widgetList<Positioned>(find.byType(Positioned))
        .where((card) => card.key is ValueKey<String>)
        .map((card) => (card.key! as ValueKey<String>).value)
        .toList();
    expect(cards, [
      characterAppearances[1].id,
      characterAppearances[2].id,
      characterAppearances[3].id,
      characterAppearances[4].id,
      characterAppearances[5].id,
    ]);

    await tester.tapAt(const Offset(310, 340));
    await tester.pumpAndSettle();
    expect(find.text('6 / 6'), findsOneWidget);
  });

  testWidgets('incoming right card eases longer and follows glass setting', (
    tester,
  ) async {
    await showPicker(
      tester,
      size: const Size(390, 760),
      liquidGlass: true,
      onSelected: (_) {},
    );
    expect(
      tester
          .widget<GlassPageSurface>(find.byType(GlassPageSurface))
          .liquidGlass,
      isTrue,
    );
    expect(
      tester
          .widget<GlassSurface>(
            find.byKey(
              ValueKey('outfit-surface-${characterAppearances.first.id}'),
            ),
          )
          .liquidGlass,
      isTrue,
    );

    await tester.tap(find.byTooltip('下一套'));
    await tester.pump();
    final incoming = tester.widget<AnimatedSlide>(
      find.descendant(
        of: find.byKey(ValueKey(characterAppearances[1].id)),
        matching: find.byType(AnimatedSlide),
      ),
    );
    final outgoing = tester.widget<AnimatedSlide>(
      find.descendant(
        of: find.byKey(ValueKey(characterAppearances.first.id)),
        matching: find.byType(AnimatedSlide),
      ),
    );
    expect(incoming.duration, const Duration(milliseconds: 680));
    expect(outgoing.duration, const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('outfit cards have no fill in either glass mode', (tester) async {
    for (final liquidGlass in [false, true]) {
      await showPicker(
        tester,
        size: const Size(390, 760),
        liquidGlass: liquidGlass,
        onSelected: (_) {},
      );
      final surface = find.byKey(
        ValueKey('outfit-surface-${characterAppearances.first.id}'),
      );
      final fills = tester
          .widgetList<DecoratedBox>(
            find.descendant(of: surface, matching: find.byType(DecoratedBox)),
          )
          .map((box) => box.decoration)
          .whereType<BoxDecoration>();
      expect(
        fills.any(
          (decoration) =>
              decoration.color == Colors.transparent &&
              decoration.gradient == null,
        ),
        isTrue,
      );
    }
  });

  testWidgets('next right card slides in from offscreen on each left swipe', (
    tester,
  ) async {
    const screenWidth = 390.0;
    await showPicker(
      tester,
      size: const Size(screenWidth, 760),
      appearances: characterAppearances.take(5).toList(),
      onSelected: (_) {},
    );

    for (final index in [2, 3]) {
      final card = find.byKey(ValueKey(characterAppearances[index].id));
      final surface = find.byKey(
        ValueKey('outfit-surface-${characterAppearances[index].id}'),
      );
      final initialLeft = tester.getTopLeft(surface).dx;
      expect(initialLeft, greaterThanOrEqualTo(screenWidth));

      await tester.drag(
        find.byType(AppearancePickerPage),
        const Offset(-220, 0),
      );
      await tester.pump();
      expect(tester.getTopLeft(surface).dx, closeTo(initialLeft, 0.01));
      final slide = tester.widget<AnimatedSlide>(
        find.descendant(of: card, matching: find.byType(AnimatedSlide)),
      );
      expect(slide.curve, Curves.easeInOutSine);
      expect(slide.duration, const Duration(milliseconds: 760));

      await tester.pump(const Duration(milliseconds: 80));
      final earlyLeft = tester.getTopLeft(surface).dx;
      await tester.pump(const Duration(milliseconds: 120));
      final middleLeft = tester.getTopLeft(surface).dx;

      await tester.pumpAndSettle();
      final finalLeft = tester.getTopLeft(surface).dx;
      expect(earlyLeft, lessThan(initialLeft));
      expect(middleLeft, lessThan(earlyLeft));
      expect(finalLeft, lessThan(middleLeft));
      expect(initialLeft - earlyLeft, lessThan((initialLeft - finalLeft) * .2));
      expect(finalLeft, lessThan(screenWidth));
    }
    expect(tester.takeException(), isNull);
  });
}
