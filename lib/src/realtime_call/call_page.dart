import 'dart:ui';

import 'package:flutter/material.dart';

import '../app_localization.dart';
import 'call_ui_models.dart';

export 'call_ui_models.dart';

/// This page occupies the virtual phone's app area. Its parent owns the status
/// bar, dynamic island and phone navigation, so none are duplicated here.
class RealtimeCallPage extends StatefulWidget {
  const RealtimeCallPage({
    super.key,
    required this.controller,
    this.language = AppLanguage.chinese,
    this.wallpaper,
    this.onOpenSettings,
    this.onOpenMessages,
    this.onBack,
  });

  final CallUiController controller;
  final AppLanguage language;
  final Widget? wallpaper;
  final VoidCallback? onOpenSettings;
  final ValueChanged<String>? onOpenMessages;
  final VoidCallback? onBack;

  @override
  State<RealtimeCallPage> createState() => _RealtimeCallPageState();
}

class _RealtimeCallPageState extends State<RealtimeCallPage> {
  bool _showHistory = false;
  bool _showCaptions = true;
  int _pendingActions = 0;
  String? _actionError;

  bool get _actionPending => _pendingActions > 0;

  String _t(String zh, String en, String ja) =>
      widget.language.text(zh, en, ja);

  Future<void> _act(
    Future<void> Function() action, {
    bool allowDuringPending = false,
  }) async {
    if (_actionPending && !allowDuringPending) return;
    setState(() {
      _pendingActions++;
      _actionError = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() {
          _actionError = _t(
            '操作未完成，请检查通话设置后重试。',
            'Unable to complete this action. Check call settings and retry.',
            '操作が完了しませんでした。通話設定を確認してください。',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _pendingActions--);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final snapshot = widget.controller.snapshot;
      return Theme(
        data: Theme.of(context).copyWith(
          brightness: Brightness.dark,
          colorScheme: const ColorScheme.dark(
            primary: Colors.white,
            surface: Color(0xFF171C23),
          ),
          iconTheme: const IconThemeData(color: Colors.white),
          textTheme: Theme.of(context).textTheme
              .apply(bodyColor: Colors.white, displayColor: Colors.white),
        ),
        child: Material(
          key: const ValueKey('realtime-call-page'),
          color: const Color(0xFF121820),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _background(),
              if (snapshot.hasCall) _callScreen(snapshot) else _directory(),
            ],
          ),
        ),
      );
    },
  );

