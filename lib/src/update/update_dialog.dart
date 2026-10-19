import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_localization.dart';
import '../foreground_dialog_coordinator.dart';
import '../glass_ui.dart';
import 'update_models.dart';
import 'update_runtime.dart';
import 'update_service.dart';
import 'resource_models.dart';

typedef UpdateExternalLauncher = Future<bool> Function(Uri uri);

enum UpdatePromptResult { dismissed }

/// Invisible host for the optional startup update prompt.
///
/// Place this once below the app Navigator. PC Agent questions may preempt the
/// prompt through [ForegroundDialogCoordinator]; a preempted prompt is offered
/// again after the higher-priority dialog releases its lease.
class UpdateForegroundHost extends StatefulWidget {
  const UpdateForegroundHost({
    super.key,
    required this.runtime,
    required this.dialogCoordinator,
    required this.language,
  });

  final UpdateRuntime runtime;
  final ForegroundDialogCoordinator dialogCoordinator;
  final AppLanguage language;

  @override
  State<UpdateForegroundHost> createState() => _UpdateForegroundHostState();
}

class _UpdateForegroundHostState extends State<UpdateForegroundHost>
    with WidgetsBindingObserver {
  DialogRoute<UpdatePromptResult>? _route;
  NavigatorState? _navigator;
  ForegroundDialogLease? _lease;
  bool _scheduled = false;
  bool _disposing = false;
  final Set<String> _dismissedReleaseIds = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.runtime.addListener(_schedulePresentation);
    widget.dialogCoordinator.addListener(_schedulePresentation);
    _schedulePresentation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _schedulePresentation();
  }

  @override
  void didUpdateWidget(UpdateForegroundHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.runtime, widget.runtime)) {
      oldWidget.runtime.removeListener(_schedulePresentation);
      widget.runtime.addListener(_schedulePresentation);
    }
    if (!identical(oldWidget.dialogCoordinator, widget.dialogCoordinator)) {
      oldWidget.dialogCoordinator.removeListener(_schedulePresentation);
      widget.dialogCoordinator.addListener(_schedulePresentation);
    }
    _schedulePresentation();
  }

  void _schedulePresentation() {
    if (_scheduled || _disposing || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted && !_disposing) unawaited(_presentIfNeeded());
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _presentIfNeeded() async {
    if (_route != null || _disposing || !mounted) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if ((lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
        ModalRoute.isCurrentOf(context) == false) {
      return;
    }
    final check = widget.runtime.lastCheck;
    final plan = check?.plan;
    if (check?.status != UpdateCheckStatus.updateAvailable || plan == null) {
      return;
    }
    final releaseId = plan.manifest.releaseId;
    if (_dismissedReleaseIds.contains(releaseId)) return;

    final navigator = Navigator.of(context, rootNavigator: true);
    DialogRoute<UpdatePromptResult>? route;
    var preempted = false;
    ForegroundDialogLease? acquiredLease;
    acquiredLease = widget.dialogCoordinator.tryAcquire(
      kind: ForegroundDialogKind.update,
      onPreempt: () {
        preempted = true;
        final activeRoute = route;
        if (identical(_route, activeRoute)) {
          _route = null;
          _navigator = null;
        }
        if (identical(_lease, acquiredLease)) _lease = null;
        acquiredLease?.release();
        if (activeRoute != null && activeRoute.isActive) {
          navigator.removeRoute(activeRoute);
        }
      },
    );
    final lease = acquiredLease;
    if (lease == null) return;

    route = DialogRoute<UpdatePromptResult>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (_) => UpdatePromptDialog(
        runtime: widget.runtime,
        language: widget.language,
      ),
    );
    _route = route;
    _navigator = navigator;
    _lease = lease;
    final result = await navigator.push(route);
    if (identical(_route, route)) {
      _route = null;
      _navigator = null;
    }
    if (identical(_lease, lease)) _lease = null;
    lease.release();

    if (!_disposing && !preempted && mounted) {
      // A null result is the Android/system back action. The outside barrier is
      // disabled, so every non-preempted null result is a user dismissal.
      if (result == null || result == UpdatePromptResult.dismissed) {
        _dismissedReleaseIds.add(releaseId);
        await widget.runtime.dismissCurrentRelease();
      }
      _schedulePresentation();
    }
  }

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    widget.runtime.removeListener(_schedulePresentation);
    widget.dialogCoordinator.removeListener(_schedulePresentation);
    final route = _route;
    final navigator = _navigator;
    if (route != null && route.isActive && navigator != null) {
      navigator.removeRoute(route);
    }
    _lease?.release();
    _lease = null;
    _route = null;
    _navigator = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Subscribe to route visibility, so returning from pairing or settings can
    // present a deferred prompt without requiring another network check.
    if (ModalRoute.isCurrentOf(context) != false) _schedulePresentation();
    return const SizedBox.shrink();
  }
}

