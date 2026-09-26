import 'package:flutter/material.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'app_theme.dart';
import 'glass_ui.dart';

Future<void> showLocalSaveDialog(
  BuildContext context,
  AppController controller,
) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black45,
    builder: (dialogContext) => Theme(
      data: atelierTheme(controller.accentTheme, Brightness.dark),
      child: _LocalSaveDialog(controller: controller),
    ),
  );
}

class _LocalSaveDialog extends StatefulWidget {
  const _LocalSaveDialog({required this.controller});

  final AppController controller;

  @override
  State<_LocalSaveDialog> createState() => _LocalSaveDialogState();
}

class _LocalSaveDialogState extends State<_LocalSaveDialog> {
  bool _busy = false;

  Future<void> _manage(int index, String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (action == 'rename') {
        final input = TextEditingController(
          text: widget.controller.localSaveSlots[index]?.name ?? '',
        );
        final name = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(_text('重命名存档', 'Rename save', 'セーブ名の変更')),
            content: TextField(
              controller: input,
              maxLength: 60,
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_text('取消', 'Cancel', 'キャンセル')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, input.text),
                child: Text(_text('保存', 'Save', '保存')),
              ),
            ],
          ),
        );
        // Let the dialog finish its closing transition before releasing its controller.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        input.dispose();
        if (name != null) await widget.controller.renameLocalSlot(index, name);
      } else if (action == 'export') {
        final includeHistory = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              _text(
                '是否包含历史对话？',
                'Include conversation history?',
                '会話履歴を含めますか？',
              ),
            ),
            content: Text(
              _text(
                '历史对话包含此存档中的用户发言、旁白和${widget.controller.activeCharacterProfile.names.chinese}回复。不包含时，导入后的存档将从空白对话开始。',
                'History includes the user, narration and ${widget.controller.activeCharacterProfile.names.english} replies in this save. Without it, the imported save starts with an empty conversation.',
                'このセーブ内のユーザー、ナレーション、${widget.controller.activeCharacterProfile.names.japanese}の会話を含みます。含めない場合、読み込んだセーブの会話は空になります。',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_text('取消', 'Cancel', 'キャンセル')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(_text('不包含', 'Without history', '含めない')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(_text('包含', 'Include', '含める')),
              ),
            ],
          ),
        );
        if (includeHistory == null || !mounted) return;
        await FilePicker.saveFile(
          fileName:
              'AgentAtelierR-save-${index + 1}-${DateTime.now().millisecondsSinceEpoch}.json',
          bytes: Uint8List.fromList(
            utf8.encode(
              const JsonEncoder.withIndent('  ').convert(
                widget.controller.exportLocalSlot(
                  index,
                  includeConversationHistory: includeHistory,
                ),
              ),
            ),
          ),
          mimeType: 'application/json',
        );
      } else if (action == 'import') {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: const ['json'],
        );
        if (file == null || !mounted) return;
        final data = jsonDecode(
          utf8.decode(await file.readAsBytes()),
        ) as Map<String, dynamic>;
        if (!mounted) return;
        if (widget.controller.localSaveSlots[index] != null &&
            !await _confirm(
              title: _text('覆盖存档？', 'Overwrite save?', '上書きしますか？'),
              body: _text(
                '导入将替换此槽位，不改变当前游戏。',
                'Import replaces this slot, not the current game.',
                'このスロットのみ置換し、現在のゲームは変更しません。',
              ),
            )) {
          return;
        }
        await widget.controller.importLocalSlot(index, data);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_text('操作失败', 'Operation failed', '操作失敗')}: $error',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _text(String zh, String en, String ja) =>
      widget.controller.interfaceLanguage.text(zh, en, ja);

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<bool> _confirm({required String title, required String body}) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(_text('取消', 'Cancel', 'キャンセル')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(_text('确认', 'Confirm', '確認')),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save(int index, bool occupied) async {
    if (_busy) return;
    if (occupied) {
      final confirmed = await _confirm(
        title: _text('覆盖存档？', 'Overwrite save?', 'セーブを上書きしますか？'),
        body: _text(
          '槽位 ${index + 1} 的旧存档将被替换。',
          'The existing save in slot ${index + 1} will be replaced.',
          'スロット ${index + 1} の既存セーブは置き換えられます。',
        ),
      );
      if (!mounted || !confirmed) return;
    }
    setState(() => _busy = true);
    try {
      await widget.controller.saveToLocalSlot(index);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_text('存档完成', 'Game saved', 'セーブしました'))),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_text('存档失败', 'Save failed', 'セーブ失敗')}: $error'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    final slots = widget.controller.localSaveSlots;
    final index = slots.indexWhere((slot) => slot == null);
    if (index < 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _text(
                '存档槽位已满，请先删除一个存档。',
                'All save slots are full. Delete one first.',
                'セーブスロットが一杯です。先に1つ削除してください。',
              ),
            ),
          ),
        );
      }
      return;
    }
    final input = TextEditingController(
      text: _text(
        '新存档 ${index + 1}',
        'New save ${index + 1}',
        '新規セーブ ${index + 1}',
      ),
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_text('新建存档', 'New save', '新規セーブ')),
        content: TextField(
          controller: input,
          maxLength: 60,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _text('存档名称', 'Save name', 'セーブ名'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_text('取消', 'Cancel', 'キャンセル')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: Text(_text('创建', 'Create', '作成')),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (!mounted || name == null) return;
    setState(() => _busy = true);
    try {
      await widget.controller.createLocalSlot(index, name: name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _text(
              '已创建并切换到新存档',
              'Created and switched to the new save',
              '新規セーブを作成して切り替えました',
            ),
          ),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_text('创建失败', 'Create failed', '作成失敗')}: $error'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load(int index) async {
    if (_busy) return;
    final confirmed = await _confirm(
      title: _text('读取存档？', 'Load save?', 'セーブを読み込みますか？'),
      body: _text(
        '当前尚未保存的进度会被槽位 ${index + 1} 替换。',
        'Unsaved progress will be replaced by slot ${index + 1}.',
        '未保存の進行状況はスロット ${index + 1} の内容に置き換えられます。',
      ),
    );
    if (!mounted || !confirmed) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.controller.loadFromLocalSlot(index);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(content: Text(_text('读取完成', 'Save loaded', 'ロードしました'))),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_text('读取失败', 'Load failed', 'ロード失敗')}: $error'),
        ),
      );
      setState(() => _busy = false);
    }
  }

  Future<void> _delete(int index) async {
    if (_busy) return;
    final confirmed = await _confirm(
      title: _text('删除存档？', 'Delete save?', 'セーブを削除しますか？'),
      body: _text(
        '槽位 ${index + 1} 删除后无法恢复。',
        'Slot ${index + 1} cannot be recovered after deletion.',
        'スロット ${index + 1} は削除後に復元できません。',
      ),
    );
    if (!mounted || !confirmed) return;
    setState(() => _busy = true);
    try {
      await widget.controller.deleteLocalSlot(index);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_text('删除失败', 'Delete failed', '削除失敗')}: $error'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slots = widget.controller.localSaveSlots;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final foreground = theme.colorScheme.onSurface;
    final secondary = foreground.withValues(alpha: 0.72);
    final tertiary = foreground.withValues(alpha: 0.60);
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 650),
        child: GlassSurface(
          liquidGlass: widget.controller.liquidGlassChatUi,
          tone: dark ? GlassTone.dark : GlassTone.light,
          fallbackColor: dark
              ? const Color(0xE0202428)
              : const Color(0xE8F1F3F4),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 30,
              offset: Offset(0, 14),
            ),
          ],
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 8, 8),
                child: Row(
                  children: [
                    Icon(Icons.save_outlined, color: foreground),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _text('本地存档', 'Local saves', 'ローカルセーブ'),
                        style: TextStyle(
                          color: foreground,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _busy ? null : _create,
                      icon: const Icon(Icons.add_box_outlined),
                      label: Text(_text('新建存档', 'New save', '新規セーブ')),
                      style: TextButton.styleFrom(foregroundColor: foreground),
                    ),
                    IconButton(
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      tooltip: _text('关闭', 'Close', '閉じる'),
                      color: foreground,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: foreground.withValues(alpha: .18)),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: slots.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final slot = slots[index];
                    return GlassContentCard(
                      liquidGlass: widget.controller.liquidGlassChatUi,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 16,
                                  backgroundColor: foreground.withValues(
                                    alpha: .12,
                                  ),
                                  foregroundColor: foreground,
                                  child: Text('${index + 1}'),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    slot == null
                                        ? _text('空存档位', 'Empty slot', '空きスロット')
                                        : slot.name.isEmpty
                                        ? slot.location
                                        : slot.name,
                                    style: TextStyle(
                                      color: foreground,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (widget.controller.activeLocalSaveSlot ==
                                    index)
                                  Tooltip(
                                    message: _text(
                                      '当前存档',
                                      'Active save',
                                      '現在のセーブ',
                                    ),
                                    child: Icon(
                                      Icons.check_circle_rounded,
                                      color: theme.colorScheme.primary,
                                      size: 20,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (slot != null) ...[
                              Text(
                                _formatTime(slot.savedAt),
                                style: TextStyle(color: secondary),
                              ),
                              const SizedBox(height: 4),
                            ],
                            Text(
                              slot == null
                                  ? _text(
                                      '点击保存当前进度',
                                      'Save current progress',
                                      '現在の進行状況を保存',
                                    )
                                  : '${slot.messageCount} ${_text('条消息', 'messages', '件のメッセージ')}\n${slot.preview}',
                              maxLines: slot == null ? null : 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: tertiary),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              alignment: WrapAlignment.end,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 8,
                              children: [
                                if (slot != null)
                                  TextButton.icon(
                                    onPressed:
                                        _busy ||
                                            widget
                                                    .controller
                                                    .activeLocalSaveSlot ==
                                                index
                                        ? null
                                        : () => _load(index),
                                    label: Text(_text('读取', 'Load', 'ロード')),
                                    style: TextButton.styleFrom(
                                      foregroundColor: foreground,
                                    ),
                                    icon: Icon(
                                      widget.controller.activeLocalSaveSlot ==
                                              index
                                          ? Icons.check_rounded
                                          : Icons.download_rounded,
                                    ),
                                  ),
                                TextButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => _save(index, slot != null),
                                  label: Text(_text('保存', 'Save', 'セーブ')),
                                  style: TextButton.styleFrom(
                                    foregroundColor: foreground,
                                  ),
                                  icon: const Icon(Icons.save_rounded),
                                ),
                                PopupMenuButton<String>(
                                  enabled: !_busy,
                                  tooltip: _text(
                                    '更多操作',
                                    'More actions',
                                    'その他の操作',
                                  ),
                                  icon: Icon(Icons.more_vert, color: secondary),
                                  onSelected: (action) => action == 'delete'
                                      ? _delete(index)
                                      : _manage(index, action),
                                  itemBuilder: (_) => [
                                    if (slot != null)
                                      PopupMenuItem(
                                        value: 'rename',
                                        child: Text(
                                          _text('重命名', 'Rename', '名前変更'),
                                        ),
                                      ),
                                    if (slot != null)
                                      PopupMenuItem(
                                        value: 'export',
                                        child: Text(
                                          _text('导出', 'Export', 'エクスポート'),
                                        ),
                                      ),
                                    PopupMenuItem(
                                      value: 'import',
                                      child: Text(
                                        _text('导入', 'Import', 'インポート'),
                                      ),
                                    ),
                                    if (slot != null)
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text(
                                          _text('删除', 'Delete', '削除'),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
