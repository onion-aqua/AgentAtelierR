import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/body_sensitivity.dart';
import 'package:ryza_chat_mvp/src/character_state.dart';
import 'package:ryza_chat_mvp/src/character_status_panel.dart';
import 'package:ryza_chat_mvp/src/status_numeric_edit_gate.dart';
import 'package:ryza_chat_mvp/src/story_clock.dart';

const _titleKey = ValueKey('status-numeric-edit-title');
const _outsideKey = ValueKey('status-edit-outside');

Future<void> _mount(
  WidgetTester tester, {
  Object resetToken = 'ryza:1',
  ValueChanged<ValueListenable<bool>>? captureAccess,
  Widget Function(ValueListenable<bool>)? bodyBuilder,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: StatusNumericEditGate(
        title: '角色状态',
        language: AppLanguage.chinese,
        resetToken: resetToken,
        builder: (context, title, access) {
          captureAccess?.call(access);
          return Scaffold(
            appBar: AppBar(title: title),
            body:
                bodyBuilder?.call(access) ??
                Column(
                  children: [
                    Text(access.value ? 'editable' : 'read-only'),
                    const SizedBox(height: 48),
                    TextButton(
                      key: _outsideKey,
                      onPressed: () {},
                      child: const Text('Other control'),
                    ),
                  ],
                ),
          );
        },
      ),
    ),
  );
  await tester.pump();
}

