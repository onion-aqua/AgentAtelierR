import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/local_tts_client.dart';
import 'package:ryza_chat_mvp/src/local_tts_japanese.dart';
import 'package:ryza_chat_mvp/src/local_tts_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Chinese and Japanese dialogue remain eligible for local speech', () {
    expect(
      localTtsLanguageForText('今日は冒険しよう', AppLanguage.chinese),
      LocalTtsLanguage.japanese,
    );
    expect(
      localTtsLanguageForText('你好，今天去冒险吧', AppLanguage.japanese),
      LocalTtsLanguage.japanese,
    );
    expect(
      localTtsLanguageForText('你好，今天去冒险吧', AppLanguage.chinese),
      LocalTtsLanguage.chinese,
    );
    expect(localTtsLanguageForText('Hello', AppLanguage.english), isNull);
  });

  test('Japanese text is normalized to CosyVoice katakana input', () async {
    expect(await normalizeJapaneseForCosyVoice3('こんにちは'), 'コンニチハ');
    final channel = const MethodChannel('jp_transliterate');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'transliterateWords');
      return [
        {'katakana': 'レンキンジュツ'},
        {'katakana': 'ッテ'},
        {'katakana': 'ケッコウ'},
        {'katakana': 'オク'},
        {'katakana': 'ガ'},
        {'katakana': 'フカイ'},
        {'katakana': 'ンダヨ'},
        {'katakana': '。'},
      ];
    });
    try {
      expect(
        await normalizeJapaneseForCosyVoice3('錬金術って結構奥が深いんだよ。'),
        'レンキンジュツ ッテ ケッコウ オク ガ フカイ ンダヨ。',
      );
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('platform status and progress preserve voice metadata', () {
    final status = LocalTtsStatus.fromPlatform({
      'modelReady': true,
      'enrollmentReady': false,
      'modelBytes': 1400000000,
      'voices': [
        {'id': 'builtin-1', 'name': 'Default', 'builtIn': true},
        {'id': 'custom-1', 'name': 'Custom', 'builtIn': false},
      ],
      'selectedVoiceId': 'custom-1',
    });
    expect(status.modelReady, isTrue);
    expect(status.enrollmentReady, isFalse);
    expect(status.modelBytes, 1400000000);
    expect(status.voices.map((voice) => voice.id), ['builtin-1', 'custom-1']);
    expect(status.voices.last.builtIn, isFalse);
    expect(status.selectedVoiceId, 'custom-1');
    expect(
      LocalTtsProgress.fromPlatform({'stage': 'downloadModel', 'progress': 1.2})
          .progress,
      1,
    );
    expect(
      () => LocalTtsStatus.fromPlatform({'modelReady': true}),
      throwsFormatException,
    );
  });

  test('Android channel receives model and enrollment operations', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(LocalTtsModelStore.channel, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'status') {
        return {
          'modelReady': true,
          'enrollmentReady': true,
          'modelBytes': 1400000000,
          'voices': [
            {'id': 'builtin', 'name': 'Default', 'builtIn': true},
          ],
          'selectedVoiceId': 'builtin',
        };
      }
      if (call.method == 'enroll') {
        expect(call.arguments, {
          'audioPath': '/reference.wav',
          'startSeconds': 1.0,
          'endSeconds': 5.0,
          'promptText': '你好。',
          'name': 'My voice',
        });
        return {'id': 'custom', 'name': 'My voice', 'builtIn': false};
      }
      if (call.method == 'importModel' || call.method == 'importEnrollment') {
        expect(call.arguments, {'path': '/models.zip'});
      }
      return null;
    });
    try {
      final store = LocalTtsModelStore.instance;
      expect(await store.isReadyFor('你好', AppLanguage.chinese), isTrue);
      expect(await store.isReadyFor('Hello', AppLanguage.english), isFalse);
      await store.downloadModel();
      await store.downloadEnrollment();
      await store.importModel('/models.zip');
      await store.importEnrollment('/models.zip');
      final voice = await store.enroll(
        audioPath: '/reference.wav',
        startSeconds: 1,
        endSeconds: 5,
        promptText: ' 你好。 ',
        name: ' My voice ',
      );
      expect(voice.id, 'custom');
      await store.selectVoice(voice.id);
      await store.deleteVoice(voice.id);
      await store.deleteEnrollment();
      await store.deleteModel();
      expect(calls, [
        'status',
        'downloadModel',
        'downloadEnrollment',
        'importModel',
        'importEnrollment',
        'enroll',
        'selectVoice',
        'deleteVoice',
        'deleteEnrollment',
        'deleteModel',
      ]);
      await expectLater(
        store.enroll(
          audioPath: '/reference.wav',
          startSeconds: 0,
          endSeconds: 8,
          promptText: '你好',
          name: 'Test',
        ),
        throwsFormatException,
      );
    } finally {
      messenger.setMockMethodCallHandler(LocalTtsModelStore.channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test(
    'synthesis forwards the character voice and returns a WAV path',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final directory = await Directory.systemTemp.createTemp(
        'cosyvoice3-test-',
      );
      final wav = File('${directory.path}/speech.wav');
      await wav.writeAsBytes(List<int>.filled(44, 0));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final requestedVoiceIds = <String>[];
      messenger.setMockMethodCallHandler(LocalTtsModelStore.channel, (
        call,
      ) async {
        if (call.method == 'status') {
          return {
            'modelReady': true,
            'enrollmentReady': true,
            'modelBytes': 1400000000,
            'voices': [
              {'id': 'builtin', 'name': 'Default', 'builtIn': true},
              {'id': 'sophie', 'name': 'Sophie', 'builtIn': false},
            ],
            'selectedVoiceId': 'builtin',
          };
        }
        expect(call.method, 'synthesize');
        expect((call.arguments as Map)['text'], 'コンニチハ');
        requestedVoiceIds.add((call.arguments as Map)['voiceId'] as String);
        return wav.path;
      });
      try {
        expect(
          await LocalTtsClient.instance.synthesize(
            text: 'こんにちは',
            preferredLanguage: AppLanguage.japanese,
            voiceProfileId: 'sophie',
          ),
          wav.path,
        );
        expect(
          await LocalTtsClient.instance.synthesize(
            text: 'こんにちは',
            preferredLanguage: AppLanguage.japanese,
            voiceProfileId: 'deleted-profile',
          ),
          wav.path,
        );
        expect(requestedVoiceIds, ['sophie', 'builtin']);
      } finally {
        messenger.setMockMethodCallHandler(LocalTtsModelStore.channel, null);
        debugDefaultTargetPlatformOverride = null;
        await directory.delete(recursive: true);
      }
    },
  );
}