class UpdatePromptDialog extends StatefulWidget {
  const UpdatePromptDialog({
    super.key,
    required this.runtime,
    required this.language,
    this.launchExternal,
  });

  final UpdateRuntime runtime;
  final AppLanguage language;
  final UpdateExternalLauncher? launchExternal;

  @override
  State<UpdatePromptDialog> createState() => _UpdatePromptDialogState();
}

class _UpdatePromptDialogState extends State<UpdatePromptDialog> {
  bool _externalOpenFailed = false;

  Future<void> _openGithub() async {
    final uri = widget.runtime.plan?.manifest.notes.githubUrl;
    if (uri == null) return;
    final launcher = widget.launchExternal ?? _defaultUpdateLauncher;
    var opened = false;
    try {
      opened = await launcher(uri);
    } on Object {
      opened = false;
    }
    if (mounted) setState(() => _externalOpenFailed = !opened);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.runtime,
    builder: (context, _) {
      final runtime = widget.runtime;
      final language = widget.language;
      final plan = runtime.plan;
      final manifest = plan?.manifest;
      final resourceOnly = plan?.resource != null && plan?.apk == null;
      final canInstallApk = plan?.apk != null;
      final busy = runtime.busy;
      final scheme = Theme.of(context).colorScheme;
      final dark = Theme.of(context).brightness == Brightness.dark;

      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540, maxHeight: 680),
          child: GlassSurface(
            liquidGlass: GlassStyleScope.resolve(context),
            tone: dark ? GlassTone.dark : GlassTone.light,
            fallbackColor: dark
                ? const Color(0xF21C2022)
                : const Color(0xF5F4F7F6),
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.system_update_alt_rounded,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          language.text(
                            '发现新版本',
                            'Update available',
                            '新しいバージョン',
                          ),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('update-prompt-close'),
                        tooltip: MaterialLocalizations.of(context)
                            .closeButtonTooltip,
                        onPressed: () =>
                            Navigator.of(context)
                                .pop(UpdatePromptResult.dismissed),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${runtime.currentVersion}  →  ${manifest?.displayVersion ?? '-'}',
                    key: const ValueKey('update-version-pair'),
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${language.text('来源', 'Source', '取得元')}: '
                    '${updateOriginLabel(runtime.origin, language)}   '
                    '${language.text('预计下载', 'Download', 'ダウンロード')}: '
                    '${formatUpdateBytes(plan?.apk?.downloadSize ?? 0)}'
                    '${plan?.resource == null ? '' : language.text(' + 按需资源', ' + missing resources', ' + 不足リソース')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Divider(height: 24),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            language.text('更新内容', 'What\'s new', '更新内容'),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _conciseNotes(runtime.notes, language),
                            key: const ValueKey('update-release-notes'),
                          ),
                          if (resourceOnly) ...[
                            const SizedBox(height: 14),
                            _UpdateNotice(
                              icon: Icons.info_outline_rounded,
                              text: language.text(
                                '仅下载缺失的资源，校验后在下次启动生效，无需安装 APK。实际下载量将在读取资源清单后确定。',
                                'Only missing resources are downloaded. They take effect on the next launch without APK installation. The download size is determined from the resource list.',
                                '不足リソースのみを取得し、検証後の次回起動時に適用します。APK のインストールは不要です。容量は一覧取得後に決まります。',
                              ),
                            ),
                          ],
                          if (canInstallApk) ...[
                            const SizedBox(height: 14),
                            _UpdateNotice(
                              icon: Icons.verified_user_outlined,
                              text: language.text(
                                '下载并校验完成后，Android 会要求你确认安装。更新不会静默安装。',
                                'After download and verification, Android will ask you to confirm installation.',
                                'ダウンロードと検証の完了後、Android のインストール確認が表示されます。',
                              ),
                            ),
                          ],
                          const SizedBox(height: 14),
                          UpdateRuntimeStatus(
                            runtime: runtime,
                            language: language,
                          ),
                          if (_externalOpenFailed) ...[
                            const SizedBox(height: 8),
                            Text(
                              language.text(
                                '无法打开浏览器，请稍后重试。',
                                'Could not open the browser. Try again later.',
                                'ブラウザーを開けませんでした。後でもう一度お試しください。',
                              ),
                              style: TextStyle(color: scheme.error),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _UpdateActions(
                    runtime: runtime,
                    language: language,
                    busy: busy,
                    canInstallApk: canInstallApk,
                    canUpdate: plan?.hasUpdate ?? false,
                    githubAvailable: manifest?.notes.githubUrl != null,
                    onGithub: _openGithub,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class UpdateRuntimeStatus extends StatelessWidget {
  const UpdateRuntimeStatus({
    super.key,
    required this.runtime,
    required this.language,
  });

  final UpdateRuntime runtime;
  final AppLanguage language;

  @override
  Widget build(BuildContext context) {
    final state = runtime.downloadState;
    final resource = runtime.resourceState;
    final resourceTransfer = const {
      ResourceUpdatePhase.downloadingManifest,
      ResourceUpdatePhase.validatingManifest,
      ResourceUpdatePhase.downloadingObjects,
    }.contains(resource.phase);
    final progress = resourceTransfer
        ? (resource.totalObjects <= 0
              ? null
              : resource.completedObjects / resource.totalObjects)
        : state.progress;
    final phase = runtime.phase;
    final error = runtime.errorCode;
    final scheme = Theme.of(context).colorScheme;
    final isError = phase == UpdateRuntimePhase.error;
    final text = updatePhaseLabel(phase, language, errorCode: error);
    final showProgress =
        phase == UpdateRuntimePhase.downloading ||
        phase == UpdateRuntimePhase.verifying;

    return Semantics(
      liveRegion: true,
      label: text,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: (isError ? scheme.errorContainer : scheme.secondaryContainer)
              .withValues(alpha: .46),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    isError ? Icons.error_outline_rounded : _phaseIcon(phase),
                    size: 19,
                    color: isError ? scheme.error : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      key: const ValueKey('update-runtime-status'),
                    ),
                  ),
                  if (phase == UpdateRuntimePhase.downloading &&
                      progress != null)
                    Text('${(progress * 100).round()}%'),
                ],
              ),
              if (showProgress) ...[
                const SizedBox(height: 9),
                LinearProgressIndicator(value: progress),
                if (resourceTransfer && resource.totalObjects > 0) ...[
                  const SizedBox(height: 5),
                  Text(
                    '${language.text('已校验资源', 'Verified resources', '検証済みリソース')}: '
                    '${resource.completedObjects} / ${resource.totalObjects}',
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ] else if (!resourceTransfer && state.totalBytes > 0) ...[
                  const SizedBox(height: 5),
                  Text(
                    '${formatUpdateBytes(state.receivedBytes)} / '
                    '${formatUpdateBytes(state.totalBytes)}',
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _UpdateActions extends StatelessWidget {
  const _UpdateActions({
    required this.runtime,
    required this.language,
    required this.busy,
    required this.canInstallApk,
    required this.canUpdate,
    required this.githubAvailable,
    required this.onGithub,
  });

  final UpdateRuntime runtime;
  final AppLanguage language;
  final bool busy;
  final bool canInstallApk;
  final bool canUpdate;
  final bool githubAvailable;
  final VoidCallback onGithub;

  @override
  Widget build(BuildContext context) {
    final phase = runtime.phase;
    if (phase == UpdateRuntimePhase.downloading) {
      return Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton.icon(
          key: const ValueKey('update-cancel-download'),
          onPressed: runtime.cancelDownload,
          icon: const Icon(Icons.close_rounded),
          label: Text(language.text('取消下载', 'Cancel download', 'ダウンロードを中止')),
        ),
      );
    }
    if (phase == UpdateRuntimePhase.permissionRequired) {
      return Wrap(
        alignment: WrapAlignment.end,
        spacing: 10,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            key: const ValueKey('update-open-permission'),
            onPressed: busy ? null : runtime.openInstallPermissionSettings,
            icon: const Icon(Icons.settings_outlined),
            label: Text(
              language.text('允许安装', 'Allow installation', 'インストールを許可'),
            ),
          ),
          FilledButton.icon(
            key: const ValueKey('update-continue-install'),
            onPressed: busy ? null : runtime.continueInstall,
            icon: const Icon(Icons.install_mobile_rounded),
            label: Text(language.text('继续安装', 'Continue install', 'インストールを続行')),
          ),
        ],
      );
    }
    if (phase == UpdateRuntimePhase.installerOpened ||
        phase == UpdateRuntimePhase.launchingInstaller) {
      return Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          key: const ValueKey('update-reopen-installer'),
          onPressed: busy ? null : runtime.continueInstall,
          icon: const Icon(Icons.install_mobile_rounded),
          label: Text(language.text('继续安装', 'Continue install', 'インストールを続行')),
        ),
      );
    }
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        TextButton.icon(
          key: const ValueKey('update-open-github'),
          onPressed: githubAvailable ? onGithub : null,
          icon: const Icon(Icons.open_in_new_rounded),
          label: Text(
            language.text('GitHub 自行更新', 'Update via GitHub', 'GitHub から更新'),
          ),
        ),
        OutlinedButton.icon(
          key: const ValueKey('update-full-package'),
          onPressed: !busy && canInstallApk
              ? () => runtime.startUpdate(fullPackage: true)
              : null,
          icon: const Icon(Icons.download_for_offline_outlined),
          label: Text(language.text('完整安装包', 'Full package', '完全版 APK')),
        ),
        FilledButton.icon(
          key: const ValueKey('update-start'),
          onPressed:
              !busy && canUpdate && phase != UpdateRuntimePhase.resourcesReady
              ? () => runtime.startUpdate()
              : null,
          icon: const Icon(Icons.system_update_alt_rounded),
          label: Text(language.text('立即更新', 'Update now', '今すぐ更新')),
        ),
      ],
    );
  }
}

