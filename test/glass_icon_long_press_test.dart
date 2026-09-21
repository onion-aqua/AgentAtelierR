import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';

void main() {
  testWidgets('long press regenerates without also replaying', (tester) async {
    var taps = 0;
    var holds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassIconButton(
            liquidGlass: false,
            icon: Icons.replay_rounded,
            tooltip: 'Replay or regenerate',
            onPressed: () => taps++,
            onLongPress: () => holds++,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.replay_rounded));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(holds, 0);
    await tester.longPress(find.byIcon(Icons.replay_rounded));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(holds, 1);
  });
}
