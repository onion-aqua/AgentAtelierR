import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/settings_slots.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final legacy in [false, true]) {
    test(
      'only saved active slots restore (legacy=$legacy), including imported saves',
      () async {
        SharedPreferences.setMockInitialValues({});
        final c = await AppController.load();
        addTearDown(c.dispose);
        for (final kind in SettingsSlotKind.values) {
          final bank = c.settingsSlots(kind)..active = 1;
          for (var i = 0; i < 5; i++) {
            bank.entries[i] = kind == SettingsSlotKind.user
                ? {
                    'address': 'old $i',
                    'portrait': 'portrait $i',
                    'preferCustom': 'true',
                  }
                : {'text': 'old $i'};
          }
          c.saveSettingsSlots(kind, bank);
        }
        final legacyBanks = c.exportData()['settingsSlots'];
        await c.saveToLocalSlot(0);
        final save = jsonDecode(
          jsonEncode(c.exportLocalSlot(0)),
        ) as Map<String, dynamic>;
        final role = save['snapshot']['roleSettings'] as Map;
        expect(role.containsKey('settingsSlots'), isFalse);
        expect(role['activeSlots'], {'user': 1, 'character': 1, 'world': 1});
        if (legacy) {
          role.remove('activeSlots');
          role['settingsSlots'] = legacyBanks;
        }
        for (final kind in SettingsSlotKind.values) {
          final bank = c.settingsSlots(kind)..active = 4;
          for (var i = 0; i < 5; i++) {
            bank.entries[i] = kind == SettingsSlotKind.user
                ? {'address': 'local $i', 'portrait': 'local portrait $i'}
                : {'text': 'local $i'};
          }
          c.saveSettingsSlots(kind, bank);
        }
        await c.importLocalSlot(2, save);
        expect(
          c.userAddress,
          'local 4',
        ); // Importing a save does not activate it.
        await c.loadFromLocalSlot(2);
        for (final kind in SettingsSlotKind.values) {
          final bank = c.settingsSlots(kind);
          final field = kind == SettingsSlotKind.user ? 'address' : 'text';
          expect(bank.active, 1);
          for (var i = 0; i < 5; i++) {
            expect(bank.entries[i]?[field], i == 1 ? 'old 1' : 'local $i');
          }
        }
        expect(c.preferCustomUserProfile, isTrue);
        // A second load must not overwrite edits made to other slots since import.
        final world = c.settingsSlots(SettingsSlotKind.world);
        world.entries[3] = {'text': 'keep newer edit'};
        c.saveSettingsSlots(SettingsSlotKind.world, world);
        await c.loadFromLocalSlot(2);
        expect(
          c.settingsSlots(SettingsSlotKind.world).entries[3]?['text'],
          'keep newer edit',
        );
      },
    );
  }
}
