import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  HttpOverrides.global = null;
  test('performance response after three seconds is accepted', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var calls = 0;
    server.listen((request) async {
      calls++;
      expect(request.headers.value('authorization'), 'Bearer test-only');
      await request.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 3300));
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '{"segments":[]}'},
            },
          ],
        }),
      );
      await request.response.close();
    });
    try {
      final result = await OpenAiCompatibleClient().complete(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'test-only',
        model: 'test-model',
        messages: [
          {'role': 'user', 'content': 'plan'},
        ],
        performancePlanning: true,
      );
      expect(result, '{"segments":[]}');
      expect(calls, 1);
    } finally {
      await server.close(force: true);
    }
  });
}
