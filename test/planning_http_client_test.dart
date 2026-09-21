import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ryza_chat_mvp/src/planning_http_client.dart';
import 'package:ryza_chat_mvp/src/retry_policy.dart';

void main() {
  test(
    'aborts a stalled body then retries without losing headers or payload',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var calls = 0;
      final requests = server.listen((request) async {
        calls++;
        expect(request.headers.value('authorization'), 'Bearer test-only');
        expect(await request.fold<int>(0, (n, bytes) => n + bytes.length), 2);
        if (calls == 1) {
          request.response.write('partial');
          await request.response.flush();
        } else {
          request.response.write('ok');
          await request.response.close();
        }
      });
      final client = PlanningHttpClient(
        http.Client(),
        attemptTimeout: const Duration(milliseconds: 100),
      );
      try {
        final response = await withAiRequestRetries(
          () => client.post(
            Uri.parse('http://127.0.0.1:${server.port}'),
            headers: {'authorization': 'Bearer test-only'},
            body: '{}',
          ),
          maxRetries: 1,
        );
        expect(response.body, 'ok');
        expect(calls, 2);
      } finally {
        client.close();
        await server.close(force: true);
        await requests.cancel();
      }
    },
  );
  test(
    'close aborts pending request and prevents late retry requests',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<void>();
      server.listen((request) {
        received.complete();
      });
      final client = PlanningHttpClient(http.Client());
      try {
        final pending = client.get(
          Uri.parse('http://127.0.0.1:${server.port}'),
        );
        final check = expectLater(
          pending,
          throwsA(isA<http.ClientException>()),
        );
        await received.future;
        client.close();
        await check;
        await expectLater(
          client.get(Uri.parse('http://127.0.0.1:${server.port}')),
          throwsStateError,
        );
      } finally {
        client.close();
        await server.close(force: true);
      }
    },
  );
}
