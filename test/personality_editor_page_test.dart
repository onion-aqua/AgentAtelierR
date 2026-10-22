import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/personality/personality_editor_page.dart';
import 'package:ryza_chat_mvp/src/personality/personality_chart.dart';
import 'package:ryza_chat_mvp/src/personality/personality_presets.dart';
import 'package:ryza_chat_mvp/src/personality/personality_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppController controller;
  late PersonalityConfiguration initial;
  final saved = <PersonalityConfiguration>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    controller = await AppController.load();
    initial = PersonalityConfiguration.defaults(controller.activeCharacterId);
    saved.clear();
  });
  tearDown(() => controller.dispose());

  Future<void> open(
    WidgetTester tester, {
    double width = 380,
    double height = 820,
    double scale = 1,
    bool failSave = false,
    Future<void> Function(PersonalityConfiguration)? onSave,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: PersonalityEditorPage(
          controller: controller,
          initialConfiguration: initial,
          onSave: (value) async {
            if (failSave) throw StateError('test persistence failure');
            if (onSave != null) await onSave(value);
            saved.add(value);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  Future<void> expand(WidgetTester tester, String title) async {
    final target = find.text(title);
    await reveal(tester, target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  PersonalityChartPanel chart(WidgetTester tester) =>
      tester.widget<PersonalityChartPanel>(
        find.byKey(const ValueKey('personality-live-chart')),
      );

  testWidgets(
    'dragging a radar node in the scrolling editor updates its draft',
    (tester) async {
      await open(tester);
      final canvas = find.byKey(
        const ValueKey('personality-chart-interactive-canvas'),
      );
      await reveal(tester, canvas);
      final size = tester.getSize(canvas);
      final center = tester.getCenter(canvas);
      final radius = personalityChartRadius(size, PersonalityChartGroup.basic);
      final gesture = await tester.startGesture(
        center - Offset(0, radius * .5),
      );
      await gesture.moveTo(center - Offset(0, radius * .82));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(chart(tester).traits['independence'], closeTo(82, 1));
      expect(chart(tester).traits['responsibility'], 50);
      expect(saved, isEmpty);
      expect(
        controller
            .personalityConfiguration
            .activeProfile
            .traits['independence'],
        50,
      );
      await tester.tap(find.byKey(const ValueKey('personality-save')));
      await tester.pumpAndSettle();
      expect(saved.single.activeProfile.traits['independence'], closeTo(82, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('direct chart edits only persist after saving', (tester) async {
    await open(tester);
    final originalTraits = Map.of(initial.activeProfile.traits);
    expect(
      find.byKey(const ValueKey('personality-slider-independence')),
      findsNothing,
    );
    chart(tester).onChanged!({'independence': 84});
    await tester.pumpAndSettle();
    expect(chart(tester).traits['independence'], 84);
    expect(chart(tester).group, PersonalityChartGroup.basic);
    expect(chart(tester).selectedParameter, 'independence');
    expect(saved, isEmpty);
    expect(
      controller.personalityConfiguration.activeProfile.traits,
      originalTraits,
    );
    chart(tester).onGroupChanged(PersonalityChartGroup.axes);
    await tester.pumpAndSettle();
    chart(tester).onChanged!({'selfOther': -77, 'restraintExpression': 45});
    await tester.pumpAndSettle();
    chart(tester).onGroupChanged(PersonalityChartGroup.tuning);
    await tester.pumpAndSettle();
    chart(tester).onChanged!({'intensity': 61});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('personality-save')));
    await tester.pumpAndSettle();
    expect(saved.single.activeProfile.traits['independence'], 84);
    expect(saved.single.activeProfile.baseAxes['selfOther'], -77);
    expect(saved.single.activeProfile.baseAxes['restraintExpression'], 45);
    expect(saved.single.activeProfile.tuning['intensity'], 61);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inspecting chart groups does not change the saved draft', (
    tester,
  ) async {
    await open(tester);
    chart(tester).onChanged!({
      'independence': initial.activeProfile.traits['independence']!,
    });
    await tester.pumpAndSettle();
    final staleChange = chart(tester).onChanged!;
    for (final group in PersonalityChartGroup.values) {
      chart(tester).onGroupChanged(group);
      await tester.pumpAndSettle();
      expect(chart(tester).group, group);
      expect(
        PersonalityChartGroup.forParameter(chart(tester).selectedParameter!),
        group,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('personality-save-status')))
            .data,
        '已保存',
      );
    }
    staleChange({'independence': 1});
    await tester.pumpAndSettle();
    expect(chart(tester).traits, initial.activeProfile.traits);
    await reveal(
      tester,
      find.byKey(const ValueKey('personality-chart-parameter-consistency')),
    );
    await tester.tap(
      find.byKey(const ValueKey('personality-chart-parameter-consistency')),
    );
    await tester.pumpAndSettle();
    expect(chart(tester).selectedParameter, 'consistency');
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('personality-save-status')))
          .data,
      '已保存',
    );
    expect(saved, isEmpty);
    await tester.tap(find.byKey(const ValueKey('personality-save')));
    await tester.pumpAndSettle();
    expect(saved.single.activeProfile.traits, initial.activeProfile.traits);
    expect(saved.single.activeProfile.baseAxes, initial.activeProfile.baseAxes);
    expect(saved.single.activeProfile.tuning, initial.activeProfile.tuning);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'short narrow large text screen retains reachable form and save',
    (tester) async {
      await open(tester, width: 320, height: 480, scale: 2);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('personality-enabled')),
      );
      await tester.tap(find.byKey(const ValueKey('personality-enabled')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('personality-save')));
      await tester.pumpAndSettle();
      expect(saved.single.enabled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('draft coordinates and toggle only persist after Save', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('personality-enabled')));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    expect(controller.personalityConfiguration.enabled, isFalse);
    chart(tester).onGroupChanged(PersonalityChartGroup.axes);
    await tester.pumpAndSettle();
    chart(tester).onChanged!({'selfOther': 77});
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    await tester.tap(find.byKey(const ValueKey('personality-save')));
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved.single.enabled, isTrue);
    expect(saved.single.activeProfile.baseAxes['selfOther'], 77);
    expect(controller.characterState.values['mood'], 0);
    expect(find.text('已保存，下次对话生效'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'preset adds an independent profile and local preview does not save',
    (tester) async {
      await open(tester);
      final oldProfileChange = chart(tester).onChanged!;
      await expand(tester, '预设与配置');
      final create = find.byKey(const ValueKey('personality-new-preset'));
      await reveal(tester, create);
      await tester.tap(create);
      await tester.pumpAndSettle();
      oldProfileChange({'independence': 1});
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(
        chart(tester).traits,
        PersonalityPresets.create(
          'energetic_adventurer',
          initial.characterId,
        ).traits,
      );
      await expand(tester, '情境测试');
      final run = find.byKey(const ValueKey('personality-run-preview'));
      await reveal(tester, run);
      await tester.tap(run);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('personality-preview-result')),
        findsOneWidget,
      );
      expect(saved, isEmpty);
      await tester.tap(find.byKey(const ValueKey('personality-save')));
      await tester.pumpAndSettle();
      expect(saved.single.profiles, hasLength(2));
      expect(saved.single.activeProfile.presetId, 'energetic_adventurer');
      expect(saved.single.profiles.first.profileId, initial.activeProfileId);
      expect(saved.single.profiles.first.traits, initial.activeProfile.traits);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid JSON import preserves the draft and export round trips',
    (tester) async {
      await open(tester);
      await expand(tester, '预设与配置');
      final paste = find.byKey(const ValueKey('personality-paste-json'));
      await reveal(tester, paste);
      await tester.tap(paste);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('personality-json-input')),
        '{"schemaVersion":999}',
      );
      await tester.tap(find.text('校验并导入'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('personality-error')), findsOneWidget);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final copy = find.byKey(const ValueKey('personality-copy-json'));
      await reveal(tester, copy);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      final restored = PersonalityConfiguration.fromJson(
        jsonDecode(copied!),
        expectedCharacterId: initial.characterId,
      );
      expect(restored.toJson(), initial.toJson());
      expect(saved, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('narrow large text form, rule editor and preview stay usable', (
    tester,
  ) async {
    await open(tester, width: 320, scale: 2);
    expect(tester.takeException(), isNull);
    await expand(tester, '动机与内在矛盾');
    final add = find.byKey(const ValueKey('personality-add-contradictions'));
    await reveal(tester, add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text('编辑人格规则'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'rule open');
    final saveRule = find.text('保存规则草稿');
    await tester.tap(saveRule);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'before preview');
    await expand(tester, '情境测试');
    expect(tester.takeException(), isNull, reason: 'preview opened');
    final run = find.byKey(const ValueKey('personality-run-preview'));
    await reveal(tester, run);
    await tester.tap(run);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('personality-preview-result')),
      findsOneWidget,
    );
    expect(saved, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'save failures retain the enabled draft and return warns before discard',
    (tester) async {
      await open(tester, failSave: true);
      await tester.tap(find.byKey(const ValueKey('personality-enabled')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('personality-save')));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('personality-enabled')),
            )
            .value,
        isTrue,
      );
      expect(find.text('保存失败，草稿已保留'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      final dialog = find.byType(AlertDialog);
      await tester.tap(find.descendant(of: dialog, matching: find.text('取消')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(PersonalityEditorPage), findsOneWidget);
      expect(saved, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('slow save disables metadata editing until snapshot completes', (
    tester,
  ) async {
    final completion = Completer<void>();
    await open(tester, onSave: (_) => completion.future);
    await expand(tester, '预设与配置');
    final description = find.byKey(
      ValueKey('personality-description-${initial.activeProfileId}:0'),
    );
    await reveal(tester, description);
    await tester.enterText(description, '保存前的说明');
    await tester.tap(find.byKey(const ValueKey('personality-save')));
    await tester.pump();
    expect(tester.widget<TextFormField>(description).enabled, isFalse);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('personality-save')))
          .onPressed,
      isNull,
    );
    expect(saved, isEmpty);
    expect(chart(tester).onChanged, isNull);
    completion.complete();
    await tester.pumpAndSettle();
    expect(saved.single.activeProfile.metadata['description'], '保存前的说明');
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(
              ValueKey('personality-description-${initial.activeProfileId}:1'),
            ),
          )
          .enabled,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('rule edits require discard confirmation for both back actions', (
    tester,
  ) async {
    await open(tester);
    await expand(tester, '动机与内在矛盾');
    final add = find.byKey(const ValueKey('personality-add-contradictions'));
    await reveal(tester, add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('personality-rule-surface'));
    await reveal(tester, surface);
    await tester.enterText(surface, '保留的规则草稿');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings-detail-back')).last);
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的规则修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('编辑人格规则'), findsOneWidget);
    expect(find.text('保留的规则草稿'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的规则修改？'), findsOneWidget);
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.text('编辑人格规则'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('personality-save')));
    await tester.pumpAndSettle();
    expect(saved.single.activeProfile.contradictions, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
