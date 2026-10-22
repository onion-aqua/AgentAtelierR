import 'package:flutter/gestures.dart';


import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/personality/personality_chart.dart';
import 'package:ryza_chat_mvp/src/personality/personality_profile.dart';

const _canvasKey = ValueKey('personality-chart-interactive-canvas');
final _basicKeys = PersonalityProfile.traitLabels.keys
    .where(
      (key) =>
          PersonalityChartGroup.forParameter(key) ==
          PersonalityChartGroup.basic,
    )
    .toList();

void main() {
  test('groups match editor definitions and radial distances are exact', () {
    expect(
      PersonalityChartGroup.forParameter('selfOther'),
      PersonalityChartGroup.axes,
    );
    expect(
      PersonalityChartGroup.forParameter('attachment'),
      PersonalityChartGroup.relationships,
    );
    expect(
      PersonalityChartGroup.forParameter('controlTendency'),
      PersonalityChartGroup.basic,
    );
    expect(
      PersonalityChartGroup.forParameter('relationshipSensitivity'),
      PersonalityChartGroup.tuning,
    );
    expect(_basicKeys.length, 9);
    const center = Offset(80, 70), radius = 60.0;
    for (final count in [6, 9]) {
      for (var index = 0; index < count; index++) {
        final zero = personalityRadarPoint(
          index: index,
          count: count,
          score: 0,
          center: center,
          radius: radius,
        );
        final mid = personalityRadarPoint(
          index: index,
          count: count,
          score: 50,
          center: center,
          radius: radius,
        );
        final full = personalityRadarPoint(
          index: index,
          count: count,
          score: 100,
          center: center,
          radius: radius,
        );
        expect(zero, center);
        expect((mid - center).distance, closeTo(30, 1e-9));
        expect((full - center).distance, closeTo(60, 1e-9));
        expect(mid, Offset.lerp(center, full, .5));
      }
    }
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final height in [80.0, 250.0, 480.0]) {
        for (final group in PersonalityChartGroup.values) {
          testWidgets('320px $brightness text=$scale height=$height $group', (
            tester,
          ) async {
            tester.view.physicalSize = const Size(320, 740);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await tester.pumpWidget(
              _Harness(
                brightness: brightness,
                scale: scale,
                height: height,
                group: group,
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester
                  .getSize(
                    find.byKey(const ValueKey('personality-chart-panel')),
                  )
                  .height,
              lessThanOrEqualTo(height),
            );
            if (height == 480) {
              expect(
                tester.getSize(find.byKey(_canvasKey)).height,
                greaterThanOrEqualTo(scale > 1.4 ? 160 : 220),
              );
            }
            if (height >= 250 && group != PersonalityChartGroup.axes) {
              final last = group == PersonalityChartGroup.tuning
                  ? 'comedyIntensity'
                  : group == PersonalityChartGroup.basic
                  ? 'teasing'
                  : 'reassuranceSeeking';
              final legend = find.byKey(
                const ValueKey('personality-chart-legend'),
              );
              final viewport = find.descendant(
                of: legend,
                matching: find.byType(Scrollable),
              );
              await tester.scrollUntilVisible(
                find.byKey(ValueKey('personality-chart-parameter-$last')),
                60,
                scrollable: viewport,
              );
              await tester.pumpAndSettle();
              await Scrollable.ensureVisible(
                tester.element(
                  find.byKey(ValueKey('personality-chart-parameter-$last')),
                ),
                alignment: 1,
              );
              await tester.pumpAndSettle();
              expect(
                find
                    .byKey(ValueKey('personality-chart-parameter-$last'))
                    .hitTestable(),
                findsOneWidget,
              );
            }
            await tester.tap(
              find.byKey(const ValueKey('personality-chart-toggle')),
            );
            await tester.pumpAndSettle();
            if (height >= 170) {
              expect(
                find.byKey(const ValueKey('personality-chart-summary')),
                findsOneWidget,
              );
              expect(find.byTooltip('展开人格图表'), findsOneWidget);
            } else {
              expect(
                find.byKey(const ValueKey('personality-chart-expanded-view')),
                findsOneWidget,
              );
              await tester.tap(find.text('返回参数编辑'));
              await tester.pumpAndSettle();
            }
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }

  testWidgets(
    'radial drag clamps at 100 and zero without changing another axis',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await tester.pumpAndSettle();
      final start = _point(tester, 0, 50),
          center = _center(tester),
          radius = _radius(tester);
      final gesture = await tester.startGesture(start);
      await gesture.moveTo(center + Offset(0, -radius * 2));
      await tester.pump();
      expect(key.currentState!.traits['independence'], 100);
      await gesture.moveTo(center + Offset(0, radius));
      await tester.pump();
      expect(key.currentState!.traits['independence'], 0);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        key.currentState!.changes.every(
          (value) => value.keys.single == 'independence',
        ),
        isTrue,
      );
      expect(key.currentState!.traits['responsibility'], 50);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'gesture locks the first radar axis when moved across another node',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(_point(tester, 0, 50));
      await gesture.moveTo(_point(tester, 0, 80));
      await tester.pump();
      await gesture.moveTo(_point(tester, 1, 80));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(key.currentState!.changes, isNotEmpty);
      expect(
        key.currentState!.changes.every(
          (value) => value.keys.single == 'independence',
        ),
        isTrue,
      );
      expect(key.currentState!.traits['responsibility'], 50);
      expect(key.currentState!.traits['independence'], closeTo(61, 1));
    },
  );

  testWidgets('zero node can be pulled out after selecting its legend', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, zero: true));
    await tester.pumpAndSettle();
    final legend = find.byKey(
      const ValueKey('personality-chart-parameter-teasing'),
    );
    await tester.ensureVisible(legend);
    await tester.tap(legend);
    await tester.pumpAndSettle();
    expect(key.currentState!.changes, isEmpty);
    final gesture = await tester.startGesture(_center(tester));
    await gesture.moveTo(_point(tester, 8, 70));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(key.currentState!.traits['teasing'], closeTo(70, 1));
    expect(
      key.currentState!.changes.every(
        (value) => value.keys.single == 'teasing',
      ),
      isTrue,
    );
  });

  testWidgets('XY point drag maps both positive and negative axes and clamps', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      _Harness(key: key, group: PersonalityChartGroup.axes),
    );
    await tester.pumpAndSettle();
    final center = _center(tester),
        radius = _radius(tester, PersonalityChartGroup.axes);
    final gesture = await tester.startGesture(center);
    await gesture.moveTo(center + Offset(radius * 2, -radius * 2));
    await tester.pump();
    expect(key.currentState!.axes, {
      'selfOther': 100,
      'restraintExpression': 100,
    });
    await gesture.moveTo(center + Offset(-radius * 2, radius * 2));
    await tester.pump();
    expect(key.currentState!.axes, {
      'selfOther': -100,
      'restraintExpression': -100,
    });
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('read-only chart and unchanged node taps do not emit changes', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();
    await tester.tapAt(_point(tester, 0, 50));
    await tester.pumpAndSettle();
    expect(key.currentState!.changes, isEmpty);
    key.currentState!.update(() => key.currentState!.readOnly = true);
    await tester.pump();
    await tester.dragFrom(_point(tester, 0, 50), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(key.currentState!.changes, isEmpty);
    expect(key.currentState!.traits['independence'], 50);
  });

  for (final reason in ['identity', 'group', 'readOnly']) {
    testWidgets('changing $reason cancels a pointer held on the old draft', (
      tester,
    ) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(_point(tester, 0, 50));
      await gesture.moveTo(_point(tester, 0, 70));
      await tester.pump();
      final calls = key.currentState!.changes.length;
      key.currentState!.update(() {
        if (reason == 'identity') {
          key.currentState!.identity = 'other-profile';
        }
        if (reason == 'group') {
          key.currentState!.group = PersonalityChartGroup.tuning;
        }
        if (reason == 'readOnly') {
          key.currentState!.readOnly = true;
        }
      });
      await tester.pump();
      await gesture.moveTo(_point(tester, 0, 100));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(key.currentState!.changes.length, calls);
    });
  }

  testWidgets('primary mouse drag changes the intended parameter', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();
    final mouse = await tester.startGesture(
      _point(tester, 0, 50),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(_point(tester, 0, 85));
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();
    expect(key.currentState!.traits['independence'], closeTo(85, 1));
    expect(
      key.currentState!.changes.every(
        (value) => value.keys.single == 'independence',
      ),
      isTrue,
    );
  });

  testWidgets('blank chart margin leaves vertical drag to outer page scroll', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, scrollable: true));
    await tester.pumpAndSettle();
    final margin =
        tester.getTopLeft(find.byKey(_canvasKey)) + const Offset(4, 30);
    await tester.dragFrom(margin, const Offset(0, -140));
    await tester.pumpAndSettle();
    expect(key.currentState!.scroll.offset, greaterThan(0));
    expect(key.currentState!.changes, isEmpty);
  });

  testWidgets(
    'complete labels, live scores and semantics adjustments are available',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await tester.pumpAndSettle();
      final item = find.bySemanticsLabel('独立性');
      var node = tester.getSemantics(item);
      expect(node.value, '50 / 100');
      node.owner!.performAction(node.id, SemanticsAction.increase);
      await tester.pump();
      expect(key.currentState!.traits['independence'], 51);
      node = tester.getSemantics(item);
      node.owner!.performAction(node.id, SemanticsAction.decrease);
      await tester.pump();
      expect(key.currentState!.traits['independence'], 50);
      key.currentState!.update(() => key.currentState!.readOnly = true);
      await tester.pump();
      node = tester.getSemantics(item);
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.increase),
        isFalse,
      );
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.decrease),
        isFalse,
      );
      semantics.dispose();
    },
  );
}

