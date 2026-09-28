import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test(
    'Fish requests use Klaudia fixed voice and shared endpoint/model',
    () async {
      final requests =
          <({Uri url, String model, String referenceId, String text})>[];
      final fish = FishAudioClient(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add((
            url: request.url,
            model: request.headers['model'] ?? '',
            referenceId: body['reference_id'] as String,
            text: body['text'] as String,
          ));
          return http.Response.bytes(
            Uint8List.fromList(const [0x49, 0x44, 0x33, 0x04]),
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        }),
      );
      final speech = assistantSpeechSegmentsForResponse(
        '旁白：门开了。\n莱莎：欢迎。\n角色[klaudia]：你来啦。\n译文：Welcome.',
        activeCharacterId: 'ryza',
        fallbackMood: CharacterMood.neutral,
      );

      for (final segment in speech) {
        await fish.synthesizeBytes(
          apiKey: 'configured-key',
          referenceId: fishReferenceIdForAssistantSpeech(
            segment,
            primaryReferenceId: 'configured-ryza-voice',
          ),
          text: segment.speechText,
          baseUrl: 'https://configured.example.test/v1/tts',
          model: 'configured-fish-model',
        );
      }

      expect(requests, hasLength(2));
      expect(requests.map((request) => request.referenceId), [
        'configured-ryza-voice',
        klaudiaFishAudioReferenceId,
      ]);
      expect(klaudiaFishAudioReferenceId, '7b7667d545f94326a7089830d2b55261');
      expect(requests.map((request) => request.url.toString()), [
        'https://configured.example.test/v1/tts',
        'https://configured.example.test/v1/tts',
      ]);
      expect(requests.map((request) => request.model), [
        'configured-fish-model',
        'configured-fish-model',
      ]);
      expect(requests.first.text, contains('欢迎。'));
      expect(requests.last.text, '你来啦。');
    },
  );
}
