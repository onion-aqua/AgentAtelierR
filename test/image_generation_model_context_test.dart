import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'generated history images do not become assistant image inputs',
    () async {
      SharedPreferences.setMockInitialValues({});
      final imageBytes = Uint8List.fromList([1, 2, 3]);
      var requests = 0;
      final transport = MockClient((request) async {
        requests++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final messages = (body['messages'] as List).cast<Map>();
        expect(messages[1]['role'], 'assistant');
        expect(messages[1]['content'], '图片已生成：海边的炼金工坊');
        expect(messages[2]['role'], 'user');
        final userParts = messages[2]['content'] as List;
        expect(userParts.last['type'], 'image_url');
        expect(
          userParts.last['image_url']['url'],
          'data:image/png;base64,${base64Encode(imageBytes)}',
        );
        return http.Response(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': 'ok'},
              },
            ],
          })}\n\ndata: [DONE]\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final client = OpenAiCompatibleClient(client: transport);
      final reply = await client
          .streamChat(
            baseUrl: 'https://example.test/v1',
            apiKey: 'test-key',
            model: 'text-model',
            systemPrompt: 'test',
            messages: [
              ChatMessage(
                text: '图片已生成：海边的炼金工坊',
                isUser: false,
                attachments: [
                  ChatAttachment(
                    name: 'generated.png',
                    mimeType: 'image/png',
                    size: imageBytes.length,
                    bytes: imageBytes,
                    generatedImageTaskId: 'img_test',
                  ),
                ],
              ),
              ChatMessage(
                text: '看看我上传的图片',
                isUser: true,
                attachments: [
                  ChatAttachment(
                    name: 'uploaded.png',
                    mimeType: 'image/png',
                    size: imageBytes.length,
                    bytes: imageBytes,
                  ),
                ],
              ),
            ],
          )
          .join();
      expect(reply, 'ok');
      expect(requests, 1);
    },
  );
}
