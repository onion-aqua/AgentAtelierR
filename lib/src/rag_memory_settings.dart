import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'settings_detail_page.dart';

/// Local recall inspection uses the same retriever as chat; it generates no reply.
class RagMemorySettingsCard extends StatefulWidget {
  const RagMemorySettingsCard({super.key, required this.controller});

  final AppController controller;

  @override
  State<RagMemorySettingsCard> createState() => _RagMemorySettingsCardState();
}

class _RagMemorySettingsCardState extends State<RagMemorySettingsCard> {
  final _query = TextEditingController();
  bool _busy = false;
  bool _tested = false;
  String _evidence = '';
  int? _evidenceRevision;
  int? _evidenceMemoryRevision;
  String? _evidenceCharacter;

  @override
  void didUpdateWidget(covariant RagMemorySettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) _tested = false;
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _recall() async {
    final query = _query.text.trim();
    final controller = widget.controller;
    if (_busy ||
        query.isEmpty ||
        !controller.ragMemoryEnabled ||
        !controller.longTermMemoryEnabled) {
      return;
    }
    final revision = controller.dataRevision;
    final character = controller.activeCharacterId;
    setState(() => _busy = true);
    try {
      await controller.prepareRagMemory(query);
      if (!mounted ||
          widget.controller != controller ||
          revision != controller.dataRevision ||
          character != controller.activeCharacterId) {
        return;
      }
      setState(() {
        _tested = true;
        _evidence = controller.ragMemoryLastEvidence;
        _evidenceRevision = revision;
        _evidenceMemoryRevision = controller.memoryEditRevision;
        _evidenceCharacter = character;
      });
    } on Object {
      if (mounted &&
          revision == controller.dataRevision &&
          character == controller.activeCharacterId) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              controller.interfaceLanguage.text(
                '暂时无法查询本地记忆，请稍后重试。',
                'Local recall is temporarily unavailable. Please try again.',
                'ローカル記憶を検索できませんでした。しばらくしてからお試しください。',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final language = controller.interfaceLanguage;
      final enabled =
          controller.longTermMemoryEnabled && controller.ragMemoryEnabled;
      final validResult =
          _tested &&
          enabled &&
          _evidenceRevision == controller.dataRevision &&
          _evidenceMemoryRevision == controller.memoryEditRevision &&
          _evidenceCharacter == controller.activeCharacterId;
      return SettingsOptionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile.adaptive(
              key: const ValueKey('rag-memory-enabled'),
              title: Text(
                language.text(
                  '本地 RAG 记忆 · 试用',
                  'Local RAG memory · Trial',
                  'ローカル RAG 記憶・試用',
                ),
              ),
              subtitle: Text(
                language.text(
                  '每轮自动检索相关往事，使用本机多语言向量与关键词，不额外请求聊天模型。',
                  'Recall relevant history each turn with on-device multilingual embeddings and keywords. No extra chat request.',
                  '端末内の多言語ベクトルとキーワードで毎回関連する過去を検索します。追加の会話リクエストはありません。',
                ),
              ),
              value: controller.ragMemoryEnabled,
              onChanged: controller.longTermMemoryEnabled
                  ? (value) {
                      setState(() => _tested = false);
                      controller.setRagMemoryEnabled(value);
                    }
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    language.text(
                      '当前存档已归档 ${controller.ragArchiveTurnCount} 轮对话',
                      '${controller.ragArchiveTurnCount} archived turns in this save',
                      '現在のセーブの会話記録：${controller.ragArchiveTurnCount} ターン',
                    ),
                    key: const ValueKey('rag-memory-archive-count'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: Text(language.text('测试回忆', 'Test recall', '記憶を検索')),
                    subtitle: Text(
                      language.text(
                        '只查询本地记忆，不生成聊天或语音',
                        'Local lookup only; no chat or speech generation',
                        'ローカル検索のみ。会話や音声は生成しません。',
                      ),
                    ),
                    children: [
                      TextField(
                        key: const ValueKey('rag-memory-test-query'),
                        controller: _query,
                        enabled: enabled && !_busy,
                        maxLength: 300,
                        minLines: 1,
                        maxLines: 3,
                        decoration: InputDecoration(
                          labelText: language.text(
                            '想回忆什么？',
                            'What would you like to recall?',
                            '何を思い出しますか？',
                          ),
                        ),
                        onChanged: (_) => setState(() => _tested = false),
                        onSubmitted: (_) => _recall(),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          key: const ValueKey('rag-memory-test-run'),
                          onPressed: enabled && !_busy ? _recall : null,
                          icon: _busy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.manage_search_rounded),
                          label: Text(
                            language.text(
                              _busy ? '正在回忆…' : '查询',
                              _busy ? 'Recalling…' : 'Search',
                              _busy ? '検索中…' : '検索',
                            ),
                          ),
                        ),
                      ),
                      if (validResult) ...[
                        const SizedBox(height: 10),
                        SelectableText(
                          _evidence.isEmpty
                              ? language.text(
                                  '没有找到足够相关的记忆。',
                                  'No sufficiently relevant memory found.',
                                  '十分に関連する記憶は見つかりませんでした。',
                                )
                              : _evidence,
                          key: const ValueKey('rag-memory-test-results'),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        controller.ragMemoryStatus,
                        key: const ValueKey('rag-memory-status'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
