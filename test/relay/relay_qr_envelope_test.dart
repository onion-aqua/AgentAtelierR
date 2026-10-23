import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/relay/relay_protocol.dart';
import 'package:ryza_chat_mvp/src/relay/relay_qr_envelope.dart';

const _fixtureRoot = 'test/relay/fixtures';
const _publicKeyHex =
    '71e74b62b1df770727468ad133620516a19e604d5295b0ce499213b62cf07aa9';
const _testSecret =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
final _now = DateTime.utc(2029, 1, 2, 3, 4, 5);

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('$_fixtureRoot/$name').readAsStringSync())
        as Map<String, dynamic>;

List<Map<String, dynamic>> _rows(Map<String, dynamic> fixture, String field) =>
    (fixture[field] as List).cast<Map<String, dynamic>>();

Map<String, Object?> _pairing() => {
  'type': 'agent-relay-pair',
  'v': 1,
  'server_base_url': 'https://relay.example.invalid',
  'pairing_id': '12345678-1234-4123-8123-123456789abc',
  'pairing_secret': _testSecret,
  'expires_at': '2030-01-02T03:09:05.000Z',
};

List<int> _fromHex(String value) => [
  for (var index = 0; index < value.length; index += 2)
    int.parse(value.substring(index, index + 2), radix: 16),
];

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

String _wrapRaw(List<int> value) =>
    '$relayQrEnvelopePrefix${base64UrlEncode(value).replaceAll('=', '')}';

Uint8List _unwrapRaw(String value) => base64Url.decode(
  base64Url.normalize(value.substring(relayQrEnvelopePrefix.length)),
);

