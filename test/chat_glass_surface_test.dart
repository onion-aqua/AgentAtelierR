import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/chat_glass_surface.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';

class _Pixels {
  _Pixels(this.bytes, this.width);
  final ByteData bytes;
  final int width;

  int alpha(int x, int y) => bytes.getUint8((y * width + x) * 4 + 3);

  int highestAlpha(Rect rect) {
    var highest = 0;
    for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
      for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
        final value = alpha(x, y);
        if (value > highest) highest = value;
      }
    }
    return highest;
  }
}

Future<_Pixels> _capture(WidgetTester tester, GlobalKey key) async =>
    (await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final pixels = _Pixels(bytes, image.width);
      image.dispose();
      return pixels;
    }))!;

Future<void> _mount(
  WidgetTester tester,
  GlobalKey key, {
  required bool enabled,
  required Brightness brightness,
  bool dense = false,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Theme(
        data: ThemeData(brightness: brightness),
        child: GlassStyleScope(
          enabled: enabled,
          child: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 240,
                height: 140,
                child: ChatGlassSurface(
                  liquidGlass: false,
                  denseContent: dense,
                  fallbackColor: brightness == Brightness.dark
                      ? const Color(0xD9293D36)
                      : const Color(0xD9FFFFFF),
                  child: const Center(
                    child: Text(
                      'Readable glass',
                      key: ValueKey('glass-foreground'),
                      style: TextStyle(fontSize: 24, color: Color(0xFFFF0000)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name} glass reveals more background without fading text',
      (tester) async {
        final key = GlobalKey();
        await _mount(tester, key, enabled: false, brightness: brightness);
        final plain = await _capture(tester, key);
        await _mount(tester, key, enabled: true, brightness: brightness);
        final glass = await _capture(tester, key);
        expect(glass.alpha(120, 30), lessThan(plain.alpha(120, 30) - 20));
        final origin = tester.getTopLeft(find.byType(ChatGlassSurface));
        final textRect = tester
            .getRect(find.byKey(const ValueKey('glass-foreground')))
            .shift(-origin);
        expect(glass.highestAlpha(textRect), greaterThanOrEqualTo(250));

        final painter = tester.widget<CustomPaint>(
          find
              .descendant(
                of: find.byType(ChatGlassSurface),
                matching: find.byType(CustomPaint),
              )
              .first,
        );
        expect(painter.foregroundPainter, isNotNull);
        expect(
          painter.foregroundPainter!.shouldRepaint(painter.foregroundPainter!),
          isFalse,
        );
        expect(find.byType(AnimatedBuilder), findsNothing);
        expect(find.byType(Opacity), findsNothing);
        expect(find.byType(ShaderMask), findsNothing);
        expect(find.byType(ImageFiltered), findsNothing);
        final filter = find.byType(BackdropFilter);
        expect(filter, findsOneWidget);
        expect(tester.getSize(filter), const Size(240, 140));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('dense small controls keep a stronger tint than ordinary glass', (
    tester,
  ) async {
    final key = GlobalKey();
    await _mount(tester, key, enabled: true, brightness: Brightness.light);
    final ordinary = await _capture(tester, key);
    await _mount(
      tester,
      key,
      enabled: true,
      brightness: Brightness.light,
      dense: true,
    );
    final dense = await _capture(tester, key);
    expect(dense.alpha(120, 30), greaterThan(ordinary.alpha(120, 30)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching glass preserves the draft, focus and long press', (
    tester,
  ) async {
    final enabled = ValueNotifier(false);
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(enabled.dispose);
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (context, value, _) => GlassStyleScope(
              enabled: value,
              child: ChatGlassSurface(
                liquidGlass: false,
                fallbackColor: Colors.white,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(controller: controller, focusNode: focus),
                    GestureDetector(
                      onLongPress: () => presses++,
                      child: const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Hold this bubble'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    final inputElement = tester.element(find.byType(TextField));
    expect(focus.hasFocus, isTrue);
    enabled.value = true;
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(TextField)), same(inputElement));
    expect(controller.text, 'Keep this draft');
    expect(focus.hasFocus, isTrue);
    await tester.longPress(find.text('Hold this bubble'));
    expect(presses, 1);
    enabled.value = false;
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(TextField)), same(inputElement));
    expect(controller.text, 'Keep this draft');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
