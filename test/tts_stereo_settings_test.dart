import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';
import 'package:ryza_chat_mvp/src/tts_spatial_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppController> load() async {
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    return controller;
  }

  test(
    'stereo defaults are off and centered; unchanged values do not notify',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await load();
      expect(controller.ttsStereoEnabled, isFalse);
      expect(controller.ttsStereoPosition, TtsStereoPosition.center);
      var changes = 0;
      controller.addListener(() => changes++);
      controller.configureTtsStereo(enabled: false);
      expect(changes, 0);
      controller.configureTtsStereo(
        enabled: true,
        position: TtsStereoPosition.left,
      );
      expect(changes, 1);
      controller.configureTtsStereo(position: TtsStereoPosition.right);
      expect(changes, 2);
      expect(controller.ttsStereoEnabled, isTrue);
    },
  );

  test(
    'stereo toggle and fixed position survive restart and full backup',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await load();
      controller.configureTtsStereo(
        enabled: true,
        position: TtsStereoPosition.left,
      );
      final backup = jsonDecode(
        jsonEncode(controller.exportData()),
      ) as Map<String, dynamic>;
      final preferences = backup['preferences'] as Map;
      expect(preferences['ttsStereoEnabled'], isTrue);
      expect(preferences['ttsStereoPosition'], 'left');
      final restored = await load();
      expect(restored.ttsStereoEnabled, isTrue);
      expect(restored.ttsStereoPosition, TtsStereoPosition.left);
      restored.configureTtsStereo(
        enabled: false,
        position: TtsStereoPosition.right,
      );
      await restored.importData(backup);
      expect(restored.ttsStereoEnabled, isTrue);
      expect(restored.ttsStereoPosition, TtsStereoPosition.left);
      restored.configureTtsStereo(enabled: false);
      final disabled = await load();
      expect(disabled.ttsStereoEnabled, isFalse);
      expect(disabled.ttsStereoPosition, TtsStereoPosition.left);
    },
  );

  test(
    'old and unknown backup fields safely restore off and centered',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await load();
      final backup = controller.exportData();
      final preferences = backup['preferences'] as Map;
      preferences.remove('ttsStereoEnabled');
      preferences.remove('ttsStereoPosition');
      controller.configureTtsStereo(
        enabled: true,
        position: TtsStereoPosition.right,
      );
      await controller.importData(backup);
      expect(controller.ttsStereoEnabled, isFalse);
      expect(controller.ttsStereoPosition, TtsStereoPosition.center);
      preferences['ttsStereoEnabled'] = 'bad-value';
      preferences['ttsStereoPosition'] = 'random';
      await controller.importData(backup);
      expect(controller.ttsStereoEnabled, isFalse);
      expect(controller.ttsStereoPosition, TtsStereoPosition.center);
    },
  );

  test(
    'game saves and character switches do not move listening position',
    () async {
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      final directory = await Directory.systemTemp.createTemp(
        'stereo-settings-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (_) async => directory.path);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null),
      );
      SharedPreferences.setMockInitialValues({});
      final controller = await load();
      controller.configureTtsStereo(
        enabled: true,
        position: TtsStereoPosition.left,
      );
      await controller.saveToLocalSlot(0);
      final snapshot = controller.exportLocalSlot(0)['snapshot'] as Map;
      expect(snapshot.containsKey('ttsStereoEnabled'), isFalse);
      expect(snapshot.containsKey('ttsStereoPosition'), isFalse);
      final roleSettings = snapshot['roleSettings'] as Map;
      expect(roleSettings.containsKey('ttsStereoPosition'), isFalse);
      controller.configureTtsStereo(position: TtsStereoPosition.right);
      await controller.loadFromLocalSlot(0);
      expect(controller.ttsStereoPosition, TtsStereoPosition.right);
      await controller.setActiveCharacter('sophie');
      expect(controller.ttsStereoEnabled, isTrue);
      expect(controller.ttsStereoPosition, TtsStereoPosition.right);
      await controller.setActiveCharacter('ryza');
      expect(controller.ttsStereoPosition, TtsStereoPosition.right);
    },
  );

  for (final language in AppLanguage.values) {
    testWidgets('stereo controls fit narrow ${language.name} settings', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final controller = (await tester.runAsync(load))!;
      controller.interfaceLanguage = language;
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: SettingsScreen(
            controller: controller,
            onMenuPressed: () {},
            initialSection: SettingsSection.audio,
          ),
        ),
      );
      const switchKey = ValueKey('tts-stereo-enabled');
      const positionKey = ValueKey('tts-stereo-position');
      expect(find.byKey(positionKey), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(switchKey),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(switchKey));
      await tester.pumpAndSettle();
      expect(controller.ttsStereoEnabled, isTrue);
      await tester.scrollUntilVisible(
        find.byKey(positionKey),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(positionKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text(TtsStereoPosition.left.label(language)).last);
      await tester.pumpAndSettle();
      expect(controller.ttsStereoPosition, TtsStereoPosition.left);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
