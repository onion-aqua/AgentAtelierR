import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';
import 'package:ryza_chat_mvp/src/virtual_phone_app_route.dart';

const _barKey = ValueKey('virtual-phone-status-bar');
const _labelKey = ValueKey('virtual-phone-status-time');
const _transitionKey = ValueKey('virtual-phone-app-transition');
const _pageKey = ValueKey('status-transition-page');
const _carrier = '库肯岛移动';
const _time = '09:41';

Finder get _bar => find.byKey(_barKey);
Finder get _app => find.byKey(const ValueKey('virtual-phone-app-status'));

Widget _testPage(BuildContext context) => Scaffold(
  key: _pageKey,
  body: Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            useRootNavigator: false,
            builder: (_) => const AlertDialog(title: Text('local dialog')),
          ),
          child: const Text('open local dialog'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('secondary page')),
            ),
          ),
          child: const Text('open secondary page'),
        ),
      ],
    ),
  ),
);

Future<void> _mount(
  WidgetTester tester, {
  required ThemeMode mode,
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = const Size(390, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: atelierTheme(AppAccentTheme.jade, Brightness.light),
      darkTheme: atelierTheme(AppAccentTheme.jade, Brightness.dark),
      themeMode: mode,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: VirtualPhoneLauncher(
        language: AppLanguage.chinese,
        liquidGlass: false,
        pages: {VirtualPhoneApp.status: _testPage},
      ),
    ),
  );
  await tester.tap(find.byIcon(Icons.smartphone_rounded));
  await tester.pumpAndSettle();
}

Color _background(WidgetTester tester) => tester.widget<Container>(_bar).color!;

Color _appBackground(WidgetTester tester) =>
    glassPageHeaderColor(tester.element(_bar)).withValues(alpha: 1);

Text _label(WidgetTester tester) => tester.widget<Text>(find.byKey(_labelKey));

VirtualPhoneAppRoute _route(WidgetTester tester) =>
    ModalRoute.of(tester.element(find.byKey(_pageKey)))!
        as VirtualPhoneAppRoute;

void _expectForeground(WidgetTester tester, Color foreground) {
  expect(_label(tester).style!.color, foreground);
  for (final indicator in ['signal', 'battery']) {
    expect(
      tester
          .widget<Image>(find.byKey(ValueKey('virtual-phone-$indicator')))
          .color,
      foreground,
    );
  }
}

void _expectHome(WidgetTester tester) {
  expect(_background(tester).a, 0);
  _expectForeground(tester, Colors.white);
  expect(_label(tester).data, _carrier);
}

void _expectApp(WidgetTester tester, ThemeMode mode) {
  expect(_background(tester), _appBackground(tester));
  _expectForeground(
    tester,
    mode == ThemeMode.dark ? Colors.white : Colors.black,
  );
  expect(_label(tester).data, _time);
}