Future<void> _tapTitle(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.tap(find.byKey(_titleKey));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _mountPanel(
  WidgetTester tester, {
  Object resetToken = 'ryza:1',
  BodySensitivityState? sensitivity,
  ValueChanged<ValueListenable<bool>>? captureAccess,
  void Function(BodySensitivityPart, int)? onChanged,
  ValueChanged<BodySensitivityPart>? onUnlock,
  ValueChanged<bool>? onGrowthChanged,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(450, 1100);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await _mount(
    tester,
    resetToken: resetToken,
    captureAccess: captureAccess,
    bodyBuilder: (access) => CharacterStatusPanel(
      language: AppLanguage.chinese,
      characterName: '莱莎',
      state: CharacterState(),
      clock: StoryClock(),
      clockEnabled: true,
      relationshipPoints: 100,
      postureLabel: '自然坐姿',
      location: '库肯岛',
      sceneTimeLabel: '午后',
      memoryEnabled: true,
      sensitivity: sensitivity ?? BodySensitivityState(),
      manualEditingEnabled: access.value,
      onSensitivityChanged: onChanged ?? (_, _) {},
      onSensitivityUnlock: onUnlock ?? (_) {},
      onTouchGrowthChanged: onGrowthChanged ?? (_) {},
    ),
  );
}

Future<void> _showSensitivity(
  WidgetTester tester, {
  BodySensitivityPart? part,
}) async {
  await tester.tap(find.byKey(const ValueKey('body-map-sensitivity-tab')));
  await tester.pump();
  if (part != null) {
    final marker = find.byKey(ValueKey('body-sensitivity-${part.name}'));
    await tester.ensureVisible(marker);
    await tester.tap(marker);
    await tester.pump();
  }
}

void main() {
  testWidgets('editing starts locked and requires ten title taps', (
    tester,
  ) async {
    late ValueListenable<bool> access;
    await _mount(tester, captureAccess: (value) => access = value);

    expect(access.value, isFalse);
    expect(find.text('read-only'), findsOneWidget);
    await _tapTitle(tester, 9);
    expect(access.value, isFalse);
    expect(find.text('editable'), findsNothing);

    await _tapTitle(tester, 1);
    expect(access.value, isTrue);
    expect(find.text('editable'), findsOneWidget);
    expect(find.text('已开启本次数值编辑，退出状态页后重新锁定。'), findsOneWidget);
  });

  testWidgets('a pause between taps starts a new sequence', (tester) async {
    late ValueListenable<bool> access;
    await _mount(tester, captureAccess: (value) => access = value);

    await _tapTitle(tester, 9);
    await tester.pump(StatusNumericEditGate.maximumTapInterval);
    await _tapTitle(tester, 1);
    expect(access.value, isFalse);
    await _tapTitle(tester, 8);
    expect(access.value, isFalse);
    await _tapTitle(tester, 1);
    expect(access.value, isTrue);
  });

  testWidgets('using another control interrupts consecutive title taps', (
    tester,
  ) async {
    late ValueListenable<bool> access;
    await _mount(tester, captureAccess: (value) => access = value);

    await _tapTitle(tester, 9);
    await tester.tap(find.byKey(_outsideKey));
    await tester.pump();
    await _tapTitle(tester, 1);
    expect(access.value, isFalse);
    await _tapTitle(tester, 9);
    expect(access.value, isTrue);
  });

  testWidgets('a held title does not count as repeated taps', (tester) async {
    late ValueListenable<bool> access;
    await _mount(tester, captureAccess: (value) => access = value);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_titleKey)),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(access.value, isFalse);
    await gesture.up();
    await tester.pump();
    await _tapTitle(tester, 8);
    expect(access.value, isFalse);
    await tester.pump(StatusNumericEditGate.maximumTapInterval);
  });

  testWidgets('save or character scope changes relock the live access handle', (
    tester,
  ) async {
    late ValueListenable<bool> access;
    await _mount(tester, captureAccess: (value) => access = value);
    await _tapTitle(tester, 10);
    final previousHandle = access;
    expect(previousHandle.value, isTrue);

    await _mount(
      tester,
      resetToken: 'klaudia:2',
      captureAccess: (value) => access = value,
    );
    expect(previousHandle.value, isFalse);
    expect(access.value, isFalse);
    await _tapTitle(tester, 9);
    expect(access.value, isFalse);
    await _tapTitle(tester, 1);
    expect(access.value, isTrue);
  });

  testWidgets('scope changes also discard a partially completed sequence', (
    tester,
  ) async {
    late ValueListenable<bool> access;
    await _mount(tester, captureAccess: (value) => access = value);
    await _tapTitle(tester, 9);
    await _mount(
      tester,
      resetToken: 'ryza:2',
      captureAccess: (value) => access = value,
    );

    await _tapTitle(tester, 1);
    expect(access.value, isFalse);
    await _tapTitle(tester, 9);
    expect(access.value, isTrue);
  });

  testWidgets('ordinary rebuilds preserve editing within the current visit', (
    tester,
  ) async {
    late ValueListenable<bool> access;
    await _mount(tester, captureAccess: (value) => access = value);
    await _tapTitle(tester, 10);
    await _mount(tester, captureAccess: (value) => access = value);

    expect(access.value, isTrue);
    expect(find.text('editable'), findsOneWidget);
  });

  testWidgets('backgrounding locks editing and returning does not unlock it', (
    tester,
  ) async {
    late ValueListenable<bool> access;
    await _mount(tester, captureAccess: (value) => access = value);
    await _tapTitle(tester, 10);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(access.value, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(access.value, isFalse);
    await _tapTitle(tester, 9);
    expect(access.value, isFalse);
    await _tapTitle(tester, 1);
    expect(access.value, isTrue);
  });

  testWidgets('leaving and reopening starts locked, including stale handles', (
    tester,
  ) async {
    late ValueListenable<bool> access;
    await _mount(tester, captureAccess: (value) => access = value);
    await _tapTitle(tester, 10);
    final previousHandle = access;

    await tester.pumpWidget(const SizedBox.shrink());
    expect(previousHandle.value, isFalse);
    await _mount(tester, captureAccess: (value) => access = value);
    expect(access.value, isFalse);
    expect(identical(access, previousHandle), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saved unlocked values remain read-only until title is unlocked',
    (tester) async {
      var edits = 0;
      final saved = BodySensitivityState(
        values: {BodySensitivityPart.legs: 79},
        unlocked: BodySensitivityPart.values,
      );
      await _mountPanel(
        tester,
        sensitivity: saved,
        onChanged: (_, _) => edits++,
      );
      await _showSensitivity(tester, part: BodySensitivityPart.legs);

      expect(find.byType(Slider), findsNothing);
      expect(
        find.byKey(const ValueKey('body-sensitivity-unlock')),
        findsNothing,
      );
      expect(find.text('腿部 · 敏感度  79 / 100'), findsOneWidget);
      expect(edits, 0);
      await _tapTitle(tester, 9);
      expect(find.byType(Slider), findsNothing);
      await _tapTitle(tester, 1);
      expect(
        find.byKey(const ValueKey('body-sensitivity-slider')),
        findsOneWidget,
      );
      expect(tester.widget<Slider>(find.byType(Slider)).value, 79);
      expect(edits, 0);
    },
  );

  testWidgets('manual part unlock is hidden until the editing session opens', (
    tester,
  ) async {
    var unlocks = 0;
    await _mountPanel(tester, onUnlock: (_) => unlocks++);
    await _showSensitivity(tester, part: BodySensitivityPart.intimate);

    expect(find.byKey(const ValueKey('body-sensitivity-unlock')), findsNothing);
    expect(find.byType(Slider), findsNothing);
    await _tapTitle(tester, 10);
    final unlock = find.byKey(const ValueKey('body-sensitivity-unlock'));
    expect(unlock, findsOneWidget);
    await tester.ensureVisible(unlock);
    await tester.tap(unlock);
    await tester.pump();
    expect(unlocks, 1);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets(
    'a slider callback retained before relocking cannot edit values',
    (tester) async {
      var edits = 0;
      await _mountPanel(tester, onChanged: (_, _) => edits++);
      await _showSensitivity(tester);
      await _tapTitle(tester, 10);
      final previousSlider = tester.widget<Slider>(find.byType(Slider));

      await _mountPanel(
        tester,
        resetToken: 'ryza:2',
        onChanged: (_, _) => edits++,
      );
      previousSlider.onChanged!(88);
      previousSlider.onChangeEnd!(88);
      await tester.pump();

      expect(edits, 0);
      expect(find.byType(Slider), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'touch updates do not grant manual editing and growth stays usable',
    (tester) async {
      late ValueListenable<bool> access;
      bool? growth;
      await _mountPanel(
        tester,
        captureAccess: (value) => access = value,
        onGrowthChanged: (value) => growth = value,
      );
      await _showSensitivity(tester);
      expect(find.byType(Slider), findsNothing);

      final touchUpdated = BodySensitivityState(
        values: {BodySensitivityPart.head: 51},
      ).unlock(BodySensitivityPart.intimate);
      await _mountPanel(
        tester,
        sensitivity: touchUpdated,
        captureAccess: (value) => access = value,
        onGrowthChanged: (value) => growth = value,
      );
      expect(access.value, isFalse);
      expect(find.text('头部 · 敏感度  51 / 100'), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      final growthControl = find.byKey(
        const ValueKey('body-sensitivity-touch-growth'),
      );
      await tester.ensureVisible(growthControl);
      await tester.tap(growthControl);
      await tester.pump();
      expect(growth, isFalse);
      expect(access.value, isFalse);
    },
  );
}