class _UpdateNotice extends StatelessWidget {
  const _UpdateNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 18),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
    ],
  );
}

Future<bool> _defaultUpdateLauncher(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

String _conciseNotes(String? value, AppLanguage language) {
  final notes = value
      ?.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
      .replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '• ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  if (notes == null || notes.isEmpty) {
    return language.text(
      '此版本的更新说明暂未同步，可前往 Release 页面查看。',
      'Release notes have not synced yet. Open the release page for details.',
      '更新内容はまだ同期されていません。リリースページで確認できます。',
    );
  }
  return notes;
}

String formatUpdateBytes(int bytes) {
  if (bytes <= 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String updateOriginLabel(UpdateReleaseOrigin? origin, AppLanguage language) =>
    switch (origin) {
      UpdateReleaseOrigin.gitee => 'Gitee',
      UpdateReleaseOrigin.github => 'GitHub',
      UpdateReleaseOrigin.cache => language.text(
        '服务器缓存',
        'Server cache',
        'サーバーキャッシュ',
      ),
      null => language.text('尚未获取', 'Not fetched', '未取得'),
    };

String updatePhaseLabel(
  UpdateRuntimePhase phase,
  AppLanguage language, {
  String? errorCode,
}) => switch (phase) {
  UpdateRuntimePhase.disabled => language.text(
    '自动更新未配置',
    'Updates are not configured',
    '自動更新は未設定です',
  ),
  UpdateRuntimePhase.idle => language.text('等待检查', 'Ready to check', '確認待ち'),
  UpdateRuntimePhase.checking => language.text(
    '正在检查更新…',
    'Checking for updates…',
    '更新を確認しています…',
  ),
  UpdateRuntimePhase.available => language.text(
    '可以更新',
    'Ready to update',
    '更新できます',
  ),
  UpdateRuntimePhase.downloading => language.text(
    '正在下载，可随时取消并稍后继续',
    'Downloading; you can cancel and resume later',
    'ダウンロード中です。中止して後で再開できます',
  ),
  UpdateRuntimePhase.verifying => language.text(
    '正在校验下载文件…',
    'Verifying the download…',
    'ダウンロードを検証しています…',
  ),
  UpdateRuntimePhase.permissionRequired => language.text(
    '需要允许此应用安装更新',
    'Permission is required to install this update',
    '更新のインストール許可が必要です',
  ),
  UpdateRuntimePhase.launchingInstaller => language.text(
    '正在打开系统安装界面…',
    'Opening the system installer…',
    'システムインストーラーを開いています…',
  ),
  UpdateRuntimePhase.installerOpened => language.text(
    '已交给系统安装；取消后可继续安装',
    'System installer opened; you can continue if it was cancelled',
    'システムインストーラーを開きました。中止後も再開できます',
  ),
  UpdateRuntimePhase.upToDate => language.text(
    '当前已是最新版本',
    'You are up to date',
    '最新バージョンです',
  ),
  UpdateRuntimePhase.resourcesReady => language.text(
    '资源已校验，将在下次启动时生效',
    'Resources verified; they will apply on the next launch',
    'リソースを検証しました。次回起動時に適用されます',
  ),
  UpdateRuntimePhase.error => updateErrorLabel(errorCode, language),
};

String updateErrorLabel(String? code, AppLanguage language) => switch (code) {
  'all_sources_failed' ||
  'network_timeout' ||
  'download_failed' => language.text(
    '网络连接失败，请稍后重试',
    'Network request failed. Try again later.',
    'ネットワーク接続に失敗しました。後でもう一度お試しください。',
  ),
  'sha256_mismatch' ||
  'signature_mismatch' ||
  'certificate_mismatch' => language.text(
    '更新文件校验失败，未执行安装',
    'Update verification failed. Nothing was installed.',
    '更新ファイルの検証に失敗したため、インストールしていません。',
  ),
  'resource_update_not_ready' => language.text(
    '当前引导版尚未启用资源热更新',
    'Resource hot updates are not enabled in this bootstrap build.',
    '現在のブートストラップ版はリソース更新に未対応です。',
  ),
  'delta_engine_unavailable' => language.text(
    '此设备暂不能应用差分包，请改用完整安装包',
    'Delta update is unavailable on this device. Use the full package.',
    'この端末では差分更新を利用できません。完全版 APK を使用してください。',
  ),
  'not_configured' => language.text(
    '自动更新未配置',
    'Updates are not configured',
    '自動更新は未設定です',
  ),
  'platform_not_supported' => language.text(
    '此平台暂不支持应用内更新',
    'In-app updates are not supported on this platform',
    'このプラットフォームはアプリ内更新に未対応です',
  ),
  _ => language.text(
    '更新未完成，请重试或下载完整安装包',
    'Update did not complete. Retry or use the full package.',
    '更新を完了できませんでした。再試行するか完全版 APK を使用してください。',
  ),
};

IconData _phaseIcon(UpdateRuntimePhase phase) => switch (phase) {
  UpdateRuntimePhase.checking ||
  UpdateRuntimePhase.downloading ||
  UpdateRuntimePhase.verifying ||
  UpdateRuntimePhase.launchingInstaller => Icons.sync_rounded,
  UpdateRuntimePhase.permissionRequired => Icons.admin_panel_settings_outlined,
  UpdateRuntimePhase.installerOpened => Icons.install_mobile_rounded,
  UpdateRuntimePhase.upToDate => Icons.check_circle_outline_rounded,
  UpdateRuntimePhase.disabled => Icons.cloud_off_outlined,
  _ => Icons.info_outline_rounded,
};
