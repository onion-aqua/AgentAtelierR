import 'dart:convert';

import 'package:http/http.dart' as http;

class UpdateNotesLoader {
  UpdateNotesLoader({
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client();

  static const maxBytes = 128 * 1024;

  final http.Client _client;
  final Duration timeout;

  Future<String?> load(Uri? url) async {
    if (url == null) return null;
    if (url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.fragment.isNotEmpty) {
      return null;
    }
    try {
      final request = http.Request('GET', url)
        ..followRedirects = false
        ..headers['Accept'] = 'text/markdown, text/plain; q=0.9';
      final response = await _client.send(request).timeout(timeout);
      if (response.statusCode != 200 ||
          (response.contentLength != null &&
              response.contentLength! > maxBytes)) {
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) return null;
      }
      final value = utf8
          .decode(bytes, allowMalformed: false)
          .replaceAll('\u0000', '')
          .trim();
      return value.isEmpty ? null : value;
    } on Object {
      return null;
    }
  }

  void close() => _client.close();
}
