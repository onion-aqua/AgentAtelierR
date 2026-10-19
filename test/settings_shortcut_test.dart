import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => null);
  });

  tearDown(() {
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
  });

  test(
    'phone shortcut persists outside character sessions and save slots',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      await controller.setVirtualPhoneSettingsShortcut(SettingsSection.audio);
      await controller.saveToLocalSlot(0);
      await controller.setVirtualPhoneSettingsShortcut(SettingsSection.data);
      await controller.createLocalSlot(1);
      await controller.loadFromLocalSlot(0);
      expect(controller.virtualPhoneSettingsShortcut, SettingsSection.data);
      await controller.setActiveCharacter('sophie');
      expect(controller.virtualPhoneSettingsShortcut, SettingsSection.data);
      final restored = await AppController.load();
      addTearDown(restored.dispose);
      expect(restored.virtualPhoneSettingsShortcut, SettingsSection.data);
      expect(
        restored.exportData().toString(),
        isNot(contains('settings_shortcut')),
      );
      await restored.setVirtualPhoneSettingsShortcut(null);
      expect(restored.virtualPhoneSettingsShortcut, isNull);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.containsKey('virtual_phone.settings_shortcut.v1'),
        isFalse,
      );
    },
  );

  test(
    'unknown persisted destinations do not become an invalid shortcut',
    () async {
      SharedPreferences.setMockInitialValues({
        'virtual_phone.settings_shortcut.v1': 'removed-page',
      });
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      expect(controller.virtualPhoneSettingsShortcut, isNull);
    },
  );

  testWidgets('settings category omits the retired phone shortcut action', (
    tester,
  ) async {
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          controller: controller,
          onMenuPressed: () {},
          embedded: true,
          initialSection: SettingsSection.audio,
        ),
      ),
    );
    expect(find.text('点击语音'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-character-switcher')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('settings-pin-phone-shortcut')),
      findsNothing,
    );
  });

  testWidgets(
    'picker includes every first-level setting and saves before selection',
    (tester) async {
      final controller = (await tester.runAsync(() => AppController.load()))!;
      addTearDown(controller.dispose);
      SettingsSection? selection;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsShortcutPicker(
            controller: controller,
            includePcAgent: true,
            onSelected: (value) {
              expect(controller.virtualPhoneSettingsShortcut, value);
              selection = value;
            },
          ),
        ),
      );
      final pc = find.byKey(const ValueKey('settings-shortcut-pcAgent'));
      await tester.scrollUntilVisible(pc, 250);
      await tester.tap(pc);
      await tester.pumpAndSettle();
      expect(selection, SettingsSection.pcAgent);
      expect(controller.virtualPhoneSettingsShortcut, SettingsSection.pcAgent);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shortcut picker follows glass changes without losing a pending selection',
    (tester) async {
      final controller = (await tester.runAsync(() => AppController.load()))!;
      addTearDown(controller.dispose);
      final glass = ValueNotifier(false);
      addTearDown(glass.dispose);
      SettingsSection? selected;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: glass,
            child: child,
            builder: (context, enabled, child) =>
                GlassStyleScope(enabled: enabled, child: child!),
          ),
          home: SettingsShortcutPicker(
            controller: controller,
            onSelected: (value) => selected = value,
          ),
        ),
      );
      final state = tester.state(find.byType(SettingsShortcutPicker));
      expect(find.byType(BackdropFilter), findsNothing);
      final appBar = find.byType(AppBar);
      expect(tester.widget<AppBar>(appBar).toolbarHeight, 56);
      glass.value = true;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(SettingsShortcutPicker)), same(state));
      expect(find.byType(BackdropFilter), findsOneWidget);
      final audio = find.byKey(const ValueKey('settings-shortcut-audio'));
      await tester.ensureVisible(audio);
      await tester.tap(audio);
      await tester.pumpAndSettle();
      expect(selected, SettingsSection.audio);
      glass.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(controller.virtualPhoneSettingsShortcut, SettingsSection.audio);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'embedded settings uses one back button for category and phone home',
    (tester) async {
      final controller = (await tester.runAsync(() => AppController.load()))!;
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: VirtualPhoneLauncher(
            language: controller.interfaceLanguage,
            liquidGlass: false,
            fullBleedApps: const {VirtualPhoneApp.settings},
            pages: {
              VirtualPhoneApp.settings: (_) => SettingsScreen(
                controller: controller,
                onMenuPressed: () {},
                embedded: true,
              ),
            },
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.smartphone_rounded));
      await tester.pumpAndSettle();
      final settingsApp = find.byKey(
        const ValueKey('virtual-phone-app-settings'),
      );
      await tester.ensureVisible(settingsApp);
      await tester.tap(settingsApp);
      await tester.pumpAndSettle();
      final category = find.byKey(
        const ValueKey('settings-category-appearance'),
      );
      await tester.ensureVisible(category);
      await tester.tap(category);
      await tester.pumpAndSettle();
      expect(find.text('主题'), findsOneWidget);
      expect(find.byKey(const ValueKey('virtual-phone-back')), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
      expect(find.byTooltip('返回设置'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-category-appearance')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('virtual-phone-back')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('virtual-phone-home-clock')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('virtual-phone-home-clock')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('virtual-phone-back')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final systemBack in [true, false]) {
    testWidgets(
      'settings category root returns to phone home (system=$systemBack)',
      (tester) async {
        final controller = (await tester.runAsync(() => AppController.load()))!;
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: VirtualPhoneLauncher(
                  language: controller.interfaceLanguage,
                  liquidGlass: false,
                  fullBleedApps: const {VirtualPhoneApp.settings},
                  pages: {
                    VirtualPhoneApp.settings: (_) => SettingsScreen(
                      controller: controller,
                      onMenuPressed: () {},
                      embedded: true,
                      initialSection: SettingsSection.audio,
                    ),
                  },
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byIcon(Icons.smartphone_rounded));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('virtual-phone-app-settings')),
        );
        await tester.tap(
          find.byKey(const ValueKey('virtual-phone-app-settings')),
        );
        await tester.pumpAndSettle();
        expect(find.text('点击语音'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('virtual-phone-back')),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
        }
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('virtual-phone-home-clock')),
          findsOneWidget,
        );
        expect(find.text('点击语音'), findsNothing);
        expect(
          find.byKey(const ValueKey('settings-character-switcher')),
          findsNothing,
        );
      },
    );
  }
}
