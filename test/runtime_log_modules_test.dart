import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/runtime_log.dart';
import 'package:ryza_chat_mvp/src/runtime_log_screen.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RuntimeLog.instance.clear();
  });
  test('planner and unknown sources persist and classify', () async {
    final log = RuntimeLog.instance;
    log.info('plan_character_action', 'action marker');
    log.info('plan_character_expression', 'face marker');
    log.error('NewModule', 'failure');
    expect(log.entries.map((e) => e.module), [
      RuntimeLogModule.action,
      RuntimeLogModule.expression,
      RuntimeLogModule.system,
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await log.initialize();
    expect(log.entries.length, 3);
    await log.clear();
    await log.initialize();
    expect(log.entries, isEmpty);
  });
  test('nested JSON is formatted and sensitive values are redacted', () {
    final value = RuntimeLog.prettyMessage(
      jsonEncode({
        'body': jsonEncode({
          'api_key': 'private-value',
          'result': [1, 2],
        }),
      }),
    );
    expect(value, contains('\n'));
    expect(value, isNot(contains('private-value')));
    expect((jsonDecode(value)['body'] as Map)['api_key'], '[REDACTED]');
    expect(
      RuntimeLog.prettyMessage('line one\nline two'),
      'line one\nline two',
    );
  });
  testWidgets('module filters isolate visible messages', (tester) async {
    RuntimeLog.instance.info('LLM', 'llm marker');
    RuntimeLog.instance.info('TTS', 'tts marker');
    await tester.pumpWidget(
      MaterialApp(
        home: RuntimeLogScreen(
          language: AppLanguage.values.first,
          onMenuPressed: () {},
        ),
      ),
    );
    expect(find.text('llm marker'), findsOneWidget);
    expect(find.text('tts marker'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'TTS'));
    await tester.pumpAndSettle();
    expect(find.text('llm marker'), findsNothing);
    expect(find.text('tts marker'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
