import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'conversation_collection_store.dart';
import 'collection_text_parts.dart';
import 'glass_ui.dart';
import 'settings_detail_page.dart';
import 'voice_playback_progress.dart';

class ConversationCollectionsPage extends StatefulWidget {
  const ConversationCollectionsPage({super.key, required this.controller});
  final AppController controller;
  @override
  State<ConversationCollectionsPage> createState() => _CollectionsState();
}

class _CollectionsState extends State<ConversationCollectionsPage> {
  final _player = AudioPlayer();
  List<Map<String, dynamic>> _cards = [];
  String _query = '';
  final Set<String> _expanded = {};
  bool _matches(Map<String, dynamic> card) {
    final query = _query.trim().toLowerCase();
    return query.isEmpty ||
        (card['name'] as String).toLowerCase().contains(query) ||
        (card['items'] as List).any(
          (item) => (item['text'] as String).toLowerCase().contains(query),
        );
  }

  String _countsLabel(Map<String, dynamic> card) {
    final counts = collectionCardCounts(card);
    return _t(
      '${counts.dialogue} 条对话，${counts.voice} 条语音，${counts.narration} 条旁白',
      '${counts.dialogue} dialogue · ${counts.voice} audio · ${counts.narration} narration',
      '台詞 ${counts.dialogue} 件・音声 ${counts.voice} 件・ナレーション ${counts.narration} 件',
    );
  }

  bool _busy = false;
  String? _playing;
  int _generation = 0;
  Completer<void>? _cancel;
  void _cancelPlayback() {
    if (_cancel != null && !_cancel!.isCompleted) _cancel!.complete();
  }

  String _t(String zh, String en, String ja) =>
      widget.controller.interfaceLanguage.text(zh, en, ja);

  @override
  void initState() {
    super.initState();
    _run(_refresh);
  }

  @override
  void dispose() {
    _generation++;
    _cancelPlayback();
    _player.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final characterId = widget.controller.activeCharacterId;
    final store = await ConversationCollectionStore.open(
      characterId: characterId,
    );
    final cards = await store.cards();
    if (mounted && widget.controller.activeCharacterId == characterId) {
      setState(() => _cards = cards.reversed.toList());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_t('操作失败', 'Operation failed', '操作失敗')}: $error'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _play(Map<String, dynamic> card, {int? audioIndex}) async {
    final generation = ++_generation;
    _cancelPlayback();
    final cancellation = Completer<void>();
    _cancel = cancellation;
    final stop = audioIndex == null && _playing == card['id'];
    setState(() => _playing = stop ? null : card['id'] as String);
    await _player.stop();
    if (stop) return;
    try {
      final store = await ConversationCollectionStore.open(
        characterId: widget.controller.activeCharacterId,
      );
      final files = card['audio'] as List;
      for (final audio in audioIndex == null ? files : [files[audioIndex]]) {
        if (!mounted || generation != _generation) return;
        final complete = Completer<void>();
        final subscription = _player.onPlayerComplete.listen((_) {
          if (!complete.isCompleted) complete.complete();
        });
        try {
          await _player.setVolume(widget.controller.voiceVolume);
          if (!mounted || generation != _generation) return;
          await _player.play(DeviceFileSource(store.path(audio as String)));
          await Future.any([complete.future, cancellation.future])
              .timeout(const Duration(minutes: 10));
        } finally {
          await subscription.cancel();
        }
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _playing = null);
    }
  }

