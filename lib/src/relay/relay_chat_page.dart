import 'dart:async';

import 'package:flutter/material.dart';

import '../glass_ui.dart';
import '../virtual_phone_chrome.dart';
import 'relay_conversations.dart';
import 'relay_page.dart';
import 'relay_protocol.dart';
import 'relay_service.dart';

class RelayChatScreen extends StatefulWidget {
  const RelayChatScreen({
    super.key,
    required this.service,
    this.embedded = false,
    this.liquidGlass = false,
  });
  final RelayService service;
  final bool embedded;
  final bool liquidGlass;

  @override
  State<RelayChatScreen> createState() => _RelayChatScreenState();
}

class _RelayChatScreenState extends State<RelayChatScreen> {
  late final RelayConversations conversations = RelayConversations(
    widget.service,
  );

  @override
  void dispose() {
    conversations.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RelayChatPage(
    service: widget.service,
    conversations: conversations,
    embedded: widget.embedded,
    liquidGlass: widget.liquidGlass,
    managementBuilder: (_) => RelayPage(service: widget.service),
  );
}

/// The PC chat surface owns its drawer and dialogs inside the current route.
/// It never exposes the character LLM to remote control actions.
class RelayChatPage extends StatefulWidget {
  const RelayChatPage({
    super.key,
    required this.service,
    required this.conversations,
    required this.managementBuilder,
    this.embedded = false,
    this.liquidGlass = false,
  });

  final RelayService service;
  final RelayConversations conversations;
  final WidgetBuilder managementBuilder;
  final bool embedded;
  final bool liquidGlass;

  @override
  State<RelayChatPage> createState() => _RelayChatPageState();
}

class _RelayChatPageState extends State<RelayChatPage> {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _prompt = TextEditingController();
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String? _profileId, _sessionId, _workspaceId, _error, _newActionId;
  bool _sending = false, _refreshing = false;
  (String?, String?)? _scrollScope;
  int? _messageSignature;
  bool _initialScroll = true, _followTail = true, _programmaticScroll = false;

  RelayService get service => widget.service;
  bool get _liquidGlass =>
      GlassStyleScope.resolve(context, fallback: widget.liquidGlass);
  RelayConversations get conversations => widget.conversations;
  Json? get _profile =>
      _profileId == null ? null : service.profile(_profileId!);

  @override
  void initState() {
    super.initState();
    _selectInitialProfile();
    service.addListener(_serviceChanged);
    _scroll.addListener(_scrollChanged);
    _search.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  void _selectInitialProfile() {
    if (_profile != null) return;
    _profileId =
        service.profiles
                .where((p) => p['state'] == 'confirmed')
                .firstOrNull?['device_id']
            as String?;
    _profileId ??= service.profiles.firstOrNull?['device_id'] as String?;
    _sessionId = null;
    _workspaceId = null;
    _newActionId = _pendingNewTask?['action_id'] as String?;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _scrollChanged() {
    if (!_programmaticScroll && _scroll.hasClients) {
      _followTail = _scroll.position.extentAfter < 80;
    }
  }

  void _followMessages(List<RelayHistoryMessage> messages) {
    final scope = (_profileId, _sessionId);
    if (scope != _scrollScope) {
      _scrollScope = scope;
      _messageSignature = null;
      _initialScroll = true;
      _followTail = true;
    }
    final signature = Object.hashAll(
      messages.map(
        (message) => Object.hash(
          message.id,
          message.revision,
          message.state,
          message.text.length,
        ),
      ),
    );
    if (messages.isEmpty || signature == _messageSignature) return;
    _messageSignature = signature;
    if (!_initialScroll && !_followTail) return;
    _initialScroll = false;
    _programmaticScroll = true;
    _scrollToLatest(scope);
  }

  void _scrollToLatest((String?, String?) scope, [int pass = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scrollScope != scope || !_scroll.hasClients) {
        _programmaticScroll = false;
        return;
      }
      final target = _scroll.position.maxScrollExtent;
      final distance = (target - _scroll.position.pixels).abs();
      _scroll.jumpTo(target);
      // A lazy list can refine its extent after a jump past long messages.
      if (pass < 3 && distance > .5) {
        _scrollToLatest(scope, pass + 1);
        WidgetsBinding.instance.scheduleFrame();
      } else {
        _programmaticScroll = false;
        _followTail = true;
      }
    });
  }

