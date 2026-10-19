import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/update/release_source.dart';
import 'package:ryza_chat_mvp/src/update/update_manifest.dart';
import 'package:ryza_chat_mvp/src/update/update_models.dart';
import 'package:ryza_chat_mvp/src/update/update_service.dart';

Map<String, dynamic> _payload({
  int releaseSeq = 47,
  String channel = 'stable',
}) => {
  'schema_version': 1,
  'canonicalization': 'aar-cjson-v1',
  'release_id': 'release-$releaseSeq',
  'release_seq': releaseSeq,
  'display_version': '1.0.4.${releaseSeq - 45}',
  'channel': channel,
  'platform': 'android',
  'updater_protocol_version': 1,
  'published_at': '2026-10-19T08:00:00Z',
  'runtime_compat_id': 'runtime-$releaseSeq',
  'resource_api_version': 1,
  'target_apk': {
    'version_code': releaseSeq,
    'package_name': 'com.example.app',
    'abis': ['arm64-v8a'],
    'sha256': 'b' * 64,
    'certificate_sha256': 'c' * 64,
    'urls': ['https://downloads.example.test/app.apk'],
    'size': 1000,
  },
  'apk_deltas': [],
  'notes': {'release_id': 'release-$releaseSeq'},
};

Future<({FetchedUpdateManifest fetched, UpdateManifestVerifier verifier})>
_fixture({int releaseSeq = 47, String channel = 'stable'}) async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final payload = _payload(releaseSeq: releaseSeq, channel: channel);
  final signature = await algorithm.sign(
    canonicalJsonBytes(payload),
    keyPair: keyPair,
  );
  final envelope = UpdateManifestEnvelope.fromJson({
    'payload': payload,
    'signature': {
      'key_id': 'key-1',
      'algorithm': 'Ed25519',
      'signed_object': 'payload',
      'canonicalization': 'aar-cjson-v1',
      'value_base64': base64.encode(signature.bytes),
    },
  });
  return (
    fetched: FetchedUpdateManifest(
      envelope: envelope,
      origin: UpdateReleaseOrigin.gitee,
      endpoint: Uri.parse('https://gitee.example.test/stable.json'),
    ),
    verifier: UpdateManifestVerifier(
      trustedKeys: {'key-1': (await keyPair.extractPublicKey()).bytes},
    ),
  );
}

final class _MemoryStore implements UpdatePreferencesStore {
  _MemoryStore([this.value = const UpdatePreferences()]);

  UpdatePreferences value;
  int writes = 0;

  @override
  Future<UpdatePreferences> load() async => value;

  @override
  Future<void> save(UpdatePreferences preferences) async {
    value = preferences;
    writes++;
  }
}

final class _FakeSource implements ReleaseSource {
  _FakeSource(this.fetched);

  FetchedUpdateManifest fetched;
  int calls = 0;
  UpdateSourcePreference? lastPreference;

  @override
  Future<FetchedUpdateManifest> fetchLatest({
    UpdateSourcePreference preference = UpdateSourcePreference.automatic,
  }) async {
    calls++;
    lastPreference = preference;
    return fetched;
  }
}

InstalledUpdateState _installed() => InstalledUpdateState(
  releaseSeq: 46,
  displayVersion: '1.0.4.1',
  nativeBuild: 46,
  packageName: 'com.example.app',
  channel: 'stable',
  platform: 'android',
  runtimeCompatId: 'runtime-46',
  resourceApiVersion: 1,
  updaterProtocolVersion: 1,
  supportedAbis: const {'arm64-v8a'},
  apkSha256: 'a' * 64,
  certificateSha256: 'c' * 64,
);

