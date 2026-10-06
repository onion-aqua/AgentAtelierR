import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/relay/relay_server_config.dart';

void main() {
  const source = {
    'v': 1,
    'server_base_url': 'https://private-relay.example.test',
  };

  test('unconfigured public build permits valid HTTPS QR servers', () async {
    final config = await RelayServerConfig.fromProtectedDefines(
      encrypted: '',
      key: '',
    );
    expect(config.isPinned, isFalse);
    expect(
      config.requireAllowed(Uri.parse('https://other.example.test')).host,
      'other.example.test',
    );
    expect(
      () => config.requireAllowed(Uri.parse('http://other.example.test')),
      throwsFormatException,
    );
  });

  test(
    'encrypted build configuration round trips with no plaintext address',
    () async {
      final definitions = await protectRelayServerConfiguration(source);
      expect(
        jsonEncode(definitions),
        isNot(contains('private-relay.example.test')),
      );
      final config = await RelayServerConfig.fromProtectedDefines(
        encrypted: definitions[relayServerBlobDefine]!,
        key: definitions[relayServerKeyDefine]!,
      );
      expect(config.isPinned, isTrue);
      expect(
        config
            .requireAllowed(Uri.parse(source['server_base_url'] as String))
            .host,
        'private-relay.example.test',
      );
      expect(
        config.allows(Uri.parse('https://elsewhere.example.test')),
        isFalse,
      );
      expect(
        () =>
            config.requireAllowed(Uri.parse('https://elsewhere.example.test')),
        throwsFormatException,
      );
      expect(config.toString(), isNot(contains('private-relay.example.test')));
    },
  );

  test(
    'tampered, missing or wrong keys cannot fall back to a public server',
    () async {
      final definitions = await protectRelayServerConfiguration(source);
      final encrypted = base64Url.decode(definitions[relayServerBlobDefine]!);
      encrypted[encrypted.length - 1] ^= 1;
      for (final candidate in [
        {
          'encrypted': base64UrlEncode(encrypted),
          'key': definitions[relayServerKeyDefine]!,
        },
        {
          'encrypted': definitions[relayServerBlobDefine]!,
          'key': base64UrlEncode(Uint8List(32)),
        },
        {'encrypted': definitions[relayServerBlobDefine]!, 'key': ''},
        {'encrypted': '', 'key': definitions[relayServerKeyDefine]!},
      ]) {
        await expectLater(
          RelayServerConfig.fromProtectedDefines(
            encrypted: candidate['encrypted']!,
            key: candidate['key']!,
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('config only accepts the documented HTTPS origin schema', () {
    for (final config in [
      {'v': 2, 'server_base_url': 'https://example.test'},
      {'v': 1.0, 'server_base_url': 'https://example.test'},
      {'v': 1, 'server_base_url': 'http://example.test'},
      {'v': 1, 'server_base_url': 'https://example.test/v1'},
      {'v': 1, 'server_base_url': 'https://user:secret@example.test'},
      {'v': 1, 'server_base_url': 'https://example.test?secret=value'},
      {
        'v': 1,
        'server_base_url': 'https://example.test',
        'device_token': 'forbidden',
      },
    ]) {
      expect(() => RelayServerConfig.fromJson(config), throwsFormatException);
    }
  });
}
