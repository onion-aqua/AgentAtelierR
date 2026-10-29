import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/chat_message_edge_transition.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';

Future<ByteData> _pixels(WidgetTester tester, GlobalKey key) async =>
    (await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      image.dispose();
      return bytes;
    }))!;

List<int> _at(ByteData bytes, int x, int y) => [
  for (var c = 0; c < 4; c++) bytes.getUint8((y * 120 + x) * 4 + c),
];

Future<void> _mount(
  WidgetTester tester,
  GlobalKey key,
  Widget child, {
  Widget? background,
  double height = 160,
  bool allowSceneBackdrop = false,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 120,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ?background,
                ChatMessageEdgeTransition(
                  allowSceneBackdrop: allowSceneBackdrop,
                  child: child,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('top fades gradually while the rest remains opaque', (
    tester,
  ) async {
    final key = GlobalKey();
    await _mount(tester, key, const ColoredBox(color: Colors.white));
    final pixels = await _pixels(tester, key);
    expect(_at(pixels, 60, 0)[3], lessThan(10));
    expect(_at(pixels, 60, 8)[3], inInclusiveRange(45, 80));
    expect(_at(pixels, 60, 16)[3], inInclusiveRange(110, 150));
    expect(_at(pixels, 60, 40), [255, 255, 255, 255]);
    expect(_at(pixels, 60, 150), [255, 255, 255, 255]);
  });

  testWidgets('blur stays in the narrow message strip and scene stays sharp', (
    tester,
  ) async {
    final key = GlobalKey();
    const scene = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: ColoredBox(color: Color(0xFFFF0000))),
        Expanded(child: ColoredBox(color: Color(0xFF0000FF))),
      ],
    );
    await _mount(tester, key, const SizedBox.expand(), background: scene);
    final clear = await _pixels(tester, key);
    for (final y in [4, 16, 40, 150]) {
      expect(_at(clear, 59, y), [255, 0, 0, 255]);
      expect(_at(clear, 60, y), [0, 0, 255, 255]);
    }
    await _mount(
      tester,
      key,
      const Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: ColoredBox(color: Colors.white)),
          Expanded(child: ColoredBox(color: Colors.black)),
        ],
      ),
    );
    final blurred = await _pixels(tester, key);
    expect(_at(blurred, 59, 16)[0], lessThan(250));
    expect(_at(blurred, 60, 16)[0], greaterThan(5));
    expect(_at(blurred, 59, 40), [255, 255, 255, 255]);
    expect(_at(blurred, 60, 40), [0, 0, 0, 255]);
    final filter = find.byType(BackdropFilter);
    expect(filter, findsOneWidget);
    expect(tester.getSize(filter).height, 24);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single child keeps scrolling and pointer hits', (tester) async {
    final key = GlobalKey();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var hits = 0;
    var builds = 0;
    await _mount(
      tester,
      key,
      Builder(
        builder: (context) {
          builds++;
          return ListView.builder(
            controller: scroll,
            itemExtent: 50,
            itemCount: 20,
            itemBuilder: (_, i) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => hits++,
              child: Text('item $i'),
            ),
          );
        },
      ),
    );
    expect(builds, 1);
    expect(scroll.positions, hasLength(1));
    await tester.tapAt(const Offset(60, 15));
    expect(hits, 1);
    await tester.drag(find.byType(ListView), const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(scroll.positions, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('short viewport clamps transition without layout errors', (
    tester,
  ) async {
    final key = GlobalKey();
    await _mount(
      tester,
      key,
      const ColoredBox(color: Colors.white),
      height: 12,
    );
    final filter = find.byType(BackdropFilter);
    expect(tester.getSize(filter).height, 9);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'glass mode samples the scene only inside local glass and top strip',
    (tester) async {
      final key = GlobalKey();
      const scene = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: ColoredBox(color: Color(0xFFFF0000))),
          Expanded(child: ColoredBox(color: Color(0xFF0000FF))),
        ],
      );
      const messages = Stack(
        children: [
          Positioned(
            left: 20,
            right: 20,
            top: 60,
            height: 50,
            child: GlassSurface(
              liquidGlass: true,
              transparentFill: true,
              blurSigma: 10,
              borderRadius: BorderRadius.zero,
              child: SizedBox.expand(),
            ),
          ),
        ],
      );
      await _mount(tester, key, messages, background: scene);
      final isolated = await _pixels(tester, key);
      expect(_at(isolated, 59, 80), [255, 0, 0, 255]);
      expect(_at(isolated, 60, 80), [0, 0, 255, 255]);

      await _mount(
        tester,
        key,
        messages,
        background: scene,
        allowSceneBackdrop: true,
      );
      final glass = await _pixels(tester, key);
      // A real bubble's backdrop now sees the external scene, not an empty mask.
      expect(_at(glass, 59, 80)[0], lessThan(250));
      expect(_at(glass, 59, 80)[2], greaterThan(5));
      expect(_at(glass, 60, 80)[0], greaterThan(5));
      // Only the small upper strip and local bubble sample the backdrop.
      for (final y in [40, 130, 150]) {
        expect(_at(glass, 59, y), [255, 0, 0, 255]);
        expect(_at(glass, 60, y), [0, 0, 255, 255]);
      }
      expect(_at(glass, 59, 16)[2], greaterThan(5));
      expect(_at(glass, 60, 16)[0], greaterThan(5));
      for (final y in [16, 40, 80, 150]) {
        expect(_at(glass, 59, y)[3], 255);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switching glass mode preserves child state and unmasked body', (
    tester,
  ) async {
    final key = GlobalKey();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var stateBuilds = 0;
    final content = Builder(
      builder: (context) {
        stateBuilds++;
        return ListView.builder(
          controller: scroll,
          itemExtent: 50,
          itemCount: 20,
          itemBuilder: (_, i) => Text('item $i'),
        );
      },
    );
    await _mount(tester, key, content);
    final listElement = tester.element(find.byType(ListView));
    scroll.jumpTo(100);
    await tester.pumpAndSettle();
    await _mount(tester, key, content, allowSceneBackdrop: true);
    expect(tester.element(find.byType(ListView)), same(listElement));
    expect(stateBuilds, 1);
    expect(scroll.offset, 100);
    expect(scroll.positions, hasLength(1));

    await _mount(
      tester,
      key,
      const ColoredBox(color: Colors.white),
      allowSceneBackdrop: true,
    );
    final pixels = await _pixels(tester, key);
    for (final y in [0, 8, 16, 40, 150]) {
      expect(_at(pixels, 60, y), [255, 255, 255, 255]);
    }
    expect(tester.takeException(), isNull);
  });
}
