import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';

const _transitionKey = ValueKey('virtual-phone-app-transition');
const _barKey = ValueKey('virtual-phone-status-bar');

Finder _icon(VirtualPhoneApp app) =>
    find.byKey(ValueKey('virtual-phone-app-${app.name}'));
Finder _glyph(VirtualPhoneApp app) =>
    find.byKey(ValueKey('virtual-phone-glyph-${app.name}'));
Finder _page(VirtualPhoneApp app) =>
    find.byKey(ValueKey('animation-test-page-${app.name}'));

Widget _testPage(BuildContext context, VirtualPhoneApp app) => Scaffold(
  key: ValueKey('animation-test-page-${app.name}'),
  drawer: const Drawer(child: Center(child: Text('local app drawer'))),
  drawerEnableOpenDragGesture: false,
  body: Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('full page ${app.name}'),
        TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            useRootNavigator: false,
            builder: (_) =>
                const AlertDialog(title: Text('local confirmation')),
          ),
          child: const Text('open local dialog'),
        ),
        TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            useRootNavigator: true,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text('outer dialog'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('close outer dialog'),
                ),
              ],
            ),
          ),
          child: const Text('open outer dialog'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('nested settings')),
                body: const Text('secondary page'),
              ),
            ),
          ),
          child: const Text('open secondary page'),
        ),
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Scaffold.of(context).openDrawer(),
            child: const Text('open local drawer'),
          ),
        ),
      ],
    ),
  ),
);

Future<void> _mountPhone(
  WidgetTester tester, {
  bool reduceMotion = false,
  ValueNotifier<bool>? allowBack,
  ValueChanged<bool>? onPop,
}) async {
  tester.view.physicalSize = const Size(390, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: VirtualPhoneLauncher(
        language: AppLanguage.chinese,
        liquidGlass: false,
        pages: {
          for (final app in VirtualPhoneApp.values)
            app: (context) => allowBack == null
                ? _testPage(context, app)
                : ValueListenableBuilder<bool>(
                    valueListenable: allowBack,
                    builder: (context, value, _) => PopScope<void>(
                      canPop: value,
                      onPopInvokedWithResult: (didPop, _) =>
                          onPop?.call(didPop),
                      child: _testPage(context, app),
                    ),
                  ),
        },
      ),
    ),
  );
  await tester.tap(find.byIcon(Icons.smartphone_rounded));
  await tester.pumpAndSettle();
}

void _expectRectClose(Rect actual, Rect expected, {double tolerance = 2}) {
  expect(actual.left, closeTo(expected.left, tolerance));
  expect(actual.top, closeTo(expected.top, tolerance));
  expect(actual.width, closeTo(expected.width, tolerance));
  expect(actual.height, closeTo(expected.height, tolerance));
}

Rect _contentRect(WidgetTester tester) {
  final phone = tester.getRect(
    find.byKey(const ValueKey('virtual-phone-screen')),
  );
  final bar = tester.getRect(find.byKey(_barKey));
  return Rect.fromLTRB(phone.left, bar.bottom, phone.right, phone.bottom);
}

PageRoute<dynamic> _appRoute(WidgetTester tester, VirtualPhoneApp app) =>
    ModalRoute.of(tester.element(_page(app)))! as PageRoute<dynamic>;

