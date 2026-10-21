import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_localization.dart';
import 'glass_ui.dart';

/// Desktop packages are complete folders; Android manifests/installers must
/// never be offered to a Windows user.
class DesktopUpdatesPage extends StatefulWidget {
  const DesktopUpdatesPage({
    super.key,
    required this.language,
    required this.liquidGlass,
    this.openRelease,
  });

  final AppLanguage language;
  final bool liquidGlass;
  final Future<bool> Function(Uri)? openRelease;

  static final releaseUrl = Uri.parse(
    'https://github.com/onion-aqua/AgentAtelierR/releases/latest',
  );

  @override
  State<DesktopUpdatesPage> createState() => _DesktopUpdatesPageState();
}

class _DesktopUpdatesPageState extends State<DesktopUpdatesPage> {
  bool _opening = false;
  bool _failed = false;

  String _t(String zh, String en, String ja) =>
      widget.language.text(zh, en, ja);

  Future<void> _open() async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _failed = false;
    });
    var opened = false;
    try {
      opened =
          await (widget.openRelease?.call(DesktopUpdatesPage.releaseUrl) ??
              launchUrl(
                DesktopUpdatesPage.releaseUrl,
                mode: LaunchMode.externalApplication,
              ));
    } on Object {
      opened = false;
    }
    if (!mounted) return;
    setState(() {
      _opening = false;
      _failed = !opened;
    });
  }

  @override
  Widget build(BuildContext context) => GlassPageSurface(
    liquidGlass: widget.liquidGlass,
    child: Scaffold(
      key: const ValueKey('desktop-updates-page'),
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: glassPageHeaderColor(context),
        title: Text(_t('PC 版下载与更新', 'PC downloads & updates', 'PC版のダウンロードと更新')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const ListTile(
            leading: Icon(Icons.desktop_windows_rounded),
            title: Text('AgentAtelierR 1.0.4.2'),
            subtitle: Text('Windows x64'),
          ),
          const SizedBox(height: 12),
          Text(
            _t(
              '在发布页面下载 Windows ZIP，完整解压到新目录。退出旧版本后，运行新目录中的 AgentAtelierR.exe。请保留同目录的 DLL 和 data 文件夹。',
              'Download the Windows ZIP from the release page and extract the complete archive to a new folder. Exit the old version, then run AgentAtelierR.exe in the new folder. Keep its DLLs and data folder together.',
              'リリースページからWindows ZIPを取得し、新しいフォルダーにすべて展開してください。旧版を終了してから、新しいAgentAtelierR.exeを起動します。DLLとdataフォルダーを同じ場所に保管してください。',
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _t(
              '存档、聊天记录和接口设置保存在当前 Windows 用户的数据目录，更新程序目录时会继续使用。PC 版通过完整包更新。',
              'Saves, conversations and connection settings stay in the current Windows user data folder. PC updates use the complete package.',
              'セーブ、会話、接続設定は現在のWindowsユーザーのデータ領域に保存されます。PC版の更新には完全パッケージを使用します。',
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const ValueKey('desktop-release-download'),
            onPressed: _opening ? null : _open,
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(
              _t(
                '前往 GitHub 下载 PC 版',
                'Download PC version on GitHub',
                'GitHubでPC版をダウンロード',
              ),
            ),
          ),
          if (_failed) ...[
            const SizedBox(height: 16),
            SelectableText(
              _t(
                '未能打开浏览器，可复制以下地址：',
                'Could not open the browser. Copy this URL:',
                'ブラウザーを開けません。以下のURLをコピーしてください：',
              ),
            ),
            SelectableText(DesktopUpdatesPage.releaseUrl.toString()),
          ],
        ],
      ),
    ),
  );
}
