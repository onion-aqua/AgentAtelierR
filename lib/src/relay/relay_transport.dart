import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'relay_protocol.dart';

abstract interface class RelaySocket {
  Stream<Object?> get messages;
  void send(Json value);
  Future<void> close();
}

abstract interface class RelayTransport {
  Future<Json> request(
    Uri origin,
    String method,
    String path, {
    String? token,
    Json? body,
  });
  Future<RelaySocket> connect(Uri origin, String token);
  void dispose();
}

class HttpsRelayTransport implements RelayTransport {
  HttpsRelayTransport({http.Client? client})
    : _client = client ?? http.Client();
  final http.Client _client;
  @override
  Future<Json> request(
    Uri origin,
    String method,
    String path, {
    String? token,
    Json? body,
  }) async {
    secureOrigin(origin.toString());
    try {
      final request = http.Request(method, origin.resolve(path))
        ..followRedirects = false;
      request.headers['Accept'] = 'application/json';
      if (token != null) request.headers['Authorization'] = 'Bearer $token';
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      final response = await (() async {
        final stream = await _client.send(request);
        return http.Response.fromStream(stream);
      })().timeout(const Duration(seconds: 20));
      if (response.statusCode == 204) return {};
      Json data;
      try {
        data = object(jsonDecode(utf8.decode(response.bodyBytes)));
      } on Object {
        throw const RelayFailure('PROTOCOL_ERROR');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = data['error'];
        final code = error is Map ? error['code'] : null;
        throw RelayFailure(
          code is String ? code : 'HTTP_ERROR',
          retryable: error is Map && error['retryable'] == true,
        );
      }
      return data;
    } on RelayFailure {
      rethrow;
    } on Object {
      throw const RelayFailure('NETWORK', retryable: true);
    }
  }

  @override
  Future<RelaySocket> connect(Uri origin, String token) async {
    secureOrigin(origin.toString());
    try {
      return _IoSocket(
        await WebSocket.connect(
          origin.replace(scheme: 'wss', path: '/v1/ws').toString(),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 20)),
      );
    } on Object {
      throw const RelayFailure('NETWORK', retryable: true);
    }
  }

  @override
  void dispose() => _client.close();
}

class _IoSocket implements RelaySocket {
  _IoSocket(this.socket);
  final WebSocket socket;
  @override
  Stream<Object?> get messages => socket.map((raw) {
    try {
      return object(jsonDecode(raw as String));
    } on Object {
      throw const RelayFailure('PROTOCOL_ERROR');
    }
  });
  @override
  void send(Json value) => socket.add(jsonEncode(value));
  @override
  Future<void> close() async {
    await socket.close();
  }
}
