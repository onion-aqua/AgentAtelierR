import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_camera.dart';
import 'package:ryza_chat_mvp/src/chat_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spine_flutter/spine_flutter.dart';

void main() {
  testWidgets('Sophie uses her portrait without mounting Ryza Spine', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': 'sophie',
    });
    final controller = await AppController.load();

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          controller: controller,
          onMenuPressed: () {},
          onShopPressed: () {},
          hideUi: false,
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/images/characters/sophie_portrait.png',
      ),
      findsOneWidget,
    );
    expect(find.byType(CharacterCamera), findsNothing);
    expect(find.byType(SpineWidget), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '和苏菲说点什么…',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('conversation replacement clears every composer draft', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': 'sophie',
    });
    final controller = await AppController.load();
    controller.setSplitNarrationComposer(true);
    await controller.saveToLocalSlot(0);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          controller: controller,
          onMenuPressed: () {},
          onShopPressed: () {},
          hideUi: false,
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('narration-input-0')),
      '旧人物的开场旁白',
    );
    await tester.enterText(
      find.byKey(const ValueKey('narration-input-1')),
      '旧人物的台词',
    );
    await tester.enterText(
      find.byKey(const ValueKey('narration-input-2')),
      '旧人物的结尾旁白',
    );

    await controller.loadFromLocalSlot(0);
    await tester.pump();

    for (var index = 0; index < 3; index++) {
      final field = tester.widget<TextField>(
        find.byKey(ValueKey('narration-input-$index')),
      );
      expect(field.controller!.text, isEmpty);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