Offset _center(WidgetTester tester) =>
    tester.getRect(find.byKey(_canvasKey)).center;
double _radius(
  WidgetTester tester, [
  PersonalityChartGroup group = PersonalityChartGroup.basic,
]) => personalityChartRadius(tester.getSize(find.byKey(_canvasKey)), group);
Offset _point(WidgetTester tester, int index, double score) =>
    personalityRadarPoint(
      index: index,
      count: 9,
      score: score,
      center: _center(tester),
      radius: _radius(tester),
    );

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    this.brightness = Brightness.light,
    this.scale = 1,
    this.height = 480,
    this.group = PersonalityChartGroup.basic,
    this.zero = false,
    this.scrollable = false,
  });
  final Brightness brightness;
  final double scale, height;
  final PersonalityChartGroup group;
  final bool zero, scrollable;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late Map<String, int> traits;
  Map<String, int> axes = {'selfOther': 0, 'restraintExpression': 0};
  Map<String, int> tuning = {...PersonalityProfile.tuningDefaults};
  late PersonalityChartGroup group;
  String? selected = 'independence';
  Object identity = 'profile-1';
  bool readOnly = false;
  final changes = <Map<String, int>>[];
  final scroll = ScrollController();
  void update(VoidCallback callback) => setState(callback);
  @override
  void initState() {
    super.initState();
    group = widget.group;
    traits = {
      for (final key in PersonalityProfile.traitLabels.keys)
        key: widget.zero ? 0 : 50,
    };
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(brightness: widget.brightness),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(widget.scale)),
      child: Scaffold(
        body: widget.scrollable
            ? SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: [panel(), const SizedBox(height: 1200)],
                ),
              )
            : Align(alignment: Alignment.topCenter, child: panel()),
      ),
    ),
  );
  Widget panel() => PersonalityChartPanel(
    baseAxes: axes,
    traits: traits,
    tuning: tuning,
    group: group,
    maxHeight: widget.height,
    selectedParameter: selected,
    editingIdentity: identity,
    onSelectParameter: (value) => setState(() => selected = value),
    onGroupChanged: (value) => setState(() => group = value),
    onChanged: readOnly
        ? null
        : (value) => setState(() {
            changes.add(Map.from(value));
            if (group == PersonalityChartGroup.axes) {
              axes = {...axes, ...value};
            } else if (group == PersonalityChartGroup.tuning) {
              tuning = {...tuning, ...value};
            } else {
              traits = {...traits, ...value};
            }
          }),
  );
}
