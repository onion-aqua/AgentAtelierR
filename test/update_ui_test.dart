import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/foreground_dialog_coordinator.dart';
import 'package:ryza_chat_mvp/src/update/apk_update_installer.dart';
import 'package:ryza_chat_mvp/src/update/update_build_config.dart';
import 'package:ryza_chat_mvp/src/update/update_center_page.dart';
import 'package:ryza_chat_mvp/src/update/update_dialog.dart';
import 'package:ryza_chat_mvp/src/update/update_downloader.dart';
import 'package:ryza_chat_mvp/src/update/update_models.dart';
import 'package:ryza_chat_mvp/src/update/update_notes_loader.dart';
import 'package:ryza_chat_mvp/src/update/update_runtime.dart';
import 'package:ryza_chat_mvp/src/update/update_service.dart';

UpdatePlan _apkPlan() {
  final target = UpdateTargetApk(
    versionCode: 47,
    packageName: 'com.example.ryza_chat_mvp',
    abis: const {'arm64-v8a'},
    sha256: 'b' * 64,
    certificateSha256: 'c' * 64,
    urls: [Uri.parse('https://downloads.example.test/app.apk')],
    size: 52 * 1024 * 1024,
  );
  final manifest = _manifest(targetApk: target);
  return UpdatePlan(manifest: manifest, apk: ApkUpdateSelection.full(target));
}

UpdatePlan _resourcePlan() {
  final snapshot = ResourceSnapshot(
    id: 'resources-47',
    schemaVersion: 1,
    compatibleRuntimeIds: const {'runtime-46'},
    assetKeyId: 'assets-1',
    manifestSha256: 'd' * 64,
    manifestUrl: Uri.parse('https://downloads.example.test/resources.json'),
    size: 8 * 1024 * 1024,
  );
  return UpdatePlan(
    manifest: _manifest(resourceSnapshot: snapshot),
    resource: ResourceUpdateSelection(snapshot, ResourceActivation.immediate),
  );
}

UpdateManifest _manifest({
  UpdateTargetApk? targetApk,
  ResourceSnapshot? resourceSnapshot,
}) => UpdateManifest(
  schemaVersion: 1,
  releaseId: 'release-47',
  releaseSeq: 47,
  displayVersion: '1.0.4.2',
  channel: 'stable',
  platform: 'android',
  updaterProtocolVersion: 1,
  publishedAt: DateTime.utc(2026, 10, 19),
  runtimeCompatId: 'runtime-47',
  resourceApiVersion: 1,
  targetApk: targetApk,
  apkDeltas: const [],
  resourceSnapshot: resourceSnapshot,
  notes: UpdateReleaseNotes(
    releaseId: 'release-47',
    giteeUrl: Uri.parse('https://gitee.com/example/releases/47'),
    githubUrl: Uri.parse('https://github.com/example/releases/tag/47'),
  ),
  signedPayload: const {},
);

class _FakeUpdateRuntime extends UpdateRuntime {
  _FakeUpdateRuntime({
    required UpdatePlan plan,
    this.testPhase = UpdateRuntimePhase.available,
    UpdateCheckStatus checkStatus = UpdateCheckStatus.updateAvailable,
    super.installed,
  }) : testPlan = plan,
       testCheckStatus = checkStatus,
       super(
         buildConfig: const UpdateBuildConfig.disabled(),
         service: null,
         downloader: UpdateDownloader(
           supportDirectory: () async => Directory.systemTemp,
         ),
         installer: ApkUpdateInstaller(
           channel: const MethodChannel('test/update-installer'),
         ),
         notesLoader: UpdateNotesLoader(),
       );

  UpdateRuntimePhase testPhase;
  UpdatePlan testPlan;
  UpdateCheckStatus testCheckStatus;
  String? testNotes = '新增自托管更新入口\n修复下载恢复';
  String? testError;
  UpdateDownloadState testDownloadState = const UpdateDownloadState();
  UpdatePreferences testPreferences = const UpdatePreferences();
  int dismissCalls = 0;
  int checkCalls = 0;
  int cancelCalls = 0;
  int clearCalls = 0;
  int permissionCalls = 0;
  int continueCalls = 0;
  int startCalls = 0;
  bool? lastFullPackage;
  UpdateSourcePreference? savedSource;

  @override
  UpdateRuntimePhase get phase => testPhase;

  @override
  UpdatePlan get plan => testPlan;

