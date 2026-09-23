import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'app_theme.dart';
import 'chat_segments.dart';
import 'glass_ui.dart';
import 'settings_detail_page.dart';

enum ConversationHistorySpeaker { user, narrator, ryza }

class ConversationHistoryEntry {
  const ConversationHistoryEntry({required this.speaker, required this.text});

  final ConversationHistorySpeaker speaker;
  final String text;
}

class ConversationHistoryGroup {
  const ConversationHistoryGroup({
    required this.slotIndex,
    required this.name,
    required this.savedAt,
    required this.entries,
  });

  final int slotIndex;
  final String name;
  final DateTime savedAt;
  final List<ConversationHistoryEntry> entries;
}

List<ConversationHistoryEntry> visibleConversationHistory(
  Iterable<ChatMessage> messages,
) {
  final result = <ConversationHistoryEntry>[];
  for (final message in messages) {
    if (message.isFailure) continue;
    if (message.isUser) {
      final parts = parseUserComposerParts(message.text);
      if (parts.narration.isNotEmpty) {
        result.add(
          ConversationHistoryEntry(
            speaker: ConversationHistorySpeaker.narrator,
            text: parts.narration,
          ),
        );
      }
      if (parts.speech.isNotEmpty) {
        result.add(
          ConversationHistoryEntry(
            speaker: ConversationHistorySpeaker.user,
            text: parts.speech,
          ),
        );
      }
      if (parts.bottomNarration.isNotEmpty) {
        result.add(
          ConversationHistoryEntry(
            speaker: ConversationHistorySpeaker.narrator,
            text: parts.bottomNarration,
          ),
        );
      }
      continue;
    }
    for (final segment in parseAssistantSegments(message.text)) {
      final speaker = switch (segment.speaker) {
        ChatSpeaker.narrator => ConversationHistorySpeaker.narrator,
        ChatSpeaker.ryza => ConversationHistorySpeaker.ryza,
        ChatSpeaker.character || ChatSpeaker.translation => null,
      };
      if (speaker == null) continue;
      final text = displayTextForAssistantSegment(segment).trim();
      if (text.isNotEmpty) {
        result.add(ConversationHistoryEntry(speaker: speaker, text: text));
      }
    }
  }
  return result;
}

