import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/update/apk_update_installer.dart';
import 'package:ryza_chat_mvp/src/update/release_source.dart';
import 'package:ryza_chat_mvp/src/update/update_build_config.dart';
import 'package:ryza_chat_mvp/src/update/update_dialog.dart';
import 'package:ryza_chat_mvp/src/update/update_downloader.dart';
import 'package:ryza_chat_mvp/src/update/update_manifest.dart';
import 'package:ryza_chat_mvp/src/update/update_models.dart';
import 'package:ryza_chat_mvp/src/update/update_notes_loader.dart';
import 'package:ryza_chat_mvp/src/update/update_runtime.dart';
import 'package:ryza_chat_mvp/src/update/update_service.dart';

final class _MemoryStore implements UpdatePreferencesStore {
  UpdatePreferences value = const UpdatePreferences();
  Completer<void>? nextLoadGate;

  @override
  Future<UpdatePreferences> load() async {
    final gate = nextLoadGate;
    nextLoadGate = null;
    if (gate != null) await gate.future;
    return value;
  }

  @override
  Future<void> save(UpdatePreferences preferences) async {
    value = preferences;
  }
}

final class _StaticSource implements ReleaseSource {
  _StaticSource(this.fetched);

  final FetchedUpdateManifest fetched;
  int calls = 0;

  @override
  Future<FetchedUpdateManifest> fetchLatest({
    UpdateSourcePreference preference = UpdateSourcePreference.automatic,
  }) async {
    calls++;
    return fetched;
  }
}

final class _Counter {
  int value = 0;
}

Map<String, dynamic> _manifestPayload() => {
  'schema_version': 1,
  'canonicalization': 'aar-cjson-v1',
  'release_id': 'release-51',
  'release_seq': 51,
  'display_version': '1.0.4.2',
  'channel': 'stable',
  'platform': 'android',
  'updater_protocol_version': 1,
  'published_at': '2026-10-19T08:00:00Z',
  'runtime_compat_id': 'runtime-51',
  'resource_api_version': 1,
  'target_apk': {
    'version_code': 51,
    'package_name': 'com.example.app',
    'abis': ['arm64-v8a'],
    'sha256': 'b' * 64,
    'certificate_sha256': 'c' * 64,
    'urls': ['https://downloads.example.test/app.apk'],
    'size': 1024,
  },
  'apk_deltas': [],
  'notes': {
    'release_id': 'release-51',
    'github_url': 'https://github.com/example/releases/tag/51',
    'cached_markdown_url': 'https://updates.example.test/release-51.md',
  },
};

InstalledUpdateState _installed() => InstalledUpdateState(
  releaseSeq: 50,
  displayVersion: '1.0.4.1',
  nativeBuild: 50,
  packageName: 'com.example.app',
  channel: 'stable',
  platform: 'android',
  runtimeCompatId: 'runtime-50',
  resourceApiVersion: 1,
  updaterProtocolVersion: 1,
  supportedAbis: const {'arm64-v8a'},
  apkSha256: 'a' * 64,
  certificateSha256: 'c' * 64,
);

Future<
  ({
    UpdateRuntime runtime,
    _StaticSource source,
    _MemoryStore store,
    _Counter notesRequests,
  })
