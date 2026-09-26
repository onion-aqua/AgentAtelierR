import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local demo reply follows the selected character', () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => Directory.systemTemp.path,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final controller = await AppController.load();
    addTearDown(controller.dispose);

    await controller.setActiveCharacter('sophie');
    final sophieReply = controller.demoReply('你好');
    expect(sophieReply, contains('苏菲：'));
    expect(sophieReply, isNot(contains('莱莎')));
    expect(sophieReply, isNot(contains('[face:')));
    expect(sophieReply, isNot(contains('[action:')));

    await controller.setActiveCharacter('ryza');
    final ryzaReply = controller.demoReply('你好');
    expect(ryzaReply, contains('莱莎：'));
    expect(ryzaReply, isNot(contains('苏菲')));
  });
}
