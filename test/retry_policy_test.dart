import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/retry_policy.dart';

void main() {
  test('network errors are retried and can recover', () async {
    var attempts = 0;
    final value = await withAiRequestRetries<String>(() async {
      attempts++;
      if (attempts == 1) throw const SocketException('offline');
      return 'ok';
    });

    expect(value, 'ok');
    expect(attempts, 2);
  });

  test('retryable results stop after three retries', () async {
    var attempts = 0;
    final value = await withAiRequestRetries<int>(() async {
      attempts++;
      return 503;
    }, shouldRetryResult: (status) => isRetryableHttpStatus(status));

    expect(value, 503);
    expect(attempts, 4);
  });
}
