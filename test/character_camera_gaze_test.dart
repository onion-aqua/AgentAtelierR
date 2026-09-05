import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_camera.dart';
import 'package:ryza_chat_mvp/src/character_gaze.dart';

void main() {
  testWidgets('press and drag use camera coordinates; release ends gaze', (
    tester,
  ) async {
    final targets = <Offset>[];
    var ends = 0;
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 600,
            child: CharacterCamera(
              initialScale: 2,
              initialVerticalOffsetFraction: 0.2,
              onTap: (_) => taps++,
              onGazeChanged: targets.add,
              onGazeEnd: () => ends++,
              child: const ColoredBox(color: Colors.white),
            ),
          ),
        ),
      ),
    );
    final pointer = await tester.startGesture(const Offset(100, 200));
    expect(targets.single, const Offset(150, 340));
    await pointer.moveTo(const Offset(300, 300));
    expect(targets.last, const Offset(250, 390));
    await pointer.up();
    expect(ends, 1);
    expect(taps, 0);
    final count = targets.length;
    await tester.pump(const Duration(seconds: 1));
    expect(targets.length, count);
  });

  testWidgets('tap and cancellation end gaze; pinch does not keep tracking', (
    tester,
  ) async {
    var updates = 0;
    var ends = 0;
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CharacterCamera(
          onTap: (_) => taps++,
          onGazeChanged: (_) => updates++,
          onGazeEnd: () => ends++,
          child: const ColoredBox(color: Colors.white),
        ),
      ),
    );
    final a = await tester.startGesture(const Offset(100, 200), pointer: 1);
    await a.up();
    expect(updates, 1);
    expect(ends, 1);
    expect(taps, 1);
    final b = await tester.startGesture(const Offset(100, 200), pointer: 2);
    await b.cancel();
    expect(ends, 2);
    final c = await tester.startGesture(const Offset(100, 200), pointer: 3);
    final d = await tester.startGesture(const Offset(200, 200), pointer: 4);
    final beforeMove = updates;
    expect(ends, 3);
    await c.moveBy(const Offset(-40, 0));
    await d.moveBy(const Offset(40, 0));
    expect(updates, beforeMove);
    await c.up();
    await d.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(taps, 1);
  });

  test('release fades immediately and reaches zero in 700 ms', () {
    final beginning = characterGazeHoldDuration;
    expect(characterGazeInfluence(beginning), 1);
    expect(
      characterGazeInfluence(beginning + const Duration(milliseconds: 350)),
      closeTo(0.5, 0.001),
    );
    expect(characterGazeInfluence(beginning + characterGazeReleaseDuration), 0);
  });
}
