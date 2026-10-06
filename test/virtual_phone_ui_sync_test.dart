import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';

const _carrier = '库肯岛冒险通信';
const _time = '16:42';
const _homeInfo = VirtualPhoneHomeInfo(
  carrierLabel: _carrier,
  dayLabel: '第27天',
  timeLabel: _time,
  locationLabel: '库肯岛周边地域',
  locationDetail: '小妖精之森・隐居处前',
  temperatureLabel: '23°C',
  weatherLabel: '晴朗',
  weatherIcon: Icons.wb_sunny_rounded,
);

Finder _app(VirtualPhoneApp app) =>
    find.byKey(ValueKey('virtual-phone-app-${app.name}'));
final _back = find.byKey(const ValueKey('virtual-phone-back'));
final _statusLabel = find.byKey(const ValueKey('virtual-phone-status-time'));

class _StatefulPage extends StatefulWidget {
  const _StatefulPage();

  @override
  State<_StatefulPage> createState() => _StatefulPageState();
}

class _StatefulPageState extends State<_StatefulPage> {
  final text = TextEditingController();

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GlassPageSurface(
    // Deliberately different from the initial switch to catch stale fallbacks.
    liquidGlass: true,
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Padding(
          padding: EdgeInsets.only(left: 40),
          child: Text('二级页面'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'glass=${GlassStyleScope.resolve(context)}',
            key: const ValueKey('sync-page-style'),
          ),
          TextField(key: const ValueKey('sync-page-input'), controller: text),
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              useRootNavigator: false,
              builder: (dialogContext) => Dialog(
                backgroundColor: Colors.transparent,
                child: GlassSurface(
                  key: const ValueKey('sync-dialog-surface'),
                  liquidGlass: false,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'dialog glass=${GlassStyleScope.resolve(dialogContext)}',
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('关闭确认'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            child: const Text('打开确认'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _mount(
  WidgetTester tester, {
  Size size = const Size(390, 800),
  double textScale = 1,
  ValueNotifier<bool>? glass,
  ValueNotifier<bool>? globalGlass,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: atelierTheme(AppAccentTheme.jade, Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: globalGlass == null
            ? child!
            : ValueListenableBuilder<bool>(
                valueListenable: globalGlass,
                child: child,
                builder: (context, enabled, child) =>
                    GlassStyleScope(enabled: enabled, child: child!),
              ),
      ),
      home: VirtualPhoneLauncher(
        language: AppLanguage.chinese,
        liquidGlass: false,
        updates: glass,
        liquidGlassBuilder: glass == null ? null : () => glass.value,
        homeInfo: _homeInfo,
        pages: {
          for (final app in VirtualPhoneApp.values)
            app: (_) => const _StatefulPage(),
        },
      ),
    ),
  );
  await tester.tap(find.byIcon(Icons.smartphone_rounded));
  await tester.pumpAndSettle();
}

bool _surfaceHasGradient(WidgetTester tester, Finder surface) => tester
    .widgetList<DecoratedBox>(
      find.descendant(of: surface, matching: find.byType(DecoratedBox)),
    )
    .map((widget) => widget.decoration)
    .whereType<BoxDecoration>()
    .any((decoration) => decoration.gradient != null);

Finder _appGlass(VirtualPhoneApp app) =>
    find.descendant(of: _app(app), matching: find.byType(GlassSurface));

Finder _homeTileGlass(String title) => find
    .ancestor(of: find.text(title), matching: find.byType(GlassSurface))
    .first;

BoxDecoration _surfaceFillDecoration(WidgetTester tester, Finder surface) =>
    tester
        .widgetList<DecoratedBox>(
          find.descendant(of: surface, matching: find.byType(DecoratedBox)),
        )
        .map((widget) => widget.decoration)
        .whereType<BoxDecoration>()
        .firstWhere(
          (decoration) =>
              decoration.color != null || decoration.gradient != null,
        );

void _expectGreyFallback(WidgetTester tester, Finder surface) {
  final fill = _surfaceFillDecoration(tester, surface);
  expect(fill.gradient, isNull);
  expect(fill.color, isNotNull);
  final color = fill.color!;
  // A visible, translucent grey separates text from bright wallpaper.
  expect(color.a, allOf(greaterThan(.5), lessThan(.9)));
  for (final channel in [color.r, color.g, color.b]) {
    expect(channel, inInclusiveRange(.15, .4));
  }
  expect((color.r - color.g).abs(), lessThan(.08));
  expect((color.g - color.b).abs(), lessThan(.08));
}

void main() {
  for (final returnWithSystem in [false, true]) {
    testWidgets(
      'status bar switches from carrier to time and back (system=$returnWithSystem)',
      (tester) async {
        await _mount(tester);
        final barRect = tester.getRect(
          find.byKey(const ValueKey('virtual-phone-status-bar')),
        );
        expect(tester.widget<Text>(_statusLabel).data, _carrier);
        await tester.tap(_app(VirtualPhoneApp.status));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(_statusLabel).data, _time);
        expect(
          tester.getRect(
            find.byKey(const ValueKey('virtual-phone-status-bar')),
          ),
          barRect,
        );
        if (returnWithSystem) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(_back);
        }
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(_statusLabel).data, _carrier);
        expect(find.byType(_StatefulPage), findsNothing);
        expect(_app(VirtualPhoneApp.status).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'home location, weather and dock switch between grey and live glass',
    (tester) async {
      final glass = ValueNotifier(false);
      addTearDown(glass.dispose);
      await _mount(tester, glass: glass);
      final surfaces = [
        _homeTileGlass('当前位置'),
        _homeTileGlass('场景天气'),
        find.byKey(const ValueKey('virtual-phone-dock')),
      ];
      final dockBefore = tester.getRect(surfaces.last);
      for (final surface in surfaces) {
        expect(surface, findsOneWidget);
        expect(_surfaceHasGradient(tester, surface), isFalse);
        _expectGreyFallback(tester, surface);
      }

      glass.value = true;
      await tester.pump();
      for (final surface in surfaces) {
        expect(_surfaceFillDecoration(tester, surface).gradient, isNotNull);
      }
      expect(tester.getRect(surfaces.last), dockBefore);

      glass.value = false;
      await tester.pump();
      for (final surface in surfaces) {
        expect(_surfaceHasGradient(tester, surface), isFalse);
        _expectGreyFallback(tester, surface);
      }
      expect(tester.getRect(surfaces.last), dockBefore);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'open phone icons, current page and back follow live glass updates',
    (tester) async {
      final glass = ValueNotifier(false);
      addTearDown(glass.dispose);
      await _mount(tester, glass: glass);
      expect(
        _surfaceHasGradient(tester, _appGlass(VirtualPhoneApp.status)),
        isFalse,
      );
      expect(
        _surfaceHasGradient(tester, _appGlass(VirtualPhoneApp.wallpaper)),
        isFalse,
      );
      glass.value = true;
      await tester.pumpAndSettle();
      expect(
        _surfaceHasGradient(tester, _appGlass(VirtualPhoneApp.status)),
        isTrue,
      );
      expect(
        _surfaceHasGradient(tester, _appGlass(VirtualPhoneApp.wallpaper)),
        isTrue,
      );
      await tester.tap(_app(VirtualPhoneApp.status));
      await tester.pumpAndSettle();
      final pageState = tester.state(find.byType(_StatefulPage));
      expect(find.text('glass=true'), findsOneWidget);
      expect(_surfaceHasGradient(tester, _back), isTrue);
      await tester.enterText(
        find.byKey(const ValueKey('sync-page-input')),
        '保留页面内容',
      );
      glass.value = false;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_StatefulPage)), same(pageState));
      expect(find.text('glass=false'), findsOneWidget);
      expect(_surfaceHasGradient(tester, _back), isFalse);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('sync-page-input')))
            .controller!
            .text,
        '保留页面内容',
      );
      glass.value = true;
      await tester.pumpAndSettle();
      expect(find.text('glass=true'), findsOneWidget);
      await tester.tap(_back);
      await tester.pumpAndSettle();
      expect(
        _surfaceHasGradient(tester, _appGlass(VirtualPhoneApp.status)),
        isTrue,
      );
      expect(tester.widget<Text>(_statusLabel).data, _carrier);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('48dp back target and 32dp icon center on the 56dp header', (
    tester,
  ) async {
    await _mount(tester);
    await tester.tap(_app(VirtualPhoneApp.status));
    await tester.pumpAndSettle();
    final pageRect = tester.getRect(find.byType(_StatefulPage));
    final backRect = tester.getRect(_back);
    expect(backRect.size, const Size(48, 48));
    expect(backRect.left - pageRect.left, 6);
    expect(backRect.top - pageRect.top, 4);
    expect(backRect.center.dy - pageRect.top, 28);
    final icon = tester.widget<Icon>(
      find.descendant(of: _back, matching: find.byType(Icon)),
    );
    expect(icon.size, 32);
    final title = tester.getRect(find.text('二级页面'));
    expect(title.center.dy, closeTo(backRect.center.dy, 1));
    expect(title.left, greaterThan(backRect.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('global glass scope updates an already open phone dialog route', (
    tester,
  ) async {
    final globalGlass = ValueNotifier(false);
    addTearDown(globalGlass.dispose);
    await _mount(tester, globalGlass: globalGlass);
    await tester.tap(_app(VirtualPhoneApp.status));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开确认'));
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('sync-dialog-surface'));
    expect(find.text('dialog glass=false'), findsOneWidget);
    expect(_surfaceHasGradient(tester, surface), isFalse);
    globalGlass.value = true;
    await tester.pumpAndSettle();
    expect(find.text('dialog glass=true'), findsOneWidget);
    expect(_surfaceHasGradient(tester, surface), isTrue);
    globalGlass.value = false;
    await tester.pumpAndSettle();
    expect(find.text('dialog glass=false'), findsOneWidget);
    expect(_surfaceHasGradient(tester, surface), isFalse);
    await tester.tap(find.text('关闭确认'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sync-dialog-surface')), findsNothing);
    expect(find.byType(_StatefulPage), findsOneWidget);
    expect(tester.widget<Text>(_statusLabel).data, _time);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 700), const Size(320, 480)]) {
    testWidgets('phone remains usable with 1.5 text scale at $size', (
      tester,
    ) async {
      await _mount(tester, size: size, textScale: 1.5);
      expect(tester.takeException(), isNull);
      final phone = tester.getRect(
        find.byKey(const ValueKey('virtual-phone-screen')),
      );
      final dock = tester.getRect(
        find.byKey(const ValueKey('virtual-phone-dock')),
      );
      expect(dock.left, greaterThanOrEqualTo(phone.left));
      expect(dock.right, lessThanOrEqualTo(phone.right));
      expect(dock.bottom, lessThanOrEqualTo(phone.bottom));
      for (final app in [
        VirtualPhoneApp.phone,
        VirtualPhoneApp.messages,
        VirtualPhoneApp.wallpaper,
        VirtualPhoneApp.shortcut,
      ]) {
        expect(_app(app).hitTestable(), findsOneWidget);
      }
      await tester.scrollUntilVisible(
        _app(VirtualPhoneApp.settings),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(_app(VirtualPhoneApp.settings).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(_app(VirtualPhoneApp.settings));
      await tester.pumpAndSettle();
      expect(find.text('二级页面'), findsOneWidget);
      expect(_back.hitTestable(), findsOneWidget);
      await tester.tap(_back);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(_statusLabel).data, _carrier);
      expect(tester.takeException(), isNull);
    });
  }
}