  @override
  UpdateCheckResult get lastCheck => switch (testCheckStatus) {
    UpdateCheckStatus.updateAvailable => UpdateCheckResult.available(
      testPlan,
      UpdateReleaseOrigin.gitee,
    ),
    UpdateCheckStatus.suppressed => UpdateCheckResult.suppressed(
      testPlan,
      UpdateReleaseOrigin.gitee,
    ),
    UpdateCheckStatus.upToDate => UpdateCheckResult.upToDate(
      testPlan,
      UpdateReleaseOrigin.gitee,
    ),
    UpdateCheckStatus.disabled => const UpdateCheckResult.disabled(),
    UpdateCheckStatus.throttled => const UpdateCheckResult.throttled(),
    UpdateCheckStatus.failed => UpdateCheckResult.failed(
      testError ?? 'check_failed',
    ),
  };

  @override
  UpdateReleaseOrigin get origin => UpdateReleaseOrigin.gitee;

  @override
  String? get errorCode => testError;

  @override
  String? get notes => testNotes;

  @override
  String get currentVersion => '1.0.4.1';

  @override
  bool get enabled => true;

  @override
  bool get busy =>
      testPhase == UpdateRuntimePhase.checking ||
      testPhase == UpdateRuntimePhase.downloading ||
      testPhase == UpdateRuntimePhase.verifying;

  @override
  UpdateDownloadState get downloadState => testDownloadState;

  @override
  String? get readyApkPath =>
      testPhase == UpdateRuntimePhase.installerOpened ? '/ready/app.apk' : null;

  @override
  Future<UpdatePreferences> preferences() async => testPreferences;

  @override
  Future<void> setAutoCheck(bool enabled) async {
    testPreferences = testPreferences.copyWith(autoCheck: enabled);
    notifyListeners();
  }

  @override
  Future<void> setSourcePreference(UpdateSourcePreference preference) async {
    savedSource = preference;
    testPreferences = testPreferences.copyWith(sourcePreference: preference);
    notifyListeners();
  }

  @override
  Future<UpdateCheckResult> check({
    UpdateCheckTrigger trigger = UpdateCheckTrigger.startup,
    bool manual = false,
  }) async {
    checkCalls++;
    notifyListeners();
    return UpdateCheckResult.available(testPlan, UpdateReleaseOrigin.gitee);
  }

  @override
  Future<void> dismissCurrentRelease() async {
    dismissCalls++;
  }

  @override
  Future<void> startUpdate({bool fullPackage = false}) async {
    startCalls++;
    lastFullPackage = fullPackage;
  }

  @override
  void cancelDownload() {
    cancelCalls++;
  }

  @override
  Future<void> openInstallPermissionSettings() async {
    permissionCalls++;
  }

  @override
  Future<void> continueInstall() async {
    continueCalls++;
  }

  @override
  Future<void> clearCache() async {
    clearCalls++;
    notifyListeners();
  }

