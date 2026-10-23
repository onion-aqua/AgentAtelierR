import 'package:flutter/material.dart';

import '../app_localization.dart';
import 'call_ui_models.dart';

/// Controls the shared phone session without covering the character scene.
class MainChatVoicePanel extends StatefulWidget {
  const MainChatVoicePanel({
    super.key,
    required this.controller,
    required this.language,
    required this.onClose,
    required this.onOpenSettings,
  });

  final CallUiController controller;
  final AppLanguage language;
  final VoidCallback onClose;
  final VoidCallback onOpenSettings;

  @override
  State<MainChatVoicePanel> createState() => _MainChatVoicePanelState();
}

class _MainChatVoicePanelState extends State<MainChatVoicePanel> {
  bool _changingMute = false;
  bool _ending = false;
  String? _error;

  String _t(String zh, String en, String ja) =>
      widget.language.text(zh, en, ja);

  Future<void> _act(
    Future<void> Function() action, {
    bool ending = false,
  }) async {
    if (ending ? _ending : _changingMute) return;
    setState(() {
      if (ending) {
        _ending = true;
      } else {
        _changingMute = true;
      }
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _t('操作未完成，请重试。', 'Please try again.', 'もう一度お試しください。'),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          if (ending) {
            _ending = false;
          } else {
            _changingMute = false;
          }
        });
      }
    }
  }

  String _status(CallUiSnapshot call) => switch (call.phase) {
    CallUiPhase.idle => _t('语音通话', 'Voice chat', '音声会話'),
    CallUiPhase.incoming => _t('语音邀请', 'Incoming call', '着信中'),
    CallUiPhase.preparing || CallUiPhase.dialing => _t(
      '正在准备语音识别…',
      'Preparing speech recognition…',
      '音声認識を準備中…',
    ),
    CallUiPhase.listening || CallUiPhase.interrupted =>
      call.muted
          ? _t('已静音', 'Microphone muted', 'マイクはミュート中')
          : _t(
              '正在聆听 · 说完后停顿片刻',
              'Listening · pause when finished',
              '聞いています · 話し終えたら少し待ってね',
            ),
    CallUiPhase.thinking => _t('正在思考…', 'Thinking…', '考えています…'),
    CallUiPhase.speaking => _t(
      '正在说话 · 开口即可打断',
      'Speaking · talk to interrupt',
      '話しています · 声で割り込めます',
    ),
    CallUiPhase.ended => _t('通话已结束', 'Call ended', '通話終了'),
    CallUiPhase.failed => _t('通话未能开始', 'Call unavailable', '通話できませんでした'),
  };

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final call = widget.controller.snapshot;
      final ongoing = call.isActive || call.phase == CallUiPhase.incoming;
      final error = call.error ?? _error;
      final elapsed =
          '${call.elapsed.inMinutes.toString().padLeft(2, '0')}:${(call.elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
      return Padding(
        key: const ValueKey('main-chat-voice-panel'),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final details = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      call.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _status(call),
                        key: const ValueKey('main-chat-voice-status'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (call.elapsed > Duration.zero)
                      Text(
                        elapsed,
                        style: const TextStyle(color: Colors.white70),
                      ),
                  ],
                ),
                if (call.interimTranscript.isNotEmpty ||
                    call.caption.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    call.interimTranscript.isNotEmpty
                        ? call.interimTranscript
                        : call.caption,
                    key: const ValueKey('main-chat-voice-caption'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  if (call.interimTranscript.isEmpty &&
                      call.captionTranslation.isNotEmpty)
                    Text(
                      call.captionTranslation,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                ],
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      error,
                      key: const ValueKey('main-chat-voice-error'),
                      style: const TextStyle(color: Color(0xFFFFD4BD)),
                    ),
                  ),
              ],
            );
            final actions = Wrap(
              spacing: 8,
              runSpacing: 4,
              alignment: WrapAlignment.end,
              children: ongoing
                  ? [
                      if (call.phase == CallUiPhase.incoming)
                        TextButton.icon(
                          key: const ValueKey('main-chat-voice-accept'),
                          onPressed: _changingMute
                              ? null
                              : () => _act(widget.controller.acceptCall),
                          icon: const Icon(Icons.call_rounded),
                          label: Text(_t('接听', 'Answer', '応答')),
                        )
                      else
                        TextButton.icon(
                          key: const ValueKey('main-chat-voice-mute'),
                          onPressed:
                              _changingMute ||
                                  _ending ||
                                  call.phase == CallUiPhase.preparing ||
                                  call.phase == CallUiPhase.dialing
                              ? null
                              : () => _act(
                                  () => widget.controller.setMuted(!call.muted),
                                ),
                          icon: Icon(
                            call.muted
                                ? Icons.mic_off_rounded
                                : Icons.mic_rounded,
                          ),
                          label: Text(
                            call.muted
                                ? _t('取消静音', 'Unmute', 'ミュート解除')
                                : _t('静音', 'Mute', 'ミュート'),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                        ),
                      FilledButton.icon(
                        key: const ValueKey('main-chat-voice-end'),
                        onPressed: _ending
                            ? null
                            : () => _act(
                                call.phase == CallUiPhase.incoming
                                    ? widget.controller.declineCall
                                    : widget.controller.endCall,
                                ending: true,
                              ),
                        icon: const Icon(Icons.call_end_rounded),
                        label: Text(_t('挂断', 'End', '終了')),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFB73838),
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ]
                  : [
                      IconButton(
                        key: const ValueKey('main-chat-voice-settings'),
                        onPressed: widget.onOpenSettings,
                        icon: const Icon(Icons.settings_outlined),
                        tooltip: _t('语音设置', 'Voice settings', '音声設定'),
                        color: Colors.white,
                      ),
                      FilledButton(
                        key: const ValueKey('main-chat-voice-close'),
                        onPressed: widget.onClose,
                        child: Text(_t('返回输入', 'Type', '文字入力へ')),
                      ),
                    ],
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (constraints.hasBoundedHeight)
                  Flexible(child: SingleChildScrollView(child: details))
                else
                  details,
                const SizedBox(height: 6),
                actions,
              ],
            );
          },
        ),
      );
    },
  );
}