void _expectPartialChrome(WidgetTester tester, ThemeMode mode) {
  expect(_background(tester).a, allOf(greaterThan(0), lessThan(1)));
  final foreground = _label(tester).style!.color!;
  _expectForeground(tester, foreground);
  if (mode == ThemeMode.light) {
    // Text and monochrome assets change together rather than jumping to black
    // while the small app window is still far from the status bar.
    expect(foreground, isNot(Colors.white));
    expect(foreground, isNot(Colors.black));
  } else {
    expect(foreground, Colors.white);
  }
}

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('status bar follows app open and close with $mode', (
      tester,
    ) async {
      await _mount(tester, mode: mode);
      _expectHome(tester);
      final barBounds = tester.getRect(_bar);
      final origin = tester.getRect(
        find.byKey(const ValueKey('virtual-phone-glyph-status')),
      );

      await tester.tap(_app);
      await tester.pump();
      _expectHome(tester);
      await tester.pump(const Duration(milliseconds: 40));
      final earlyWindow = tester.getRect(find.byKey(_transitionKey));
      expect(earlyWindow.width, greaterThan(origin.width));
      expect(earlyWindow.height, greaterThan(origin.height));
      _expectHome(tester);
      await tester.pump(const Duration(milliseconds: 120));
      _expectPartialChrome(tester, mode);
      final openingAlpha = _background(tester).a;
      await tester.pump(const Duration(milliseconds: 60));
      expect(_background(tester).a, greaterThan(openingAlpha));
      expect(_background(tester).a, lessThan(1));
      expect(tester.getRect(_bar), barBounds);

      await tester.pumpAndSettle();
      _expectApp(tester, mode);
      final fullWindow = tester.getRect(find.byKey(_transitionKey));
      await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
      await tester.pump();
      _expectApp(tester, mode);
      await tester.pump(const Duration(milliseconds: 160));
      final closingWindow = tester.getRect(find.byKey(_transitionKey));
      expect(closingWindow.width, lessThan(fullWindow.width));
      expect(closingWindow.width, greaterThan(origin.width));
      _expectPartialChrome(tester, mode);
      final closingAlpha = _background(tester).a;
      await tester.pump(const Duration(milliseconds: 40));
      expect(_background(tester).a, lessThan(closingAlpha));
      await tester.pumpAndSettle();
      _expectHome(tester);
      expect(tester.getRect(_bar), barBounds);
      expect(tester.takeException(), isNull);
    });

    testWidgets('status bar follows cancelled and committed back with $mode', (
      tester,
    ) async {
      await _mount(tester, mode: mode);
      await tester.tap(_app);
      await tester.pumpAndSettle();
      final route = _route(tester);
      final fullWindow = tester.getRect(find.byKey(_transitionKey));

      route.handleStartBackGesture();
      await tester.pump();
      _expectApp(tester, mode);
      route.handleUpdateBackGestureProgress(progress: .8);
      await tester.pump();
      _expectPartialChrome(tester, mode);
      expect(
        tester.getRect(find.byKey(_transitionKey)).width,
        lessThan(fullWindow.width),
      );
      final cancelledAlpha = _background(tester).a;
      route.handleCancelBackGesture();
      await tester.pump();
      expect(_background(tester).a, cancelledAlpha);
      await tester.pump(const Duration(milliseconds: 50));
      expect(_background(tester).a, greaterThan(cancelledAlpha));
      await tester.pumpAndSettle();
      _expectApp(tester, mode);
      expect(tester.getRect(find.byKey(_transitionKey)), fullWindow);

      route.handleStartBackGesture();
      route.handleUpdateBackGestureProgress(progress: .8);
      await tester.pump();
      _expectPartialChrome(tester, mode);
      final committedAlpha = _background(tester).a;
      route.handleCommitBackGesture();
      await tester.pump();
      expect(_background(tester).a, committedAlpha);
      await tester.pump(const Duration(milliseconds: 50));
      expect(_background(tester).a, lessThan(committedAlpha));
      await tester.pumpAndSettle();
      _expectHome(tester);
      expect(find.byKey(_pageKey), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('nested pages and dialogs retain app status bar with $mode', (
      tester,
    ) async {
      await _mount(tester, mode: mode);
      await tester.tap(_app);
      await tester.pumpAndSettle();
      _expectApp(tester, mode);
      await tester.tap(find.text('open local dialog'));
      await tester.pump();
      _expectApp(tester, mode);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 60));
      _expectApp(tester, mode);
      await tester.pumpAndSettle();

      await tester.tap(find.text('open secondary page'));
      await tester.pump(const Duration(milliseconds: 60));
      _expectApp(tester, mode);
      await tester.pumpAndSettle();
      expect(find.text('secondary page'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 60));
      _expectApp(tester, mode);
      await tester.pumpAndSettle();
      _expectApp(tester, mode);
      expect(find.byKey(_pageKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion has no status bar lag with $mode', (
      tester,
    ) async {
      await _mount(tester, mode: mode, reduceMotion: true);
      _expectHome(tester);
      await tester.tap(_app);
      await tester.pump();
      expect(_route(tester).transitionDuration, Duration.zero);
      _expectApp(tester, mode);
      await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
      await tester.pump();
      _expectHome(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'closing the phone during app animation resets chrome with $mode',
      (tester) async {
        await _mount(tester, mode: mode);
        await tester.tap(_app);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 160));
        _expectPartialChrome(tester, mode);
        await tester.drag(_bar, const Offset(0, 220));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('virtual-phone-screen')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);

        await tester.tap(find.byIcon(Icons.smartphone_rounded));
        await tester.pumpAndSettle();
        _expectHome(tester);
        await tester.tap(_app);
        await tester.pump();
        _expectHome(tester);
        await tester.pumpAndSettle();
        _expectApp(tester, mode);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
