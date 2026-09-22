import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';
import 'package:ryza_chat_mvp/src/settings_detail_page.dart';
import 'package:ryza_chat_mvp/src/settings_slots.dart';

void main() {
  for (final kind in SettingsSlotKind.values) {
    testWidgets(
      '${kind.name}: preset editor, five drafts and bidirectional copy do not activate until save',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final c = (await tester.runAsync(() => AppController.load()))!;
        addTearDown(c.dispose);
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(controller: c, onMenuPressed: () {}),
          ),
        );
        await tester.tap(
          find.byKey(
            ValueKey(
              'settings-category-${kind == SettingsSlotKind.user ? 'profile' : 'roleplay'}',
            ),
          ),
        );
        await tester.pumpAndSettle();
        final title = switch (kind) {
          SettingsSlotKind.user => '称呼与自画像',
          SettingsSlotKind.character => '编辑人物设定',
          SettingsSlotKind.world => '编辑世界书',
        };
        await tester.ensureVisible(find.text(title));
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        Finder field() => find
            .descendant(
              of: find.byType(SettingsDetailPage).last,
              matching: find.byType(TextField),
            )
            .first;
        await tester.enterText(field(), 'live draft');
        await tester.tap(
          find.byKey(const ValueKey('open-setting-presets')).last,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('导入 / 导出').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('从存档控制槽位导入'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(SimpleDialogOption, '槽位 1'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('覆盖'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field()).controller!.text,
          'live draft',
        );
        await tester.enterText(field(), 'preset edited');
        await tester.tap(find.byTooltip('导入 / 导出').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('导出到存档控制槽位'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(SimpleDialogOption, '槽位 1'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('覆盖'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-slot-4')).last);
        await tester.pumpAndSettle();
        await tester.enterText(field(), 'fifth preset');
        await tester.ensureVisible(find.text('保存预设'));
        await tester.tap(find.text('保存预设'));
        await tester.pumpAndSettle();
        final key = kind == SettingsSlotKind.user ? 'address' : 'text';
        expect(c.presetSlots(kind).entries[0]?[key], 'preset edited');
        expect(c.presetSlots(kind).entries[4]?[key], 'fifth preset');
        expect(c.settingsSlots(kind).entries[0]?[key], isNot('preset edited'));
        expect(
          tester.widget<TextField>(field()).controller!.text,
          'preset edited',
        );
        await tester.ensureVisible(find.text('保存并使用'));
        await tester.tap(find.text('保存并使用'));
        await tester.pumpAndSettle();
        expect(c.settingsSlots(kind).entries[0]?[key], 'preset edited');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