>
_runtimeFixture({Completer<void>? firstNotesGate}) async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final payload = _manifestPayload();
  final signature = await algorithm.sign(
    canonicalJsonBytes(payload),
    keyPair: keyPair,
  );
  final source = _StaticSource(
    FetchedUpdateManifest(
      envelope: UpdateManifestEnvelope.fromJson({
        'payload': payload,
        'signature': {
          'key_id': 'key-1',
          'algorithm': 'Ed25519',
          'signed_object': 'payload',
          'canonicalization': 'aar-cjson-v1',
          'value_base64': base64.encode(signature.bytes),
        },
      }),
      origin: UpdateReleaseOrigin.gitee,
      endpoint: Uri.parse('https://gitee.example.test/stable.json'),
    ),
  );
  final store = _MemoryStore();
  final service = UpdateService(
    source: source,
    verifier: UpdateManifestVerifier(
      trustedKeys: {'key-1': (await keyPair.extractPublicKey()).bytes},
    ),
    store: store,
    clock: () => DateTime.utc(2026, 10, 19, 10),
  );
  final notesRequests = _Counter();
  final runtime = UpdateRuntime(
    buildConfig: const UpdateBuildConfig.disabled(),
    installed: _installed(),
    service: service,
    downloader: UpdateDownloader(
      supportDirectory: () async => Directory.systemTemp,
    ),
    installer: ApkUpdateInstaller(
      channel: const MethodChannel('test/update-runtime-state-installer'),
    ),
    notesLoader: UpdateNotesLoader(
      client: MockClient((request) async {
        notesRequests.value++;
        expect(
          request.url,
          Uri.parse('https://updates.example.test/release-51.md'),
        );
        if (notesRequests.value == 1 && firstNotesGate != null) {
          await firstNotesGate.future;
        }
        return http.Response(
          notesRequests.value == 1
              ? '# Runtime state fix\n\nUse automatic update.'
              : '# Refreshed release notes\n\nManual check completed.',
          200,
          headers: const {'content-type': 'text/markdown; charset=utf-8'},
        );
      }),
    ),
  );
  return (
    runtime: runtime,
    source: source,
    store: store,
    notesRequests: notesRequests,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'foreground throttle preserves the available update display state',
    () async {
      final fixture = await _runtimeFixture();
      final runtime = fixture.runtime;
      addTearDown(runtime.dispose);

      final startup = await runtime.check(trigger: UpdateCheckTrigger.startup);
      await pumpEventQueue();

      expect(startup.status, UpdateCheckStatus.updateAvailable);
      expect(runtime.lastCheck, same(startup));
      expect(runtime.phase, UpdateRuntimePhase.available);
      expect(runtime.plan?.manifest.releaseId, 'release-51');
      expect(runtime.origin, UpdateReleaseOrigin.gitee);
      expect(fixture.source.calls, 1);
      expect(runtime.notes, '# Runtime state fix\n\nUse automatic update.');
      expect(fixture.notesRequests.value, 1);

      final foreground = await runtime.check(
        trigger: UpdateCheckTrigger.foreground,
      );

      expect(foreground.status, UpdateCheckStatus.throttled);
      expect(fixture.source.calls, 1);
      expect(runtime.lastCheck, same(startup));
      expect(runtime.lastCheck?.status, UpdateCheckStatus.updateAvailable);
      expect(runtime.phase, UpdateRuntimePhase.available);
      expect(runtime.plan?.manifest.releaseId, 'release-51');
      expect(runtime.origin, UpdateReleaseOrigin.gitee);
      expect(runtime.notes, '# Runtime state fix\n\nUse automatic update.');
      expect(fixture.notesRequests.value, 1);
    },
  );

  testWidgets(
    'an open update prompt remains actionable after a throttled foreground check',
    (tester) async {
      final fixture = await _runtimeFixture();
      final runtime = fixture.runtime;
      addTearDown(runtime.dispose);
      final startup = await tester.runAsync(() async {
        final result = await runtime.check();
        for (
          var attempt = 0;
          attempt < 20 && runtime.notes == null;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        return result;
      });
      expect(startup?.status, UpdateCheckStatus.updateAvailable);
      expect(runtime.notes, '# Runtime state fix\n\nUse automatic update.');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UpdatePromptDialog(
              runtime: runtime,
              language: AppLanguage.chinese,
            ),
          ),
        ),
      );

      expect(find.text('1.0.4.1  →  1.0.4.2'), findsOneWidget);
      expect(find.textContaining('Gitee'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('update-release-notes')))
            .data,
        'Runtime state fix\n\nUse automatic update.',
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('update-start')))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('update-full-package')),
            )
            .onPressed,
        isNotNull,
      );

      final foreground = await runtime.check(
        trigger: UpdateCheckTrigger.foreground,
      );
      await tester.pump();

      expect(foreground.status, UpdateCheckStatus.throttled);
      expect(find.text('1.0.4.1  →  1.0.4.2'), findsOneWidget);
      expect(find.textContaining('Gitee'), findsOneWidget);
      expect(find.text('可以更新'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('update-release-notes')))
            .data,
        'Runtime state fix\n\nUse automatic update.',
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('update-start')))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('update-full-package')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  test('manual check bypasses throttle and refreshes release notes', () async {
    final fixture = await _runtimeFixture();
    final runtime = fixture.runtime;
    addTearDown(runtime.dispose);

    expect((await runtime.check()).status, UpdateCheckStatus.updateAvailable);
    await pumpEventQueue();
    expect(runtime.notes, '# Runtime state fix\n\nUse automatic update.');

    final refreshed = await runtime.check(
      trigger: UpdateCheckTrigger.foreground,
      manual: true,
    );
    await pumpEventQueue();

    expect(refreshed.status, UpdateCheckStatus.updateAvailable);
    expect(runtime.lastCheck, same(refreshed));
    expect(runtime.phase, UpdateRuntimePhase.available);
    expect(runtime.plan?.manifest.releaseId, 'release-51');
    expect(runtime.origin, UpdateReleaseOrigin.gitee);
    expect(fixture.source.calls, 2);
    expect(fixture.notesRequests.value, 2);
    expect(
      runtime.notes,
      '# Refreshed release notes\n\nManual check completed.',
    );
  });

  test('late release notes are not rolled back by a throttled check', () async {
    final notesGate = Completer<void>();
    final fixture = await _runtimeFixture(firstNotesGate: notesGate);
    final runtime = fixture.runtime;
    addTearDown(runtime.dispose);

    expect((await runtime.check()).status, UpdateCheckStatus.updateAvailable);
    await pumpEventQueue();
    expect(fixture.notesRequests.value, 1);
    expect(runtime.notes, isNull);

    final storeGate = Completer<void>();
    fixture.store.nextLoadGate = storeGate;
    final foreground = runtime.check(trigger: UpdateCheckTrigger.foreground);
    expect(runtime.phase, UpdateRuntimePhase.checking);

    notesGate.complete();
    await pumpEventQueue();
    expect(runtime.notes, '# Runtime state fix\n\nUse automatic update.');

    storeGate.complete();
    expect((await foreground).status, UpdateCheckStatus.throttled);
    expect(runtime.lastCheck?.status, UpdateCheckStatus.updateAvailable);
    expect(runtime.phase, UpdateRuntimePhase.available);
    expect(runtime.notes, '# Runtime state fix\n\nUse automatic update.');
  });
}
