import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/virtual_phone_carrier.dart';
import 'package:ryza_chat_mvp/src/world_travel_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory supportDirectory;

  setUpAll(() async {
    supportDirectory = await Directory.systemTemp.createTemp('aar_carrier_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return call.method == 'getApplicationSupportDirectory'
              ? supportDirectory.path
              : null;
        });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await supportDirectory.delete(recursive: true);
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('region mapping follows exact world catalog areas and Sophie', () async {
    final catalog = await WorldTravelCatalog.load();
    const expected = {
      'area_01': '库肯岛',
      'area_02': '克莱利亚',
      'area_03': '内米德',
      'area_04': '异界',
      'area_05': '王都',
    };
    for (final area in expected.entries) {
      final stage = catalog.destinations.firstWhere(
        (item) => item.areaId == area.key,
      );
      expect(
        VirtualPhoneCarrier.regionForLocation(
          catalog: catalog,
          characterId: CharacterRuntimeIds.ryza,
          areaId: 'wrong_area',
          stageId: stage.stageId,
        ),
        area.value,
      );
    }
    expect(
      VirtualPhoneCarrier.regionForLocation(
        catalog: catalog,
        characterId: CharacterRuntimeIds.ryza,
        areaId: 'area_03',
        stageId: 'stage_02_fake',
      ),
      '内米德',
    );
    expect(
      VirtualPhoneCarrier.regionForLocation(
        catalog: catalog,
        characterId: CharacterRuntimeIds.sophie,
        areaId: 'sophie_erde_wiege',
        stageId: 'sophie_roytale',
      ),
      '异界',
    );
    expect(
      VirtualPhoneCarrier.regionForLocation(
        catalog: catalog,
        characterId: CharacterRuntimeIds.ryza,
        areaId: 'unknown',
        stageId: 'stage_01_fake',
      ),
      '异界',
    );
  });

  test(
    'new carriers choose a valid suffix without requiring different draws',
    () {
      final random = Random(18);
      final choices = List.generate(
        30,
        (_) => VirtualPhoneCarrier.create(region: '库肯岛', random: random),
      );
      expect(
        choices.map((carrier) => carrier.suffix),
        everyElement(isIn(VirtualPhoneCarrier.suffixes)),
      );
      expect(choices.map((carrier) => carrier.suffix).toSet().length, 3);
      final original = choices.first;
      final restored = VirtualPhoneCarrier.fromJson(original.toJson());
      expect(restored.name, original.name);
      expect(
        () => VirtualPhoneCarrier.fromJson({
          'region': '库肯岛',
          'suffix': 'invalid',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'travel changes the region while the saved carrier suffix stays fixed',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final suffix = controller.virtualPhoneCarrier.suffix;
      expect(controller.virtualPhoneCarrierName, '库肯岛$suffix');
      expect(controller.virtualPhoneCarrier.region, '库肯岛');
      expect(
        VirtualPhoneCarrier.suffixes,
        contains(controller.virtualPhoneCarrier.suffix),
      );
      controller.selectLocation(areaId: 'area_03', stageId: 'stage_03_001_01');
      expect(controller.virtualPhoneCarrierName, '内米德$suffix');
      expect(controller.virtualPhoneCarrier.suffix, suffix);
      await controller.saveToLocalSlot(0);
      final restarted = await AppController.load();
      addTearDown(restarted.dispose);
      expect(restarted.virtualPhoneCarrierName, '内米德$suffix');
      expect(restarted.virtualPhoneCarrier.suffix, suffix);
      expect(
        (controller.exportLocalSlot(0)['snapshot']
            as Map)['virtualPhoneCarrier'],
        controller.virtualPhoneCarrier.toJson(),
      );
    },
  );

  test(
    'new saves reset location and store an independent fixed carrier',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final existing = controller.exportData()
        ..['selectedAreaId'] = 'area_03'
        ..['selectedStageId'] = 'stage_03_001_01'
        ..['virtualPhoneCarrier'] = {'region': '内米德', 'suffix': '电信'};
      await controller.importData(existing);
      await controller.saveToLocalSlot(0);
      await controller.createLocalSlot(1);
      expect(controller.selectedAreaId, 'area_01');
      expect(controller.virtualPhoneCarrier.region, '库肯岛');
      final freshSuffix = controller.virtualPhoneCarrier.suffix;
      controller.selectLocation(areaId: 'area_02', stageId: 'stage_02_001_01');
      await controller.saveToLocalSlot(1);
      await controller.loadFromLocalSlot(0);
      expect(controller.virtualPhoneCarrierName, '内米德电信');
      await controller.loadFromLocalSlot(1);
      expect(controller.virtualPhoneCarrierName, '克莱利亚$freshSuffix');
      expect(controller.virtualPhoneCarrier.suffix, freshSuffix);
      expect(controller.virtualPhoneCarrier.region, '库肯岛');
    },
  );

  test('backup and slot import keep carrier data without affecting the active slot', () async {
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    final original = controller.exportData()
      ..['selectedAreaId'] = 'area_02'
      ..['selectedStageId'] = 'stage_02_001_01'
      ..['virtualPhoneCarrier'] = {'region': '克莱利亚', 'suffix': '联通'};
    await controller.importData(original);
    await controller.saveToLocalSlot(0);
    final slot = controller.exportLocalSlot(
      0,
      includeConversationHistory: false,
    );
    await controller.createLocalSlot(1);
    final current = controller.virtualPhoneCarrierName;
    await controller.importLocalSlot(2, slot);
    expect(controller.virtualPhoneCarrierName, current);
    await controller.loadFromLocalSlot(2);
    expect(controller.virtualPhoneCarrierName, '克莱利亚联通');
    await controller.importData(original);
    expect(controller.virtualPhoneCarrierName, '克莱利亚联通');
    expect(
      controller.exportData()['virtualPhoneCarrier'],
      original['virtualPhoneCarrier'],
    );
  });

  test(
    'legacy slot migration is stable across load, restart, export and import',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.selectLocation(areaId: 'area_02', stageId: 'stage_02_001_01');
      await controller.saveToLocalSlot(0);
      final preferences = await SharedPreferences.getInstance();
      final legacy = controller.exportLocalSlot(0);
      (legacy['snapshot'] as Map).remove('virtualPhoneCarrier');
      await preferences.setString('local_save_slot_0', jsonEncode(legacy));
      final exportedBeforeLoad = controller.exportLocalSlot(0);
      final migrated =
          (exportedBeforeLoad['snapshot'] as Map)['virtualPhoneCarrier'];
      expect((migrated as Map)['region'], '克莱利亚');
      await controller.loadFromLocalSlot(0);
      final name = controller.virtualPhoneCarrierName;
      expect(controller.virtualPhoneCarrier.toJson(), migrated);
      expect(
        (jsonDecode(preferences.getString('local_save_slot_0')!)['snapshot']
            as Map)['virtualPhoneCarrier'],
        migrated,
      );
      await controller.importLocalSlot(1, legacy);
      await controller.loadFromLocalSlot(1);
      expect(controller.virtualPhoneCarrierName, name);
      final restarted = await AppController.load();
      addTearDown(restarted.dispose);
      expect(restarted.virtualPhoneCarrierName, name);
      await restarted.loadFromLocalSlot(0);
      expect(restarted.virtualPhoneCarrierName, name);
    },
  );

  test(
    'character sessions and Sophie saves preserve separate carriers',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final ryza = controller.exportData()
        ..['selectedAreaId'] = 'area_03'
        ..['selectedStageId'] = 'stage_03_001_01'
        ..['virtualPhoneCarrier'] = {'region': '内米德', 'suffix': '移动'};
      await controller.importData(ryza);
      await controller.saveToLocalSlot(0);
      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      expect(controller.virtualPhoneCarrier.region, '异界');
      await controller.createLocalSlot(0);
      final sophie = controller.virtualPhoneCarrierName;
      await controller.setActiveCharacter(CharacterRuntimeIds.ryza);
      expect(controller.virtualPhoneCarrierName, '内米德移动');
      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      expect(controller.virtualPhoneCarrierName, sophie);
      await controller.loadFromLocalSlot(0);
      expect(controller.virtualPhoneCarrierName, sophie);
      final restarted = await AppController.load();
      addTearDown(restarted.dispose);
      expect(restarted.activeCharacterId, CharacterRuntimeIds.sophie);
      expect(restarted.virtualPhoneCarrierName, sophie);
      await restarted.setActiveCharacter(CharacterRuntimeIds.ryza);
      expect(restarted.virtualPhoneCarrierName, '内米德移动');
    },
  );
}
