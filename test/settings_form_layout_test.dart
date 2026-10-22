import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/settings_form.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_settings.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final glass in [false, true]) {
      testWidgets('call settings narrow large text $brightness glass=$glass', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var opened = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: RealtimeCallSettingsPage(
              ttsProvider: TtsProvider.fishAudioMcp,
              liquidGlass: glass,
              onOpenVoiceSettings: () => opened = true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final manual = find.byKey(const ValueKey('call-manual-models'));
        await tester.scrollUntilVisible(
          manual,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(manual);
        await tester.pumpAndSettle();
        final shortcut = find.byKey(const ValueKey('call-open-voice-settings'));
        await tester.scrollUntilVisible(
          shortcut,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(shortcut);
        await tester.pumpAndSettle();
        expect(opened, isTrue);
        expect(find.byType(TextFormField), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('settings form keeps draft and focus when theme changes', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    Widget page(Brightness brightness) => MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: SettingsFormTheme(
        child: Scaffold(
          body: TextField(
            controller: controller,
            focusNode: focus,
            decoration: const InputDecoration(
              labelText: '接口地址',
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(page(Brightness.light));
    await tester.enterText(find.byType(TextField), 'https://example.test/v1');
    await tester.pumpWidget(page(Brightness.dark));
    await tester.pumpAndSettle();
    final decoration = tester
        .widget<InputDecorator>(find.byType(InputDecorator))
        .decoration;
    expect(decoration.filled, isTrue);
    expect(
      (decoration.enabledBorder! as OutlineInputBorder).borderRadius,
      BorderRadius.circular(14),
    );
    expect(controller.text, 'https://example.test/v1');
    expect(focus.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });
}
