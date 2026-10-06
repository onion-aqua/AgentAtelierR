import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/runtime_log.dart';

void main() {
  testWidgets('logging during build refreshes listeners after the frame', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() => RuntimeLog.instance.clear());
    var recorded = false;
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: RuntimeLog.instance,
          builder: (context, _) => Column(
            children: [
              Text('entries=${RuntimeLog.instance.entries.length}'),
              Builder(
                builder: (context) {
                  if (!recorded) {
                    recorded = true;
                    RuntimeLog.instance.error('Flutter', 'build diagnostic');
                  }
                  return const SizedBox();
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(find.text('entries=1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
