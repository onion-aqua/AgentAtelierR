import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/chat_bubble.dart';
import 'package:ryza_chat_mvp/src/chat_glass_surface.dart';

class _Pixels {
  const _Pixels(this.bytes, this.width);

  final ByteData bytes;
  final int width;

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
  Widget child, {
  double width = 320,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: textScaler),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('subtitle narration is centered, readable, and announced once', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    const narration = '树叶随着微风轻轻摇晃。';
    await _mount(tester, const ChatNarration(text: narration));

    final text = tester.widget<Text>(find.text(narration));
    expect(text.textAlign, TextAlign.center);
    expect(text.style!.fontSize, 14);
    expect(text.style!.fontWeight, FontWeight.w600);
    expect(text.style!.fontStyle, FontStyle.normal);
    expect(text.style!.color, Colors.white);
    expect(text.style!.shadows, hasLength(9));
    expect(find.byType(Text), findsOneWidget);
    expect(find.bySemanticsLabel(narration), findsOneWidget);
    expect(find.byType(ChatGlassSurface), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(Card), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('halo supports the text locally without filling the panel', (
    tester,
  ) async {
    final key = GlobalKey();
    Widget scene(String text) => RepaintBoundary(
      key: key,
      child: SizedBox(
        height: 160,
        child: ColoredBox(
          color: Colors.white,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 160,
                child: ColoredBox(color: Color(0xFFE6F4DB)),
              ),
              Center(child: ChatNarration(text: text)),
            ],
          ),
        ),
      ),
    );
    await _mount(tester, scene(''));
    final baseline = await _capture(tester, key);
    await _mount(tester, scene('A quiet moment'));
    final subtitle = await _capture(tester, key);
    final origin = tester.getTopLeft(find.byKey(key));
    final textRect = tester
        .getRect(find.byKey(const ValueKey('chat-narration-subtitle-text')))
        .shift(-origin);

    // Outside glyph bounds, only the feathered support can darken the scene.
    final x = (textRect.left - 7).round();
    final y = textRect.center.dy.round();
    final supported = subtitle.rgb(x, y);
    final original = baseline.rgb(x, y);
    expect(supported[1], lessThan(original[1] - 3));
    expect(supported[1], greaterThan(original[1] - 60));
    for (final position in const [Offset(8, 8), Offset(310, 150)]) {
      expect(
        subtitle.rgb(position.dx.toInt(), position.dy.toInt()),
        baseline.rgb(position.dx.toInt(), position.dy.toInt()),
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'long narration wraps at narrow widths with large accessibility text',
    (tester) async {
      final narration = '树叶随着微风轻轻摇晃，阳光从枝叶间落下。' * 8;
      await _mount(
        tester,
        SingleChildScrollView(child: ChatNarration(text: narration)),
        width: 240,
        textScaler: TextScaler.linear(2),
      );
      final text = find.byKey(const ValueKey('chat-narration-subtitle-text'));
      expect(tester.getSize(text).width, lessThanOrEqualTo(196));
      expect(tester.getSize(text).height, greaterThan(84));
      expect(tester.takeException(), isNull);
      expect(find.text(narration), findsOneWidget);
    },
  );

  testWidgets(
    'custom text settings and the narration long press are preserved',
    (tester) async {
      Offset? pressedAt;
      await _mount(
        tester,
        ChatNarration(
          text: '按住旁白打开菜单',
          textStyle: const TextStyle(fontSize: 18, color: Color(0xFF263B51)),
          onLongPressStart: (details) => pressedAt = details.globalPosition,
        ),
      );
      final target = find.text('按住旁白打开菜单');
      final text = tester.widget<Text>(target);
      expect(text.style!.fontSize, 18);
      expect(text.style!.color, const Color(0xFF263B51));
      expect(
        text.style!.shadows!.first.color.computeLuminance(),
        greaterThan(.9),
      );
      final position = tester.getCenter(target);
      await tester.longPress(target);
      expect(pressedAt, position);
      expect(tester.takeException(), isNull);
    },
  );
}
