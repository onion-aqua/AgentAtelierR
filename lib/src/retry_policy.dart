import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Shared policy for transient AI/TTS network failures.
///
/// [maxRetries] counts retries after the initial request, so the default
/// permits at most four total attempts. A retry is only made before a usable
/// response is consumed; callers must not use this around a partially read
/// streaming response.
const int aiRequestMaxRetries = 3;

bool isRetryableHttpStatus(int statusCode) =>
    statusCode == 408 ||
    statusCode == 425 ||
    statusCode == 429 ||
    statusCode >= 500;

bool isRetryableNetworkError(Object error) =>
    error is TimeoutException ||
    error is SocketException ||
    error is HttpException ||
    error is http.ClientException;

Future<T> withAiRequestRetries<T>(
  Future<T> Function() operation, {
  bool Function(T result)? shouldRetryResult,
  Future<void> Function(T result)? disposeRetryResult,
  int maxRetries = aiRequestMaxRetries,
}) async {
  Object? lastError;
  StackTrace? lastStack;
  final retries = maxRetries < 0 ? 0 : maxRetries;

  for (var attempt = 0; attempt <= retries; attempt++) {
    try {
      final result = await operation();
      final retryResult = shouldRetryResult?.call(result) ?? false;
      if (!retryResult || attempt == retries) return result;
      if (disposeRetryResult != null) {
        await disposeRetryResult(result);
      }
    } catch (error, stack) {
      if (!isRetryableNetworkError(error) || attempt == retries) {
        Error.throwWithStackTrace(error, stack);
      }
      lastError = error;
      lastStack = stack;
    }
    // Small exponential backoff avoids hammering a temporarily unavailable
    // provider while keeping a normal recovery fast.
    await Future<void>.delayed(Duration(milliseconds: 500 * (1 << attempt)));
  }

  // The loop always returns or rethrows. Keep a defensive fallback for static
  // analysis if a future implementation changes the loop bounds.
  Error.throwWithStackTrace(
    lastError ?? StateError('AI request retry loop ended unexpectedly'),
    lastStack ?? StackTrace.current,
  );
}
