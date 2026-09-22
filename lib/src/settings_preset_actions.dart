import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'settings_slots.dart';

/// Transfers a single configuration; never imports application state.
class SettingsPresetFile {
  static Map<String, dynamic> encode(
    SettingsSlotKind kind,
    Map<String, String> entry,
  ) => {
    'format': 'agent-atelier-r-setting',
    'version': 1,
    'kind': kind.name,
    'entry': entry,
  };

  static Map<String, String> decode(Object? data, SettingsSlotKind kind) {
    if (data is! Map ||
        data['format'] != 'agent-atelier-r-setting' ||
        data['version'] != 1 ||
        data['kind'] != kind.name ||
        data['entry'] is! Map) {
      throw const FormatException('Invalid configuration type or format');
    }
    final raw = data['entry'] as Map;
    final fields = kind == SettingsSlotKind.user
        ? {
            'address',
            'portrait',
            'relationshipRole',
            'interactionStyle',
            'relationshipCustom',
            'interactionCustom',
            'preferCustom',
            'boundaries',
          }
        : {'text'};
    if (raw.keys.any((key) => !fields.contains(key)) ||
        raw.values.any((value) => value is! String) ||
        (kind != SettingsSlotKind.user && raw['text'] is! String) ||
        raw.isEmpty) {
      throw const FormatException('Invalid configuration fields');
    }
    return Map<String, String>.from(raw);
  }
}

class SettingsPresetActions extends StatelessWidget {
  const SettingsPresetActions({
    super.key,
    required this.controller,
    required this.kind,
    required this.presets,
    required this.draft,
    required this.reload,
    required this.liveDraft,
    this.openPresets,
  });
  final AppController controller;
  final SettingsSlotKind kind;
  final bool presets;
  final SettingsSlots Function() draft;
  final VoidCallback reload;
  final SettingsSlots liveDraft;
  final VoidCallback? openPresets;
  AppLanguage get language => controller.interfaceLanguage;
  String t(String zh, String en, String ja) => language.text(zh, en, ja);

  Future<int?> _choose(
    BuildContext context,
    SettingsSlots slots,
    String title, {
    bool source = false,
  }) => showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        for (var i = 0; i < SettingsSlots.count; i++)
          SimpleDialogOption(
            onPressed: source && slots.entries[i] == null
                ? null
                : () => Navigator.pop(context, i),
            child: Text(
              t('槽位 ${i + 1}', 'Slot ${i + 1}', '${i + 1}枠') +
                  (slots.entries[i] == null ? t('（空）', ' (empty)', '（空）') : ''),
            ),
          ),
      ],
    ),
  );

  Future<bool> _confirm(BuildContext context) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t('覆盖目标槽位？', 'Replace target slot?', '対象の枠を上書きしますか？')),
          content: Text(
            t(
              '将替换目标内容。当前编辑页的更改需要保存后生效。',
              'This replaces its contents. Save the editor to apply changes.',
              '内容を置き換えます。編集画面で保存すると反映されます。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('取消', 'Cancel', 'キャンセル')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('覆盖', 'Replace', '上書き')),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _run(BuildContext context, String action) async {
    try {
      final bank = draft();
      final entry = bank.entries[bank.active];
      if (action == 'export') {
        if (entry == null) return;
        await FilePicker.saveFile(
          fileName: 'AgentAtelierR-${kind.name}-${bank.active + 1}.json',
          mimeType: 'application/json',
          bytes: Uint8List.fromList(
            utf8.encode(
              const JsonEncoder.withIndent('  ')
                  .convert(SettingsPresetFile.encode(kind, entry)),
            ),
          ),
        );
        return;
      }
      if (action == 'import') {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['json'],
        );
        if (file == null) return;
        final bytes = await file.readAsBytes();
        if (bytes.length > 1024 * 1024) {
          throw const FormatException('File exceeds 1 MB');
        }
        final value = SettingsPresetFile.decode(
          jsonDecode(utf8.decode(bytes)),
          kind,
        );
        if (!context.mounted || !await _confirm(context) || !context.mounted) {
          return;
        }
        bank.entries[bank.active] = value;
        reload();
        return;
      }
      final other = presets ? liveDraft : controller.presetSlots(kind);
      final index = await _choose(
        context,
        other,
        action == 'from'
            ? t('选择来源槽位', 'Select source slot', 'コピー元を選択')
            : t('选择目标槽位', 'Select target slot', 'コピー先を選択'),
        source: action == 'from',
      );
      if (index == null || !context.mounted) return;
      if (!await _confirm(context) || !context.mounted) return;
      if (action == 'from') {
        bank.entries[bank.active] = Map<String, String>.from(
          other.entries[index]!,
        );
        reload();
      } else if (entry != null) {
        other.entries[index] = Map<String, String>.from(entry);
        if (!presets) await controller.savePresetSlots(kind, other);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              presets
                  ? t(
                      '已复制到当前设定草稿，返回并保存后生效',
                      'Copied to live draft. Go back and save to apply.',
                      '現在の設定にコピーしました。戻って保存してください。',
                    )
                  : t(
                      '已保存到独立预设',
                      'Saved to independent presets',
                      '独立プリセットに保存しました',
                    ),
            ),
          ),
        );
      }
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${t('操作失败', 'Operation failed', '操作失敗')}: $error'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (!presets)
        IconButton(
          key: const ValueKey('open-setting-presets'),
          tooltip: t('预设配置', 'Presets', 'プリセット'),
          icon: const Icon(Icons.bookmarks_outlined),
          onPressed: openPresets,
        ),
      PopupMenuButton<String>(
        tooltip: t('导入 / 导出', 'Import / export', 'インポート / エクスポート'),
        icon: const Icon(Icons.import_export),
        onSelected: (action) => _run(context, action),
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'from',
            child: Text(
              presets
                  ? t('从存档控制槽位导入', 'Copy from live slot', '現在の設定からコピー')
                  : t('从独立预设导入', 'Copy from preset', 'プリセットからコピー'),
            ),
          ),
          PopupMenuItem(
            value: 'to',
            child: Text(
              presets
                  ? t('导出到存档控制槽位', 'Copy to live slot', '現在の設定へコピー')
                  : t('导出到独立预设', 'Copy to preset', 'プリセットへコピー'),
            ),
          ),
          PopupMenuItem(
            value: 'import',
            child: Text(t('导入 JSON 文件', 'Import JSON file', 'JSONをインポート')),
          ),
          PopupMenuItem(
            value: 'export',
            child: Text(t('导出当前槽位文件', 'Export current slot', '現在の枠をエクスポート')),
          ),
        ],
      ),
    ],
  );
}
