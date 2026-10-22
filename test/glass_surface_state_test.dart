import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/liquid_glass_optics.dart';

void main() {
  testWidgets(
    'lightweight glass has no shader or touch ticker and reuses its filter',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GlassSurface(
              liquidGlass: true,
              borderRadius: BorderRadius.zero,
              child: ListView(
                children: List.generate(
                  8,
                  (i) => GlassSurface(
                    key: ValueKey('card-$i'),
                    liquidGlass: true,
                    child: SizedBox(height: 100, child: Text('Card $i')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<BackdropFilter>(find.byType(BackdropFilter))
            .where((f) => f.enabled)
            .length,
        1,
      );
      final fullPage = tester.widget<LiquidGlassOptics>(
        find.byType(LiquidGlassOptics).first,
      );
      expect(fullPage.borderRadius, BorderRadius.zero);
      expect(
        tester
            .widget<BackdropFilter>(find.byType(BackdropFilter).first)
            .filter
            .toString(),
        isNot(contains('shader')),
      );
      final filters = tester
          .widgetList<BackdropFilter>(find.byType(BackdropFilter))
          .toList();
      final element = tester.element(find.byType(LiquidGlassOptics).at(1));
      final filterRender = tester.renderObject<RenderBackdropFilter>(
        find.byType(BackdropFilter).at(1),
      );
      final layerBefore = filterRender.filterConfig;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('card-1'))),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.binding.transientCallbackCount, 0);
        // Touch must not schedule glint frames or reconstruct filter layers.
        final current = tester
            .widgetList<BackdropFilter>(find.byType(BackdropFilter))
            .toList();
        for (var j = 0; j < filters.length; j++) {
          expect(current[j], same(filters[j]));
        }
        expect(filterRender.filterConfig, same(layerBefore));
        expect(element.dirty, isFalse);
      }
      await gesture.up();
      await tester.drag(find.byType(ListView), const Offset(0, -230));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<BackdropFilter>(find.byType(BackdropFilter))
            .where((f) => f.enabled)
            .length,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('live glass toggle preserves draft, selection and focus', (
    tester,
  ) async {
    final glass = ValueNotifier(false);
    addTearDown(glass.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: glass,
            builder: (context, enabled, _) =>
                GlassSurface(liquidGlass: enabled, child: const TextField()),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '尚未保存的内容');
    final original = tester.state<EditableTextState>(find.byType(EditableText));
    original.widget.controller.selection = const TextSelection.collapsed(
      offset: 3,
    );
    for (final enabled in [true, false, true]) {
      glass.value = enabled;
      await tester.pumpAndSettle();
      final current = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(current, same(original));
      expect(current.widget.controller.text, '尚未保存的内容');
      expect(current.widget.controller.selection.baseOffset, 3);
      expect(current.widget.focusNode.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    }
  });
}