List<ConversationHistoryGroup> savedConversationHistory(
  AppController controller,
) {
  final groups = <ConversationHistoryGroup>[];
  for (final slot in controller.localSaveSlots.whereType<LocalSaveSlot>()) {
    final data = controller.exportLocalSlot(slot.index);
    final snapshot = data['snapshot'];
    if (snapshot is! Map) continue;
    final rawMessages = snapshot['messages'];
    final messages = (rawMessages is List ? rawMessages : const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(ChatMessage.fromJson);
    final entries = visibleConversationHistory(messages);
    if (entries.isEmpty) continue;
    groups.add(
      ConversationHistoryGroup(
        slotIndex: slot.index,
        name: slot.name,
        savedAt: slot.savedAt,
        entries: entries,
      ),
    );
  }
  return groups;
}

class ConversationHistoryPage extends StatefulWidget {
  const ConversationHistoryPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<ConversationHistoryPage> createState() =>
      _ConversationHistoryPageState();
}

class _ConversationHistoryPageState extends State<ConversationHistoryPage> {
  final _searchController = TextEditingController();
  String _query = '';

  AppLanguage get _language => widget.controller.interfaceLanguage;

  String _t(String zh, String en, String ja) => _language.text(zh, en, ja);

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _slotName(ConversationHistoryGroup group) => group.name.trim().isEmpty
      ? _t(
          '存档 ${group.slotIndex + 1}',
          'Save ${group.slotIndex + 1}',
          'セーブ ${group.slotIndex + 1}',
        )
      : group.name.trim();

  String _speakerLabel(ConversationHistorySpeaker speaker) => switch (speaker) {
    ConversationHistorySpeaker.user => _t('用户', 'You', 'あなた'),
    ConversationHistorySpeaker.narrator => _t('旁白', 'Narration', 'ナレーション'),
    ConversationHistorySpeaker.ryza => _t('莱莎', 'Ryza', 'ライザ'),
  };

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final normalizedQuery = _query.trim().toLowerCase();
    final groups = savedConversationHistory(widget.controller)
        .map((group) {
          if (normalizedQuery.isEmpty) return group;
          final nameMatches = _slotName(group)
              .toLowerCase()
              .contains(normalizedQuery);
          final entries = nameMatches
              ? group.entries
              : group.entries
                    .where(
                      (entry) =>
                          entry.text.toLowerCase().contains(normalizedQuery) ||
                          _speakerLabel(entry.speaker)
                              .toLowerCase()
                              .contains(normalizedQuery),
                    )
                    .toList(growable: false);
          return ConversationHistoryGroup(
            slotIndex: group.slotIndex,
            name: group.name,
            savedAt: group.savedAt,
            entries: entries,
          );
        })
        .where((group) => group.entries.isNotEmpty)
        .toList(growable: false);

    return SettingsDetailPage(
      controller: widget.controller,
      title: Text(_t('历史对话', 'Conversation history', '会話履歴')),
      content: Column(
        children: [
          TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: _t('清除搜索', 'Clear search', '検索を消去'),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
              hintText: _t(
                '搜索存档名或对话内容',
                'Search save names or dialogue',
                'セーブ名または会話を検索',
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  Icon(
                    Icons.history_toggle_off_rounded,
                    size: 42,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    normalizedQuery.isEmpty
                        ? _t(
                            '暂无已保存的历史对话',
                            'No saved conversation history',
                            '保存された会話履歴はありません',
                          )
                        : _t(
                            '没有匹配的历史对话',
                            'No matching conversations',
                            '一致する会話はありません',
                          ),
                  ),
                ],
              ),
            )
          else
            for (final group in groups) ...[
              GlassSurface(
                liquidGlass: widget.controller.liquidGlassChatUi,
                borderRadius: BorderRadius.circular(12),
                fallbackColor: dark
                    ? const Color(0xB8202428)
                    : const Color(0xB8F1F3F4),
                tone: dark ? GlassTone.dark : GlassTone.light,
                child: ExpansionTile(
                  initiallyExpanded: normalizedQuery.isNotEmpty,
                  iconColor: colors.onSurfaceVariant,
                  collapsedIconColor: colors.onSurfaceVariant,
                  leading: Icon(
                    Icons.save_outlined,
                    color: colors.onSurfaceVariant,
                  ),
                  title: Text(
                    _slotName(group),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    '${_formatTime(group.savedAt)} · ${group.entries.length} '
                    '${_t('条', 'entries', '件')}',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  children: [
                    Divider(height: 1, color: colors.outlineVariant),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 18),
                      child: MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                          textScaler: TextScaler.linear(
                            MediaQuery.textScalerOf(context).scale(14) /
                                14 *
                                (Theme.of(context)
                                        .extension<DialogueAppearance>()
                                        ?.fontScale ??
                                    1),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final entry in group.entries)
                              _HistoryDialogueEntry(
                                entry: entry,
                                language: _language,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }
}

class _HistoryDialogueEntry extends StatelessWidget {
  const _HistoryDialogueEntry({required this.entry, required this.language});

  final ConversationHistoryEntry entry;
  final AppLanguage language;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: switch (entry.speaker) {
      ConversationHistorySpeaker.narrator => _narration(context),
      ConversationHistorySpeaker.user => _user(context),
      ConversationHistorySpeaker.ryza => _ryza(context),
    },
  );

  Widget _narration(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 1, right: 8),
        child: Icon(
          Icons.menu_rounded,
          size: 18,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      Expanded(
        child: Text(
          entry.text,
          style: TextStyle(
            color:
                Theme.of(context).extension<DialogueAppearance>()?.textColor ??
                Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 13,
            fontStyle: FontStyle.italic,
            height: 1.38,
          ),
        ),
      ),
    ],
  );

  Widget _user(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        entry.text,
        textAlign: TextAlign.right,
        style: TextStyle(
          color:
              Theme.of(context).extension<DialogueAppearance>()?.textColor ??
              Theme.of(context).colorScheme.onSurface,
          height: 1.4,
        ),
      ),
    ),
  );

  Widget _ryza(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.12),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(
              'assets/images/chara_icons/ryza.png',
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Icon(
                Icons.person_outline_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  language.text('莱莎', 'Ryza', 'ライザ'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  entry.text,
                  style: TextStyle(
                    color:
                        Theme.of(context)
                            .extension<DialogueAppearance>()
                            ?.textColor ??
                        Theme.of(context).colorScheme.onSurface,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
