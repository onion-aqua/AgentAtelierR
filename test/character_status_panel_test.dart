import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/character_state.dart';
import 'package:ryza_chat_mvp/src/body_sensitivity.dart';
import 'package:ryza_chat_mvp/src/character_status_silhouette.dart';
import 'package:spine_flutter/spine_flutter.dart'
    show SkeletonDrawable, initSpineFlutter;
import 'package:ryza_chat_mvp/src/character_status_panel.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/story_clock.dart';

const _metricNames = [
  'curiosity',
  'mood',
  'closeness',
  'satiety',
  'energy',
  'posture',
];
const _captureKey = ValueKey('status-test-capture');
final _renderEnabled = Platform.environment['AAR_STATUS_RENDER'] == '1';
CharacterStatusSilhouette? _renderSilhouette;
final _sensitivityDetail = find.byKey(
  const ValueKey('body-sensitivity-detail'),
);
Finder _sensitivityMarker(BodySensitivityPart part) =>
    find.byKey(ValueKey('body-sensitivity-${part.name}'));
Finder _sensitivityValue(BodySensitivityPart part) =>
    find.byKey(ValueKey('body-sensitivity-value-${part.name}'));
final _detail = find.byKey(const ValueKey('body-status-detail'));
Finder _marker(String name) => find.byKey(ValueKey('body-status-$name'));
Finder _value(String name) => find.byKey(ValueKey('body-status-value-$name'));

CharacterState _state({int mood = -500, int energy = 22}) => CharacterState(
  values: {'mood': mood, 'energy': energy, 'closeness': 42, 'curiosity': 77},
  bands: const {'mood': 0, 'energy': 0, 'closeness': 1, 'curiosity': 2},
  delta: const {'mood': -500, 'energy': -3, 'curiosity': 5},
  emotion: 'sad',
  reason: '确认丢失了誓约之戒，等待下一次对话和新的变化。',
  updatedAt: DateTime(2026, 10, 27, 12, 34),
);

ThemeData _theme(Brightness brightness) {
  final base = atelierTheme(AppAccentTheme.jade, brightness);
  return !_renderEnabled
      ? base
      : base.copyWith(
          textTheme: base.textTheme.apply(fontFamily: 'StatusAudit'),
          primaryTextTheme: base.primaryTextTheme.apply(
            fontFamily: 'StatusAudit',
          ),
        );
}