  Future<void> _action(Map<String, dynamic> card, String action) async {
    final store = await ConversationCollectionStore.open(
      characterId: widget.controller.activeCharacterId,
    );
    if (!mounted) return;
    final id = card['id'] as String;
    if (action == 'export') {
      await FilePicker.saveFile(
        fileName: '$id.zip',
        bytes: await store.export(id),
        mimeType: 'application/zip',
      );
    } else if (action == 'rename') {
      var name = card['name'] as String;
      final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_t('重命名', 'Rename', '名前変更')),
          content: TextFormField(
            initialValue: name,
            maxLength: 60,
            onChanged: (value) => name = value,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_t('取消', 'Cancel', 'キャンセル')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, name),
              child: Text(_t('保存', 'Save', '保存')),
            ),
          ],
        ),
      );
      if (result != null) await store.rename(id, result);
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_t('删除收藏？', 'Delete collection?', 'お気に入りを削除しますか？')),
          content: Text(
            _t(
              '将删除此卡片和收藏的语音，无法撤销。',
              'Deletes this card and its saved audio permanently.',
              'カードと保存音声を削除します。元に戻せません。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_t('取消', 'Cancel', 'キャンセル')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_t('删除', 'Delete', '削除')),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        if (_playing == id) {
          _generation++;
          _cancelPlayback();
          await _player.stop();
          _playing = null;
        }
        await store.delete(id);
      }
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => SettingsDetailPage(
    controller: widget.controller,
    title: Text(_t('语音和文字收藏', 'Voice & text collections', '音声・テキストのお気に入り')),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _t(
            '语音缓存最多保留最近 50 轮；收藏独立保存，不受存档或缓存清理影响。导出 ZIP 包含文字及所选音频。',
            'Recent voice cache: 50 replies. Collections are independent of saves and cache cleanup. ZIP exports include text and selected audio.',
            '音声キャッシュは最新50件。お気に入りはセーブと独立し、キャッシュ削除の影響を受けません。ZIPにテキストと音声を含みます。',
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: TextField(
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: _t('搜索收藏名称或文字', 'Search names or text', '名前・テキストを検索'),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_cards.isNotEmpty && !_cards.any(_matches))
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _t('没有找到匹配的收藏', 'No matching collections', '一致するお気に入りがありません'),
            ),
          ),
        if (_cards.isEmpty && !_busy)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _t(
                '尚无收藏，请在对话框中多选收藏。',
                'No collections. Select messages in chat to save one.',
                'チャットでメッセージを選択して保存してください。',
              ),
            ),
          ),
        for (final card in _cards.where(_matches))
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: GlassSurface(
              liquidGlass: widget.controller.liquidGlassChatUi,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          tooltip: _expanded.contains(card['id'])
                              ? _t('折叠', 'Collapse', '閉じる')
                              : _t('展开', 'Expand', '開く'),
                          icon: Icon(
                            _expanded.contains(card['id'])
                                ? Icons.expand_less
                                : Icons.expand_more,
                          ),
                          onPressed: () => setState(() {
                            final id = card['id'] as String;
                            if (!_expanded.remove(id)) _expanded.add(id);
                          }),
                        ),
                        Expanded(
                          child: Text(
                            (card['name'] as String).isEmpty
                                ? _t('对话收藏', 'Conversation', '会話')
                                : card['name'] as String,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        if ((card['audio'] as List).isNotEmpty)
                          IconButton(
                            onPressed: _busy ? null : () => _play(card),
                            icon: Icon(
                              _playing == card['id']
                                  ? Icons.stop_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                          ),
                        PopupMenuButton<String>(
                          enabled: !_busy,
                          onSelected: (action) =>
                              _run(() => _action(card, action)),
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'rename',
                              child: Text(_t('重命名', 'Rename', '名前変更')),
                            ),
                            PopupMenuItem(
                              value: 'export',
                              child: Text(_t('导出', 'Export', 'エクスポート')),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text(_t('删除', 'Delete', '削除')),
                            ),
                          ],
                        ),
                      ],
                    ),
                    if ((card['audio'] as List).isNotEmpty)
                      _playing == card['id']
                          ? VoicePlaybackProgress(
                              key: ValueKey(card['id']),
                              player: _player,
                            )
                          : const LinearProgressIndicator(
                              value: 0,
                              minHeight: 3,
                            ),
                    Text(
                      (card['createdAt'] as String)
                          .replaceFirst('T', ' ')
                          .split('.')
                          .first,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      _countsLabel(card),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_expanded.contains(card['id']))
                      for (final item in card['items'] as List)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item['isUser'] == true
                                    ? _t('你', 'You', 'あなた')
                                    : _t('角色回复', 'Reply', '返答'),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              for (final part in collectionTextParts(
                                item['text'] as String,
                                item['speech'] as List? ?? [],
                                (card['audio'] as List).length,
                              ))
                                if (part.audioIndex == null)
                                  if (part.text.trim().isNotEmpty)
                                    SelectableText(part.text.trim())
                                  else
                                    const SizedBox.shrink()
                                else
                                  TextButton.icon(
                                    onPressed: _busy
                                        ? null
                                        : () => _play(
                                            card,
                                            audioIndex: part.audioIndex!,
                                          ),
                                    icon: const Icon(
                                      Icons.play_arrow_rounded,
                                      size: 18,
                                    ),
                                    label: Text(
                                      part.text,
                                      textAlign: TextAlign.start,
                                    ),
                                  ),
                              if ((item['audioIndexes'] as List).isNotEmpty)
                                Text('♫ ${_t('已收藏语音', 'Saved audio', '保存音声')}'),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
