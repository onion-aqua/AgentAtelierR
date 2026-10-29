import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/chat_glass_surface.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';

class _Pixels {
  const _Pixels(this.bytes, this.width);

  final ByteData bytes;
  final int width;

  Uint8List get values =>
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);

  List<int> rgb(int x, int y) => [
    for (var channel = 0; channel < 3; channel++)
      bytes.getUint8((y * width + x) * 4 + channel),
  ];
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
  required ChatGlassVariant variant,
  bool enabled = true,
  bool reducedMotion = false,
  GestureLongPressCallback? onLongPress,
  ScrollController? scroll,
}) async {
  final surface = RepaintBoundary(
    key: key,
    child: SizedBox(
      width: 240,
      height: 140,
      child: ColoredBox(
        color: const Color(0xFF2C455A),
        child: ChatGlassSurface(
          liquidGlass: true,
          variant: variant,
          fallbackColor: const Color(0xD91A2934),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: onLongPress,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reducedMotion),
        child: GlassStyleScope(
          enabled: enabled,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: scroll == null
                  ? surface
                  : SizedBox(
                      width: 240,
                      height: 220,
                      child: SingleChildScrollView(
                        controller: scroll,
                        child: Column(
                          children: [surface, const SizedBox(height: 600)],
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
  for (final variant in [ChatGlassVariant.bubble, ChatGlassVariant.menu]) {
    testWidgets('${variant.name} glint changes pixels only while held', (
      tester,
    ) async {
      final key = GlobalKey();
      await _mount(tester, key, variant: variant);
      final baseline = await _capture(tester, key);
      final origin = tester.getTopLeft(find.byKey(key));
      final gesture = await tester.startGesture(origin + const Offset(60, 45));
      await tester.pump();
      final held = await _capture(tester, key);
      final before = baseline.rgb(60, 45);
      final highlight = held.rgb(60, 45);
      expect(highlight[0], greaterThan(before[0] + 3));
      expect(highlight[1], greaterThan(before[1] + 3));
      expect(highlight[2], greaterThan(before[2] + 3));
      expect(tester.binding.transientCallbackCount, 0);

      await gesture.up();
      await tester.pump();
      final released = await _capture(tester, key);
      expect(released.values, orderedEquals(baseline.values));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });

    for (final mode in [
      (enabled: false, reducedMotion: false, label: 'disabled'),
      (enabled: true, reducedMotion: true, label: 'reduced motion'),
    ]) {
      testWidgets('${variant.name} stays static with ${mode.label}', (
        tester,
      ) async {
        final key = GlobalKey();
        await _mount(
          tester,
          key,
          variant: variant,
          enabled: mode.enabled,
          reducedMotion: mode.reducedMotion,
        );
        final baseline = await _capture(tester, key);
        final origin = tester.getTopLeft(find.byKey(key));
        final gesture = await tester.startGesture(
          origin + const Offset(60, 45),
        );
        await tester.pump(const Duration(milliseconds: 100));
        final held = await _capture(tester, key);
        expect(held.values, orderedEquals(baseline.values));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('glint observation leaves the bubble long press intact', (
    tester,
  ) async {
    final key = GlobalKey();
    var presses = 0;
    await _mount(
      tester,
      key,
      variant: ChatGlassVariant.bubble,
      onLongPress: () => presses++,
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(key)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    expect(presses, 1);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(presses, 1);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling clears the glint and retains the scroll gesture', (
    tester,
  ) async {
    final key = GlobalKey();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _mount(tester, key, variant: ChatGlassVariant.bubble, scroll: scroll);
    final baseline = await _capture(tester, key);
    final origin = tester.getTopLeft(find.byKey(key));
    final gesture = await tester.startGesture(origin + const Offset(80, 105));
    await tester.pump();
    final held = await _capture(tester, key);
    // A real ScrollPosition may enter its hold activity on pointer-down,
    // before any movement. It already suppresses decorative glints then.
    if (scroll.position.isScrollingNotifier.value) {
      expect(
        held.rgb(80, 105)[0],
        lessThanOrEqualTo(baseline.rgb(80, 105)[0] + 2),
      );
    } else {
      expect(held.rgb(80, 105)[0], greaterThan(baseline.rgb(80, 105)[0] + 3));
    }
    await gesture.moveBy(const Offset(0, -25));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    expect(scroll.offset, greaterThan(0));
    final moved = await _capture(tester, key);
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
      isFalse,
    );
    for (var channel = 0; channel < 3; channel++) {
      expect(
        moved.rgb(80, 105)[channel],
        lessThanOrEqualTo(baseline.rgb(80, 105)[channel] + 2),
      );
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
