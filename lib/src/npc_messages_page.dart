import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'glass_ui.dart';
import 'npc_chat_contacts.dart';
import 'npc_chat_models.dart';
import 'npc_chat_service.dart';
import 'virtual_phone.dart';

/// NPC private messages live independently from the character's main dialogue.
/// The controller owns generation; closing this page does not cancel a reply.
class NpcMessagesPage extends StatefulWidget {
  const NpcMessagesPage({
    super.key,
    required this.controller,
    this.service,
    this.liquidGlass = false,
  });

  final AppController controller;
  final NpcChatService? service;
  final bool liquidGlass;

  @override
  State<NpcMessagesPage> createState() => _NpcMessagesPageState();
}

class _NpcMessagesPageState extends State<NpcMessagesPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _drafts = <String, TextEditingController>{};
  final _localErrors = <String, String>{};
  late NpcChatService _service;
  late int _revision;
  String? _selectedId;
  LocalHistoryEntry? _contactHistory;
  LocalHistoryEntry? _settingsHistory;
  bool _settingsOpen = false;
  bool _disposing = false;
  bool _followTail = true;
  int? _messageSignature;

  AppLanguage get _language => widget.controller.interfaceLanguage;
  bool get _glass =>
      GlassStyleScope.resolve(context, fallback: widget.liquidGlass);
  NpcChatContact? get _selected => widget.controller.npcMessagingContacts
      .where((contact) => contact.id == _selectedId)
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? widget.controller.npcMessaging;
    _revision = widget.controller.dataRevision;
    widget.controller.addListener(_controllerChanged);
    _search.addListener(_searchChanged);
    _scroll.addListener(_scrollChanged);
  }

  @override
  void didUpdateWidget(NpcMessagesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
      _resetSession();
    }
    _service = widget.service ?? widget.controller.npcMessaging;
  }

  void _searchChanged() {
    if (mounted) setState(() {});
  }

  void _scrollChanged() {
    if (_scroll.hasClients) _followTail = _scroll.position.extentAfter < 80;
  }

  void _controllerChanged() {
    if (widget.controller.dataRevision != _revision) _resetSession();
  }

  void _resetSession() {
    _revision = widget.controller.dataRevision;
    final settingsHistory = _settingsHistory;
    _settingsHistory = null;
    _settingsOpen = false;
    final history = _contactHistory;
    _contactHistory = null;
    _selectedId = null;
    _messageSignature = null;
    _localErrors.clear();
    _search.clear();
    final oldDrafts = _drafts.values.toList();
    _drafts.clear();
    // Text fields retire their old controller during the next rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final draft in oldDrafts) {
        draft.dispose();
      }
    });
    settingsHistory?.remove();
    history?.remove();
    if (mounted && !_disposing) setState(() {});
  }

  void _openContact(NpcChatContact contact) {
    if (_selectedId != null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final route = ModalRoute.of(context);
    LocalHistoryEntry? history;
    if (route != null) {
      history = LocalHistoryEntry(
        onRemove: () {
          if (!identical(_contactHistory, history)) return;
          _contactHistory = null;
          _selectedId = null;
          _messageSignature = null;
          FocusManager.instance.primaryFocus?.unfocus();
          if (mounted && !_disposing) setState(() {});
        },
      );
      _contactHistory = history;
      route.addLocalHistoryEntry(history);
    }
    _drafts.putIfAbsent(contact.id, TextEditingController.new);
    setState(() {
      _selectedId = contact.id;
      _messageSignature = null;
      _followTail = true;
    });
  }

  void _backToContacts() {
    final history = _contactHistory;
    if (history != null) {
      history.remove();
    } else {
      setState(() => _selectedId = null);
    }
  }

  void _openSettings() {
    if (_settingsOpen) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final route = ModalRoute.of(context);
    LocalHistoryEntry? history;
    if (route != null) {
      history = LocalHistoryEntry(
        onRemove: () {
          if (!identical(_settingsHistory, history)) return;
          _settingsHistory = null;
          _settingsOpen = false;
          if (mounted && !_disposing) setState(() {});
        },
      );
      _settingsHistory = history;
      route.addLocalHistoryEntry(history);
    }
    setState(() => _settingsOpen = true);
  }

  void _backFromSettings() {
    final history = _settingsHistory;
    if (history != null) {
      history.remove();
    } else {
      setState(() => _settingsOpen = false);
    }
  }

  @override
  void dispose() {
    _disposing = true;
    widget.controller.removeListener(_controllerChanged);
    _settingsHistory?.remove();
    _contactHistory?.remove();
    _search.dispose();
    _scroll.dispose();
    for (final draft in _drafts.values) {
      draft.dispose();
    }
    super.dispose();
  }

  Future<void> _send(NpcChatContact contact) async {
    final draft = _drafts[contact.id]!;
    final text = draft.text.trim();
    if (text.isEmpty || _service.isSending(contact.id)) return;
    final previousMessageId = widget.controller.npcChats
        .threadFor(contact.id)
        .messages
        .lastOrNull
        ?.id;
    setState(() {
      _followTail = true;
      _localErrors.remove(contact.id);
    });
    try {
      final operation = _service.send(contact.id, text);
      final last = widget.controller.npcChats
          .threadFor(contact.id)
          .messages
          .lastOrNull;
      // Keep the draft when configuration checks reject a send immediately.
      if (last != null &&
          last.id != previousMessageId &&
          last.role == NpcChatRole.user) {
        draft.clear();
      }
      await operation;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _localErrors[contact.id] = _language.text(
          '发送失败，请重试。',
          'Could not send the message. Please try again.',
          '送信できませんでした。もう一度お試しください。',
        );
      });
    }
  }

  Future<void> _retry(NpcChatContact contact) async {
    if (_service.isSending(contact.id)) return;
    setState(() {
      _followTail = true;
      _localErrors.remove(contact.id);
    });
    await _service.retry(contact.id);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.controller, _service]),
    builder: (context, _) {
      final contact = _selected;
      final inPhone =
          context.dependOnInheritedWidgetOfExactType<VirtualPhoneScope>() !=
          null;
      return PopScope(
        canPop: MediaQuery.viewInsetsOf(context).bottom == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) FocusManager.instance.primaryFocus?.unfocus();
        },
        child: GlassPageSurface(
          liquidGlass: _glass,
          child: Scaffold(
            key: const ValueKey('npc-messages-page'),
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              toolbarHeight: 56,
              automaticallyImplyLeading: false,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              flexibleSpace: GlassSurface(
                liquidGlass: _glass,
                backdropBlur: false,
                borderRadius: BorderRadius.zero,
                tone: Theme.of(context).brightness == Brightness.dark
                    ? GlassTone.dark
                    : GlassTone.light,
                fallbackColor: glassPageHeaderColor(context),
                child: const SizedBox.expand(),
              ),
              leading: !inPhone && (contact != null || _settingsOpen)
                  ? Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: GlassIconButton(
                        size: 48,
                        liquidGlass: _glass,
                        icon: Icons.chevron_left_rounded,
                        iconWidget: const Icon(
                          Icons.chevron_left_rounded,
                          size: 32,
                        ),
                        tooltip: _settingsOpen
                            ? _language.text(
                                '返回信息',
                                'Back to messages',
                                'メッセージに戻る',
                              )
                            : _language.text(
                                '返回联系人',
                                'Back to contacts',
                                '連絡先に戻る',
                              ),
                        onPressed: _settingsOpen
                            ? _backFromSettings
                            : _backToContacts,
                      ),
                    )
                  : null,
              leadingWidth: !inPhone && (contact != null || _settingsOpen)
                  ? 54
                  : null,
              title: Padding(
                padding: EdgeInsets.only(left: inPhone ? 40 : 0),
                child: Text(
                  _settingsOpen
                      ? _language.text('信息设置', 'Message settings', 'メッセージ設定')
                      : contact?.names.forLanguage(_language) ??
                            _language.text('信息', 'Messages', 'メッセージ'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              actions: [
                if (!_settingsOpen)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GlassIconButton(
                      key: const ValueKey('npc-message-settings-button'),
                      size: 44,
                      liquidGlass: _glass,
                      icon: Icons.settings_rounded,
                      tooltip: _language.text(
                        '信息设置',
                        'Message settings',
                        'メッセージ設定',
                      ),
                      onPressed: _openSettings,
                    ),
                  ),
              ],
            ),
            body: _settingsOpen
                ? _settings(context)
                : contact == null
                ? _contacts(context)
                : _conversation(context, contact),
          ),
        ),
      );
    },
  );

  Widget _settings(BuildContext context) {
    final controller = widget.controller;
    final names = controller.activeCharacterProfile.names;
    final followReply = _language.text(
      '跟随${names.chinese}（${controller.characterReplyLanguage.nativeLabel}）',
      'Follow ${names.english} (${controller.characterReplyLanguage.nativeLabel})',
      '${names.japanese}に従う（${controller.characterReplyLanguage.nativeLabel}）',
    );
    final followTranslation = _language.text(
      '跟随${names.chinese}（${controller.translationLanguage.label(_language)}）',
      'Follow ${names.english} (${controller.translationLanguage.label(_language)})',
      '${names.japanese}に従う（${controller.translationLanguage.label(_language)}）',
    );
    DropdownMenuItem<String> option(String value, String label) =>
        DropdownMenuItem(
          value: value,
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        );
    return ListView(
      key: const ValueKey('npc-message-settings-page'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        Text(
          _language.text('聊天语言', 'Chat language', 'チャット言語'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        GlassSurface(
          liquidGlass: _glass,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  key: ValueKey(
                    'npc-reply-language-${controller.npcReplyLanguageOverride?.name ?? 'follow'}',
                  ),
                  initialValue:
                      controller.npcReplyLanguageOverride?.name ?? 'follow',
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _language.text(
                      'NPC 回复语言',
                      'NPC reply language',
                      'NPC の返信言語',
                    ),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    option('follow', followReply),
                    for (final language in AppLanguage.values)
                      option(language.name, language.nativeLabel),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    controller.configureNpcMessageLanguages(
                      reply: AppLanguage.values
                          .where((language) => language.name == value)
                          .firstOrNull,
                      translation: controller.npcTranslationLanguageOverride,
                    );
                  },
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<String>(
                  key: ValueKey(
                    'npc-translation-language-${controller.npcTranslationLanguageOverride?.name ?? 'follow'}',
                  ),
                  initialValue:
                      controller.npcTranslationLanguageOverride?.name ??
                      'follow',
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _language.text(
                      '翻译语言',
                      'Translation language',
                      '翻訳言語',
                    ),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    option('follow', followTranslation),
                    for (final language in TranslationLanguage.values)
                      option(language.name, language.label(_language)),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    controller.configureNpcMessageLanguages(
                      reply: controller.npcReplyLanguageOverride,
                      translation: TranslationLanguage.values
                          .where((language) => language.name == value)
                          .firstOrNull,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          _language.text(
            '默认跟随${names.chinese}的回复和翻译语言，也可以在这里单独选择。更改立即保存，对新发送的消息生效；历史消息与译文保留。',
            'Replies and translations follow ${names.english} by default, or you can choose them here. Changes are saved immediately and apply to new messages. Saved messages and translations are retained.',
            '既定では${names.japanese}の返信・翻訳言語に従います。個別にも選べます。変更はすぐ保存され、新しいメッセージに適用されます。履歴と訳文は保持されます。',
          ),
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Text(
          _language.text(
            '选择翻译语言后，NPC 的回复会另行生成译文，并与原文一起保存。',
            'Selecting a translation language adds a translation of the NPC reply and saves it with the original.',
            '翻訳言語を選ぶと、NPC の返信に訳文を追加し、原文と一緒に保存します。',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _contacts(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final contacts = widget.controller.npcMessagingContacts.where((contact) {
      if (query.isEmpty) return true;
      return [
        contact.names.chinese,
        contact.names.english,
        contact.names.japanese,
        ...contact.aliases,
      ].any((name) => name.toLowerCase().contains(query));
    }).toList();
    contacts.sort((a, b) {
      final aMessages = widget.controller.npcChats.threadFor(a.id).messages;
      final bMessages = widget.controller.npcChats.threadFor(b.id).messages;
      if (aMessages.isEmpty && bMessages.isEmpty) return 0;
      if (aMessages.isEmpty) return 1;
      if (bMessages.isEmpty) return -1;
      return bMessages.last.createdAt.compareTo(aMessages.last.createdAt);
    });
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: GlassContentCard(
            liquidGlass: _glass,
            child: TextField(
              key: const ValueKey('npc-contacts-search'),
              controller: _search,
              decoration: InputDecoration(
                hintText: _language.text('搜索联系人', 'Search contacts', '連絡先を検索'),
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: _language.text(
                          '清空搜索',
                          'Clear search',
                          '検索をクリア',
                        ),
                        onPressed: _search.clear,
                        icon: const Icon(Icons.close_rounded),
                      ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: contacts.isEmpty
              ? _emptyContacts(context, query.isNotEmpty)
              : ListView.builder(
                  key: const ValueKey('npc-contacts-list'),
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: contacts.length,
                  itemBuilder: (context, index) {
                    final contact = contacts[index];
                    final messages = widget.controller.npcChats
                        .threadFor(contact.id)
                        .messages;
                    final live = _service.liveReply(contact.id);
                    final preview = live.isNotEmpty
                        ? live
                        : messages.isNotEmpty
                        ? messages.last.text
                        : _language.text(
                            '点击开始私信',
                            'Start a private chat',
                            'タップして会話を始める',
                          );
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GlassContentCard(
                        liquidGlass: _glass,
                        child: ListTile(
                          key: ValueKey('npc-contact-${contact.id}'),
                          leading: _avatar(context, contact),
                          title: Text(contact.names.forLanguage(_language)),
                          subtitle: Text(
                            preview.replaceAll(RegExp(r'\s+'), ' ').trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: _service.isSending(contact.id)
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.chevron_right_rounded),
                          onTap: () => _openContact(contact),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _emptyContacts(BuildContext context, bool hasSearch) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasSearch
                ? Icons.search_off_rounded
                : Icons.person_add_alt_1_rounded,
            size: 42,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            _language.text(
              hasSearch ? '没有匹配的联系人' : '在主对话中询问 NPC 是否可以添加联系方式，确认后会出现在这里。',
              hasSearch ? 'No matching contacts' : 'Ask an NPC in the main chat to exchange contact details. Confirming adds them here.',
              hasSearch
                  ? '一致する連絡先はありません'
                  : 'メイン会話で NPC に連絡先の交換を尋ね、確認するとここに追加されます。',
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );

  Widget _avatar(BuildContext context, NpcChatContact contact) {
    final name = contact.names.forLanguage(_language);
    final fallback = Center(
      child: Text(
        name.isEmpty ? '?' : name.characters.first,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
    );
    return CircleAvatar(
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: contact.avatarAsset == null
          ? fallback
          : ClipOval(
              child: Image.asset(
                contact.avatarAsset!,
                width: 40,
                height: 40,
                cacheWidth: 96,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    SizedBox.square(dimension: 40, child: fallback),
              ),
            ),
    );
  }

  Widget _conversation(BuildContext context, NpcChatContact contact) {
    final sending = _service.isSending(contact.id);
    final live = _service.liveReply(contact.id);
    final thread = widget.controller.npcChats.threadFor(contact.id);
    final messages = thread.messages.toList();
    if (sending &&
        messages.isNotEmpty &&
        messages.last.role == NpcChatRole.assistant &&
        messages.last.status != NpcChatStatus.completed) {
      messages.removeLast();
    }
    final error = _localErrors[contact.id] ?? _service.errorFor(contact.id);
    final last = thread.messages.lastOrNull;
    final canRetry =
        !sending &&
        last != null &&
        (last.role == NpcChatRole.user ||
            last.status != NpcChatStatus.completed);
    _followMessages(contact.id, messages, live, sending);
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          Expanded(
            child: ListView.builder(
              key: ValueKey('npc-conversation-${contact.id}'),
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              itemCount:
                  messages.length +
                  (sending ? 1 : 0) +
                  (messages.isEmpty && !sending ? 1 : 0),
              itemBuilder: (context, index) {
                if (messages.isEmpty && !sending) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _language.text(
                        '给${contact.names.chinese}发一条消息吧。',
                        'Send ${contact.names.english} a message.',
                        '${contact.names.japanese}にメッセージを送りましょう。',
                      ),
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                if (index == messages.length) {
                  return _bubble(
                    context,
                    contact,
                    text: live.isEmpty
                        ? _language.text(
                            '正在等待回复…',
                            'Waiting for a reply…',
                            '返信を待っています…',
                          )
                        : live,
                    user: false,
                    live: true,
                  );
                }
                final message = messages[index];
                return _bubble(
                  context,
                  contact,
                  text: message.text,
                  user: message.role == NpcChatRole.user,
                  message: message,
                );
              },
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.min(180, constraints.maxHeight * .65),
            ),
            child: SingleChildScrollView(
              child: _composer(context, contact, sending, error, canRetry),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(
    BuildContext context,
    NpcChatContact contact, {
    required String text,
    required bool user,
    NpcChatMessage? message,
    bool live = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      key: message == null
          ? ValueKey('npc-live-${contact.id}')
          : ValueKey('npc-message-${message.id}'),
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * .84,
          ),
          child: GlassContentCard(
            liquidGlass: _glass,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user
                        ? _language.text('你', 'You', 'あなた')
                        : contact.names.forLanguage(_language),
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    text.isEmpty
                        ? _language.text('（无文本）', '(No text)', '（本文なし）')
                        : text,
                  ),
                  if (message?.translatedText?.trim().isNotEmpty ?? false) ...[
                    const Divider(height: 18),
                    SelectableText(
                      message!.translatedText!,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                  if (live ||
                      message?.status != NpcChatStatus.completed &&
                          message != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      live
                          ? _language.text('正在回复…', 'Replying…', '返信中…')
                          : message!.status == NpcChatStatus.failed
                          ? _language.text('回复失败', 'Reply failed', '返信に失敗')
                          : _language.text(
                              '回复已停止',
                              'Reply stopped',
                              '返信を停止しました',
                            ),
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _composer(
    BuildContext context,
    NpcChatContact contact,
    bool sending,
    String? error,
    bool canRetry,
  ) {
    final draft = _drafts.putIfAbsent(contact.id, TextEditingController.new);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: GlassContentCard(
          liquidGlass: _glass,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error != null || canRetry)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          error ??
                              _language.text(
                                '上一条回复未完成。',
                                'The previous reply did not finish.',
                                '前の返信は完了していません。',
                              ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: error == null
                                    ? Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant
                                    : Theme.of(context).colorScheme.error,
                              ),
                        ),
                      ),
                      if (canRetry)
                        TextButton(
                          key: ValueKey('npc-retry-${contact.id}'),
                          onPressed: () => unawaited(_retry(contact)),
                          child: Text(_language.text('重试', 'Retry', '再試行')),
                        ),
                    ],
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('npc-draft-${contact.id}'),
                        controller: draft,
                        minLines: 1,
                        maxLines: 4,
                        maxLength: 4000,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: _language.text(
                            '发送私信…',
                            'Send a message…',
                            'メッセージを送信…',
                          ),
                          counterText: '',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    IconButton.filled(
                      key: ValueKey(
                        sending
                            ? 'npc-stop-${contact.id}'
                            : 'npc-send-${contact.id}',
                      ),
                      tooltip: sending
                          ? _language.text('停止生成', 'Stop reply', '返信を停止')
                          : _language.text('发送', 'Send', '送信'),
                      onPressed: sending
                          ? () => _service.cancel(contact.id)
                          : draft.text.trim().isEmpty
                          ? null
                          : () => unawaited(_send(contact)),
                      icon: Icon(
                        sending
                            ? Icons.stop_rounded
                            : Icons.arrow_upward_rounded,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _followMessages(
    String id,
    List<NpcChatMessage> messages,
    String live,
    bool sending,
  ) {
    final signature = Object.hash(
      id,
      live.length,
      sending,
      Object.hashAll(
        messages.map(
          (message) =>
              Object.hash(message.id, message.text.length, message.status),
        ),
      ),
    );
    if (signature == _messageSignature) return;
    _messageSignature = signature;
    if (!_followTail) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selectedId == id && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }
}
