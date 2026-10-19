import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/update/update_models.dart';

UpdateManifest _manifest({
  int releaseSeq = 47,
  int versionCode = 47,
  String runtime = 'runtime-47',
  Set<String> resourceRuntimes = const {'runtime-46', 'runtime-47'},
  int deltaSize = 200,
  bool includeResource = true,
}) {
  final target = UpdateTargetApk(
    versionCode: versionCode,
    packageName: 'com.example.app',
    abis: const {'arm64-v8a'},
    sha256: 'b' * 64,
    certificateSha256: 'c' * 64,
    urls: [Uri.parse('https://example.test/app.apk')],
    size: 1000,
  );
  return UpdateManifest(
    schemaVersion: 1,
    releaseId: 'release-$releaseSeq',
    releaseSeq: releaseSeq,
    displayVersion: '1.0.4.2',
    channel: 'stable',
    platform: 'android',
    updaterProtocolVersion: 1,
    publishedAt: DateTime.utc(2026, 10, 19),
    runtimeCompatId: runtime,
    resourceApiVersion: 1,
    targetApk: target,
    apkDeltas: [
      ApkDelta(
        baseSha256: 'a' * 64,
        targetSha256: target.sha256,
        format: 'hdiffpatch',
        patchProtocolVersion: 1,
        patchSha256: 'd' * 64,
        urls: [Uri.parse('https://example.test/app.patch')],
        size: deltaSize,
      ),
    ],
    resourceSnapshot: includeResource
        ? ResourceSnapshot(
            id: 'resources-47',
            schemaVersion: 1,
            compatibleRuntimeIds: resourceRuntimes,
            assetKeyId: 'key-1',
            manifestSha256: 'e' * 64,
            manifestUrl: Uri.parse('https://example.test/resources.json'),
            size: 300,
          )
        : null,
    notes: const UpdateReleaseNotes(releaseId: 'release-47'),
    signedPayload: const {},
  );
}

InstalledUpdateState _installed({
  String? apkSha =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  String runtime = 'runtime-46',
  String? snapshot = 'resources-46',
}) => InstalledUpdateState(
  releaseSeq: 46,
  displayVersion: '1.0.4.1',
  nativeBuild: 46,
  packageName: 'com.example.app',
  channel: 'stable',
  platform: 'android',
  runtimeCompatId: runtime,
  resourceApiVersion: 1,
  updaterProtocolVersion: 1,
  supportedAbis: const {'arm64-v8a'},
  supportedDeltaFormats: const {'hdiffpatch'},
  apkSha256: apkSha,
  certificateSha256: 'c' * 64,
  resourceSnapshotId: snapshot,
);

void main() {
  const planner = UpdatePlanner();

  test('selects only an exact base-to-target delta', () {
    final plan = planner.plan(_installed(), _manifest());
    expect(plan.isAvailable, isTrue);
    expect(plan.apk?.kind, ApkUpdateKind.delta);
    expect(plan.apk?.delta?.baseSha256, 'a' * 64);
    expect(plan.resource?.activation, ResourceActivation.immediate);
    expect(plan.downloadSize, 500);
  });

  test('unknown APK hash falls back to the complete target APK', () {
    final plan = planner.plan(_installed(apkSha: null), _manifest());
    expect(plan.apk?.kind, ApkUpdateKind.full);
    expect(plan.apk?.delta, isNull);
  });

  test('unknown APK hash treats the installed versionCode as current', () {
    final plan = planner.plan(
      _installed(apkSha: null, snapshot: null),
      _manifest(releaseSeq: 46, versionCode: 46, includeResource: false),
    );
    expect(plan.isAvailable, isTrue);
    expect(plan.apk, isNull);
    expect(plan.hasUpdate, isFalse);
  });

  test(
    'manual APK installation can still fetch its missing resource snapshot',
    () {
      final plan = planner.plan(
        _installed(apkSha: null, snapshot: null),
        _manifest(releaseSeq: 46, versionCode: 46),
      );
      expect(plan.isAvailable, isTrue);
      expect(plan.apk, isNull);
      expect(plan.resource?.snapshot.id, 'resources-47');
      expect(plan.hasUpdate, isTrue);
    },
  );

  test('oversized or unsupported patches fall back to full APK', () {
    final oversized = planner.plan(_installed(), _manifest(deltaSize: 751));
    expect(oversized.apk?.kind, ApkUpdateKind.full);

    final unsupported = InstalledUpdateState(
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
      supportedDeltaFormats: const {'another-format'},
      apkSha256: 'a' * 64,
      certificateSha256: 'c' * 64,
    );
    expect(
      planner.plan(unsupported, _manifest()).apk?.kind,
      ApkUpdateKind.full,
    );
  });

  test('resource waits for APK when only target runtime is compatible', () {
    final plan = planner.plan(
      _installed(runtime: 'runtime-legacy'),
      _manifest(resourceRuntimes: const {'runtime-47'}),
    );
    expect(plan.apk, isNotNull);
    expect(plan.resource?.activation, ResourceActivation.afterApkInstall);
  });

  test('does not plan the resource snapshot that is already active', () {
    final plan = planner.plan(
      _installed(snapshot: 'resources-47'),
      _manifest(),
    );
    expect(plan.resource, isNull);
    expect(plan.apk, isNotNull);
  });

  test('rejects signature, ABI, protocol and rollback incompatibilities', () {
    final wrongCertificate = InstalledUpdateState(
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
      certificateSha256: 'f' * 64,
    );
    expect(
      planner.plan(wrongCertificate, _manifest()).unavailableReason,
      'certificate_mismatch',
    );

    final rollback = _manifest(releaseSeq: 45, versionCode: 45);
    expect(
      planner.plan(_installed(), rollback).unavailableReason,
      'release_rollback',
    );
  });
}
