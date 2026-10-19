import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/update/update_build_config.dart';

void main() {
  final config = {
    'v': 1,
    'gitee_latest_url': 'https://gitee.example.test/releases/latest.json',
    'cache_latest_url': 'https://updates.example.test/android/stable.json',
    'github_latest_url': 'https://github.example.test/releases/latest.json',
    'trusted_keys': {
      'release-2026': base64.encode(List<int>.generate(32, (index) => index)),
    },
    'resource_asset_key_ids': ['character-assets-2026'],
    'release_seq': 46,
    'channel': 'stable',
    'runtime_compat_id': 'android-bootstrap-v1',
    'resource_api_version': 1,
    'updater_protocol_version': 1,
  };

  test('missing protected defines disables networking', () async {
    final value = await UpdateBuildConfig.fromProtectedDefines(
      encrypted: '',
      key: '',
    );
    expect(value.enabled, isFalse);
    expect(value.sources, isNull);
  });

  test(
    'protected build config round trips without plaintext defaults',
    () async {
      final protected = await protectUpdateBuildConfiguration(
        config,
        key: Uint8List.fromList(List<int>.filled(32, 7)),
      );
      final value = await UpdateBuildConfig.fromProtectedDefines(
        encrypted: protected[updateConfigBlobDefine]!,
        key: protected[updateConfigKeyDefine]!,
      );
      expect(value.enabled, isTrue);
      expect(value.releaseSeq, 46);
      expect(value.sources!.giteeLatest!.host, 'gitee.example.test');
      expect(value.trustedKeys['release-2026'], hasLength(32));
      expect(value.resourceAssetKeyIds, {'character-assets-2026'});
    },
  );

  test('plaintext endpoints are rejected', () {
    expect(
      () => UpdateBuildConfig.fromJson({
        ...config,
        'cache_latest_url': 'http://updates.example.test/latest.json',
      }),
      throwsFormatException,
    );
  });

  test('resource key trust must be explicitly embedded', () {
    expect(
      () => UpdateBuildConfig.fromJson({
        ...config,
        'resource_asset_key_ids': <String>[],
      }),
      throwsFormatException,
    );
    expect(
      () => UpdateBuildConfig.fromJson({
        ...config,
        'resource_asset_key_ids': ['character-assets-2026', 'bad/key'],
      }),
      throwsFormatException,
    );
  });
}