  void _serviceChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _followAcceptedNewConversation();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    service.removeListener(_serviceChanged);
    conversations.activate(null, null);
    _prompt.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      for (final profile in service.profiles) {
        await service.sync(profile['device_id'] as String, snapshot: true);
      }
      await _refreshMessages();
    } on Object catch (error) {
      if (mounted) setState(() => _error = safeRelayError(error));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _refreshMessages() async {
    final profileId = _profileId, sessionId = _sessionId;
    if (profileId != null && sessionId != null) {
      await conversations.refresh(profileId, sessionId);
    }
  }

  void _chooseProfile(String id) {
    setState(() {
      _profileId = id;
      _sessionId = null;
      _workspaceId = null;
      _error = null;
      _newActionId = null;
      _prompt.clear();
    });
    _newActionId = _pendingNewTask?['action_id'] as String?;
    conversations.activate(null, null);
  }

  void _newConversation() {
    _scaffold.currentState?.closeDrawer();
    setState(() {
      _sessionId = null;
      _workspaceId = null;
      _error = null;
      _prompt.clear();
    });
    conversations.activate(null, null);
  }

  Future<void> _selectSession(String id) async {
    _scaffold.currentState?.closeDrawer();
    setState(() {
      _sessionId = id;
      _workspaceId = null;
      _error = null;
      _prompt.clear();
    });
    conversations.activate(_profileId, id);
    try {
      await _refreshMessages();
    } on Object catch (error) {
      if (mounted) setState(() => _error = safeRelayError(error));
    }
  }

  Future<void> _openManagement() async {
    _scaffold.currentState?.closeDrawer();
    await Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: widget.managementBuilder));
    if (mounted) await _refresh();
  }

  bool get _canSend {
    final profile = _profile;
    return !_sending &&
        profile != null &&
        profile['state'] == 'confirmed' &&
        service.ready.contains(_profileId) &&
        relayCapabilities(profile['capabilities']).contains('task.start') &&
        (_sessionId != null || _workspaceId != null) &&
        (_sessionId != null || _pendingNewTask == null) &&
        _prompt.text.trim().isNotEmpty;
  }

  Json? get _pendingNewTask {
    final profile = _profile;
    if (profile == null) return null;
    return service.collection(profile, 'outbox').reversed.where((action) {
      final body = object(action['body']);
      if (body['type'] != 'task.start' || body['session_id'] != null) {
        return false;
      }
      final status = action['local_status'];
      final result = _actionResult(profile, action);
      return {
            'sending',
            'retry',
            'queued',
            'delivered',
            'unknown',
          }.contains(status) ||
          (status == 'accepted' && result['session_id'] == null);
    }).firstOrNull;
  }

  Json _actionResult(Json profile, Json action) =>
      service
          .collection(profile, 'actions')
          .where((summary) => summary['action_id'] == action['action_id'])
          .lastOrNull ??
      (action['result'] is Map
          ? object(action['result'])
          : <String, dynamic>{});

  void _followAcceptedNewConversation() {
    final profile = _profile;
    if (profile == null || _newActionId == null || _sessionId != null) return;
    final action = service
        .collection(profile, 'outbox')
        .where((a) => a['action_id'] == _newActionId)
        .firstOrNull;
    if (action?['local_status'] != 'accepted') {
      return;
    }
    final sessionId = _actionResult(profile, action!)['session_id'];
    if (sessionId is String && sessionId.isNotEmpty) {
      _newActionId = null;
      unawaited(_selectSession(sessionId));
    }
  }

  Future<void> _send() async {
    if (!_canSend) return;
    final profile = _profile!;
    final prompt = _prompt.text.trim();
    final profileId = _profileId!, sessionId = _sessionId;
    final accepted = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        backgroundColor: _dialogColor(context),
        surfaceTintColor: Colors.transparent,
        title: const Text('向 PC 发送任务？'),
        content: SingleChildScrollView(
          child: Text(
            'PC：${service.pcName(profile)}\n'
            '会话：${service.sessionName(profile, sessionId)}\n\n$prompt',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认发送'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted || !_canSend) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final actionId = await service.startTask(
        profileId,
        prompt: prompt,
        sessionId: sessionId,
        workspaceId: _workspaceId,
      );
      if (mounted) {
        _prompt.clear();
        if (sessionId == null) _newActionId = actionId;
        _followAcceptedNewConversation();
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = safeRelayError(error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([service, conversations]),
    builder: (context, _) {
      _selectInitialProfile();
      final profile = _profile;
      return GlassPageSurface(
        liquidGlass: _liquidGlass,
        child: Scaffold(
          key: _scaffold,
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            toolbarHeight: 56,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            flexibleSpace: GlassSurface(
              liquidGlass: _liquidGlass,
              backdropBlur: false,
              borderRadius: BorderRadius.zero,
              tone: Theme.of(context).brightness == Brightness.dark
                  ? GlassTone.dark
                  : GlassTone.light,
              fallbackColor: glassPageHeaderColor(context),
              child: const SizedBox.expand(),
            ),
            automaticallyImplyLeading: false,
            leadingWidth: widget.embedded ? 104 : 96,
            leading: Row(
              children: [
                if (widget.embedded)
                  SizedBox(
                    width: 56,
                    child: Center(
                      child: VirtualPhoneBackButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  )
                else if (Navigator.canPop(context))
                  const BackButton()
                else
                  const SizedBox(width: 48),
                IconButton(
                  key: const ValueKey('relay-chat-history'),
                  tooltip: '历史对话',
                  onPressed: () => _scaffold.currentState?.openDrawer(),
                  icon: const Icon(Icons.menu_open_rounded),
                ),
              ],
            ),
            titleSpacing: 0,
            title: Text(
              _sessionId == null || profile == null
                  ? 'PC Agent'
                  : service.sessionName(profile, _sessionId),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            actions: [
              IconButton(
                key: const ValueKey('relay-chat-new'),
                tooltip: '新开对话',
                onPressed: _sending ? null : _newConversation,
                icon: const Icon(Icons.add_comment_outlined),
              ),
            ],
          ),
          drawer: _historyDrawer(context),
          body: Column(
            children: [
              _connectionHeader(context),
              if (_refreshing) const LinearProgressIndicator(minHeight: 2),
              Expanded(child: _conversationBody(context)),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              _composer(context),
            ],
          ),
        ),
      );
    },
  );

  Widget _connectionHeader(BuildContext context) {
    final profile = _profile;
    final pcState = profile == null
        ? null
        : service
              .collection(profile, 'devices')
              .where((device) => device['device_id'] == profile['pc_id'])
              .firstOrNull?['connection_state'];
    final relayState = service.connections[_profileId];
    final status = relayState == 'offline'
        ? '网络离线 · 本地缓存'
        : pcState == 'offline'
        ? 'PC 离线 · 已同步历史'
        : pcState == 'online' && relayState == 'online'
        ? 'PC 在线'
        : relayLabel(relayState ?? profile?['state']);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: profile == null
                ? const Text('尚未绑定 PC')
                : PopupMenuButton<String>(
                    tooltip: '选择目标 PC',
                    onSelected: _chooseProfile,
                    itemBuilder: (_) => [
                      for (final p in service.profiles)
                        PopupMenuItem(
                          value: p['device_id'] as String,
                          child: Text(service.pcName(p)),
                        ),
                    ],
                    child: Row(
                      children: [
                        const Icon(Icons.computer_outlined, size: 16),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${service.pcName(profile)} · $status',
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        const Icon(Icons.expand_more, size: 16),
                      ],
                    ),
                  ),
          ),
          IconButton(
            tooltip: '同步对话与状态',
            visualDensity: VisualDensity.compact,
            onPressed: _refreshing ? null : _refresh,
            icon: const Icon(Icons.sync, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _historyDrawer(BuildContext context) {
    final profile = _profile;
    final query = _search.text.trim().toLowerCase();
    final sessions = profile == null
        ? <Json>[]
        : service
              .collection(profile, 'sessions')
              .where((session) => session['pc_id'] == profile['pc_id'])
              .where(
                (session) => (session['title']?.toString() ?? '')
                    .toLowerCase()
                    .contains(query),
              )
              .toList();
    sessions.sort((a, b) => _updated(b).compareTo(_updated(a)));
    final groups = <String, List<Json>>{};
    for (final session in sessions) {
      final age = service.now().difference(_updated(session)).inDays;
      final group = age < 7
          ? '7 天内'
          : age < 30
          ? '30 天内'
          : '更早';
      groups.putIfAbsent(group, () => []).add(session);
    }
    return Drawer(
      width: MediaQuery.sizeOf(context).width * .88,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: GlassPageSurface(
        liquidGlass: _liquidGlass,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 12, 12),
                child: GlassContentCard(
                  liquidGlass: _liquidGlass,
                  borderRadius: BorderRadius.circular(28),
                  child: TextField(
                    key: const ValueKey('relay-history-search'),
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: '搜索对话标题…',
                      prefixIcon: const Icon(Icons.search),
                      filled: false,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              ),
              if (profile != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('relay-history-profile-$_profileId'),
                    initialValue: _profileId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '已配对 PC'),
                    items: [
                      for (final p in service.profiles)
                        DropdownMenuItem(
                          value: p['device_id'] as String,
                          child: Text(service.pcName(p)),
                        ),
                    ],
                    onChanged: (id) {
                      if (id != null) _chooseProfile(id);
                    },
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    if (sessions.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          profile == null
                              ? '绑定 PC 后自动同步桌面会话。'
                              : query.isEmpty
                              ? '此 PC 尚未同步历史会话。'
                              : '没有匹配的对话。',
                        ),
                      ),
                    for (final group in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 18, 12, 6),
                        child: Text(
                          group.key,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                      for (final session in group.value)
                        ListTile(
                          key: ValueKey(
                            'relay-session-${session['session_id']}',
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          selected: session['session_id'] == _sessionId,
                          title: Text(
                            session['title']?.toString() ?? '未命名对话',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${service.pcName(profile!)} · ${relayLabel(session['status'])}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () =>
                              _selectSession(session['session_id'] as String),
                        ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                key: const ValueKey('relay-chat-management'),
                leading: const Icon(Icons.settings_outlined),
                title: const Text('配对与联动管理'),
                subtitle: const Text('PC、任务、审批与通知'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openManagement,
              ),
            ],
          ),
        ),
      ),
    );
  }

  DateTime _updated(Json session) =>
      DateTime.tryParse(session['updated_at']?.toString() ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);

  Widget _conversationBody(BuildContext context) {
    final profile = _profile;
    final profileId = _profileId, sessionId = _sessionId;
    final messages = profileId == null || sessionId == null
        ? <RelayHistoryMessage>[]
        : conversations.messages(profileId, sessionId);
    _followMessages(messages);
    final history = profileId == null || sessionId == null
        ? null
        : conversations.history(profileId, sessionId);
    final cached = profile == null || sessionId == null
        ? null
        : service
              .collection(profile, 'history')
              .where((row) => row['session_id'] == sessionId)
              .firstOrNull;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        key: ValueKey('relay-chat-content-$profileId-$sessionId'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (sessionId == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 42, horizontal: 12),
              child: Column(
                children: [
                  Icon(
                    Icons.forum_outlined,
                    size: 54,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '向 PC Agent 发送任务',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    profile == null
                        ? '在左上角历史页面的联动管理中绑定 PC。'
                        : '从左上角打开桌面历史，或选择授权工作区开始新对话。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          if (history?.loading == true && messages.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (cached?['sync_state'] == 'syncing' && messages.isNotEmpty)
            const _HistoryNotice(icon: Icons.sync, text: '桌面正在同步，当前显示上一完整版本。'),
          if (history?.hasMore == true)
            Center(
              child: TextButton.icon(
                onPressed: history?.loadingOlder == true
                    ? null
                    : () => conversations.loadOlder(profileId!, sessionId!),
                icon: const Icon(Icons.history, size: 18),
                label: Text(history?.loadingOlder == true ? '正在加载…' : '加载更早消息'),
              ),
            ),
          if (history?.availability == 'unsupported')
            const _HistoryNotice(
              icon: Icons.link_off_rounded,
              text: '此桌面客户端尚未提供完整聊天历史。会话列表与下方任务、问题仍来自真实联动数据。',
            ),
          if (history?.availability == 'not_ready')
            const _HistoryNotice(
              icon: Icons.hourglass_empty_rounded,
              text: '正在等待桌面客户端同步此会话的完整消息。',
            ),
          if (history?.availability == 'forbidden')
            const _HistoryNotice(
              icon: Icons.lock_outline_rounded,
              text: '请在 PC 手机联动设置中为此手机启用读取历史，并选择授权工作区。',
            ),
          if (history?.error != null)
            _HistoryNotice(
              icon: Icons.sync_problem_outlined,
              text: history!.error!,
            ),
          if (history?.availability == 'available' &&
              history?.loading != true &&
              messages.isEmpty)
            const _HistoryNotice(
              icon: Icons.chat_bubble_outline,
              text: '此会话暂无消息。',
            ),
          if (profile != null) _statusDetails(context, profile),
          for (final message in messages) _message(context, message),
        ],
      ),
    );
  }

  Widget _message(BuildContext context, RelayHistoryMessage message) {
    final colors = Theme.of(context).colorScheme;
    final user = message.role == 'user';
    if (message.role == 'tool' || message.role == 'system') {
      return ExpansionTile(
        key: ValueKey('relay-message-${message.id}'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 6),
        title: Text(message.role == 'tool' ? '工具记录' : '系统记录'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            child: SelectableText(message.text),
          ),
        ],
      );
    }
    return Align(
      key: ValueKey('relay-message-${message.id}'),
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * .82,
          ),
          child: user
              ? GlassContentCard(
                  liquidGlass: _liquidGlass,
                  borderRadius: BorderRadius.circular(20),
                  child: _messageContent(context, message, user, colors),
                )
              : _messageContent(context, message, user, colors),
        ),
      ),
    );
  }

  Widget _messageContent(
    BuildContext context,
    RelayHistoryMessage message,
    bool user,
    ColorScheme colors,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!user)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'PC Agent',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        SelectableText(message.text),
        if ({
          'queued',
          'streaming',
          'cancelled',
          'failed',
        }.contains(message.state))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              switch (message.state) {
                'queued' => '等待回复',
                'streaming' => '正在回复…',
                'cancelled' => '回复已取消',
                _ => '回复失败',
              },
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
      ],
    ),
  );

  Widget _statusDetails(BuildContext context, Json profile) {
    final requests = service
        .collection(profile, 'requests')
        .where(
          (request) => _sessionId == null
              ? isPending(request, service.now())
              : request['session_id'] == _sessionId,
        )
        .toList();
    final tasks = service
        .collection(profile, 'tasks')
        .where(
          (task) => _sessionId == null
              ? {'queued', 'running'}.contains(task['status'])
              : _taskSession(profile, task) == _sessionId,
        )
        .toList();
    final outbox = service
        .collection(profile, 'outbox')
        .where((action) {
          final body = object(action['body']);
          final result = _actionResult(profile, action);
          return _sessionId == null
              ? body['session_id'] == null
              : body['session_id'] == _sessionId ||
                    result['session_id'] == _sessionId;
        })
        .toList()
        .reversed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final request in requests)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GlassContentCard(
              liquidGlass: _liquidGlass,
              child: ListTile(
                leading: Icon(
                  request['kind'] == 'approval'
                      ? Icons.gpp_maybe_outlined
                      : Icons.chat_bubble_outline_rounded,
                ),
                title: Text(
                  object(request['payload'])['title']?.toString() ??
                      (request['kind'] == 'approval' ? '等待审批' : 'PC 问题'),
                ),
                subtitle: Text(
                  '${service.sessionName(profile, request['session_id'])}\n'
                  '${relayLabel(request['state'] == 'pending' && !isPending(request, service.now()) ? 'expired' : request['state'])}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showDialog<void>(
                  context: context,
                  useRootNavigator: false,
                  builder: (_) => RelayQuestionDialog(
                    service: service,
                    profileId: _profileId!,
                    requestId: request['request_id'] as String,
                  ),
                ),
              ),
            ),
          ),
        if (tasks.isNotEmpty || outbox.isNotEmpty)
          ExpansionTile(
            key: ValueKey('relay-chat-status-$_profileId-$_sessionId'),
            initiallyExpanded: true,
            tilePadding: EdgeInsets.zero,
            title: const Text('任务与操作状态'),
            subtitle: const Text('已送达后仍需等待 PC 接受'),
            children: [
              for (final task in tasks)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(task['summary']?.toString() ?? 'PC 任务'),
                  subtitle: Text(
                    '${relayLabel(task['status'])} · ${_taskSession(profile, task) == null ? '会话尚未同步' : service.sessionName(profile, _taskSession(profile, task))}',
                  ),
                  trailing: {'queued', 'running'}.contains(task['status'])
                      ? TextButton(
                          onPressed: _sending ? null : () => _cancelTask(task),
                          child: const Text('取消'),
                        )
                      : null,
                ),
              for (final action in outbox) _actionRow(context, action),
            ],
          ),
      ],
    );
  }

  String? _taskSession(Json profile, Json task) {
    if (task['pc_id'] != null && task['pc_id'] != profile['pc_id']) return null;
    final direct = task['session_id'];
    if (direct is String && direct.isNotEmpty) return direct;
    final summary = service
        .collection(profile, 'actions')
        .reversed
        .where(
          (action) =>
              action['task_id'] == task['task_id'] &&
              action['target_pc_id'] == profile['pc_id'] &&
              action['session_id'] is String &&
              (action['session_id'] as String).isNotEmpty,
        )
        .firstOrNull;
    return summary?['session_id'] as String?;
  }

  Widget _actionRow(BuildContext context, Json action) {
    final body = object(action['body']);
    final payload = object(body['payload']);
    final type = body['type'];
    final title = type == 'task.start'
        ? payload['prompt']?.toString() ?? '手机下发的任务'
        : type == 'task.cancel'
        ? '取消任务'
        : type == 'approval.respond'
        ? '审批决定'
        : '手机回答';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.outbox_outlined, size: 20),
      title: Text(title, maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: Text(relayLabel(action['local_status'])),
      trailing: action['local_status'] == 'retry'
          ? TextButton(
              onPressed: _sending
                  ? null
                  : () => _runAction(
                      () => service.retryAction(
                        _profileId!,
                        action['action_id'] as String,
                      ),
                    ),
              child: const Text('幂等重试'),
            )
          : null,
    );
  }

  Future<void> _cancelTask(Json task) async {
    final profileId = _profileId;
    if (profileId == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        backgroundColor: _dialogColor(context),
        surfaceTintColor: Colors.transparent,
        title: const Text('取消此任务？'),
        content: Text(task['summary']?.toString() ?? 'PC 任务'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认取消'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await _runAction(
        () async => service.cancelTask(profileId, task['task_id'] as String),
      );
    }
  }

  Future<void> _runAction(Future<void> Function() run) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await run();
    } on Object catch (error) {
      if (mounted) setState(() => _error = safeRelayError(error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _composer(BuildContext context) {
    final profile = _profile;
    final workspaces = profile == null
        ? <Json>[]
        : service
              .collection(profile, 'workspaces')
              .where((workspace) => workspace['pc_id'] == profile['pc_id'])
              .toList();
    if (!workspaces.any((w) => w['workspace_id'] == _workspaceId)) {
      _workspaceId = null;
    }
    final connected =
        profile?['state'] == 'confirmed' && service.ready.contains(_profileId);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: GlassContentCard(
          liquidGlass: _liquidGlass,
          borderRadius: BorderRadius.circular(26),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_sessionId == null && _pendingNewTask != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '新对话任务尚未确认结果，请等待 PC 或在上方幂等重试原操作。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (_sessionId == null && profile != null)
                  DropdownButtonFormField<String>(
                    key: ValueKey('relay-chat-workspace-$_profileId'),
                    initialValue: _workspaceId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      hintText: '选择 PC 授权工作区以新建对话',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    items: [
                      for (final workspace in workspaces)
                        DropdownMenuItem(
                          value: workspace['workspace_id'] as String,
                          child: Text(
                            workspace['label']?.toString() ?? '授权工作区',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _sending || !connected
                        ? null
                        : (id) => setState(() => _workspaceId = id),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('relay-chat-prompt'),
                        controller: _prompt,
                        enabled: !_sending && connected,
                        minLines: 1,
                        maxLines: 5,
                        maxLength: 20000,
                        onChanged: (_) => _changed(),
                        decoration: const InputDecoration(
                          hintText: '向 PC Agent 发送消息…',
                          border: InputBorder.none,
                          counterText: '',
                        ),
                      ),
                    ),
                    IconButton.filled(
                      key: const ValueKey('relay-chat-send'),
                      tooltip: '发送任务',
                      onPressed: _canSend ? _send : null,
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_upward_rounded),
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

  Color _dialogColor(BuildContext dialogContext) => Theme.of(dialogContext)
      .colorScheme
      .surface
      .withValues(
        alpha:
            GlassStyleScope.resolve(dialogContext, fallback: widget.liquidGlass)
            ? .76
            : .94,
      );
}

class _HistoryNotice extends StatelessWidget {
  const _HistoryNotice({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 18,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );
}