  void setDownloadProgress(int received, int total) {
    testPhase = UpdateRuntimePhase.downloading;
    testDownloadState = UpdateDownloadState(
      phase: UpdateDownloadPhase.downloading,
      id: 'release-47',
      receivedBytes: received,
      totalBytes: total,
    );
    notifyListeners();
  }
}

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData(colorSchemeSeed: const Color(0xFF347B68)),
  home: Scaffold(body: child),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('startup prompt is dismissible and records the release', (
    tester,
  ) async {
    final runtime = _FakeUpdateRuntime(plan: _apkPlan());
    final coordinator = ForegroundDialogCoordinator();
    addTearDown(runtime.dispose);
    addTearDown(coordinator.dispose);

    await tester.pumpWidget(
      _app(
        UpdateForegroundHost(
          runtime: runtime,
          dialogCoordinator: coordinator,
          language: AppLanguage.chinese,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('1.0.4.1  →  1.0.4.2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-prompt-close')));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsNothing);
    expect(runtime.dismissCalls, 1);
  });

  testWidgets('relay question preempts and update prompt returns afterwards', (
    tester,
  ) async {
    final runtime = _FakeUpdateRuntime(plan: _apkPlan());
    final coordinator = ForegroundDialogCoordinator();
    addTearDown(runtime.dispose);
    addTearDown(coordinator.dispose);

    await tester.pumpWidget(
      _app(
        UpdateForegroundHost(
          runtime: runtime,
          dialogCoordinator: coordinator,
          language: AppLanguage.english,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsOneWidget);

    final relayLease = coordinator.tryAcquire(
      kind: ForegroundDialogKind.relayQuestion,
      onPreempt: () {},
    );
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsNothing);
    expect(runtime.dismissCalls, 0);

    relayLease!.release();
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsOneWidget);
    expect(runtime.dismissCalls, 0);
  });

  testWidgets('update prompt waits for foreground and the main route', (
    tester,
  ) async {
    final runtime = _FakeUpdateRuntime(plan: _apkPlan())
      ..testCheckStatus = UpdateCheckStatus.disabled;
    final coordinator = ForegroundDialogCoordinator();
    addTearDown(runtime.dispose);
    addTearDown(coordinator.dispose);
    await tester.pumpWidget(
      _app(
        UpdateForegroundHost(
          runtime: runtime,
          dialogCoordinator: coordinator,
          language: AppLanguage.english,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Pairing')),
      ),
    );
    await tester.pumpAndSettle();
    runtime.testCheckStatus = UpdateCheckStatus.updateAvailable;
    runtime.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsOneWidget);
    expect(runtime.dismissCalls, 0);
  });

  testWidgets('prompt exposes full package, GitHub and download progress', (
    tester,
  ) async {
    final runtime = _FakeUpdateRuntime(plan: _apkPlan());
    addTearDown(runtime.dispose);
    Uri? launched;
    await tester.pumpWidget(
      _app(
        UpdatePromptDialog(
          runtime: runtime,
          language: AppLanguage.chinese,
          launchExternal: (uri) async {
            launched = uri;
            return true;
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('update-full-package')));
    expect(runtime.startCalls, 1);
    expect(runtime.lastFullPackage, isTrue);
    await tester.tap(find.byKey(const ValueKey('update-open-github')));
    await tester.pump();
    expect(launched?.host, 'github.com');

    runtime.setDownloadProgress(25, 100);
    await tester.pump();
    expect(find.text('25%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-cancel-download')));
    expect(runtime.cancelCalls, 1);
  });

  testWidgets('resource-only prompt updates without offering an APK', (
    tester,
  ) async {
    final runtime = _FakeUpdateRuntime(plan: _resourcePlan());
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      _app(
        UpdatePromptDialog(runtime: runtime, language: AppLanguage.japanese),
      ),
    );

    expect(find.textContaining('APK のインストールは不要'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('update-start')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('update-start')));
    expect(runtime.startCalls, 1);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('update-full-package')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('update center saves source and exposes maintenance actions', (
    tester,
  ) async {
    final runtime = _FakeUpdateRuntime(plan: _apkPlan());
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      _app(
        UpdateCenterPage(
          runtime: runtime,
          language: AppLanguage.chinese,
          launchExternal: (_) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('版本中心'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -220));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-check-now')));
    await tester.pump();
    expect(runtime.checkCalls, 1);

    await tester.drag(find.byType(ListView), const Offset(0, 220));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-auto-check')));
    await tester.pump();
    expect(runtime.testPreferences.autoCheck, isFalse);

    await tester.tap(find.byKey(const ValueKey('update-source-preference')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GitHub').last);
    await tester.pumpAndSettle();
    expect(runtime.savedSource, UpdateSourcePreference.github);

    await tester.drag(find.byType(ListView), const Offset(0, -220));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-clear-cache')));
    await tester.pump();
    expect(runtime.clearCalls, 1);
  });

  testWidgets('update center identifies test build and bundled resources', (
    tester,
  ) async {
    final runtime = _FakeUpdateRuntime(
      plan: _apkPlan(),
      installed: InstalledUpdateState(
        releaseSeq: 48,
        displayVersion: '1.0.4.1',
        nativeBuild: 48,
        packageName: 'com.example.ryza_chat_mvp',
        channel: 'device-test',
        platform: 'android',
        runtimeCompatId: 'android-bootstrap-v1',
        resourceApiVersion: 1,
        updaterProtocolVersion: 1,
        supportedAbis: const {'arm64-v8a'},
      ),
    );
    addTearDown(runtime.dispose);

    await tester.pumpWidget(
      _app(UpdateCenterPage(runtime: runtime, language: AppLanguage.chinese)),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前渠道'), findsOneWidget);
    expect(find.text('device-test'), findsOneWidget);
    expect(find.text('内部构建'), findsOneWidget);
    expect(find.text('48'), findsOneWidget);
    expect(find.text('资源快照'), findsOneWidget);
    expect(find.text('内置资源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission state offers settings and continue installation', (
    tester,
  ) async {
    final runtime = _FakeUpdateRuntime(
      plan: _apkPlan(),
      testPhase: UpdateRuntimePhase.permissionRequired,
    );
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      _app(UpdatePromptDialog(runtime: runtime, language: AppLanguage.english)),
    );

    await tester.tap(find.byKey(const ValueKey('update-open-permission')));
    await tester.tap(find.byKey(const ValueKey('update-continue-install')));
    expect(runtime.permissionCalls, 1);
    expect(runtime.continueCalls, 1);
  });
}
