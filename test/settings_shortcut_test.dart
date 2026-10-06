import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';

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

  testWidgets('shortcut opens the real category directly and can be pinned', (
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
    await tester.tap(find.byKey(const ValueKey('settings-pin-phone-shortcut')));
    await tester.pumpAndSettle();
    expect(controller.virtualPhoneSettingsShortcut, SettingsSection.audio);
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

  for (final systemBack in [true, false]) {
    testWidgets('shortcut root returns to phone home (system=$systemBack)', (
      tester,
    ) async {
      final controller = (await tester.runAsync(() => AppController.load()))!;
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsScreen(
                      controller: controller,
                      onMenuPressed: () {},
                      embedded: true,
                      initialSection: SettingsSection.audio,
                    ),
                  ),
                ),
                child: const Text('phone-home'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('phone-home'));
      await tester.pumpAndSettle();
      expect(find.text('点击语音'), findsOneWidget);
      if (systemBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      }
      await tester.pumpAndSettle();
      expect(find.text('phone-home'), findsOneWidget);
      expect(find.text('点击语音'), findsNothing);
      expect(
        find.byKey(const ValueKey('settings-character-switcher')),
        findsNothing,
      );
    });
  }
}