Future<void> _mount(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  AppLanguage language = AppLanguage.chinese,
  Brightness brightness = Brightness.light,
  bool glass = false,
  bool clockEnabled = true,
  CharacterState? state,
  String? characterName,
  BodySensitivityState? sensitivity,
  bool manualEditingEnabled = false,
  void Function(BodySensitivityPart, int)? onSensitivityChanged,
  ValueChanged<BodySensitivityPart>? onSensitivityUnlock,
  bool touchGrowthEnabled = true,
  ValueChanged<bool>? onTouchGrowthChanged,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: GlassStyleScope(enabled: glass, child: child!),
      ),
      home: RepaintBoundary(
        key: _captureKey,
        child: Scaffold(
          appBar: AppBar(
            title: Text(language.text('角色状态', 'Character status', 'キャラクター状態')),
          ),
          body: GlassPageSurface(
            liquidGlass: glass,
            child: CharacterStatusPanel(
              language: language,
              characterName:
                  characterName ?? language.text('莱莎', 'Ryza', 'ライザ'),
              state: state ?? _state(),
              silhouette: _renderSilhouette == null
                  ? null
                  : Future.value(_renderSilhouette!),
              sensitivity: sensitivity,
              manualEditingEnabled: manualEditingEnabled,
              onSensitivityChanged: onSensitivityChanged,
              onSensitivityUnlock: onSensitivityUnlock,
              touchGrowthEnabled: touchGrowthEnabled,
              onTouchGrowthChanged: onTouchGrowthChanged,
              clock: StoryClock(
                totalMinutes: 3 * 1440 + 12 * 60 + 34,
                satiety: 18,
              ),
              clockEnabled: clockEnabled,
              relationshipPoints: 4999,
              postureLabel: language.text(
                '放松盘腿',
                'Relaxed cross-legged',
                'ゆったりしたあぐら',
              ),
              outfitLabel: language.text(
                '万圣节女巫',
                'Halloween witch',
                'ハロウィンの魔女',
              ),
              location: language.text(
                '库肯岛周边地域\n小妖精之森・隐居处前',
                'Kurken Island\nPixie Forest · Hideaway entrance',
                'クーケン島周辺\n小妖精の森・隠れ家の前',
              ),
              sceneTimeLabel: language.text('午后', 'Afternoon', '午後'),
              memoryEnabled: true,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (_renderEnabled) {
      final font = FontLoader('StatusAudit')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
            ),
          ),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                'D:/flutter/flutter_windows_3.47.2-stable/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes(),
            ),
          ),
        );
      await icons.load();
    }
  });
  tearDown(() {
    // Each test owns the synthetic surface; no application/device state changes.
    final binding = TestWidgetsFlutterBinding.instance;
    binding.platformDispatcher.views.first.resetPhysicalSize();
    binding.platformDispatcher.views.first.resetDevicePixelRatio();
  });

  testWidgets(
    'body markers select the corresponding current stat explanation',
    (tester) async {
      await _mount(tester);
      const titles = {
        'curiosity': '头部 · 好奇心',
        'mood': '胸口 · 心情',
        'closeness': '心间 · 亲近感',
        'satiety': '腹部 · 饱食度',
        'energy': '四肢 · 精力',
        'posture': '下肢 · 当前姿态',
      };
      final explanations = <String>{};
      for (final entry in titles.entries) {
        await tester.ensureVisible(_marker(entry.key));
        await tester.tap(_marker(entry.key));
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: _detail, matching: find.text(entry.value)),
          findsOneWidget,
        );
        final semantics = tester.widget<Semantics>(
          find
              .ancestor(
                of: _marker(entry.key),
                matching: find.byType(Semantics),
              )
              .first,
        );
        expect(semantics.properties.selected, isTrue);
        explanations.add(
          tester
              .widgetList<Text>(
                find.descendant(of: _detail, matching: find.byType(Text)),
              )
              .last
              .data!,
        );
      }
      expect(
        explanations.length,
        6,
        reason: 'Each marker exposes its own explanation',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'exceptional negative mood stays exact while its meter stays bounded',
    (tester) async {
      await _mount(tester);
      expect(tester.widget<Text>(_value('mood')).data, '-500');
      expect(
        find.descendant(of: _detail, matching: find.text('-500 · 低落')),
        findsOneWidget,
      );
      final meter = tester.widget<LinearProgressIndicator>(
        find.descendant(
          of: _detail,
          matching: find.byType(LinearProgressIndicator),
        ),
      );
      expect(meter.value, 0);
      expect(find.textContaining('关系点数  4999'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disabled story clock hides the stored satiety and its meter', (
    tester,
  ) async {
    await _mount(tester, clockEnabled: false);
    expect(tester.widget<Text>(_value('satiety')).data, '—');
    expect(find.text('剧情时钟已关闭'), findsOneWidget);
    await tester.tap(_marker('satiety'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _detail, matching: find.text('— · 时钟已关闭')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _detail,
        matching: find.byType(LinearProgressIndicator),
      ),
      findsNothing,
    );
    expect(find.text('18'), findsNothing);
  });

  testWidgets(
    'selected metric follows new character state and interface language',
    (tester) async {
      await _mount(tester);
      await tester.ensureVisible(_marker('energy'));
      await tester.tap(_marker('energy'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(_value('energy')).data, '22');
      await _mount(
        tester,
        language: AppLanguage.english,
        state: _state(mood: 10, energy: 88),
        characterName: 'Sophie',
      );
      expect(find.text('Sophie'), findsOneWidget);
      expect(find.text('莱莎'), findsNothing);
      expect(tester.widget<Text>(_value('energy')).data, '88');
      expect(
        find.descendant(of: _detail, matching: find.text('LIMBS · Energy')),
        findsOneWidget,
      );
      expect(find.text('心情'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sensitivity tab exposes eight saved values and bounded adjustment',
    (tester) async {
      final values = BodySensitivityState(
        values: {
          BodySensitivityPart.head: 0,
          BodySensitivityPart.chest: 17,
          BodySensitivityPart.abdomen: 29,
          BodySensitivityPart.leftArm: 41,
          BodySensitivityPart.rightArm: 53,
          BodySensitivityPart.hands: 67,
          BodySensitivityPart.legs: 100,
          BodySensitivityPart.waist: 89,
        },
      );
      await _mount(
        tester,
        sensitivity: values,
        manualEditingEnabled: true,
        onSensitivityChanged: (_, _) {},
      );
      await tester.tap(find.byKey(const ValueKey('body-map-sensitivity-tab')));
      await tester.pumpAndSettle();
      for (final part in BodySensitivityState.initiallyUnlocked) {
        expect(
          tester.widget<Text>(_sensitivityValue(part)).data,
          '${values.valueFor(part)}',
        );
        await tester.ensureVisible(_sensitivityMarker(part));
        await tester.tap(_sensitivityMarker(part));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: _sensitivityDetail,
            matching: find.text(
              '${part.label(AppLanguage.chinese)} · 敏感度  ${values.valueFor(part)} / 100',
            ),
          ),
          findsOneWidget,
        );
        final slider = tester.widget<Slider>(
          find.byKey(const ValueKey('body-sensitivity-slider')),
        );
        expect(slider.value, values.valueFor(part));
        expect(slider.min, 0);
        expect(slider.max, 100);
        final semantics = tester.widget<Semantics>(
          find
              .ancestor(
                of: _sensitivityMarker(part),
                matching: find.byType(Semantics),
              )
              .first,
        );
        expect(semantics.properties.selected, isTrue);
      }
      expect(find.byKey(const ValueKey('body-status-detail')), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('body-map-overview-tab')),
      );
      await tester.tap(find.byKey(const ValueKey('body-map-overview-tab')));
      await tester.pumpAndSettle();
      expect(_detail, findsOneWidget);
      expect(_sensitivityDetail, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sensitivity drag previews locally and commits once on release', (
    tester,
  ) async {
    final changes = <(BodySensitivityPart, int)>[];
    await _mount(
      tester,
      manualEditingEnabled: true,
      onSensitivityChanged: (part, value) => changes.add((part, value)),
    );
    await tester.tap(find.byKey(const ValueKey('body-map-sensitivity-tab')));
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('body-sensitivity-slider'));
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    final rect = tester.getRect(slider);
    final gesture = await tester.startGesture(rect.center);
    await tester.pump();
    await gesture.moveTo(
      Offset(rect.center.dx + rect.width * .15, rect.center.dy),
    );
    await tester.pump();
    await gesture.moveTo(
      Offset(rect.center.dx + rect.width * .25, rect.center.dy),
    );
    await tester.pump();
    expect(
      changes,
      isEmpty,
      reason: 'Persistence is deferred until the drag is committed',
    );
    expect(tester.widget<Slider>(slider).value, greaterThan(50));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(changes, hasLength(1));
    expect(changes.single.$1, BodySensitivityPart.head);
    expect(changes.single.$2, inInclusiveRange(51, 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'touch growth switch reports user choice without changing stats',
    (tester) async {
      final changes = <bool>[];
      await _mount(tester, onTouchGrowthChanged: changes.add);
      await tester.tap(find.byKey(const ValueKey('body-map-sensitivity-tab')));
      await tester.pumpAndSettle();
      final toggle = find.byKey(
        const ValueKey('body-sensitivity-touch-growth'),
      );
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(changes, [false]);
      expect(
        tester.widget<Text>(_sensitivityValue(BodySensitivityPart.head)).data,
        '50',
      );
      await _mount(
        tester,
        touchGrowthEnabled: false,
        onTouchGrowthChanged: changes.add,
      );
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('sensitivity selection follows new saved values and language', (
    tester,
  ) async {
    await _mount(
      tester,
      sensitivity: BodySensitivityState(values: {BodySensitivityPart.legs: 8}),
    );
    await tester.tap(find.byKey(const ValueKey('body-map-sensitivity-tab')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(_sensitivityMarker(BodySensitivityPart.legs));
    await tester.tap(_sensitivityMarker(BodySensitivityPart.legs));
    await tester.pumpAndSettle();
    await _mount(
      tester,
      language: AppLanguage.japanese,
      characterName: 'ソフィー',
      sensitivity: BodySensitivityState(values: {BodySensitivityPart.legs: 92}),
    );
    expect(
      tester.widget<Text>(_sensitivityValue(BodySensitivityPart.legs)).data,
      '92',
    );
    expect(
      find.descendant(
        of: _sensitivityDetail,
        matching: find.text('脚 · 敏感度  92 / 100'),
      ),
      findsOneWidget,
    );
    expect(find.text('ソフィー'), findsOneWidget);
    expect(
      find.byType(Slider),
      findsNothing,
      reason: 'Without an edit callback the values remain read-only',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'locked private-area marker never reveals hidden value or unlocks on selection',
    (tester) async {
      final unlocks = <BodySensitivityPart>[];
      final edits = <(BodySensitivityPart, int)>[];
      final data = BodySensitivityState(
        values: {BodySensitivityPart.intimate: 97},
      );
      await _mount(
        tester,
        sensitivity: data,
        manualEditingEnabled: true,
        onSensitivityUnlock: unlocks.add,
        onSensitivityChanged: (part, value) => edits.add((part, value)),
      );
      await tester.tap(find.byKey(const ValueKey('body-map-sensitivity-tab')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(_sensitivityValue(BodySensitivityPart.intimate))
            .data,
        '未解锁',
      );
      final markerSemantics = tester.widget<Semantics>(
        find
            .ancestor(
              of: _sensitivityMarker(BodySensitivityPart.intimate),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(markerSemantics.properties.label, contains('未解锁'));
      expect(markerSemantics.properties.label, isNot(contains('97')));
      await tester.ensureVisible(
        _sensitivityMarker(BodySensitivityPart.intimate),
      );
      await tester.tap(_sensitivityMarker(BodySensitivityPart.intimate));
      await tester.pumpAndSettle();
      expect(unlocks, isEmpty);
      expect(edits, isEmpty);
      expect(data.isUnlocked(BodySensitivityPart.intimate), isFalse);
      expect(
        find.byKey(const ValueKey('body-sensitivity-slider')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: _sensitivityDetail,
          matching: find.textContaining('97'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: _sensitivityDetail,
          matching: find.text('私处 · 敏感度  未解锁'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('body-sensitivity-unlock')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unlock button targets selected part and waits for save-owned state',
    (tester) async {
      final unlocks = <BodySensitivityPart>[];
      final data = BodySensitivityState();
      await _mount(
        tester,
        sensitivity: data,
        manualEditingEnabled: true,
        onSensitivityUnlock: unlocks.add,
        onSensitivityChanged: (_, _) {},
      );
      await tester.tap(find.byKey(const ValueKey('body-map-sensitivity-tab')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        _sensitivityMarker(BodySensitivityPart.intimate),
      );
      await tester.tap(_sensitivityMarker(BodySensitivityPart.intimate));
      await tester.pumpAndSettle();
      final unlockButton = find.byKey(
        const ValueKey('body-sensitivity-unlock'),
      );
      await tester.ensureVisible(unlockButton);
      await tester.tap(unlockButton);
      await tester.pumpAndSettle();
      expect(unlocks, [BodySensitivityPart.intimate]);
      expect(
        tester
            .widget<Text>(_sensitivityValue(BodySensitivityPart.intimate))
            .data,
        '未解锁',
      );
      expect(
        find.byKey(const ValueKey('body-sensitivity-slider')),
        findsNothing,
        reason: 'Only the save owner can acknowledge a persisted unlock',
      );
      await _mount(
        tester,
        sensitivity: data.unlock(BodySensitivityPart.intimate),
        manualEditingEnabled: true,
        onSensitivityUnlock: unlocks.add,
        onSensitivityChanged: (_, _) {},
      );
      expect(
        tester
            .widget<Text>(_sensitivityValue(BodySensitivityPart.intimate))
            .data,
        '50',
      );
      expect(
        find.descendant(
          of: _sensitivityDetail,
          matching: find.text('私处 · 敏感度  50 / 100'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Slider>(
              find.byKey(const ValueKey('body-sensitivity-slider')),
            )
            .value,
        50,
      );
      expect(unlockButton, findsNothing);
      expect(unlocks, [BodySensitivityPart.intimate]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editing another part and loading a locked save cannot unlock private area',
    (tester) async {
      final edits = <(BodySensitivityPart, int)>[];
      final data = BodySensitivityState();
      await _mount(
        tester,
        sensitivity: data,
        manualEditingEnabled: true,
        onSensitivityChanged: (part, value) => edits.add((part, value)),
        onSensitivityUnlock: (_) {},
      );
      await tester.tap(find.byKey(const ValueKey('body-map-sensitivity-tab')));
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('body-sensitivity-slider'));
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getRect(slider).centerRight - const Offset(25, 0),
      );
      await tester.pumpAndSettle();
      expect(edits, hasLength(1));
      expect(edits.single.$1, BodySensitivityPart.head);
      final edited = data.withValue(BodySensitivityPart.head, edits.single.$2);
      await _mount(
        tester,
        sensitivity: edited,
        onSensitivityChanged: (_, _) {},
        onSensitivityUnlock: (_) {},
      );
      expect(
        tester
            .widget<Text>(_sensitivityValue(BodySensitivityPart.intimate))
            .data,
        '未解锁',
      );
      await tester.ensureVisible(
        _sensitivityMarker(BodySensitivityPart.intimate),
      );
      await tester.tap(_sensitivityMarker(BodySensitivityPart.intimate));
      await tester.pumpAndSettle();
      expect(slider, findsNothing);
      await _mount(
        tester,
        language: AppLanguage.english,
        characterName: 'Another save',
        sensitivity: BodySensitivityState(
          values: {BodySensitivityPart.intimate: 83},
        ),
        onSensitivityChanged: (_, _) {},
        onSensitivityUnlock: (_) {},
      );
      expect(
        tester
            .widget<Text>(_sensitivityValue(BodySensitivityPart.intimate))
            .data,
        'Locked',
      );
      expect(
        find.descendant(
          of: _sensitivityDetail,
          matching: find.textContaining('83'),
        ),
        findsNothing,
      );
      expect(slider, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all unlocked sensitivity markers fit smallest enlarged layout', (
    tester,
  ) async {
    await _mount(
      tester,
      size: const Size(320, 720),
      scale: 2,
      language: AppLanguage.japanese,
      sensitivity: BodySensitivityState(unlocked: BodySensitivityPart.values),
      onSensitivityChanged: (_, _) {},
      onSensitivityUnlock: (_) {},
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('body-map-sensitivity-tab')),
    );
    await tester.tap(find.byKey(const ValueKey('body-map-sensitivity-tab')));
    await tester.pumpAndSettle();
    final map = tester.getRect(
      find.byKey(const ValueKey('character-status-body-map')),
    );
    for (final part in BodySensitivityPart.values) {
      final rect = tester.getRect(_sensitivityMarker(part));
      expect(rect.left, greaterThanOrEqualTo(map.left));
      expect(rect.right, lessThanOrEqualTo(map.right + .1));
      expect(rect.bottom, lessThanOrEqualTo(map.bottom + .1));
    }
    expect(
      tester.widget<Text>(_sensitivityValue(BodySensitivityPart.intimate)).data,
      '50',
    );
    expect(tester.takeException(), isNull);
  });

  final layouts = <(Size, double, AppLanguage)>[
    (const Size(320, 720), 1, AppLanguage.chinese),
    (const Size(390, 844), 2, AppLanguage.chinese),
    (const Size(844, 390), 1.4, AppLanguage.english),
    (const Size(1000, 800), 2, AppLanguage.japanese),
  ];
  for (final (size, scale, language) in layouts) {
    for (final brightness in Brightness.values) {
      for (final glass in [false, true]) {
        testWidgets(
          'status fits $size scale=$scale ${language.name} ${brightness.name} glass=$glass',
          (tester) async {
            await _mount(
              tester,
              size: size,
              scale: scale,
              language: language,
              brightness: brightness,
              glass: glass,
              onSensitivityChanged: (_, _) {},
              onTouchGrowthChanged: (_) {},
            );
            expect(tester.takeException(), isNull);
            final mapRect = tester.getRect(
              find.byKey(const ValueKey('character-status-body-map')),
            );
            for (final name in _metricNames) {
              final rect = tester.getRect(_marker(name));
              expect(rect.left, greaterThanOrEqualTo(mapRect.left));
              expect(rect.right, lessThanOrEqualTo(mapRect.right + .1));
              expect(
                rect.bottom,
                lessThanOrEqualTo(mapRect.bottom + .1),
                reason: '$name must stay inside the body map',
              );
            }
            for (var i = 0; i < 4; i++) {
              expect(
                tester.getRect(_marker(_metricNames[i])).bottom,
                lessThanOrEqualTo(
                  tester.getRect(_marker(_metricNames[i + 2])).top,
                ),
                reason:
                    'Successive callouts in the same column must not overlap',
              );
            }
            await tester.ensureVisible(
              find.byKey(const ValueKey('body-map-sensitivity-tab')),
            );
            await tester.tap(
              find.byKey(const ValueKey('body-map-sensitivity-tab')),
            );
            await tester.pumpAndSettle();
            final sensitivityRect = tester.getRect(
              find.byKey(const ValueKey('character-status-body-map')),
            );
            const order = [
              BodySensitivityPart.head,
              BodySensitivityPart.chest,
              BodySensitivityPart.rightArm,
              BodySensitivityPart.leftArm,
              BodySensitivityPart.abdomen,
              BodySensitivityPart.waist,
              BodySensitivityPart.hands,
              BodySensitivityPart.legs,
              BodySensitivityPart.intimate,
            ];
            for (final part in order) {
              final rect = tester.getRect(_sensitivityMarker(part));
              expect(rect.left, greaterThanOrEqualTo(sensitivityRect.left));
              expect(rect.right, lessThanOrEqualTo(sensitivityRect.right + .1));
              expect(rect.top, greaterThanOrEqualTo(sensitivityRect.top));
              expect(
                rect.bottom,
                lessThanOrEqualTo(sensitivityRect.bottom + .1),
                reason: '${part.name} must stay within the silhouette map',
              );
            }
            for (var i = 0; i < order.length - 2; i++) {
              expect(
                tester.getRect(_sensitivityMarker(order[i])).bottom,
                lessThanOrEqualTo(
                  tester.getRect(_sensitivityMarker(order[i + 2])).top,
                ),
                reason:
                    'Nine sensitivity labels cannot overlap in the same column',
              );
            }
            await tester.drag(
              find.byKey(const ValueKey('character-status-scroll')),
              const Offset(0, -1800),
            );
            await tester.pumpAndSettle();
            final memory = find.text(
              language.text(
                '长期记忆 · 已启用',
                'Long-term memory · Enabled',
                '長期記憶 · 有効',
              ),
            );
            await tester.ensureVisible(memory);
            expect(memory.hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('render optional status preview evidence', (tester) async {
    _renderSilhouette = await tester.runAsync(() async {
      await initSpineFlutter();
      const root =
          'assets/character/ryza/crf_skn_002_0001_99/crf_skn_002_0001_99';
      final drawable = await SkeletonDrawable.fromFile(
        '$root.atlas',
        '$root.skel',
      );
      try {
        return await CharacterStatusSilhouettes.renderFromDrawable(drawable);
      } finally {
        drawable.dispose();
      }
    });
    expect(_renderSilhouette, isNotNull);
    try {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        final example = BodySensitivityState(
          values: {
            BodySensitivityPart.head: 45,
            BodySensitivityPart.chest: 72,
            BodySensitivityPart.abdomen: 31,
            BodySensitivityPart.leftArm: 55,
            BodySensitivityPart.rightArm: 52,
            BodySensitivityPart.hands: 64,
            BodySensitivityPart.legs: 38,
            BodySensitivityPart.waist: 60,
          },
        );
        final exampleState = CharacterState(
          values: const {
            'mood': 28,
            'energy': 72,
            'closeness': 42,
            'curiosity': 77,
          },
          bands: const {'mood': 2, 'energy': 2, 'closeness': 1, 'curiosity': 2},
          delta: const {'mood': 3, 'energy': -1, 'curiosity': 5},
          emotion: 'happy',
          reason: '一起探索了新的炼金素材，今天的心情很不错。',
          updatedAt: DateTime(2026, 10, 27, 12, 34),
        );
        await _mount(
          tester,
          size: const Size(390, 844),
          brightness: brightness,
          glass: true,
          onSensitivityChanged: (_, _) {},
          onSensitivityUnlock: (_) {},
          onTouchGrowthChanged: (_) {},
          sensitivity: example,
          state: exampleState,
        );
        await _capture(tester, 'status-${brightness.name}');
        tester.view.physicalSize = const Size(390, 1450);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('body-map-sensitivity-tab')),
        );
        await tester.pumpAndSettle();
        await tester.tap(_sensitivityMarker(BodySensitivityPart.intimate));
        await tester.pumpAndSettle();
        await _capture(tester, 'sensitivity-${brightness.name}');
        await _mount(
          tester,
          size: const Size(390, 1450),
          brightness: brightness,
          glass: true,
          onSensitivityChanged: (_, _) {},
          onSensitivityUnlock: (_) {},
          onTouchGrowthChanged: (_) {},
          sensitivity: example.unlock(BodySensitivityPart.intimate),
          state: exampleState,
        );
        await _capture(tester, 'sensitivity-unlocked-${brightness.name}');
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      _renderSilhouette?.dispose();
      _renderSilhouette = null;
    }
  }, skip: !_renderEnabled);
}

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory('build/status-audit').create(recursive: true);
      await File('build/status-audit/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
