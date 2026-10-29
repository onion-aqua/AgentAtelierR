import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/chat_bubble.dart';

class _Pixels {
  _Pixels(this.bytes, this.width);
  final ByteData bytes;
  final int width;

  List<int> at(int x, int y) => [
    for (var channel = 0; channel < 4; channel++)
      bytes.getUint8((y * width + x) * 4 + channel),
  ];

  int alpha(int x, int y) => at(x, y)[3];
}

Future<_Pixels> _capture(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final pixels = _Pixels(bytes, image.width);
    image.dispose();
    return pixels;
  }))!;
}

Future<void> _mount(
  WidgetTester tester,
  GlobalKey key, {
  double height = 400,
  required Widget child,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Theme(
        data: ThemeData.light(),
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 17, top: 11),
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 240,
                height: height,
                child: ChatConversationBackdrop(child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Widget _background({Widget child = const SizedBox.expand()}) =>
    ChatBubbleBackground(
      color: Colors.white,
      borderRadius: BorderRadius.zero,
      child: child,
    );

void _expectUniformTint(_Pixels pixels, int x, int y) => expect(
  pixels.alpha(x, y),
  closeTo(.84 * 255, 1),
  reason: 'plain tint must stay uniform at ($x,$y)',
);

void main() {
  testWidgets('conversation shell paints no full panel fill', (tester) async {
    final key = GlobalKey();
    await _mount(tester, key, child: const SizedBox.expand());
    final pixels = await _capture(tester, key);
    for (final y in [0, 80, 200, 399]) {
      expect(pixels.alpha(120, y), 0);
    }
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets(
    'different bubble sizes and positions have the same uniform tint',
    (tester) async {
      final key = GlobalKey();
      await _mount(
        tester,
        key,
        child: Stack(
          children: [
            Positioned(
              left: 10,
              top: 20,
              width: 90,
              height: 100,
              child: _background(),
            ),
            Positioned(
              left: 120,
              top: 80,
              width: 90,
              height: 220,
              child: _background(),
            ),
          ],
        ),
      );
      final pixels = await _capture(tester, key);
      for (final y in [30, 80, 110]) {
        _expectUniformTint(pixels, 40, y);
      }
      for (final y in [90, 180, 290]) {
        _expectUniformTint(pixels, 150, y);
      }
      expect(pixels.alpha(110, 200), 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('scrolling does not change plain bubble opacity', (tester) async {
    final key = GlobalKey();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _mount(
      tester,
      key,
      height: 300,
      child: ListView.builder(
        controller: scroll,
        padding: EdgeInsets.zero,
        itemCount: 8,
        itemExtent: 100,
        itemBuilder: (_, _) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: _background(),
        ),
      ),
    );
    final before = await _capture(tester, key);
    scroll.jumpTo(65);
    await tester.pumpAndSettle();
    final after = await _capture(tester, key);
    for (final y in [50, 150, 250]) {
      _expectUniformTint(before, 40, y);
      _expectUniformTint(after, 40, y);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('resizing no longer remaps bubble opacity', (tester) async {
    final key = GlobalKey();
    Widget content() => Stack(
      children: [
        Positioned(
          left: 10,
          top: 100,
          width: 200,
          height: 180,
          child: _background(),
        ),
      ],
    );
    await _mount(tester, key, height: 300, child: content());
    final before = await _capture(tester, key);
    await _mount(tester, key, height: 500, child: content());
    final after = await _capture(tester, key);
    _expectUniformTint(before, 40, 150);
    _expectUniformTint(after, 40, 150);
    expect(before.alpha(40, 150), after.alpha(40, 150));
  });

  testWidgets('bubble surface keeps foreground fully opaque', (tester) async {
    final key = GlobalKey();
    await _mount(
      tester,
      key,
      child: Stack(
        children: [
          Positioned(
            left: 10,
            top: 20,
            width: 90,
            height: 100,
            child: _background(
              child: const Center(
                child: SizedBox(
                  width: 10,
                  height: 10,
                  child: ColoredBox(color: Color(0xFFFF0000)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    final pixels = await _capture(tester, key);
    expect(pixels.at(55, 70), [255, 0, 0, 255]);
    _expectUniformTint(pixels, 40, 70);
    expect(find.byType(Opacity), findsNothing);
    expect(find.byType(ShaderMask), findsNothing);
  });
}
