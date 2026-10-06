import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';

class _ChromePage extends StatefulWidget {
  const _ChromePage();

  @override
  State<_ChromePage> createState() => _ChromePageState();
}

class _ChromePageState extends State<_ChromePage> {
  final input = TextEditingController();

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GlassPageSurface(
    liquidGlass: false,
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(automaticallyImplyLeading: false, title: const Text('页面')),
      body: Column(
        children: [
          TextField(key: const ValueKey('chrome-input'), controller: input),
          TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => const Scaffold(body: Text('子页面')),
              ),
            ),
            child: const Text('打开子页面'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _mount(
  WidgetTester tester,
  ValueNotifier<ThemeMode> themeMode,
) async {
  tester.view.physicalSize = const Size(390, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ValueListenableBuilder<ThemeMode>(
      valueListenable: themeMode,
      builder: (context, mode, _) => MaterialApp(
        theme: atelierTheme(AppAccentTheme.jade, Brightness.light),
        darkTheme: atelierTheme(AppAccentTheme.jade, Brightness.dark),
        themeMode: mode,
        home: VirtualPhoneLauncher(
          language: AppLanguage.chinese,
          liquidGlass: false,
          pages: {VirtualPhoneApp.status: (_) => const _ChromePage()},
        ),
      ),
    ),
  );
  await tester.tap(find.byIcon(Icons.smartphone_rounded));
  await tester.pumpAndSettle();
}

void _expectStatusContrast(
  WidgetTester tester, {
  bool home = false,
  bool dark = false,
}) {
  final bar = tester.widget<Container>(
    find.byKey(const ValueKey('virtual-phone-status-bar')),
  );
  expect(bar.color!.a, home ? 0 : 1);
  if (!home) {
    expect(
      ThemeData.estimateBrightnessForColor(bar.color!),
      dark ? Brightness.dark : Brightness.light,
    );
  }
  final foreground = home || dark ? Colors.white : Colors.black;
  final time = tester.widget<Text>(
    find.byKey(const ValueKey('virtual-phone-status-time')),
  );
  expect(time.style!.color, foreground);
  for (final indicator in ['signal', 'battery']) {
    final icon = tester.widget<Image>(
      find.byKey(ValueKey('virtual-phone-$indicator')),
    );
    expect(icon.color, foreground);
    expect(icon.colorBlendMode, BlendMode.srcIn);
  }
}

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('page status bar contrasts with $mode and restores home', (
      tester,
    ) async {
      final themeMode = ValueNotifier(mode);
      addTearDown(themeMode.dispose);
      await _mount(tester, themeMode);
      _expectStatusContrast(tester, home: true);
      final bar = find.byKey(const ValueKey('virtual-phone-status-bar'));
      final bounds = tester.getRect(bar);
      await tester.tap(find.byKey(const ValueKey('virtual-phone-app-status')));
      await tester.pumpAndSettle();
      _expectStatusContrast(tester, dark: mode == ThemeMode.dark);
      expect(tester.getRect(bar), bounds);
      await tester.tap(find.text('打开子页面'));
      await tester.pumpAndSettle();
      _expectStatusContrast(tester, dark: mode == ThemeMode.dark);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      _expectStatusContrast(tester, dark: mode == ThemeMode.dark);
      await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
      await tester.pumpAndSettle();
      _expectStatusContrast(tester, home: true);
      expect(tester.getRect(bar), bounds);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('open page status updates with theme without losing input', (
    tester,
  ) async {
    final themeMode = ValueNotifier(ThemeMode.light);
    addTearDown(themeMode.dispose);
    await _mount(tester, themeMode);
    await tester.tap(find.byKey(const ValueKey('virtual-phone-app-status')));
    await tester.pumpAndSettle();
    final pageState = tester.state(find.byType(_ChromePage));
    await tester.enterText(find.byKey(const ValueKey('chrome-input')), '保留输入');
    _expectStatusContrast(tester);
    themeMode.value = ThemeMode.dark;
    await tester.pumpAndSettle();
    _expectStatusContrast(tester, dark: true);
    expect(tester.state(find.byType(_ChromePage)), same(pageState));
    themeMode.value = ThemeMode.light;
    await tester.pumpAndSettle();
    _expectStatusContrast(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('chrome-input')))
          .controller!
          .text,
      '保留输入',
    );
    expect(tester.takeException(), isNull);
  });
}