// Independent test-only encoder. Fixed nonces never enter application code.
Future<String> _encryptBytes(
  List<int> plaintext, {
  List<int>? nonce,
  List<int>? key,
  String aad = relayQrEnvelopePrefix,
}) async {
  final box = await AesGcm.with256bits().encrypt(
    plaintext,
    secretKey: SecretKey(key ?? _fromHex(_publicKeyHex)),
    nonce: nonce ?? List<int>.generate(12, (index) => index),
    aad: utf8.encode(aad),
  );
  return _wrapRaw([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}

Future<String> _encrypt(
  String plaintext, {
  String aad = relayQrEnvelopePrefix,
}) => _encryptBytes(utf8.encode(plaintext), aad: aad);

Future<void> _expectInvalid(Future<Object?> Function() operation) async {
  Object? failure;
  try {
    await operation();
  } on Object catch (error) {
    failure = error;
  }
  expect(failure, isA<FormatException>());
  if (failure is! FormatException) return;
  expect(failure.message, invalidRelayQrMessage);
  expect(failure.source, isNull);
  expect(failure.offset, isNull);
  expect(failure.toString(), isNot(contains(_testSecret)));
  expect(failure.toString(), isNot(contains('relay.example.invalid')));
  expect(failure.toString(), isNot(contains(relayQrEnvelopePrefix)));
  expect(failure.toString(), isNot(contains('pairing_secret')));
}

void main() {
  final independent = _fixture('qr-envelope-v2.json');
  final harness = _fixture('harness-qr-envelope-v2.json');
  final randomHarness = _fixture('harness-random-qr-v2.json');

  test(
    'public compatibility key and wire metadata agree across languages',
    () async {
      final key = await Sha256().hash(utf8.encode(relayQrCompatibilitySeed));
      expect(_hex(key.bytes), _publicKeyHex);
      expect(independent['derived_key_hex'], _publicKeyHex);
      expect(harness['public_compat_key_hex'], _publicKeyHex);
      for (final fixture in [independent, harness]) {
        expect(fixture['prefix'], relayQrEnvelopePrefix);
        expect(fixture['aad_utf8'], relayQrEnvelopePrefix);
        expect(fixture['algorithm'], 'AES-256-GCM');
      }
      expect(harness['nonce_bytes'], 12);
      expect(harness['tag_bytes'], 16);
      expect(harness['public_compat_key_seed_utf8'], relayQrCompatibilitySeed);
      expect(independent['key_seed_utf8'], relayQrCompatibilitySeed);
    },
  );

  for (final vector in _rows(independent, 'vectors')) {
    test('independent Node encoding decodes: ${vector['name']}', () async {
      final plaintext = vector['plaintext_utf8'] as String;
      final envelope = vector['envelope'] as String;
      expect(await decodeRelayQrEnvelope(envelope), plaintext);
      expect(
        await _encryptBytes(
          utf8.encode(plaintext),
          nonce: _fromHex(vector['nonce_hex'] as String),
        ),
        envelope,
      );
      final pairing = await PairingQr.parseScanned(envelope, now: _now);
      final original = jsonDecode(plaintext) as Map<String, dynamic>;
      expect(pairing.origin.toString(), original['server_base_url']);
      expect(pairing.pairingId, original['pairing_id']);
      expect(pairing.secret, original['pairing_secret']);
      expect(pairing.toString(), 'PairingQr(redacted)');
    });
  }

  for (final vector in _rows(harness, 'cases')) {
    test(
      'actual Harness vector decodes without UTF-8 loss: ${vector['id']}',
      () async {
        final plaintext = vector['plaintext'] as String;
        final envelope = vector['envelope'] as String;
        final decoded = await decodeRelayQrEnvelope(envelope);
        expect(decoded, plaintext);
        expect(utf8.encode(decoded), utf8.encode(plaintext));
        final original = jsonDecode(plaintext) as Map<String, dynamic>;
        final pairing = await PairingQr.parseScanned(envelope, now: _now);
        expect(pairing.origin.toString(), original['server_base_url']);
        expect(pairing.pairingId, original['pairing_id']);
        expect(pairing.secret, original['pairing_secret']);
        final raw = _unwrapRaw(envelope);
        expect(_hex(raw.sublist(0, 12)), vector['nonce_hex']);
        expect(
          _hex(raw.sublist(12, raw.length - 16)),
          vector['ciphertext_hex'],
        );
        expect(_hex(raw.sublist(raw.length - 16)), vector['tag_hex']);
      },
    );
  }

  test('real Harness random generation uses distinct nonces and all outputs interoperate', () async {
    final envelopes = (randomHarness['envelopes'] as List).cast<String>();
    final plaintext = randomHarness['plaintext'] as String;
    expect(envelopes, hasLength(16));
    expect(envelopes.toSet(), hasLength(envelopes.length));
    final nonces = <String>{};
    for (final envelope in envelopes) {
      expect(await decodeRelayQrEnvelope(envelope), plaintext);
      final pairing = await PairingQr.parseScanned(envelope, now: _now);
      expect(pairing.secret, _testSecret);
      expect(envelope, isNot(contains('relay.example.invalid')));
      expect(envelope, isNot(contains(_testSecret)));
      nonces.add(_hex(_unwrapRaw(envelope).sublist(0, 12)));
    }
    expect(nonces, hasLength(envelopes.length));
  });

  for (final legacy in _rows(harness, 'legacy_v1')) {
    test('legacy plaintext v1 remains supported: ${legacy['id']}', () async {
      final input = legacy['input'] as String;
      expect(await decodeRelayQrEnvelope(input), input);
      final parsed = await PairingQr.parseScanned(input, now: _now);
      expect(parsed.secret, _testSecret);
    });
  }

  test(
    'legacy v1 without expires_at remains valid after arbitrary local time',
    () async {
      final plaintext = jsonEncode(_pairing()..remove('expires_at'));
      final legacy = await PairingQr.parseScanned(
        plaintext,
        now: DateTime.utc(2100),
      );
      final wrapped = await PairingQr.parseScanned(
        await _encrypt(plaintext),
        now: DateTime.utc(2100),
      );
      expect(legacy.secret, _testSecret);
      expect(wrapped.secret, legacy.secret);
    },
  );

  for (final invalid in _rows(harness, 'invalid_cases')) {
    test(
      'actual Harness invalid fixture is rejected: ${invalid['id']}',
      () async {
        final input = invalid['input'] as String;
        await _expectInvalid(() => decodeRelayQrEnvelope(input));
        await _expectInvalid(() => PairingQr.parseScanned(input, now: _now));
      },
    );
  }

  final validEnvelope = _rows(harness, 'cases').first['envelope'] as String;
  final malformed = <String, String>{
    'empty': '',
    'bare prefix': relayQrEnvelopePrefix,
    'one Base64URL character': '${relayQrEnvelopePrefix}A',
    'unknown v1 envelope': 'ryzasync:v1:$validEnvelope',
    'unknown future version': 'ryzasync:v999:$validEnvelope',
    'leading whitespace': ' $validEnvelope',
    'trailing whitespace': '$validEnvelope ',
    'URL query suffix': '$validEnvelope?secret=$_testSecret',
    'standard Base64 plus': '$relayQrEnvelopePrefix${'+' * 40}',
    'standard Base64 slash': '$relayQrEnvelopePrefix${'/' * 40}',
    'percent encoding': '$relayQrEnvelopePrefix%41%41%41%41',
    'only nonce': _wrapRaw(List<int>.filled(12, 0)),
    'nonce plus incomplete tag': _wrapRaw(List<int>.filled(27, 0)),
    'nonce plus tag without ciphertext': _wrapRaw(List<int>.filled(28, 0)),
    'oversized envelope':
        '$relayQrEnvelopePrefix${'A' * maxRelayQrEnvelopeLength}',
  };
  for (final entry in malformed.entries) {
    test('malformed envelope: ${entry.key}', () async {
      // Leading whitespace cannot be a legacy JSON object; parseScanned must
      // reject it even though the unwrap layer preserves arbitrary v1 text.
      if (entry.key != 'leading whitespace') {
        await _expectInvalid(() => decodeRelayQrEnvelope(entry.value));
      }
      await _expectInvalid(
        () => PairingQr.parseScanned(entry.value, now: _now),
      );
    });
  }

  test('noncanonical unused Base64URL bits are rejected', () async {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final envelope = await _encrypt('a');
    final encoded = envelope.substring(relayQrEnvelopePrefix.length);
    expect(encoded.length % 4, 3);
    final last = alphabet.indexOf(encoded[encoded.length - 1]);
    expect(last & 3, 0);
    final malformed =
        '$relayQrEnvelopePrefix${encoded.substring(0, encoded.length - 1)}${alphabet[last | 1]}';
    // Dart's Base64 decoder already rejects nonzero unused bits. The public
    // decoder must still replace that low-level exception and its source.
    expect(malformed, isNot(envelope));
    await _expectInvalid(() => decodeRelayQrEnvelope(malformed));
    await _expectInvalid(() => PairingQr.parseScanned(malformed, now: _now));
  });

  for (final component in ['nonce', 'ciphertext', 'tag']) {
    test('bit modification in $component fails authentication', () async {
      final raw = _unwrapRaw(validEnvelope);
      final index = switch (component) {
        'nonce' => 0,
        'ciphertext' => 12,
        _ => raw.length - 1,
      };
      raw[index] ^= 1;
      final modified = _wrapRaw(raw);
      await _expectInvalid(() => decodeRelayQrEnvelope(modified));
      await _expectInvalid(() => PairingQr.parseScanned(modified, now: _now));
    });
  }

  test('wrong AAD and key are rejected without plaintext fallback', () async {
    final plaintext = jsonEncode(_pairing());
    final inputs = [
      await _encrypt(plaintext, aad: 'ryzasync:v2'),
      await _encrypt(plaintext, aad: ''),
      await _encryptBytes(utf8.encode(plaintext), key: List<int>.filled(32, 0)),
      '$relayQrEnvelopePrefix$plaintext',
    ];
    for (final input in inputs) {
      await _expectInvalid(() => decodeRelayQrEnvelope(input));
      await _expectInvalid(() => PairingQr.parseScanned(input, now: _now));
    }
  });

  test(
    'plaintext byte limits are enforced for UTF-8 and legacy inputs',
    () async {
      final atLimit = 'x' * maxRelayQrPlaintextBytes;
      expect(await decodeRelayQrEnvelope(await _encrypt(atLimit)), atLimit);
      expect(await decodeRelayQrEnvelope(atLimit), atLimit);
      for (final input in ['x' * (maxRelayQrPlaintextBytes + 1), '测' * 1366]) {
        await _expectInvalid(() => decodeRelayQrEnvelope(input));
        await _expectInvalid(
          () async => decodeRelayQrEnvelope(await _encrypt(input)),
        );
      }
    },
  );

  test(
    'authenticated empty and malformed UTF-8 plaintext are rejected',
    () async {
      for (final plaintext in <List<int>>[
        [],
        [0xc0, 0xaf],
        [0xed, 0xa0, 0x80],
        [0xf0, 0x9f, 0x9a],
      ]) {
        final input = await _encryptBytes(plaintext);
        await _expectInvalid(() => decodeRelayQrEnvelope(input));
        await _expectInvalid(() => PairingQr.parseScanned(input, now: _now));
      }
    },
  );

  final invalidJson = <String, String>{
    'unclosed object': '{"pairing_secret":"$_testSecret"',
    'string': jsonEncode(_testSecret),
    'array': jsonEncode([_pairing()]),
    'null': 'null',
    'number': '1',
    'wrong type': jsonEncode(_pairing()..['type'] = 'other'),
    'wrong protocol version': jsonEncode(_pairing()..['v'] = 2),
    'string version': jsonEncode(_pairing()..['v'] = '1'),
    'missing ID': jsonEncode(_pairing()..remove('pairing_id')),
    'bad ID': jsonEncode(_pairing()..['pairing_id'] = 'bad'),
    'missing secret': jsonEncode(_pairing()..remove('pairing_secret')),
    'short secret': jsonEncode(_pairing()..['pairing_secret'] = 'a' * 63),
    'uppercase secret': jsonEncode(_pairing()..['pairing_secret'] = 'A' * 64),
    'numeric secret': jsonEncode(_pairing()..['pairing_secret'] = 123),
    'missing origin': jsonEncode(_pairing()..remove('server_base_url')),
  };
  for (final entry in invalidJson.entries) {
    test(
      'authenticated plaintext still validates protocol: ${entry.key}',
      () async {
        final envelope = await _encrypt(entry.value);
        expect(await decodeRelayQrEnvelope(envelope), entry.value);
        await _expectInvalid(() => PairingQr.parseScanned(envelope, now: _now));
        await _expectInvalid(
          () => PairingQr.parseScanned(entry.value, now: _now),
        );
      },
    );
  }

  for (final origin in [
    'http://relay.example.invalid',
    'https://user:$_testSecret@relay.example.invalid',
    'https://relay.example.invalid/path',
    'https://relay.example.invalid?secret=$_testSecret',
    'https://relay.example.invalid#$_testSecret',
    'https://',
    '',
  ]) {
    test(
      'HTTPS origin validation is retained: ${origin.split(':').first} ${origin.length}',
      () async {
        final envelope = await _encrypt(
          jsonEncode(_pairing()..['server_base_url'] = origin),
        );
        await _expectInvalid(() => PairingQr.parseScanned(envelope, now: _now));
      },
    );
  }

  for (final expiry in <Object?>[
    null,
    123,
    '',
    'not-a-time',
    '2029-01-02T03:04:05.000Z', // Equal to now is expired.
    '2029-01-02T03:04:04.999Z',
    '2030-01-02T03:09:05+00:00',
    '2030-01-02T03:09:05',
    '2030-02-30T03:09:05.000Z',
    '2030-13-01T03:09:05.000Z',
    '2030-01-02T25:09:05.000Z',
    '2030-01-02T03:09:05.000001Z',
  ]) {
    test('expiry remains mandatory-valid when supplied: $expiry', () async {
      final plaintext = jsonEncode(_pairing()..['expires_at'] = expiry);
      await _expectInvalid(() => PairingQr.parseScanned(plaintext, now: _now));
      final envelope = await _encrypt(plaintext);
      await _expectInvalid(() => PairingQr.parseScanned(envelope, now: _now));
    });
  }

  test(
    'expiry one millisecond in future and UTC-normalized now are valid',
    () async {
      final plaintext = jsonEncode(
        _pairing()..['expires_at'] = '2029-01-02T03:04:05.001Z',
      );
      final localOffsetNow = DateTime.parse('2029-01-02T11:04:05+08:00');
      final parsed = await PairingQr.parseScanned(
        await _encrypt(plaintext),
        now: localOffsetNow,
      );
      expect(parsed.secret, _testSecret);
    },
  );
}