  Widget _background() => ClipRect(
    child: Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child:
              widget.wallpaper ??
              Image.asset(
                'assets/images/virtual_phone/bg1.png',
                fit: BoxFit.cover,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) =>
                    const ColoredBox(color: Color(0xFF28364A)),
              ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x5C141924), Color(0xD4080B10)],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _directory() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            if (widget.onBack != null)
              IconButton(
                key: const ValueKey('call-directory-back'),
                onPressed: widget.onBack,
                tooltip: _t('返回', 'Back', '戻る'),
                iconSize: 32,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  _t('电话', 'Phone', '電話'),
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            if (widget.onOpenSettings != null)
              IconButton(
                key: const ValueKey('call-settings'),
                onPressed: widget.onOpenSettings,
                tooltip: _t('通话设置', 'Call settings', '通話設定'),
                icon: const Icon(Icons.settings_outlined),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Expanded(child: _tab(false, _t('通讯录', 'Contacts', '連絡先'))),
            const SizedBox(width: 10),
            Expanded(child: _tab(true, _t('最近通话', 'Recents', '履歴'))),
          ],
        ),
      ),
      if (_actionError != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _actionError!,
            style: const TextStyle(color: Color(0xFFFFCFBC)),
          ),
        ),
      Expanded(child: _showHistory ? _history() : _contacts()),
    ],
  );

  Widget _tab(bool history, String label) => Material(
    color: _showHistory == history
        ? Colors.white.withValues(alpha: .18)
        : Colors.transparent,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      key: ValueKey(history ? 'call-tab-history' : 'call-tab-contacts'),
      borderRadius: BorderRadius.circular(16),
      onTap: () => setState(() => _showHistory = history),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );

  Widget _contacts() {
    final contacts = widget.controller.contacts;
    if (contacts.isEmpty) {
      return _empty(_t('还没有联系人', 'No contacts yet', '連絡先はありません'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
      itemCount: contacts.length + 1,
      separatorBuilder: (_, _) =>
          Divider(color: Colors.white.withValues(alpha: .10)),
      itemBuilder: (context, index) {
        if (index == contacts.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
            child: Text(
              _t(
                '目前可与莱莎、科洛蒂娅通话。通话语言和字幕翻译跟随莱莎的语言设置，并使用当前存档的记忆。',
                'Calls are available with Ryza and Klaudia. Speech and caption translation follow Ryza’s language settings and use the current save’s memory.',
                'ライザとクラウディアに発信できます。通話言語と字幕翻訳はライザの言語設定に従い、現在のセーブの記憶を使います。',
              ),
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          );
        }
        final contact = contacts[index];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _avatar(contact),
          title: Text(
            contact.displayName,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: contact.subtitle == null
              ? null
              : Text(
                  contact.subtitle!,
                  style: const TextStyle(color: Colors.white60),
                ),
          onTap: _actionPending
              ? null
              : () => _act(() => widget.controller.startCall(contact.id)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: ValueKey('call-contact-${contact.id}'),
                tooltip: _t('拨打', 'Call', '発信'),
                onPressed: _actionPending
                    ? null
                    : () => _act(() => widget.controller.startCall(contact.id)),
                icon: const Icon(Icons.phone_rounded, color: Color(0xFF70EC91)),
              ),
              PopupMenuButton<String>(
                key: ValueKey('call-contact-menu-${contact.id}'),
                tooltip: _t('更多', 'More', 'その他'),
                enabled: !_actionPending,
                onSelected: (value) {
                  if (value == 'offer') {
                    _act(() => widget.controller.offerCall(contact.id));
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'offer',
                    child: Text(
                      _t(
                        '让 TA 来电（应用内）',
                        'Ask to call me (in app)',
                        '電話をかけてもらう（アプリ内）',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _history() {
    final entries = widget.controller.history;
    if (entries.isEmpty) {
      return _empty(_t('暂无通话记录', 'No recent calls', '通話履歴はありません'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
      itemCount: entries.length,
      separatorBuilder: (_, _) =>
          Divider(color: Colors.white.withValues(alpha: .10)),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final missed =
            entry.status == CallHistoryStatus.missed ||
            entry.status == CallHistoryStatus.failed;
        final available = widget.controller.contacts.any(
          (contact) => contact.id == entry.contactId,
        );
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            entry.incoming
                ? Icons.call_received_rounded
                : Icons.call_made_rounded,
            color: missed ? const Color(0xFFFF938A) : Colors.white60,
          ),
          title: Text(
            entry.contactName,
            style: TextStyle(
              color: missed ? const Color(0xFFFF938A) : Colors.white,
            ),
          ),
          subtitle: Text(
            '${_historyLabel(entry.status)} · ${_date(entry.startedAt)}',
            style: const TextStyle(color: Colors.white60),
          ),
          trailing: entry.duration > Duration.zero
              ? Text(_duration(entry.duration))
              : null,
          onTap: available && !_actionPending
              ? () => _act(() => widget.controller.startCall(entry.contactId))
              : null,
        );
      },
    );
  }

  Widget _avatar(CallContact contact) => CircleAvatar(
    radius: 23,
    backgroundColor: Colors.white.withValues(alpha: .14),
    child: contact.avatarAsset == null
        ? const Icon(Icons.person_rounded, color: Colors.white, size: 28)
        : ClipOval(
            child: Image.asset(
              contact.avatarAsset!,
              width: 46,
              height: 46,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.person_rounded, color: Colors.white),
            ),
          ),
  );

  Widget _empty(String label) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white60),
      ),
    ),
  );

  Widget _callScreen(CallUiSnapshot snapshot) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxHeight < 650;
      final terminal =
          snapshot.phase == CallUiPhase.ended ||
          snapshot.phase == CallUiPhase.failed;
      return SingleChildScrollView(
        key: const ValueKey('call-screen-scroll'),
        padding: EdgeInsets.fromLTRB(20, compact ? 18 : 38, 20, 22),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (constraints.maxHeight - (compact ? 40 : 60)).clamp(
              0,
              double.infinity,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                children: [
                  Text(
                    snapshot.contact?.displayName ??
                        _t('角色', 'Character', 'キャラクター'),
                    key: const ValueKey('call-contact-name'),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 38 : 46,
                      fontWeight: FontWeight.w400,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    snapshot.phase == CallUiPhase.incoming
                        ? _t('应用内来电', 'In-app call', 'アプリ内の着信')
                        : _t('手机 · 实时语音', 'Phone · Voice call', '電話 · 音声通話'),
                    style: const TextStyle(color: Colors.white60, fontSize: 17),
                  ),
                  const SizedBox(height: 18),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _status(snapshot),
                      key: const ValueKey('call-status'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 19, color: Colors.white),
                    ),
                  ),
                  if (snapshot.elapsed > Duration.zero && snapshot.isActive)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _duration(snapshot.elapsed),
                        key: const ValueKey('call-timer'),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                        ),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: EdgeInsets.symmetric(vertical: compact ? 16 : 28),
                child: _caption(snapshot),
              ),
              if (snapshot.phase == CallUiPhase.incoming)
                _incomingControls(snapshot)
              else if (terminal)
                _terminalControls(snapshot)
              else
                _activeControls(snapshot, compact: compact),
            ],
          ),
        ),
      );
    },
  );

  Widget _caption(CallUiSnapshot snapshot) {
    final error = _actionError ?? snapshot.error;
    if (error != null && error.isNotEmpty) {
      return Text(
        error,
        key: const ValueKey('call-error'),
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0xFFFFCFBC), height: 1.5),
      );
    }
    if (!_showCaptions) return const SizedBox(height: 12);
    final transcript = snapshot.interimTranscript.trim();
    final caption = snapshot.caption.trim();
    final translation = snapshot.captionTranslation.trim();
    if (transcript.isEmpty && caption.isEmpty) {
      return const SizedBox(height: 12);
    }
    return Container(
      key: const ValueKey('call-caption'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .20),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          if (caption.isNotEmpty)
            Text(
              caption,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, height: 1.5),
            ),
          if (caption.isNotEmpty && translation.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                translation,
                key: const ValueKey('call-caption-translation'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, height: 1.5),
              ),
            ),
          if (transcript.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: caption.isEmpty ? 0 : 10),
              child: Text(
                '${_t('你', 'You', 'あなた')}：$transcript',
                style: const TextStyle(color: Colors.white70, height: 1.5),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }

  Widget _incomingControls(CallUiSnapshot snapshot) => Column(
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _control(
            id: 'call-remind',
            icon: Icons.alarm_rounded,
            label: _t('稍后再聊', 'Later', '後で話す'),
            onTap: () => _remind(snapshot),
          ),
          if (widget.onOpenMessages != null && snapshot.contact != null)
            _control(
              id: 'call-message',
              icon: Icons.message_rounded,
              label: _t('信息', 'Message', 'メッセージ'),
              onTap: () async {
                await _act(() async {
                  await widget.controller.declineCall();
                  await widget.controller.endCall();
                });
                if (mounted) widget.onOpenMessages!(snapshot.contact!.id);
              },
            ),
        ],
      ),
      const SizedBox(height: 28),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _control(
            id: 'call-decline',
            icon: Icons.call_end_rounded,
            label: _t('拒绝', 'Decline', '拒否'),
            color: const Color(0xFFFF453A),
            large: true,
            onTap: () => _act(widget.controller.declineCall),
          ),
          _control(
            id: 'call-accept',
            icon: Icons.call_rounded,
            label: _t('接听', 'Accept', '応答'),
            color: const Color(0xFF30CC4D),
            large: true,
            onTap: () => _act(widget.controller.acceptCall),
          ),
        ],
      ),
    ],
  );

  Future<void> _remind(CallUiSnapshot snapshot) async {
    // An in-app invitation has no system alarm backend. Make the behavior
    // explicit and let the user return to the contact rather than fake a timer.
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_t('稍后再聊', 'Call later', '後で話す')),
        content: Text(
          _t(
            '这是一通应用内来电。结束后，可以从最近通话再次拨打。',
            'This is an in-app invitation. Call back from Recents when you are ready.',
            'アプリ内の着信です。終了後、履歴からかけ直せます。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_t('知道了', 'OK', 'OK')),
          ),
        ],
      ),
    );
    if (mounted && widget.controller.snapshot.phase == CallUiPhase.incoming) {
      await _act(() async {
        await widget.controller.declineCall();
        await widget.controller.endCall();
      });
    }
  }

  Widget _activeControls(
    CallUiSnapshot snapshot, {
    required bool compact,
  }) => Column(
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _control(
              id: 'call-mute',
              icon: snapshot.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
              label: _t('静音', 'Mute', 'ミュート'),
              selected: snapshot.muted,
              onTap: () =>
                  _act(() => widget.controller.setMuted(!snapshot.muted)),
            ),
          ),
          Expanded(
            child: _control(
              id: 'call-keypad',
              icon: Icons.dialpad_rounded,
              label: _t('键盘', 'Keypad', 'キーパッド'),
              onTap: _textInput,
            ),
          ),
          Expanded(
            child: _control(
              id: 'call-speaker',
              icon: snapshot.speaker
                  ? Icons.volume_up_rounded
                  : Icons.hearing_rounded,
              label: _t('扬声器', 'Speaker', 'スピーカー'),
              selected: snapshot.speaker,
              onTap: () =>
                  _act(() => widget.controller.setSpeaker(!snapshot.speaker)),
            ),
          ),
        ],
      ),
      SizedBox(height: compact ? 18 : 24),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _control(
              id: 'call-captions',
              icon: Icons.closed_caption_outlined,
              label: _t('字幕', 'Captions', '字幕'),
              selected: _showCaptions,
              onTap: () => setState(() => _showCaptions = !_showCaptions),
            ),
          ),
          Expanded(
            child: _control(
              id: 'call-interrupt',
              icon: Icons.record_voice_over_rounded,
              label: _t('我来说', 'My turn', '話す'),
              onTap:
                  snapshot.phase == CallUiPhase.speaking ||
                      snapshot.phase == CallUiPhase.thinking
                  ? () => _act(widget.controller.interrupt)
                  : null,
            ),
          ),
          Expanded(
            child: _control(
              id: 'call-active-settings',
              icon: Icons.settings_outlined,
              label: _t('设置', 'Settings', '設定'),
              onTap: widget.onOpenSettings,
            ),
          ),
        ],
      ),
      TextButton.icon(
        key: const ValueKey('call-active-contacts'),
        onPressed: _showContacts,
        icon: const Icon(Icons.contacts_outlined, size: 18),
        label: Text(_t('通讯录', 'Contacts', '連絡先')),
      ),
      SizedBox(height: compact ? 22 : 32),
      _control(
        id: 'call-end',
        icon: Icons.call_end_rounded,
        label: _t('结束通话', 'End call', '通話終了'),
        color: const Color(0xFFFF453A),
        large: true,
        allowDuringPending: true,
        onTap: () => _act(widget.controller.endCall, allowDuringPending: true),
      ),
    ],
  );

  Widget _terminalControls(CallUiSnapshot snapshot) => Column(
    children: [
      if (snapshot.phase == CallUiPhase.failed && widget.onOpenSettings != null)
        TextButton.icon(
          onPressed: widget.onOpenSettings,
          icon: const Icon(Icons.settings_outlined),
          label: Text(_t('检查通话设置', 'Check call settings', '通話設定を確認')),
        ),
      const SizedBox(height: 14),
      _control(
        id: 'call-close',
        icon: Icons.close_rounded,
        label: _t('返回通讯录', 'Back to contacts', '連絡先に戻る'),
        onTap: () => _act(widget.controller.endCall),
      ),
    ],
  );

  Widget _control({
    required String id,
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    Color? color,
    bool selected = false,
    bool large = false,
    bool allowDuringPending = false,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final maxWidth = constraints.hasBoundedWidth
          ? constraints.maxWidth
          : 100.0;
      final diameter = (large ? 80.0 : 64.0).clamp(
        48.0,
        maxWidth.clamp(48.0, 100.0),
      );
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              selected: selected,
              label: label,
              child: Material(
                color:
                    color ??
                    (selected
                        ? Colors.white.withValues(alpha: .88)
                        : Colors.white.withValues(alpha: .16)),
                shape: const CircleBorder(),
                child: InkWell(
                  key: ValueKey(id),
                  customBorder: const CircleBorder(),
                  onTap: _actionPending && !allowDuringPending ? null : onTap,
                  child: SizedBox.square(
                    dimension: diameter,
                    child: Icon(
                      icon,
                      size: large ? 37 : 29,
                      color: onTap == null
                          ? Colors.white30
                          : selected && color == null
                          ? const Color(0xFF18202C)
                          : Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 9),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: onTap == null ? Colors.white38 : Colors.white,
                height: 1.25,
              ),
            ),
          ],
        ),
      );
    },
  );

  Future<void> _showContacts() => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    backgroundColor: const Color(0xFF202631),
    showDragHandle: true,
    builder: (context) => ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
      children: [
        Text(
          _t('通讯录', 'Contacts', '連絡先'),
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            _t(
              '正在通话中。结束本次通话后可拨打其他联系人。',
              'End the current call before calling another contact.',
              '別の相手に発信するには、現在の通話を終了してください。',
            ),
            style: const TextStyle(color: Colors.white60),
          ),
        ),
        for (final contact in widget.controller.contacts)
          ListTile(
            leading: _avatar(contact),
            title: Text(contact.displayName),
            trailing: widget.controller.snapshot.contact?.id == contact.id
                ? const Icon(
                    Icons.phone_in_talk_rounded,
                    color: Color(0xFF70EC91),
                  )
                : null,
          ),
      ],
    ),
  );

  Future<void> _textInput() async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) => _CallTextDialog(language: widget.language),
    );
    if (mounted && text != null && text.isNotEmpty) {
      await _act(() => widget.controller.sendText(text));
    }
  }

  String _status(CallUiSnapshot snapshot) {
    final message = snapshot.statusMessage?.trim();
    if (snapshot.phase != CallUiPhase.listening &&
        message != null &&
        message.isNotEmpty) {
      return message;
    }
    return switch (snapshot.phase) {
      CallUiPhase.idle => '',
      CallUiPhase.incoming => _t('来电', 'Incoming call', '着信中'),
      CallUiPhase.preparing => _t(
        '正在准备麦克风与语音识别…',
        'Preparing microphone and recognition…',
        'マイクと音声認識を準備中…',
      ),
      CallUiPhase.dialing => _t('正在呼叫…', 'Calling…', '呼び出し中…'),
      CallUiPhase.listening =>
        snapshot.muted
            ? _t('麦克风已静音', 'Microphone muted', 'マイクはミュート中')
            : _t(
                '正在聆听 · 说完后停顿片刻',
                'Listening · pause briefly when finished',
                '聞いています · 話し終えたら少し間を空けてください',
              ),
      CallUiPhase.thinking => _t('正在思考…', 'Thinking…', '考えています…'),
      CallUiPhase.speaking => _t('正在说话', 'Speaking', '話しています'),
      CallUiPhase.interrupted => _t('已打断，请说', 'Your turn', 'どうぞ話してください'),
      CallUiPhase.ended => _t('通话已结束', 'Call ended', '通話終了'),
      CallUiPhase.failed => _t('通话未接通', 'Unable to connect', '接続できませんでした'),
    };
  }

  String _historyLabel(CallHistoryStatus status) => switch (status) {
    CallHistoryStatus.completed => _t('已结束', 'Completed', '通話終了'),
    CallHistoryStatus.missed => _t('未接来电', 'Missed', '不在着信'),
    CallHistoryStatus.rejected => _t('已拒绝', 'Declined', '拒否'),
    CallHistoryStatus.cancelled => _t('已取消', 'Cancelled', 'キャンセル'),
    CallHistoryStatus.failed => _t('未接通', 'Not connected', '接続失敗'),
  };

  static String _duration(Duration duration) {
    final seconds = duration.inSeconds.clamp(0, 359999);
    final hours = seconds ~/ 3600;
    final minutes = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
    final remainder = (seconds % 60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$remainder' : '$minutes:$remainder';
  }

  static String _date(DateTime date) {
    final local = date.toLocal();
    return '${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _CallTextDialog extends StatefulWidget {
  const _CallTextDialog({required this.language});
  final AppLanguage language;

  @override
  State<_CallTextDialog> createState() => _CallTextDialogState();
}

class _CallTextDialogState extends State<_CallTextDialog> {
  final _draft = TextEditingController();

  String _t(String zh, String en, String ja) =>
      widget.language.text(zh, en, ja);

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_t('通话文字输入', 'Type during call', '文字で話す')),
    content: TextField(
      key: const ValueKey('call-text-draft'),
      controller: _draft,
      autofocus: true,
      minLines: 2,
      maxLines: 5,
      maxLength: 2000,
      decoration: InputDecoration(
        hintText: _t('发送给正在通话的角色', 'Send to this contact', '通話相手に送信'),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(_t('取消', 'Cancel', 'キャンセル')),
      ),
      TextButton(
        key: const ValueKey('call-text-send'),
        onPressed: () => Navigator.pop(context, _draft.text.trim()),
        child: Text(_t('发送', 'Send', '送信')),
      ),
    ],
  );
}
