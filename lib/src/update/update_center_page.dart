import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_localization.dart';
import '../glass_ui.dart';
import 'update_dialog.dart';
import 'update_models.dart';
import 'update_runtime.dart';
import 'update_service.dart';

/// User-facing controls and status for the self-hosted updater.
class UpdateCenterPage extends StatefulWidget {
  const UpdateCenterPage({
    super.key,
    required this.runtime,
    required this.language,
    this.liquidGlass = false,
    this.launchExternal,
  });

  final UpdateRuntime runtime;
  final AppLanguage language;
  final bool liquidGlass;
  final UpdateExternalLauncher? launchExternal;

  @override
  State<UpdateCenterPage> createState() => _UpdateCenterPageState();
}

class _UpdateCenterPageState extends State<UpdateCenterPage> {
  UpdatePreferences? _preferences;
  bool _loadingPreferences = true;
  bool _savingPreferences = false;
  bool _clearingCache = false;
  String? _localMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreferences());
  }

  @override
  void didUpdateWidget(UpdateCenterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.runtime, widget.runtime)) {
      _preferences = null;
      _loadingPreferences = true;
      unawaited(_loadPreferences());
    }
  }

  Future<void> _loadPreferences() async {
    final value = await widget.runtime.preferences();
    if (!mounted) return;
    setState(() {
      _preferences = value;
      _loadingPreferences = false;
    });
  }

  Future<void> _setAutoCheck(bool value) async {
    final current = _preferences;
    if (current == null || _savingPreferences) return;
    setState(() {
      _savingPreferences = true;
      _preferences = current.copyWith(autoCheck: value);
    });
    try {
      await widget.runtime.setAutoCheck(value);
    } on Object {
      if (mounted) {
        setState(() {
          _preferences = current;
          _localMessage = widget.language.text(
            '保存更新设置失败',
            'Could not save update settings',
            '更新設定を保存できませんでした',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _savingPreferences = false);
    }
  }

  Future<void> _setSource(UpdateSourcePreference? value) async {
    final current = _preferences;
    if (value == null || current == null || _savingPreferences) return;
    setState(() {
      _savingPreferences = true;
      _preferences = current.copyWith(sourcePreference: value);
    });
    try {
      await widget.runtime.setSourcePreference(value);
    } on Object {
      if (mounted) {
        setState(() {
          _preferences = current;
          _localMessage = widget.language.text(
            '保存更新来源失败',
            'Could not save the update source',
            '更新元を保存できませんでした',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _savingPreferences = false);
    }
  }

  Future<void> _checkNow() async {
    setState(() => _localMessage = null);
    final result = await widget.runtime.check(
      trigger: UpdateCheckTrigger.manual,
      manual: true,
    );
    if (!mounted) return;
    if (result.status == UpdateCheckStatus.failed) return;
    setState(() {
      _localMessage = switch (result.status) {
        UpdateCheckStatus.updateAvailable || UpdateCheckStatus.suppressed =>
          widget.language.text('发现可用更新', 'An update is available', '更新があります'),
        UpdateCheckStatus.upToDate => widget.language.text(
          '当前已是最新版本',
          'You are up to date',
          '最新バージョンです',
        ),
        UpdateCheckStatus.disabled => widget.language.text(
          '自动更新未配置',
          'Updates are not configured',
          '自動更新は未設定です',
        ),
        UpdateCheckStatus.throttled => widget.language.text(
          '刚刚检查过，请稍后再试',
          'Checked recently. Try again later.',
          '直前に確認済みです。後でもう一度お試しください。',
        ),
        UpdateCheckStatus.failed => '',
      };
    });
  }

  Future<void> _clearCache() async {
    if (_clearingCache || widget.runtime.busy) return;
    setState(() {
      _clearingCache = true;
      _localMessage = null;
    });
    try {
      await widget.runtime.clearCache();
      if (mounted) {
        setState(() {
          _localMessage = widget.language.text(
            '更新缓存已清理',
            'Update cache cleared',
            '更新キャッシュを削除しました',
          );
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _localMessage = widget.language.text(
            '无法清理更新缓存',
            'Could not clear the update cache',
            '更新キャッシュを削除できませんでした',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  Future<void> _openGithub() async {
    final uri = widget.runtime.plan?.manifest.notes.githubUrl;
    if (uri == null) return;
    final launcher = widget.launchExternal;
    var opened = false;
    try {
      opened =
          await (launcher?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
    } on Object {
      opened = false;
    }
    if (!mounted || opened) return;
    setState(() {
      _localMessage = widget.language.text(
        '无法打开浏览器，请稍后重试',
        'Could not open the browser. Try again later.',
        'ブラウザーを開けませんでした。後でもう一度お試しください。',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final language = widget.language;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: glassPageHeaderColor(context),
        surfaceTintColor: Colors.transparent,
        title: Text(language.text('版本中心', 'Update center', 'アップデート')),
      ),
      body: GlassPageSurface(
        liquidGlass: widget.liquidGlass,
        child: AnimatedBuilder(
          animation: widget.runtime,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _buildOverview(context),
              const Divider(height: 1),
              _buildPreferences(context),
              const Divider(height: 1),
              _buildActions(context),
              const Divider(height: 1),
              _buildStatus(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverview(BuildContext context) {
    final runtime = widget.runtime;
    final language = widget.language;
    final manifest = runtime.plan?.manifest;
    final installed = runtime.installed;
    final currentChannel =
        installed?.channel ??
        (runtime.buildConfig.enabled ? runtime.buildConfig.channel : '—');
    final currentSnapshot =
        installed?.resourceSnapshotId ??
        language.text('内置资源', 'Bundled resources', '内蔵リソース');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            language.text('版本', 'Version', 'バージョン'),
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          _ValueRow(
            label: language.text('当前版本', 'Current', '現在'),
            value: runtime.currentVersion,
          ),
          _ValueRow(
            label: language.text('当前渠道', 'Channel', 'チャンネル'),
            value: currentChannel,
          ),
          _ValueRow(
            label: language.text('内部构建', 'Internal build', '内部ビルド'),
            value: installed?.nativeBuild.toString() ?? '—',
          ),
          _ValueRow(
            label: language.text('资源快照', 'Resources', 'リソース'),
            value: currentSnapshot,
          ),
          _ValueRow(
            label: language.text('最新版本', 'Latest', '最新'),
            value: manifest?.displayVersion ?? '—',
          ),
          _ValueRow(
            label: language.text('信息来源', 'Source', '取得元'),
            value: updateOriginLabel(runtime.origin, language),
          ),
          _ValueRow(
            label: language.text('预计下载', 'Download', 'ダウンロード'),
            value:
                '${formatUpdateBytes(runtime.plan?.apk?.downloadSize ?? 0)}'
                '${runtime.plan?.resource == null ? '' : language.text(' + 按需资源', ' + missing resources', ' + 不足リソース')}',
          ),
          if ((runtime.notes ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(runtime.notes!.trim()),
          ],
        ],
      ),
    );
  }

  Widget _buildPreferences(BuildContext context) {
    final language = widget.language;
    final preferences = _preferences;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
            child: Text(
              language.text('检查设置', 'Check settings', '確認設定'),
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          SwitchListTile(
            key: const ValueKey('update-auto-check'),
            value: preferences?.autoCheck ?? true,
            onChanged: _loadingPreferences || _savingPreferences
                ? null
                : _setAutoCheck,
            title: Text(
              language.text('自动检查更新', 'Check automatically', '自動的に確認'),
            ),
            subtitle: Text(
              language.text(
                '启动和恢复前台时按频率检查',
                'Check at startup and when returning to the app',
                '起動時とアプリ復帰時に確認します',
              ),
            ),
          ),
          ListTile(
            title: Text(language.text('更新来源', 'Update source', '更新元')),
            subtitle: Text(
              language.text(
                '自动模式优先使用 Gitee，并在失败时切换备用来源',
                'Automatic prefers Gitee and falls back when unavailable',
                '自動では Gitee を優先し、失敗時に別の取得元へ切り替えます',
              ),
            ),
            trailing: DropdownButton<UpdateSourcePreference>(
              key: const ValueKey('update-source-preference'),
              value:
                  preferences?.sourcePreference ??
                  UpdateSourcePreference.automatic,
              onChanged: _loadingPreferences || _savingPreferences
                  ? null
                  : _setSource,
              items: [
                DropdownMenuItem(
                  value: UpdateSourcePreference.automatic,
                  child: Text(language.text('自动', 'Auto', '自動')),
                ),
                const DropdownMenuItem(
                  value: UpdateSourcePreference.gitee,
                  child: Text('Gitee'),
                ),
                const DropdownMenuItem(
                  value: UpdateSourcePreference.github,
                  child: Text('GitHub'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    final runtime = widget.runtime;
    final language = widget.language;
    final plan = runtime.plan;
    final resourceOnly = plan?.resource != null && plan?.apk == null;
    final canInstall = plan?.apk != null && !runtime.busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            language.text('操作', 'Actions', '操作'),
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                key: const ValueKey('update-center-start'),
                onPressed:
                    !runtime.busy &&
                        (plan?.hasUpdate ?? false) &&
                        runtime.phase != UpdateRuntimePhase.resourcesReady
                    ? () => runtime.startUpdate()
                    : null,
                icon: const Icon(Icons.system_update_alt_rounded),
                label: Text(language.text('立即更新', 'Update now', '今すぐ更新')),
              ),
              FilledButton.icon(
                key: const ValueKey('update-check-now'),
                onPressed: runtime.busy ? null : _checkNow,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(language.text('检查更新', 'Check now', '更新を確認')),
              ),
              OutlinedButton.icon(
                key: const ValueKey('update-center-full-package'),
                onPressed: canInstall
                    ? () => runtime.startUpdate(fullPackage: true)
                    : null,
                icon: const Icon(Icons.download_for_offline_outlined),
                label: Text(language.text('完整更新', 'Full update', '完全版で更新')),
              ),
              TextButton.icon(
                key: const ValueKey('update-center-github'),
                onPressed: plan?.manifest.notes.githubUrl == null
                    ? null
                    : _openGithub,
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('GitHub'),
              ),
              TextButton.icon(
                key: const ValueKey('update-clear-cache'),
                onPressed: runtime.busy || _clearingCache ? null : _clearCache,
                icon: const Icon(Icons.cleaning_services_outlined),
                label: Text(language.text('清理下载缓存', 'Clear cache', 'キャッシュを削除')),
              ),
            ],
          ),
          if (runtime.phase == UpdateRuntimePhase.downloading) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const ValueKey('update-center-cancel'),
              onPressed: runtime.cancelDownload,
              icon: const Icon(Icons.close_rounded),
              label: Text(
                language.text('取消下载', 'Cancel download', 'ダウンロードを中止'),
              ),
            ),
          ],
          if (runtime.phase == UpdateRuntimePhase.permissionRequired) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('update-center-permission'),
                  onPressed: runtime.busy
                      ? null
                      : runtime.openInstallPermissionSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: Text(
                    language.text('允许安装', 'Allow installation', 'インストールを許可'),
                  ),
                ),
                FilledButton.icon(
                  key: const ValueKey('update-center-continue'),
                  onPressed: runtime.busy ? null : runtime.continueInstall,
                  icon: const Icon(Icons.install_mobile_rounded),
                  label: Text(
                    language.text('继续安装', 'Continue install', 'インストールを続行'),
                  ),
                ),
              ],
            ),
          ],
          if (runtime.phase == UpdateRuntimePhase.installerOpened) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('update-center-reopen-installer'),
              onPressed: runtime.busy ? null : runtime.continueInstall,
              icon: const Icon(Icons.install_mobile_rounded),
              label: Text(
                language.text('继续安装', 'Continue install', 'インストールを続行'),
              ),
            ),
          ],
          if (resourceOnly) ...[
            const SizedBox(height: 12),
            Text(
              language.text(
                '资源更新无需安装 APK，校验后在下次启动生效。',
                'Resource updates apply on the next launch without APK installation.',
                'リソース更新は APK のインストールなしで次回起動時に適用されます。',
              ),
              key: const ValueKey('update-resource-ready-notice'),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            language.text(
              '代码更新下载并校验后会打开 Android 系统安装界面，由你确认安装。',
              'Code updates open the Android system installer after download and verification.',
              'コード更新はダウンロードと検証後に Android のインストーラーを開きます。',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildStatus(BuildContext context) {
    final runtime = widget.runtime;
    final language = widget.language;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            language.text(
              '下载与安装状态',
              'Download and installation',
              'ダウンロードとインストール',
            ),
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          UpdateRuntimeStatus(runtime: runtime, language: language),
          if (runtime.readyApkPath != null) ...[
            const SizedBox(height: 8),
            Text(
              language.text(
                '已保留通过校验的安装包，可继续安装。',
                'The verified installer is kept and can be installed later.',
                '検証済みの APK は保持されており、後でインストールできます。',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_localMessage != null) ...[
            const SizedBox(height: 10),
            Text(_localMessage!, key: const ValueKey('update-center-message')),
          ],
          if (_preferences?.lastSuccessfulCheckAt case final last?) ...[
            const SizedBox(height: 8),
            Text(
              '${language.text('上次成功检查', 'Last successful check', '前回の確認')}: '
              '${MaterialLocalizations.of(context).formatCompactDate(last.toLocal())} '
              '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(last.toLocal()))}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}
