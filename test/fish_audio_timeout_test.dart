import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StalledClient extends http.BaseClient {
  int requests = 0;
  int active = 0;
  int peakActive = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    active++;
    if (active > peakActive) peakActive = active;
    final abortable = request as http.AbortableRequest;
    await abortable.abortTrigger;
    active--;
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  test(
    'Fish timeout aborts each attempt before retry and hides credentials',
    () async {
      final client = _StalledClient();
      final fish = FishAudioClient(
        client: client,
        requestTimeout: const Duration(milliseconds: 10),
      );
      await expectLater(
        fish.synthesizeBytes(
          apiKey: 'secret-test-value',
          referenceId: 'voice',
          text: 'hello',
        ),
        throwsA(
          isA<AiServiceException>()
              .having(
                (e) => e.toString(),
                'network explanation',
                contains('已重试 3 次'),
              )
              .having(
                (e) => e.toString(),
                'no key',
                isNot(contains('secret-test-value')),
              ),
        ),
      );
      expect(client.requests, 4);
      expect(client.active, 0);
      expect(client.peakActive, 1);
    },
  );
}