Future<void> _predictiveEvent(
  WidgetTester tester,
  String method, {
  double progress = 0,
  int edge = 0,
}) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, {
        'touchOffset': <double>[5, 300],
        'progress': progress,
        'swipeEdge': edge,
      }),
    ),
    (_) {},
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'home and dock apps grow from their actual glyph and shrink back',
    (tester) async {
      await _mountPhone(tester);
      final bar = tester.getRect(find.byKey(_barKey));
      final content = _contentRect(tester);
      for (final app in [
        VirtualPhoneApp.status,
        VirtualPhoneApp.motion,
        VirtualPhoneApp.phone,
      ]) {
        final origin = tester.getRect(_glyph(app));
        expect(origin.size, const Size(58, 58));
        await tester.tap(_icon(app));
        await tester.pump();
        final route = _appRoute(tester, app);
        final initial = tester.getRect(find.byKey(_transitionKey));
        _expectRectClose(initial, origin);
        final halfForward = Duration(
          microseconds: route.transitionDuration.inMicroseconds ~/ 2,
        );
        await tester.pump(halfForward);
        final middle = tester.getRect(find.byKey(_transitionKey));
        expect(middle.width, greaterThan(initial.width));
        expect(middle.height, greaterThan(initial.height));
        expect(middle.width, lessThan(content.width));
        expect(middle.height, lessThan(content.height));
        expect(tester.getRect(find.byKey(_barKey)), bar);
        await tester.pumpAndSettle();
        _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
        await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
        await tester.pump();
        final halfReverse = Duration(
          microseconds: route.reverseTransitionDuration.inMicroseconds ~/ 2,
        );
        await tester.pump(halfReverse);
        final closing = tester.getRect(find.byKey(_transitionKey));
        expect(closing.width, lessThan(content.width));
        expect(closing.width, greaterThan(origin.width));
        await tester.pump(
          route.reverseTransitionDuration -
              halfReverse -
              const Duration(milliseconds: 1),
        );
        _expectRectClose(
          tester.getRect(find.byKey(_transitionKey)),
          origin,
          tolerance: 5,
        );
        expect(tester.getRect(find.byKey(_barKey)), bar);
        await tester.pumpAndSettle();
        expect(_page(app), findsNothing);
        expect(_glyph(app), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid app taps create one page and one back returns to launcher',
    (tester) async {
      await _mountPhone(tester);
      final point = tester.getCenter(_glyph(VirtualPhoneApp.status));
      await tester.tapAt(point);
      await tester.tapAt(point);
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      expect(_page(VirtualPhoneApp.status), findsOneWidget);
      expect(find.byKey(_transitionKey, skipOffstage: false), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_page(VirtualPhoneApp.status), findsNothing);
      expect(_icon(VirtualPhoneApp.status).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local dialog and secondary route pop before the root app shrinks',
    (tester) async {
      await _mountPhone(tester);
      await tester.tap(_icon(VirtualPhoneApp.status));
      await tester.pumpAndSettle();
      final content = _contentRect(tester);
      await tester.tap(find.text('open local dialog'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 60));
      _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
      await tester.pumpAndSettle();
      expect(find.text('local confirmation'), findsNothing);
      expect(_page(VirtualPhoneApp.status), findsOneWidget);
      await tester.tap(find.text('open secondary page'));
      await tester.pumpAndSettle();
      expect(find.text('secondary page'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('secondary page'), findsNothing);
      _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 90));
      expect(
        tester.getRect(find.byKey(_transitionKey)).width,
        lessThan(content.width),
      );
      await tester.pumpAndSettle();
      expect(_icon(VirtualPhoneApp.status).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'left and right edge drags cancel or shrink toward the source icon',
    (tester) async {
      await _mountPhone(tester);
      final bar = tester.getRect(find.byKey(_barKey));
      for (final side in ['left', 'right']) {
        final origin = tester.getRect(_glyph(VirtualPhoneApp.motion));
        await tester.tap(_icon(VirtualPhoneApp.motion));
        await tester.pumpAndSettle();
        final content = _contentRect(tester);
        final edge = find.byKey(ValueKey('virtual-phone-back-edge-$side'));
        final direction = side == 'left' ? 1.0 : -1.0;
        final cancel = await tester.startGesture(tester.getCenter(edge));
        await tester.pump(const Duration(milliseconds: 30));
        await cancel.moveBy(Offset(direction * 25, 0));
        await tester.pump(const Duration(milliseconds: 60));
        await cancel.moveBy(Offset(direction * content.width * .10, 0));
        await tester.pump(const Duration(milliseconds: 150));
        final partial = tester.getRect(find.byKey(_transitionKey));
        expect(partial.width, lessThan(content.width));
        expect(partial.width, greaterThan(origin.width));
        expect(tester.getRect(find.byKey(_barKey)), bar);
        await cancel.up();
        await tester.pumpAndSettle();
        expect(_page(VirtualPhoneApp.motion), findsOneWidget);
        _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
        final commit = await tester.startGesture(tester.getCenter(edge));
        await tester.pump(const Duration(milliseconds: 30));
        await commit.moveBy(Offset(direction * 25, 0));
        await tester.pump(const Duration(milliseconds: 60));
        await commit.moveBy(Offset(direction * content.width * .60, 0));
        await tester.pump(const Duration(milliseconds: 150));
        final committing = tester.getRect(find.byKey(_transitionKey));
        expect(
          committing.center.dx,
          closeTo(
            origin.center.dx +
                (content.center.dx - origin.center.dx) *
                    ((committing.width - origin.width) /
                        (content.width - origin.width)),
            2,
          ),
        );
        await commit.up();
        await tester.pumpAndSettle();
        expect(_page(VirtualPhoneApp.motion), findsNothing);
        expect(_glyph(VirtualPhoneApp.motion).hitTestable(), findsOneWidget);
        expect(tester.getRect(find.byKey(_barKey)), bar);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android predictive back supports cancellation and commit geometry',
    (tester) async {
      await _mountPhone(tester);
      await tester.tap(_icon(VirtualPhoneApp.status));
      await tester.pumpAndSettle();
      final content = _contentRect(tester);
      final bar = tester.getRect(find.byKey(_barKey));
      await _predictiveEvent(tester, 'startBackGesture');
      await _predictiveEvent(
        tester,
        'updateBackGestureProgress',
        progress: .45,
      );
      expect(
        tester.getRect(find.byKey(_transitionKey)).width,
        lessThan(content.width),
      );
      expect(tester.getRect(find.byKey(_barKey)), bar);
      await _predictiveEvent(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
      await _predictiveEvent(tester, 'startBackGesture', edge: 1);
      await _predictiveEvent(
        tester,
        'updateBackGestureProgress',
        progress: .7,
        edge: 1,
      );
      expect(
        tester.getRect(find.byKey(_transitionKey)).width,
        lessThan(content.width),
      );
      await _predictiveEvent(tester, 'commitBackGesture', edge: 1);
      await tester.pumpAndSettle();
      expect(_page(VirtualPhoneApp.status), findsNothing);
      expect(_icon(VirtualPhoneApp.status).hitTestable(), findsOneWidget);
      expect(tester.getRect(find.byKey(_barKey)), bar);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a pressed glyph remains the measured opening origin', (
    tester,
  ) async {
    await _mountPhone(tester);
    final app = VirtualPhoneApp.shop;
    final glyph = _glyph(app);
    final press = await tester.startGesture(tester.getCenter(glyph));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final pressedRect = tester.getRect(glyph);
    expect(pressedRect.width, lessThan(58));
    await press.up();
    await tester.pump();
    _expectRectClose(tester.getRect(find.byKey(_transitionKey)), pressedRect);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('drawer local history closes before a predictive app exit', (
    tester,
  ) async {
    await _mountPhone(tester);
    await tester.tap(_icon(VirtualPhoneApp.status));
    await tester.pumpAndSettle();
    final content = _contentRect(tester);
    await tester.tap(find.text('open local drawer'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
    await tester.pumpAndSettle();
    expect(find.text('local app drawer').hitTestable(), findsNothing);
    expect(_page(VirtualPhoneApp.status), findsOneWidget);
    _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
    await tester.tap(find.text('open local drawer'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('virtual-phone-back-edge-right')),
      Offset(-content.width * .70, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('local app drawer').hitTestable(), findsNothing);
    expect(_page(VirtualPhoneApp.status), findsOneWidget);
    _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
    await tester.tap(find.text('open local drawer'));
    await tester.pumpAndSettle();
    expect(
      _appRoute(tester, VirtualPhoneApp.status).willHandlePopInternally,
      isTrue,
    );
    await _predictiveEvent(tester, 'startBackGesture');
    await _predictiveEvent(tester, 'updateBackGestureProgress', progress: .6);
    _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
    await _predictiveEvent(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('local app drawer').hitTestable(), findsNothing);
    expect(_page(VirtualPhoneApp.status), findsOneWidget);
    _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_icon(VirtualPhoneApp.status).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'PopScope blocks swipe and predictive exits until it permits back',
    (tester) async {
      final allowBack = ValueNotifier(false);
      final popAttempts = <bool>[];
      addTearDown(allowBack.dispose);
      await _mountPhone(tester, allowBack: allowBack, onPop: popAttempts.add);
      await tester.tap(_icon(VirtualPhoneApp.status));
      await tester.pumpAndSettle();
      final content = _contentRect(tester);
      await tester.drag(
        find.byKey(const ValueKey('virtual-phone-back-edge-left')),
        Offset(content.width * .8, 0),
      );
      await tester.pumpAndSettle();
      _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
      expect(popAttempts, contains(false));
      await _predictiveEvent(tester, 'startBackGesture');
      await _predictiveEvent(tester, 'updateBackGestureProgress', progress: .8);
      _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
      await _predictiveEvent(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(_page(VirtualPhoneApp.status), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_page(VirtualPhoneApp.status), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
      await tester.pumpAndSettle();
      expect(_page(VirtualPhoneApp.status), findsOneWidget);
      _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
      allowBack.value = true;
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(
        tester.getRect(find.byKey(_transitionKey)).width,
        lessThan(content.width),
      );
      await tester.pumpAndSettle();
      expect(_page(VirtualPhoneApp.status), findsNothing);
      expect(_icon(VirtualPhoneApp.status).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an outer dialog prevents edge and predictive app exits', (
    tester,
  ) async {
    await _mountPhone(tester);
    await tester.tap(_icon(VirtualPhoneApp.status));
    await tester.pumpAndSettle();
    final content = _contentRect(tester);
    await tester.tap(find.text('open outer dialog'));
    await tester.pumpAndSettle();
    await tester.dragFrom(
      Offset(content.left + 10, content.center.dy),
      Offset(content.width * .65, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('outer dialog'), findsOneWidget);
    _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
    await _predictiveEvent(tester, 'startBackGesture');
    await _predictiveEvent(tester, 'updateBackGestureProgress', progress: .7);
    _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
    await _predictiveEvent(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('outer dialog'), findsOneWidget);
    expect(_page(VirtualPhoneApp.status), findsOneWidget);
    await tester.tap(find.text('close outer dialog'));
    await tester.pumpAndSettle();
    _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_icon(VirtualPhoneApp.status).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion opens and closes without an expanding interval', (
    tester,
  ) async {
    await _mountPhone(tester, reduceMotion: true);
    await tester.tap(_icon(VirtualPhoneApp.status));
    await tester.pump();
    final route = _appRoute(tester, VirtualPhoneApp.status);
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    _expectRectClose(
      tester.getRect(find.byKey(_transitionKey)),
      _contentRect(tester),
    );
    final content = _contentRect(tester);
    final edge = find.byKey(const ValueKey('virtual-phone-back-edge-left'));
    final cancel = await tester.startGesture(tester.getCenter(edge));
    await tester.pump(const Duration(milliseconds: 30));
    await cancel.moveBy(const Offset(25, 0));
    await tester.pump(const Duration(milliseconds: 60));
    await cancel.moveBy(Offset(content.width * .10, 0));
    await tester.pump(const Duration(milliseconds: 150));
    _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
    await cancel.up();
    await tester.pumpAndSettle();
    expect(_page(VirtualPhoneApp.status), findsOneWidget);
    _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
    final commit = await tester.startGesture(tester.getCenter(edge));
    await tester.pump(const Duration(milliseconds: 30));
    await commit.moveBy(const Offset(25, 0));
    await tester.pump(const Duration(milliseconds: 60));
    await commit.moveBy(Offset(content.width * .60, 0));
    await tester.pump(const Duration(milliseconds: 150));
    _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
    await commit.up();
    await tester.pumpAndSettle();
    expect(_page(VirtualPhoneApp.status), findsNothing);
    expect(_icon(VirtualPhoneApp.status).hitTestable(), findsOneWidget);
    await tester.tap(_icon(VirtualPhoneApp.status));
    await tester.pump();
    _expectRectClose(tester.getRect(find.byKey(_transitionKey)), content);
    // Let NavigatorPopHandler apply its child-navigation notification.
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();
    expect(_page(VirtualPhoneApp.status), findsNothing);
    expect(_icon(VirtualPhoneApp.status).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
