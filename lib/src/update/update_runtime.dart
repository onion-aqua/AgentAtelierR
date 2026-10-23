import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'apk_update_installer.dart';
import 'protected_resource_health.dart';
import 'release_source.dart';
import 'resource_models.dart';
import 'resource_resolver.dart';
import 'resource_update_manager.dart';
import 'update_build_config.dart';
import 'update_downloader.dart';
import 'update_manifest.dart';
import 'update_models.dart';
import 'update_notes_loader.dart';
import 'update_service.dart';

enum UpdateRuntimePhase {
  disabled,
  idle,
  checking,
  available,
  downloading,
  verifying,
  permissionRequired,
  launchingInstaller,
  installerOpened,
  upToDate,
  resourcesReady,
  error,
}

class UpdateRuntime extends ChangeNotifier {
  static const _downloadFreeSpaceMargin = 16 * 1024 * 1024;

  UpdateRuntime({
    required this.buildConfig,
    required this.installed,
    required UpdateService? service,
    required this.downloader,
    required this.installer,
    required this.notesLoader,
    this.resourceManager,
    this.ownedSource,
    this.disabledReason,
  }) : _service = service,
       _phase = service == null
           ? UpdateRuntimePhase.disabled
           : UpdateRuntimePhase.idle {
    downloader.addListener(_downloadChanged);
    resourceManager?.addListener(_resourceChanged);
  }

  final UpdateBuildConfig buildConfig;
  final InstalledUpdateState? installed;
  final UpdateService? _service;
  final UpdateDownloader downloader;
  final ApkUpdateInstaller installer;
  final UpdateNotesLoader notesLoader;
  final ResourceUpdateManager? resourceManager;
  final CascadingReleaseSource? ownedSource;
  final String? disabledReason;

  UpdateRuntimePhase _phase;
  UpdateCheckResult? _lastCheck;
  String? _errorCode;
  String? _notes;
  String? _notesReleaseId;
  String? _readyApkPath;
  bool _busy = false;
  bool _disposed = false;

  UpdateRuntimePhase get phase => _phase;
  UpdateCheckResult? get lastCheck => _lastCheck;
  UpdatePlan? get plan => _lastCheck?.plan;
  UpdateReleaseOrigin? get origin => _lastCheck?.origin;
  String? get errorCode => _errorCode ?? disabledReason;
  String? get notes => _notes;
  String? get readyApkPath => _readyApkPath;
  bool get enabled => _service != null;
  bool get busy =>
      _busy || downloader.isRunning || (resourceManager?.busy ?? false);
  UpdateDownloadState get downloadState => downloader.state;
  ResourceUpdateState get resourceState =>
      resourceManager?.state ?? const ResourceUpdateState();
  String get currentVersion => installed?.displayVersion ?? 'unknown';

