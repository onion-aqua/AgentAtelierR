import 'dart:typed_data';
import 'dart:ui' as ui;

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

  List<int> rgba(int x, int y) => [
    for (var channel = 0; channel < 4; channel++)
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

const _leftRadius = BorderRadius.only(
  topLeft: Radius.circular(4),
  topRight: Radius.circular(24),
  bottomLeft: Radius.circular(22),
  bottomRight: Radius.circular(22),
);
const _rightRadius = BorderRadius.only(
  topLeft: Radius.circular(24),
  topRight: Radius.circular(4),
  bottomLeft: Radius.circular(22),
  bottomRight: Radius.circular(22),
);

Widget _surface(String id, ChatGlassVariant variant) => SizedBox(
  width: 240,
  height: 80,
  child: ChatGlassSurface(
    key: ValueKey(id),
    liquidGlass: true,
    variant: variant,
    borderRadius: id == 'left' ? _leftRadius : _rightRadius,
    fallbackColor: const Color(0xD9263633),
    child: const SizedBox.expand(),
  ),
);

BackdropFilter _filter(WidgetTester tester, String id) =>
    tester.widget<BackdropFilter>(
      find.descendant(
        of: find.byKey(ValueKey(id)),
        matching: find.byType(BackdropFilter),
      ),
    );

Future<void> _mountScene(
  WidgetTester tester,
  GlobalKey key, {
  required bool grouped,
}) async {
  Widget bubble(String text, BorderRadius radius) => ChatGlassSurface(
    liquidGlass: true,
    variant: ChatGlassVariant.bubble,
    borderRadius: radius,
    fallbackColor: const Color(0xD9263633),
    child: Stack(
      children: [
        Center(
          child: Text(text, style: const TextStyle(color: Colors.white)),
        ),
        const Positioned(
          left: 12,
          top: 12,
          width: 10,
          height: 10,
          child: ColoredBox(color: Color(0xFFFFE400)),
        ),
      ],
    ),
  );
  final messages = Stack(
    children: [
      Positioned(
        left: 20,
        top: 20,
        width: 140,
        height: 100,
        child: bubble('原文 Original A', _leftRadius),
      ),
      Positioned(
        left: 200,
        top: 160,
        width: 140,
        height: 110,
        child: bubble('原文 Original B', _rightRadius),
      ),
    ],
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 360,
              height: 300,
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: ColoredBox(color: Color(0xFFD12638))),
                        Expanded(child: ColoredBox(color: Color(0xFF1CC6D5))),
                      ],
                    ),
                  ),
                  Positioned.fill(
                    child: grouped
                        ? ChatBubbleBackdropGroup(child: messages)
                        : messages,
                  ),
                ],
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
  testWidgets('only bubbles share the stable backdrop input', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBubbleBackdropGroup(
            child: Column(
              children: [
                _surface('left', ChatGlassVariant.bubble),
                const SizedBox(height: 12),
                _surface('right', ChatGlassVariant.bubble),
                _surface('menu', ChatGlassVariant.menu),
                _surface('standard', ChatGlassVariant.standard),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final group = tester.widget<BackdropGroup>(find.byType(BackdropGroup));
    final left = _filter(tester, 'left');
    final right = _filter(tester, 'right');
    expect(group.backdropKey, isNotNull);
    expect(left.enabled, isTrue);
    expect(right.enabled, isTrue);
    expect(left.backdropGroupKey, same(group.backdropKey));
    expect(right.backdropGroupKey, same(group.backdropKey));
    expect(_filter(tester, 'menu').backdropGroupKey, isNull);
    expect(_filter(tester, 'standard').backdropGroupKey, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('grouped sampling preserves scene positions and curved clips', (
    tester,
  ) async {
    final key = GlobalKey();
    await _mountScene(tester, key, grouped: false);
    final separate = await _capture(tester, key);
    await _mountScene(tester, key, grouped: true);
    final grouped = await _capture(tester, key);

    // Both backdrop coordinates and foreground painting must remain identical.
    expect(grouped.values, orderedEquals(separate.values));
    final left = grouped.rgba(60, 90);
    final right = grouped.rgba(250, 240);
    expect(left[0] - left[1], greaterThan(20));
    expect(right[1] - right[0], greaterThan(20));
    expect(right[2] - right[0], greaterThan(20));
    // Opposite corners use different radii; clipped pixels show the scene.
    expect(grouped.rgba(159, 119), [209, 38, 56, 255]);
    expect(grouped.rgba(201, 161), [28, 198, 213, 255]);
    // Fully opaque foreground markers are never blurred or sampled away.
    expect(grouped.rgba(35, 35), [255, 228, 0, 255]);
    expect(grouped.rgba(215, 175), [255, 228, 0, 255]);
    expect(find.text('原文 Original A'), findsOneWidget);
    expect(find.text('原文 Original B'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass toggles retain group key, input element and draft', (
    tester,
  ) async {
    final enabled = ValueNotifier(true);
    final input = TextEditingController();
    final focus = FocusNode();
    addTearDown(enabled.dispose);
    addTearDown(input.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (context, value, _) => GlassStyleScope(
              enabled: value,
              child: ChatBubbleBackdropGroup(
                child: SizedBox(
                  width: 240,
                  height: 100,
                  child: ChatGlassSurface(
                    key: const ValueKey('editable'),
                    liquidGlass: false,
                    variant: ChatGlassVariant.bubble,
                    fallbackColor: const Color(0xD9263633),
                    child: TextField(controller: input, focusNode: focus),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '不丢失的草稿');
    input.selection = const TextSelection(baseOffset: 1, extentOffset: 4);
    await tester.pumpAndSettle();
    final groupElement = tester.element(find.byType(ChatBubbleBackdropGroup));
    final surfaceElement = tester.element(
      find.byKey(const ValueKey('editable')),
    );
    final inputElement = tester.element(find.byType(TextField));
    final groupKey = _filter(tester, 'editable').backdropGroupKey;
    expect(groupKey, isNotNull);
    for (final value in [false, true, false, true]) {
      enabled.value = value;
      await tester.pumpAndSettle();
      expect(
        tester.element(find.byType(ChatBubbleBackdropGroup)),
        same(groupElement),
      );
      expect(
        tester.element(find.byKey(const ValueKey('editable'))),
        same(surfaceElement),
      );
      expect(tester.element(find.byType(TextField)), same(inputElement));
      expect(_filter(tester, 'editable').backdropGroupKey, same(groupKey));
      expect(_filter(tester, 'editable').enabled, value);
      expect(input.text, '不丢失的草稿');
      expect(
        input.selection,
        const TextSelection(baseOffset: 1, extentOffset: 4),
      );
      expect(focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('drag pauses only bubble blur and restores it when settled', (
    tester,
  ) async {
    final scroll = ScrollController();
    final input = TextEditingController(text: '滚动时保留草稿');
    addTearDown(scroll.dispose);
    addTearDown(input.dispose);
    Widget surface(
      String id,
      ChatGlassVariant variant,
      Widget child, {
      double height = 80,
    }) => SizedBox(
      width: 240,
      height: height,
      child: ChatGlassSurface(
        key: ValueKey(id),
        liquidGlass: true,
        variant: variant,
        fallbackColor: const Color(0xD9263633),
        child: child,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatBubbleBackdropGroup(
            child: SizedBox(
              width: 240,
              height: 320,
              child: SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: [
                    surface(
                      'scroll-bubble',
                      ChatGlassVariant.bubble,
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('原文保持清晰'),
                          TextButton(
                            onPressed: () {},
                            child: const Text('保留控件'),
                          ),
                        ],
                      ),
                      height: 120,
                    ),
                    surface(
                      'scroll-menu',
                      ChatGlassVariant.menu,
                      const Center(child: Text('菜单保持模糊')),
                    ),
                    surface(
                      'scroll-standard',
                      ChatGlassVariant.standard,
                      TextField(controller: input),
                    ),
                    const SizedBox(height: 600),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bubble = find.byKey(const ValueKey('scroll-bubble'));
    final bubbleElement = tester.element(bubble);
    final textElement = tester.element(find.text('原文保持清晰'));
    final buttonElement = tester.element(find.text('保留控件'));
    final inputElement = tester.element(find.byType(TextField));
    final groupKey = _filter(tester, 'scroll-bubble').backdropGroupKey;
    final baseGlass = tester.widget<GlassSurface>(
      find.descendant(of: bubble, matching: find.byType(GlassSurface)),
    );
    final paintedLayers = tester
        .widgetList<CustomPaint>(
          find.descendant(of: bubble, matching: find.byType(CustomPaint)),
        )
        .where(
          (paint) => paint.painter != null || paint.foregroundPainter != null,
        )
        .length;
    expect(groupKey, isNotNull);
    expect(scroll.position.isScrollingNotifier.value, isFalse);
    expect(_filter(tester, 'scroll-bubble').enabled, isTrue);
    expect(_filter(tester, 'scroll-menu').enabled, isTrue);
    expect(_filter(tester, 'scroll-standard').enabled, isTrue);

    final origin = tester.getTopLeft(bubble);
    final gesture = await tester.startGesture(origin + const Offset(220, 90));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    expect(scroll.offset, greaterThan(0));
    expect(_filter(tester, 'scroll-bubble').enabled, isFalse);
    expect(_filter(tester, 'scroll-bubble').backdropGroupKey, same(groupKey));
    expect(_filter(tester, 'scroll-menu').enabled, isTrue);
    expect(_filter(tester, 'scroll-standard').enabled, isTrue);
    expect(_filter(tester, 'scroll-menu').backdropGroupKey, isNull);
    expect(_filter(tester, 'scroll-standard').backdropGroupKey, isNull);
    final movingGlass = tester.widget<GlassSurface>(
      find.descendant(of: bubble, matching: find.byType(GlassSurface)),
    );
    expect(movingGlass.fillOpacity, baseGlass.fillOpacity);
    expect(movingGlass.readableText, isTrue);
    expect(
      tester
          .widgetList<CustomPaint>(
            find.descendant(of: bubble, matching: find.byType(CustomPaint)),
          )
          .where(
            (paint) => paint.painter != null || paint.foregroundPainter != null,
          ),
      hasLength(paintedLayers),
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(scroll.position.isScrollingNotifier.value, isFalse);
    expect(_filter(tester, 'scroll-bubble').enabled, isTrue);
    expect(_filter(tester, 'scroll-bubble').backdropGroupKey, same(groupKey));
    expect(tester.element(bubble), same(bubbleElement));
    expect(tester.element(find.text('原文保持清晰')), same(textElement));
    expect(tester.element(find.text('保留控件')), same(buttonElement));
    expect(tester.element(find.byType(TextField)), same(inputElement));
    expect(input.text, '滚动时保留草稿');
    final settledOffset = scroll.offset;
    expect(settledOffset, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(scroll.offset, settledOffset);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
