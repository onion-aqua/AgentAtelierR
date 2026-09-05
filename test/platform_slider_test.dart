import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/platform_slider.dart';

void main() {
  testWidgets('Windows slider avoids OverlayPortal and keeps interaction', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final semantics = tester.ensureSemantics();
    var value = 0.5;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: PlatformSlider(
                value: value,
                divisions: 10,
                onChanged: (next) => value = next,
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(CupertinoSlider), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(OverlayPortal), findsNothing);
    await tester.drag(find.byType(CupertinoSlider), const Offset(80, 0));
    expect(value, greaterThan(0.5));
    expect(tester.takeException(), isNull);
    semantics.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android keeps the Material slider', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PlatformSlider(value: 0.5, onChanged: (_) {})),
      ),
    );
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(CupertinoSlider), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
