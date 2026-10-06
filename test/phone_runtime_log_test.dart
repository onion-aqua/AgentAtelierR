import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/runtime_log.dart';
import 'package:ryza_chat_mvp/src/runtime_log_screen.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';

String _longError(int index) => <String>[
  "error $index: 'package:flutter/src/rendering/object.dart': "
      "Failed assertion: line 5732 pos 12: 'node.built': is not true.",
  for (var frame = 0; frame < 25; frame++)
    '#$frame _RenderObjectSemantics.debugCheckForBuilds '
        '(package:flutter/src/rendering/object.dart:5732:12)',
].join('\n');

Future<void> _mount(
  WidgetTester tester,
  bool glass, {
  bool openLogs = true,
}) async {
  tester.view.physicalSize = const Size(390, 840);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    await RuntimeLog.instance.initialize();
    await RuntimeLog.instance.clear();
    for (var i = 0; i < RuntimeLog.maxEntries; i++) {
      RuntimeLog.instance.add(RuntimeLogLevel.error, 'Flutter', _longError(i));
    }
    // Settle singleton storage in a real async zone instead of carrying
    // pending fake-time futures into the next widget test.
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pumpWidget(
    MaterialApp(
      home: VirtualPhoneLauncher(
        language: AppLanguage.chinese,
        liquidGlass: glass,
        pages: {
          VirtualPhoneApp.runtimeLogs: (_) => RuntimeLogScreen(
            language: AppLanguage.chinese,
            liquidGlass: glass,
            embedded: true,
            onMenuPressed: () {},
          ),
        },
      ),
    ),
  );
  await tester.tap(find.byIcon(Icons.smartphone_rounded));
  await tester.pumpAndSettle();
  if (!openLogs) return;
  await tester.tap(find.byKey(const ValueKey('virtual-phone-app-runtimeLogs')));
  // Sample the geometry updates while the long-list app expands from an icon.
  await tester.pump();
  for (var frame = 0; frame < 30; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'phone status tooltips remain accessible through page and phone exits',
    (tester) async {
      await _mount(tester, true, openLogs: false);
      final signal = find.byKey(const ValueKey('virtual-phone-signal'));
      final battery = find.byKey(const ValueKey('virtual-phone-battery'));
      for (final target in [signal, battery, signal, battery]) {
        await tester.longPress(target);
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          find.bySemanticsLabel(RegExp(target == signal ? 'LLM' : '饱食度')),
          findsWidgets,
        );
        Tooltip.dismissAllToolTips();
        await tester.pumpAndSettle();
      }
      await tester.longPress(signal);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(
        find.byKey(const ValueKey('virtual-phone-app-runtimeLogs')),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const ValueKey('virtual-phone-back')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
      await tester.pumpAndSettle();
      await tester.longPress(battery);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.drag(
        find.byKey(const ValueKey('virtual-phone-pull-handle')),
        const Offset(0, 240),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('virtual-phone-screen')), findsNothing);
      // The main launcher uses the same grouped GlassIconButton tooltip.
      await tester.longPress(find.byIcon(Icons.smartphone_rounded));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byIcon(Icons.smartphone_rounded));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('virtual-phone-screen')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.runAsync(RuntimeLog.instance.clear);
      await tester.pumpAndSettle();
    },
  );

  for (final glass in [false, true]) {
    testWidgets(
      'phone long log expansion, append, scrolling and return (glass=$glass)',
      (tester) async {
        await _mount(tester, glass);
        expect(find.text('250 / 250'), findsOneWidget);
        await tester.tap(find.byType(ExpansionTile).first);
        await tester.pumpAndSettle();
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(() async {
            RuntimeLog.instance.add(
              RuntimeLogLevel.error,
              'Flutter',
              _longError(250 + i),
            );
            await Future<void>.delayed(Duration.zero);
          });
          await tester.pump(const Duration(milliseconds: 16));
        }
        // An overlay blocks the log list's semantics while background logs
        // continue to prepend rows. Returning must rebuild the current subtree.
        await tester.tap(find.byType(DropdownButton<RuntimeLogLevel>));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          RuntimeLog.instance.error('Flutter', _longError(500));
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pumpAndSettle();
        await tester.tap(find.text('ERROR').last);
        await tester.pumpAndSettle();
        expect(find.text('250 / 250'), findsOneWidget);
        final list = find.byType(ListView).last;
        await tester.drag(list, const Offset(0, -550));
        await tester.pumpAndSettle();
        await tester.drag(list, const Offset(0, 550));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
        await tester.pump();
        for (var frame = 0; frame < 24; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pumpAndSettle();
        expect(find.byType(RuntimeLogScreen), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.runAsync(RuntimeLog.instance.clear);
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('enabling accessibility after a long log app opens and changes', (
    tester,
  ) async {
    await _mount(tester, true);
    final handle = tester.ensureSemantics();
    try {
      await tester.pump();
      await tester.tap(find.byType(ExpansionTile).first);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        RuntimeLog.instance.error('Flutter', _longError(999));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(RuntimeLogScreen), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      handle.dispose();
      await tester.runAsync(RuntimeLog.instance.clear);
      await tester.pumpAndSettle();
    }
  }, semanticsEnabled: false);
}