  static Future<UpdateRuntime> production() async {
    final installer = ApkUpdateInstaller();
    final downloader = UpdateDownloader();
    final notesLoader = UpdateNotesLoader();
    ResourceUpdateManager? resources;
    CascadingReleaseSource? source;
    try {
      final config = await UpdateBuildConfig.fromEnvironment();
      if (!config.enabled) {
        ResourceAssetResolver.instance.setOverlayEnabled(false);
        return UpdateRuntime(
          buildConfig: config,
          installed: null,
          service: null,
          downloader: downloader,
          installer: installer,
          notesLoader: notesLoader,
          disabledReason: 'not_configured',
        );
      }
      if (!Platform.isAndroid) {
        ResourceAssetResolver.instance.setOverlayEnabled(false);
        return UpdateRuntime(
          buildConfig: config,
          installed: null,
          service: null,
          downloader: downloader,
          installer: installer,
          notesLoader: notesLoader,
          disabledReason: 'platform_not_supported',
        );
      }
      resources = ResourceUpdateManager(
        compatibility: ResourceRuntimeCompatibility(
          runtimeId: config.runtimeCompatId,
          resourceApiVersion: config.resourceApiVersion,
          assetKeyIds: config.resourceAssetKeyIds,
        ),
        resolver: ResourceAssetResolver.instance,
        healthValidator: ProductionResourceHealthValidator().call,
      );
      await resources.initialize(bundledReleaseSeq: config.releaseSeq);
      final app = await installer.getInstalledAppInfo();
      final installed = InstalledUpdateState(
        releaseSeq: config.releaseSeq,
        displayVersion: app.versionName ?? app.versionCode.toString(),
        nativeBuild: app.versionCode,
        packageName: app.packageName,
        channel: config.channel,
        platform: 'android',
        runtimeCompatId: config.runtimeCompatId,
        resourceApiVersion: config.resourceApiVersion,
        updaterProtocolVersion: config.updaterProtocolVersion,
        supportedAbis: app.supportedAbis.toSet(),
        certificateSha256: app.certificateSha256,
        supportedDeltaFormats: app.supportedDeltaFormats.toSet(),
        resourceSnapshotId: await resources.resolver.activeSnapshotId(),
      );
      final verifier = UpdateManifestVerifier(trustedKeys: config.trustedKeys);
      source = CascadingReleaseSource(
        config: config.sources!,
        transport: DefaultReleaseHttpTransport(),
        authenticate: (envelope) async {
          final manifest = await verifier.verify(envelope);
          if (manifest.channel != config.channel ||
              manifest.platform != 'android') {
            throw const FormatException('更新来源与当前应用通道不匹配');
          }
        },
      );
      final service = UpdateService(
        source: source,
        verifier: verifier,
        store: SharedPreferencesUpdateStore(),
      );
      return UpdateRuntime(
        buildConfig: config,
        installed: installed,
        service: service,
        downloader: downloader,
        installer: installer,
        notesLoader: notesLoader,
        resourceManager: resources,
        ownedSource: source,
      );
    } on Object {
      ResourceAssetResolver.instance.setOverlayEnabled(false);
      resources?.dispose();
      source?.close();
      return UpdateRuntime(
        buildConfig: const UpdateBuildConfig.disabled(),
        installed: null,
        service: null,
        downloader: downloader,
        installer: installer,
        notesLoader: notesLoader,
        disabledReason: 'invalid_build_config',
      );
    }
  }

  Future<UpdatePreferences> preferences() async =>
      await _service?.preferences() ?? const UpdatePreferences();

  Future<void> setAutoCheck(bool enabled) async {
    await _service?.setAutoCheck(enabled);
    _notify();
  }

  Future<void> setSourcePreference(UpdateSourcePreference preference) async {
    await _service?.setSourcePreference(preference);
    _notify();
  }

