import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/update/update_manifest.dart';
import 'package:ryza_chat_mvp/src/update/update_models.dart';

Map<String, dynamic> _payload() => {
  'schema_version': 1,
  'canonicalization': 'aar-cjson-v1',
  'release_id': 'release-47',
  'release_seq': 47,
  'display_version': '1.0.4.2',
  'channel': 'stable',
  'platform': 'android',
  'updater_protocol_version': 1,
  'published_at': '2026-10-19T08:00:00Z',
  'runtime_compat_id': 'android-runtime-47',
  'resource_api_version': 1,
  'target_apk': {
    'version_code': 47,
    'package_name': 'com.example.ryza_chat_mvp',
    'abis': ['arm64-v8a'],
    'sha256': 'b' * 64,
    'certificate_sha256': 'c' * 64,
    'urls': ['https://downloads.example.test/app-47.apk'],
    'size': 800000,
  },
  'apk_deltas': [
    {
      'base_sha256': 'a' * 64,
      'target_sha256': 'b' * 64,
      'format': 'hdiffpatch',
      'patch_protocol_version': 1,
      'patch_sha256': 'd' * 64,
      'urls': ['https://downloads.example.test/a-b.patch'],
      'size': 200000,
    },
  ],
  'resource_snapshot': {
    'id': 'resources-47',
    'schema_version': 1,
    'compatible_runtime_ids': ['android-runtime-46', 'android-runtime-47'],
    'asset_key_id': 'assets-key-1',
    'manifest_sha256': 'e' * 64,
    'manifest_url': 'https://downloads.example.test/resources-47.json',
    'size': 100000,
  },
  'notes': {
    'release_id': 'release-47',
    'gitee_url': 'https://gitee.com/example/releases/release-47',
    'github_url': 'https://github.com/example/releases/tag/release-47',
  },
};

Future<({UpdateManifestEnvelope envelope, List<int> publicKey})>
_signedEnvelope(Map<String, dynamic> payload) async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final signature = await algorithm.sign(
    canonicalJsonBytes(payload),
    keyPair: keyPair,
  );
  final publicKey = await keyPair.extractPublicKey();
  return (
    envelope: UpdateManifestEnvelope.fromJson({
      'payload': payload,
      'signature': {
        'key_id': 'release-key-1',
        'algorithm': 'Ed25519',
        'signed_object': 'payload',
        'canonicalization': 'aar-cjson-v1',
        'value_base64': base64.encode(signature.bytes),
      },
    }),
    publicKey: publicKey.bytes,
  );
}

void main() {
  test('aar-cjson-v1 matches the publisher cross-language fixture', () async {
    final input = jsonDecode(
      await File('test/fixtures/update/canonical-input.json').readAsString(),
    );
    final expected = (await File(
      'test/fixtures/update/canonical-payload.json',
    ).readAsString()).trimRight();
    final canonical = canonicalJsonEncode(input);
    final digest = await Sha256().hash(utf8.encode(canonical));
    final hex = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();

    expect(canonical, expected);
    expect(
      hex,
      'b824f3bec2a9db75971aa240eb29750cbc9fef603c63de884c39168b3256d43b',
    );
  });

  test('aar-cjson-v1 sorts keys and emits exact string escapes', () {
    final value = {
      'z': [true, null, -2],
      'a': 'quote" slash\\ \b\f\n\r\t ${String.fromCharCode(1)} 旅行😀',
    };
    expect(
      canonicalJsonEncode(value),
      '{"a":"quote\\" slash\\\\ \\b\\f\\n\\r\\t \\u0001 旅行😀","z":[true,null,-2]}',
    );
    expect(() => canonicalJsonEncode({'value': 1.0}), throwsFormatException);
    expect(
      () => canonicalJsonEncode({'value': String.fromCharCode(0xd800)}),
      throwsFormatException,
    );
  });

  test(
    'valid Ed25519 envelope verifies and preserves release identity',
    () async {
      final signed = await _signedEnvelope(_payload());
      final verifier = UpdateManifestVerifier(
        trustedKeys: {'release-key-1': signed.publicKey},
      );

      final manifest = await verifier.verify(signed.envelope);

      expect(manifest.releaseId, 'release-47');
      expect(manifest.releaseSeq, 47);
      expect(manifest.targetApk?.versionCode, 47);
      expect(manifest.apkDeltas.single.baseSha256, 'a' * 64);
      expect(manifest.resourceSnapshot?.id, 'resources-47');
    },
  );

  test('payload tampering and untrusted keys are rejected', () async {
    final payload = _payload();
    final signed = await _signedEnvelope(payload);
    final tamperedPayload =
        jsonDecode(jsonEncode(signed.envelope.payload)) as Map<String, dynamic>
          ..['release_seq'] = 48;
    final tampered = UpdateManifestEnvelope(
      payload: tamperedPayload,
      signature: signed.envelope.signature,
    );
    final verifier = UpdateManifestVerifier(
      trustedKeys: {'release-key-1': signed.publicKey},
    );

    await expectLater(
      verifier.verify(tampered),
      throwsA(
        isA<UpdateVerificationException>().having(
          (error) => error.code,
          'code',
          'signature_mismatch',
        ),
      ),
    );
    final other = await Ed25519().newKeyPair();
    await expectLater(
      UpdateManifestVerifier(
        trustedKeys: {'other-key': (await other.extractPublicKey()).bytes},
      ).verify(signed.envelope),
      throwsA(
        isA<UpdateVerificationException>().having(
          (error) => error.code,
          'code',
          'untrusted_key',
        ),
      ),
    );
  });

  test('strict schema rejects unknown fields and insecure artifact URLs', () {
    final unknown = jsonDecode(jsonEncode(_payload())) as Map<String, dynamic>
      ..['future_field'] = true;
    expect(() => parseUpdateManifestPayload(unknown), throwsFormatException);

    final insecure = jsonDecode(jsonEncode(_payload())) as Map<String, dynamic>;
    (insecure['target_apk'] as Map<String, dynamic>)['urls'] = [
      'http://downloads.example.test/app.apk',
    ];
    expect(() => parseUpdateManifestPayload(insecure), throwsFormatException);
  });

  test('display versions compare numeric components rather than decimals', () {
    expect(compareDisplayVersions('1.0.4.10', '1.0.4.9'), greaterThan(0));
    expect(compareDisplayVersions('1.0.4.1 MCP FishAudio', '1.0.4.1'), 0);
    expect(compareDisplayVersions('1.0.4', '1.0.4.0'), 0);
  });
}