void main() {
  test('disabled automatic checks do not touch the network', () async {
    final fixture = await _fixture();
    final source = _FakeSource(fixture.fetched);
    final service = UpdateService(
      source: source,
      verifier: fixture.verifier,
      store: _MemoryStore(const UpdatePreferences(autoCheck: false)),
    );

    final result = await service.check(_installed());

    expect(result.status, UpdateCheckStatus.disabled);
    expect(source.calls, 0);
  });

  test('foreground checks are durably throttled', () async {
    final fixture = await _fixture();
    final source = _FakeSource(fixture.fetched);
    final now = DateTime.utc(2026, 10, 19, 10);
    final store = _MemoryStore(
      UpdatePreferences(lastCheckAt: now.subtract(const Duration(minutes: 5))),
    );
    final service = UpdateService(
      source: source,
      verifier: fixture.verifier,
      store: store,
      clock: () => now,
    );

    final result = await service.check(
      _installed(),
      trigger: UpdateCheckTrigger.foreground,
    );

    expect(result.status, UpdateCheckStatus.throttled);
    expect(source.calls, 0);
  });

  test(
    'dismissal suppresses a release for 24h but manual check bypasses it',
    () async {
      final fixture = await _fixture();
      final source = _FakeSource(fixture.fetched);
      var now = DateTime.utc(2026, 10, 19, 10);
      final store = _MemoryStore();
      final service = UpdateService(
        source: source,
        verifier: fixture.verifier,
        store: store,
        clock: () => now,
      );

      expect(
        (await service.check(_installed())).status,
        UpdateCheckStatus.updateAvailable,
      );
      await service.dismissRelease('release-47');
      now = now.add(const Duration(hours: 1));
      expect(
        (await service.check(_installed())).status,
        UpdateCheckStatus.suppressed,
      );
      expect(
        (await service.check(_installed(), manual: true)).status,
        UpdateCheckStatus.updateAvailable,
      );
      expect(store.value.highestSeenReleaseSeq, 47);
      expect(store.value.lastSuccessfulCheckAt, isNotNull);
    },
  );

  test(
    'a signed older release cannot roll back the highest seen sequence',
    () async {
      final fixture = await _fixture(releaseSeq: 47);
      final source = _FakeSource(fixture.fetched);
      final store = _MemoryStore(
        const UpdatePreferences(highestSeenReleaseSeq: 50),
      );
      final service = UpdateService(
        source: source,
        verifier: fixture.verifier,
        store: store,
      );

      final result = await service.check(_installed());

      expect(result.status, UpdateCheckStatus.failed);
      expect(result.errorCode, 'release_replay');
      expect(store.value.highestSeenReleaseSeq, 50);
    },
  );

  test(
    'a release sequence remains bound to one immutable release id',
    () async {
      final fixture = await _fixture(releaseSeq: 47);
      final source = _FakeSource(fixture.fetched);
      final store = _MemoryStore(
        const UpdatePreferences(
          highestSeenReleaseSeq: 47,
          highestSeenReleaseId: 'different-release-47',
        ),
      );
      final service = UpdateService(
        source: source,
        verifier: fixture.verifier,
        store: store,
      );

      final result = await service.check(_installed());

      expect(result.status, UpdateCheckStatus.failed);
      expect(result.errorCode, 'release_identity_conflict');
      expect(store.value.highestSeenReleaseId, 'different-release-47');
    },
  );

  test(
    'first successful check stores the immutable release identity',
    () async {
      final fixture = await _fixture(releaseSeq: 47);
      final store = _MemoryStore();
      final service = UpdateService(
        source: _FakeSource(fixture.fetched),
        verifier: fixture.verifier,
        store: store,
      );

      final result = await service.check(_installed());

      expect(result.status, UpdateCheckStatus.updateAvailable);
      expect(store.value.highestSeenReleaseSeq, 47);
      expect(store.value.highestSeenReleaseId, 'release-47');
      expect(
        store.value.highestSeenPayloadSha256,
        matches(RegExp(r'^[a-f0-9]{64}$')),
      );
    },
  );

  test('same release identity cannot replace signed payload bytes', () async {
    final fixture = await _fixture(releaseSeq: 47);
    final store = _MemoryStore(
      const UpdatePreferences(
        highestSeenReleaseSeq: 47,
        highestSeenReleaseId: 'release-47',
        highestSeenPayloadSha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
      ),
    );
    final service = UpdateService(
      source: _FakeSource(fixture.fetched),
      verifier: fixture.verifier,
      store: store,
    );
    expect(
      (await service.check(_installed())).errorCode,
      'release_identity_conflict',
    );
  });

  test(
    'a signed foreign channel cannot poison the replay checkpoint',
    () async {
      final beta = await _fixture(releaseSeq: 100, channel: 'beta');
      final stable = await _fixture(releaseSeq: 49);
      final source = _FakeSource(beta.fetched);
      final store = _MemoryStore();
      final betaService = UpdateService(
        source: source,
        verifier: beta.verifier,
        store: store,
      );
      expect(
        (await betaService.check(_installed())).errorCode,
        'channel_mismatch',
      );
      expect(store.value.highestSeenReleaseSeq, 0);
      source.fetched = stable.fetched;
      final stableService = UpdateService(
        source: source,
        verifier: stable.verifier,
        store: store,
      );
      expect(
        (await stableService.check(_installed())).status,
        UpdateCheckStatus.updateAvailable,
      );
      expect(store.value.highestSeenReleaseSeq, 49);
    },
  );

  test('source preference is persisted and forwarded', () async {
    final fixture = await _fixture();
    final source = _FakeSource(fixture.fetched);
    final store = _MemoryStore();
    final service = UpdateService(
      source: source,
      verifier: fixture.verifier,
      store: store,
    );

    await service.setSourcePreference(UpdateSourcePreference.github);
    await service.check(_installed());

    expect(store.value.sourcePreference, UpdateSourcePreference.github);
    expect(source.lastPreference, UpdateSourcePreference.github);
  });
}