  Future<UpdateCheckResult> check({
    UpdateCheckTrigger trigger = UpdateCheckTrigger.startup,
    bool manual = false,
  }) async {
    if (_phase == UpdateRuntimePhase.resourcesReady ||
        _phase == UpdateRuntimePhase.permissionRequired ||
        _phase == UpdateRuntimePhase.launchingInstaller ||
        _phase == UpdateRuntimePhase.installerOpened) {
      return _lastCheck ?? const UpdateCheckResult.throttled();
    }
    final service = _service;
    final current = installed;
    if (service == null || current == null) {
      const result = UpdateCheckResult.disabled();
      _lastCheck = result;
      _phase = UpdateRuntimePhase.disabled;
      _notify();
      return result;
    }
    if (_busy) {
      return _lastCheck ?? const UpdateCheckResult.throttled();
    }
    final previousLastCheck = _lastCheck;
    final previousPhase = _phase;
    final previousErrorCode = _errorCode;
    _phase = UpdateRuntimePhase.checking;
    _busy = true;
    _errorCode = null;
    _notify();
    try {
      final result = await service.check(
        current,
        trigger: trigger,
        manual: manual,
      );
      if (result.status == UpdateCheckStatus.throttled &&
          previousLastCheck != null) {
        _lastCheck = previousLastCheck;
        _phase = previousPhase;
        _errorCode = previousErrorCode;
        return result;
      }
      _lastCheck = result;
      _notes = null;
      _notesReleaseId = null;
      _readyApkPath = null;
      switch (result.status) {
        case UpdateCheckStatus.updateAvailable:
        case UpdateCheckStatus.suppressed:
          _phase = UpdateRuntimePhase.available;
          final manifest = result.plan?.manifest;
          if (manifest != null) {
            _notesReleaseId = manifest.releaseId;
            unawaited(
              _loadNotes(
                manifest.notes.cachedMarkdownUrl,
                releaseId: manifest.releaseId,
              ),
            );
          }
          break;
        case UpdateCheckStatus.upToDate:
          _phase = UpdateRuntimePhase.upToDate;
          break;
        case UpdateCheckStatus.disabled:
          _phase = UpdateRuntimePhase.disabled;
          break;
        case UpdateCheckStatus.throttled:
          _phase = UpdateRuntimePhase.idle;
          break;
        case UpdateCheckStatus.failed:
          _phase = UpdateRuntimePhase.error;
          _errorCode = result.errorCode;
          break;
      }
      return result;
    } on Object {
      const result = UpdateCheckResult.failed('check_failed');
      _lastCheck = result;
      _phase = UpdateRuntimePhase.error;
      _errorCode = result.errorCode;
      return result;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> dismissCurrentRelease() async {
    final releaseId = plan?.manifest.releaseId;
    if (releaseId != null) await _service?.dismissRelease(releaseId);
  }

  Future<void> startUpdate({bool fullPackage = false}) async {
    final currentPlan = plan;
    final target = currentPlan?.manifest.targetApk;
    if (currentPlan == null || !currentPlan.hasUpdate) {
      _fail('no_update_plan');
      return;
    }
    if (_busy) return;
    _busy = true;
    _errorCode = null;
    _notify();
    try {
      final resource = currentPlan.resource;
      if (resource != null) {
        final manager = resourceManager;
        if (manager == null) {
          _fail('resource_update_unavailable');
          return;
        }
        if (!buildConfig.resourceAssetKeyIds.contains(
          resource.snapshot.assetKeyId,
        )) {
          _fail('resource_key_mismatch');
          return;
        }
        await manager.prepareVerifiedSnapshot(
          snapshot: resource.snapshot,
          releaseSeq: currentPlan.manifest.releaseSeq,
          expectedResourceApiVersion: currentPlan.manifest.resourceApiVersion,
          forNextRuntime:
              resource.activation == ResourceActivation.afterApkInstall,
        );
      }

      if (target == null || currentPlan.apk == null) {
        if (resource != null) {
          _phase = UpdateRuntimePhase.resourcesReady;
          _notify();
          return;
        }
        _fail('no_executable_update');
        return;
      }
      final selected = currentPlan.apk;
      // Delta is selected only when a platform advertises a working patcher.
      // The Android bootstrap currently advertises none, so full APK is the
      // safe executable path while the native patch engine is integrated.
      final useFull =
          fullPackage ||
          selected == null ||
          selected.kind == ApkUpdateKind.full;
      if (!useFull) {
        _fail('delta_engine_unavailable');
        return;
      }
      final availableSpace = await installer.getAvailableUpdateSpace();
      if (availableSpace < target.size + _downloadFreeSpaceMargin) {
        _fail('storage_insufficient');
        return;
      }
      final file = await downloader.download(
        UpdateDownloadRequest(
          id: '${currentPlan.manifest.releaseId}-${target.sha256.substring(0, 12)}-full',
          urls: target.urls,
          sha256: target.sha256,
          size: target.size,
          fileExtension: 'apk',
        ),
      );
      _phase = UpdateRuntimePhase.verifying;
      _notify();
      await installer.validateApk(
        path: file.path,
        expectedPackageName: target.packageName,
        expectedVersionCode: target.versionCode,
        expectedSha256: target.sha256,
      );
      _readyApkPath = file.path;
      final permission = await installer.getInstallPermissionStatus();
      if (permission.required && !permission.granted) {
        _phase = UpdateRuntimePhase.permissionRequired;
        _notify();
        return;
      }
      await _launchInstaller();
    } on UpdateDownloadException catch (error) {
      if (error.code == 'cancelled') {
        _phase = UpdateRuntimePhase.available;
      } else {
        _fail(error.code);
      }
    } on ApkUpdateInstallerException catch (error) {
      _fail(error.code);
    } on ResourceUpdateException catch (error) {
      if (error.code == 'resource_cancelled' || error.code == 'cancelled') {
        _phase = UpdateRuntimePhase.available;
      } else {
        _fail(error.code);
      }
    } on Object {
      _fail('update_failed');
    } finally {
      _busy = false;
      _notify();
    }
  }

  void cancelDownload() {
    downloader.cancel();
    resourceManager?.cancel();
  }

  Future<void> openInstallPermissionSettings() async {
    try {
      await installer.openInstallPermissionSettings();
    } on ApkUpdateInstallerException catch (error) {
      _fail(error.code);
    }
  }

  Future<void> continueInstall() async {
    if (_busy) return;
    _busy = true;
    try {
      final permission = await installer.getInstallPermissionStatus();
      if (permission.required && !permission.granted) {
        _phase = UpdateRuntimePhase.permissionRequired;
        _notify();
        return;
      }
      await _launchInstaller();
    } on ApkUpdateInstallerException catch (error) {
      _fail(error.code);
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> clearCache() async {
    await downloader.clearCache();
    _readyApkPath = null;
    if (_phase == UpdateRuntimePhase.permissionRequired ||
        _phase == UpdateRuntimePhase.launchingInstaller ||
        _phase == UpdateRuntimePhase.installerOpened) {
      _phase = UpdateRuntimePhase.available;
    }
    await resourceManager?.clearUnreferencedCache();
    _notify();
  }

  Future<void> _launchInstaller() async {
    final target = plan?.manifest.targetApk;
    final path = _readyApkPath;
    if (target == null || path == null || !await File(path).exists()) {
      _fail('ready_apk_missing');
      return;
    }
    _phase = UpdateRuntimePhase.launchingInstaller;
    _notify();
    await installer.installApk(
      path: path,
      expectedPackageName: target.packageName,
      expectedVersionCode: target.versionCode,
      expectedSha256: target.sha256,
    );
    _phase = UpdateRuntimePhase.installerOpened;
    _notify();
  }

  Future<void> _loadNotes(Uri? url, {required String releaseId}) async {
    final value = await notesLoader.load(url);
    if (_disposed ||
        _notesReleaseId != releaseId ||
        plan?.manifest.releaseId != releaseId) {
      return;
    }
    _notes = value;
    _notify();
  }

  void _downloadChanged() {
    if (_disposed) return;
    switch (downloader.state.phase) {
      case UpdateDownloadPhase.downloading:
        _phase = UpdateRuntimePhase.downloading;
        break;
      case UpdateDownloadPhase.verifying:
        _phase = UpdateRuntimePhase.verifying;
        break;
      default:
        break;
    }
    _notify();
  }

  void _resourceChanged() {
    if (_disposed) return;
    final state = resourceManager?.state;
    if (state == null) return;
    switch (state.phase) {
      case ResourceUpdatePhase.downloadingManifest:
      case ResourceUpdatePhase.downloadingObjects:
        _phase = UpdateRuntimePhase.downloading;
        break;
      case ResourceUpdatePhase.validatingManifest:
      case ResourceUpdatePhase.activating:
      case ResourceUpdatePhase.rollingBack:
        _phase = UpdateRuntimePhase.verifying;
        break;
      case ResourceUpdatePhase.failed:
        _phase = UpdateRuntimePhase.error;
        _errorCode = state.errorCode ?? 'resource_update_failed';
        break;
      case ResourceUpdatePhase.cancelled:
        _phase = UpdateRuntimePhase.available;
        break;
      case ResourceUpdatePhase.pending:
      case ResourceUpdatePhase.idle:
      case ResourceUpdatePhase.active:
      case ResourceUpdatePhase.rolledBack:
        break;
    }
    _notify();
  }

  void _fail(String code) {
    _errorCode = code;
    _phase = UpdateRuntimePhase.error;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    downloader.removeListener(_downloadChanged);
    resourceManager?.removeListener(_resourceChanged);
    downloader.dispose();
    resourceManager?.dispose();
    notesLoader.close();
    ownedSource?.close();
    super.dispose();
  }
}
