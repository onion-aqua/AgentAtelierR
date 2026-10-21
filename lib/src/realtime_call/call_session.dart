import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../ai_services.dart';
import '../android_companion_runtime.dart';
import '../app_controller.dart';
import '../app_localization.dart';
import '../character_runtime_profile.dart';
import '../chat_segments.dart' show klaudiaFishAudioReferenceId;
import '../dialogue_language_guard.dart';
import 'call_audio.dart';
import 'call_audio_priority.dart';
import 'call_records.dart';
import 'call_reply.dart';
import 'call_settings.dart';
import 'call_ui_models.dart';
import 'fish_call_tts.dart';
import 'local_call_asr.dart';

class CallSpeech {
  const CallSpeech(this.pcm, this.cancel);
  final Stream<Uint8List> pcm;
  final Future<void> Function() cancel;
}

typedef CallSpeechFactory = CallSpeech Function(
  String text,
  String voice,
  String model,
  String apiKey,
);

/// One foreground call, one generation, one active speaker. Network and ASR
/// results carry epochs so a hangup/save switch cannot resurrect a call.
class RealtimeCallController extends CallUiController
    with WidgetsBindingObserver {
  RealtimeCallController({
    required this.app,
    LocalCallAsr? asr,
    CallPcmOutput? output,
    CallReplyBackend? replies,
    CallSettingsStore? settingsStore,
    CallSpeechFactory? speechFactory,
    Future<String> Function()? readFishKey,
    this.canStart,
  }) : asr = asr ?? LocalCallAsr(),
       output = output ?? AndroidCallPcmOutput(),
       replies = replies ?? const DirectCallReplyBackend(),
       settingsStore = settingsStore ?? CallSettingsStore(),
       _readFishKey = readFishKey ?? const SecretStore().readFishAudioKey {
    _revision = app.dataRevision;
    _character = app.activeCharacterId;
    _speechFactory =
        speechFactory ??
        (text, voice, model, key) {
          final stream = FishCallTtsClient().synthesize(
            apiKey: key,
            text: text,
            voiceId: voice,
            model: model,
            speed: app.fishAudioSpeed,
            endpoint: Uri.parse(app.fishAudioBaseUrl),
          );
          return CallSpeech(stream.pcm, stream.cancel);
        };
    app.addListener(_appChanged);
    _asrEvents = this.asr.events.listen(_asrEvent);
    AndroidCompanionRuntime.instance.addListener(_externalAudioChanged);
    WidgetsBinding.instance.addObserver(this);
  }
  final AppController app;
  final LocalCallAsr asr;
  final CallPcmOutput output;
  final CallReplyBackend replies;
  final CallSettingsStore settingsStore;
  final Future<String> Function() _readFishKey;
  final bool Function()? canStart;
  late final CallSpeechFactory _speechFactory;
  late final StreamSubscription<LocalCallAsrEvent> _asrEvents;
  final playbackLevel = ValueNotifier<double>(0);
  CallUiPhase _phase = CallUiPhase.idle;
  CallContact? _contact;
  String _caption = '', _interim = '', _voice = '', _model = '', _fishKey = '';
  String _captionTranslation = '';
  TranslationLanguage? _captionTranslationLanguage;
  AppLanguage? _captionSourceLanguage;
  String? _error;
  bool _muted = false, _speaker = true, _closed = false;
  int _sessionEpoch = 0, _turnEpoch = 0;
  late int _revision;
  late String _character;
  DateTime? _connected;
  CallRecord? _record;
  Timer? _clock, _ringTimeout;
  CallSpeech? _speech;
  StreamIterator<String>? _llm;
  StreamIterator<Uint8List>? _audio;
  Future<void>? _finishing;
  Future<void>? _preparing;
  Future<void>? _turnTask;
  Future<void>? _interrupting;
  String? _bargeTranscript;
  Future<void> _resourceQueue = Future.value();
  String? _pendingInput;
  StringBuffer? _pendingSpoken;
  int? _pendingRecordIndex;
  int _seconds = 0;
  bool get active => snapshot.isActive;
  bool get speaking => _phase == CallUiPhase.speaking;

  Future<T> _serializeResources<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _resourceQueue = _resourceQueue.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  @override
  List<CallContact> get contacts {
    // Calls are currently adapted only for these two Ryza-world characters.
    // Never reuse Sophie's persona or save as a callable Ryza profile.
    if (app.activeCharacterId != CharacterRuntimeIds.ryza) return const [];
    final language = app.interfaceLanguage;
    return [
      CallContact(
        id: 'primary:ryza',
        displayName: app.activeCharacterProfile.displayNameFor(language.name),
        avatarAsset: app.activeCharacterProfile.staticPortraitAsset,
        subtitle: language.text('当前角色', 'Current character', '現在のキャラクター'),
      ),
      for (final npc in app.npcChatContacts.where((npc) => npc.id == 'claudia'))
        CallContact(
          id: npc.id,
          displayName: language.text(
            npc.names.chinese,
            npc.names.english,
            npc.names.japanese,
          ),
          avatarAsset: npc.avatarAsset,
        ),
    ];
  }

  @override
  List<CallHistoryEntry> get history => app.callRecords.reversed
      .where(
        (record) =>
            const {'primary:ryza', 'claudia'}.contains(record.contactId),
      )
      .map((r) => r.history)
      .toList();
  @override
  CallUiSnapshot get snapshot => CallUiSnapshot(
    phase: _phase,
    contact: _contact,
    elapsed: Duration(seconds: _seconds),
    muted: _muted,
    speaker: _speaker,
    caption: _caption,
    captionTranslation:
        _captionTranslationLanguage == app.translationLanguage &&
            _captionSourceLanguage == app.characterReplyLanguage
        ? _captionTranslation
        : '',
    interimTranscript: _interim,
    error: _error,
    statusMessage: _phase == CallUiPhase.listening ? '正在聆听 · 说完后停顿片刻' : null,
  );
  void _notify() {
    if (!_closed) notifyListeners();
  }

  bool _current(int session, int turn) =>
      !_closed &&
      _sessionEpoch == session &&
      _turnEpoch == turn &&
      active &&
      app.dataRevision == _revision;
  void _appChanged() {
    if (_revision != app.dataRevision || _character != app.activeCharacterId) {
      // Keep the old revision until teardown has finished. Saving an old
      // record with a newly selected save's revision would cross save scopes.
      if (active || _phase == CallUiPhase.incoming) {
        unawaited(endCall());
      } else if (_record == null) {
        _revision = app.dataRevision;
        _character = app.activeCharacterId;
      }
    }
    _notify();
  }

  void _externalAudioChanged() {
    final runtime = AndroidCompanionRuntime.instance;
    if ((active || _phase == CallUiPhase.incoming) &&
        // `muted` also covers an ordinary media-focus loss or a pending
        // focus request. Those states belong to background audio and can be
        // raised by this call's own AudioTrack while it is starting. Only a
        // native communication state (or an explicit user stop) is a reason
        // to tear down the in-app call.
        (runtime.callActive || runtime.stopRequested)) {
      unawaited(
        _finish(CallHistoryStatus.cancelled, '通话因系统来电或音频中断结束，请稍后重新拨打。'),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((active || _phase == CallUiPhase.incoming) &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached ||
            state == AppLifecycleState.hidden)) {
      unawaited(_finish(CallHistoryStatus.cancelled, '应用已进入后台，麦克风和通话已停止。'));
    }
  }

  CallContact _find(String id) =>
      contacts.where((c) => c.id == id).firstOrNull ??
      (throw const FormatException('目前仅支持与莱莎和科洛蒂娅通话。'));
  @override
  Future<void> offerCall(String contactId) async {
    if (_closed || active || _phase == CallUiPhase.incoming) return;
    if (_finishing != null) await _finishing;
    if (_preparing != null) await _preparing;
    if (_closed || active) return;
    _contact = _find(contactId);
    _phase = CallUiPhase.incoming;
    _error = null;
    _seconds = 0;
    _newRecord(true);
    _ringTimeout = Timer(
      const Duration(seconds: 30),
      () => unawaited(_finish(CallHistoryStatus.missed)),
    );
    _notify();
  }

  void _newRecord(bool incoming) {
    _revision = app.dataRevision;
    _character = app.activeCharacterId;
    _record = CallRecord(
      id: 'call-${DateTime.now().microsecondsSinceEpoch}',
      contactId: _contact!.id,
      contactName: _contact!.displayName,
      startedAt: DateTime.now().toUtc(),
      incoming: incoming,
    );
    _saveRecord();
  }

  void _saveRecord() {
    final record = _record;
    if (record != null) app.saveCallRecord(record, expectedRevision: _revision);
  }

  @override
  Future<void> acceptCall() async {
    if (_phase != CallUiPhase.incoming || _contact == null) return;
    _ringTimeout?.cancel();
    final preparing = _connect(_contact!.id, incoming: true);
    _preparing = preparing;
    try {
      await preparing;
    } finally {
      if (identical(_preparing, preparing)) _preparing = null;
    }
  }

  @override
  Future<void> declineCall() => _finish(CallHistoryStatus.rejected);
  @override
  Future<void> startCall(String contactId) async {
    if (_closed || active || _phase == CallUiPhase.incoming) return;
    if (_finishing != null) await _finishing;
    if (_preparing != null) await _preparing;
    if (_closed || active) return;
    final preparing = _connect(contactId);
    _preparing = preparing;
    try {
      await preparing;
    } finally {
      if (identical(_preparing, preparing)) _preparing = null;
    }
  }

  Future<void> _connect(String id, {bool incoming = false}) async {
    final session = ++_sessionEpoch;
    _turnEpoch++;
    _contact = _find(id);
    if (id == 'claudia') app.addNpcContact(id);
    _error = null;
    _caption = '';
    _interim = '';
    _seconds = 0;
    _muted = false;
    _phase = CallUiPhase.preparing;
    if (!incoming) _newRecord(false);
    _notify();
    try {
      if (canStart?.call() == false) {
        throw const FormatException('请先等待主聊天回复完成，并关闭持续 ASMR。');
      }
      if (!app.aiEnabled || app.activeLlmModel.trim().isEmpty) {
        throw const FormatException('请先在 AI 接口中配置并启用主 LLM。');
      }
      final uri = Uri.tryParse(app.activeLlmBaseUrl);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('通话的 LLM 接口必须使用 HTTPS。');
      }
      final config = await settingsStore.load();
      await config.asr.validateFiles();
      if (session != _sessionEpoch || _closed) return;
      _model = config.fishModel.trim().isEmpty
          ? app.fishAudioModel
          : config.fishModel;
      _voice = config.voiceOverrides[id]?.trim() ?? '';
      if (_voice.isEmpty && id.startsWith('primary:')) {
        _voice = app.fishAudioReferenceId.trim().isNotEmpty
            ? app.fishAudioReferenceId.trim()
            : app.fishMcpVoice.trim();
      }
      if (_voice.isEmpty && id == 'claudia') {
        _voice = klaudiaFishAudioReferenceId;
      }
      if (_voice.isEmpty) {
        throw const FormatException('请在电话设置中为这位联系人填写 Fish Audio 音色 ID。');
      }
      _fishKey = await _readFishKey();
      if (_fishKey.trim().isEmpty) {
        throw const FormatException(
          '实时通话需要 Fish Audio REST API Key，请在原 TTS 设置中填写。MCP OAuth 不能替代此密钥。',
        );
      }
      if (session != _sessionEpoch || _closed) return;
      CallAudioPriority.instance.value = true;
      _phase = CallUiPhase.dialing;
      _notify();
      // Verify playback before acquiring microphone. No charge is incurred.
      final ready = await _serializeResources(() async {
        if (session != _sessionEpoch || _closed) return false;
        await output.start();
        if (session != _sessionEpoch || _closed) return false;
        await asr.start(config.asr);
        return session == _sessionEpoch && !_closed;
      });
      if (!ready) return;
      _connected = DateTime.now();
      _phase = CallUiPhase.listening;
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        _seconds = DateTime.now().difference(_connected!).inSeconds;
        _notify();
      });
      _notify();
    } catch (error) {
      if (session == _sessionEpoch && !_closed) {
        await _finish(CallHistoryStatus.failed, _safeError(error));
      }
    }
  }

  void _asrEvent(LocalCallAsrEvent event) {
    if (!active) return;
    if (event.kind == LocalCallAsrEventKind.transcript &&
        !_muted &&
        _phase != CallUiPhase.preparing &&
        _phase != CallUiPhase.dialing) {
      // Recognition may finish before the cancelled AudioTrack/HTTP stream
      // settles. Keep the utterance until teardown can no longer affect it.
      if (_interrupting != null) {
        _bargeTranscript = [?_bargeTranscript, event.text].join(' ').trim();
        return;
      }
      unawaited(
        sendText(event.text).catchError(
          (Object error, StackTrace _) =>
              _finish(CallHistoryStatus.failed, _safeError(error)),
        ),
      );
    } else if (event.kind == LocalCallAsrEventKind.error) {
      unawaited(_finish(CallHistoryStatus.failed, event.text));
    } else if (event.kind == LocalCallAsrEventKind.speechStarted && !_muted) {
      _interim = '正在识别…';
      _notify();
      if (_phase == CallUiPhase.speaking || _phase == CallUiPhase.thinking) {
        unawaited(
          interrupt().catchError(
            (Object error, StackTrace _) =>
                _finish(CallHistoryStatus.failed, _safeError(error)),
          ),
        );
      }
    }
  }

  @override
  Future<void> setMuted(bool value) async {
    _muted = value;
    if (value) _bargeTranscript = null;
    _notify();
    try {
      await asr.setMuted(value);
    } catch (error) {
      if (active) {
        await _finish(CallHistoryStatus.failed, _safeError(error));
      }
    }
  }

  @override
  Future<void> setSpeaker(bool value) async {
    if (!active) return;
    if (await output.setSpeaker(value)) {
      _speaker = value;
    } else {
      _error = '当前设备暂不支持切换此输出设备，可使用耳机。';
    }
    _notify();
  }

  @override
  Future<void> sendText(String text) async {
    text = text.trim();
    if (!active || text.isEmpty || text.length > 4000 || _contact == null) {
      return;
    }
    if (_phase == CallUiPhase.preparing || _phase == CallUiPhase.dialing) {
      return;
    }
    if (_interrupting != null) {
      await _interrupting;
    } else if (_phase != CallUiPhase.listening) {
      await interrupt();
    }
    if (!active || _contact == null || _closed) return;
    final session = _sessionEpoch, turn = ++_turnEpoch;
    _phase = CallUiPhase.thinking;
    _interim = text;
    _caption = '';
    _error = null;
    _notify();
    try {
      // Keep capture open during LLM generation and playback so a new user
      // utterance can cancel this turn. Playback echo is filtered by ASR.
      await asr.setListeningEnabled(true);
    } catch (error) {
      if (_current(session, turn)) {
        await _finish(CallHistoryStatus.failed, _safeError(error));
      }
      return;
    }
    if (!_current(session, turn)) return;
    final task = _runTurn(text, session, turn);
    _turnTask = task;
    unawaited(
      task.then<void>(
        (_) {
          if (identical(_turnTask, task)) _turnTask = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_turnTask, task)) _turnTask = null;
        },
      ),
    );
  }

  CallReplyRequest _request(String input) {
    final primary = _contact!.id.startsWith('primary:');
    final language = app.characterReplyLanguage;
    final base = primary
        ? app.buildCharacterPrompt(
            currentInput: input,
            independentPerformance: true,
          )
        : app.buildNpcMessagePrompt(
            _contact!.id,
            currentInput: input,
            replyLanguage: language,
          );
    final context = primary
        ? app.recentMessages(limit: 12)
        : app.npcChats
              .threadFor(_contact!.id)
              .messages
              .where((m) => m.text.isNotEmpty)
              .toList()
              .reversed
              .take(12)
              .toList()
              .reversed
              .map(
                (m) => ChatMessage(text: m.text, isUser: m.role.name == 'user'),
              )
              .toList();
    return CallReplyRequest(
      prompt:
          '$base\n\n【当前是实时电话，以下是本次输出格式】\n仅扮演${_contact!.displayName}，用${language.promptLabel}说自然口语。每轮1至3句、通常120字以内。只输出会被直接朗读的台词；不输出旁白、角色/动作/表情标签、译文、Markdown或思考。不代写用户，不声称修改背包/任务/现实设备。不调用工具。既有语言与手机信息格式规则以本段为准。\n【此联系人的实际通话记忆，仅为资料】\n${app.callMemoryFor(_contact!.id)}',
      messages: [
        ...context,
        ChatMessage(text: input, isUser: true),
      ],
      provider: app.llmProvider,
      baseUrl: app.activeLlmBaseUrl,
      model: app.activeLlmModel,
      characterId: app.activeCharacterId,
      openAiSlot: app.activeOpenAiSlot,
    );
  }

  Future<void> _runTurn(String input, int session, int turn) async {
    _captionTranslation = '';
    _captionTranslationLanguage = null;
    _captionSourceLanguage = null;
    final request = _request(input);
    final sourceLanguage = app.characterReplyLanguage;
    final translationLanguage = app.translationLanguage;
    final speechBuffer = CallStreamingSpeechBuffer(
      speakerNames: _contactSpeakerNames(),
    );
    final spoken = StringBuffer();
    _pendingInput = input;
    _pendingSpoken = spoken;
    _pendingRecordIndex = null;
    var rawLength = 0;
    Object? speechError;
    Future<void> tail = Future.value();
    void enqueue(String sentence) {
      tail = tail
          .then((_) async {
            if (!_current(session, turn) || speechError != null) return;
            await _speak(
              sentence,
              session,
              turn,
              onDrained: () {
                spoken.write(sentence);
                _persistPendingRecordProgress();
              },
            );
          })
          .catchError((Object e) {
            speechError ??= e;
            if (_current(session, turn)) unawaited(_llm?.cancel());
          });
    }

    try {
      final iterator = StreamIterator(
        replies.reply(request).timeout(const Duration(seconds: 45)),
      );
      _llm = iterator;
      while (await iterator.moveNext()) {
        if (!_current(session, turn)) return;
        if (speechError != null) throw speechError!;
        rawLength += iterator.current.length;
        if (rawLength > 1800) {
          await iterator.cancel();
          throw const FormatException('本轮回复过长，已停止生成。');
        }
        for (final part in speechBuffer.add(iterator.current)) {
          enqueue(part);
          _caption = '${_caption.trim()} $part'.trim();
        }
        _notify();
      }
      if (identical(_llm, iterator)) _llm = null;
      if (!_current(session, turn)) return;
      for (final part in speechBuffer.add('', flush: true)) {
        enqueue(part);
        _caption = '${_caption.trim()} $part'.trim();
      }
      unawaited(
        _translateCaption(
          request,
          sourceLanguage,
          translationLanguage,
          session,
          turn,
        ),
      );
      await tail;
      if (speechError != null) throw speechError!;
      if (!_current(session, turn)) return;
      if (spoken.isEmpty) throw const FormatException('本轮没有得到可播放的语音，请重新说话。');
      _commitPending();
      playbackLevel.value = 0;
      await asr.setPlaybackActive(false);
      if (!_current(session, turn)) return;
      _phase = CallUiPhase.listening;
      _notify();
      await asr.setListeningEnabled(true);
    } catch (error) {
      if (!_current(session, turn)) return;
      // Cancel both producers once. Never repeat a potentially billable POST.
      ++_turnEpoch;
      await _cancelActiveProducers();
      try {
        await _serializeResources(output.stop);
      } on Object {
        // The original LLM/TTS error remains the useful user-facing failure.
      }
      playbackLevel.value = 0;
      _commitPending();
      _phase = CallUiPhase.interrupted;
      _error = _safeError(error);
      _notify();
      try {
        await asr.setPlaybackActive(false, preserveSpeech: true);
        await asr.setListeningEnabled(true);
        if (!_closed && _sessionEpoch == session && active) {
          _phase = CallUiPhase.listening;
          _notify();
        }
      } catch (resumeError) {
        if (!_closed && _sessionEpoch == session && active) {
          await _finish(CallHistoryStatus.failed, _safeError(resumeError));
        }
      }
    }
  }

  Future<void> _translateCaption(
    CallReplyRequest request,
    AppLanguage sourceLanguage,
    TranslationLanguage language,
    int session,
    int turn,
  ) async {
    final source = _caption.trim();
    final backend = replies;
    if (backend is! CallCaptionTranslationBackend ||
        source.isEmpty ||
        language == TranslationLanguage.none ||
        translationLanguageToAppLanguage(language) == sourceLanguage) {
      return;
    }
    try {
      final translated = await (backend as CallCaptionTranslationBackend)
          .translateCaption(request, source, language);
      if (!_current(session, turn) ||
          app.characterReplyLanguage != sourceLanguage ||
          app.translationLanguage != language ||
          _caption.trim() != source) {
        return;
      }
      _captionTranslation = translated.trim();
      _captionTranslationLanguage = language;
      _captionSourceLanguage = sourceLanguage;
      _notify();
    } on Object {
      // Translation is optional; a subtitle failure cannot stop audio or
      // repeat a potentially billable generation request.
    }
  }

  Iterable<String> _contactSpeakerNames() sync* {
    final contact = _contact;
    if (contact == null) return;
    yield contact.displayName;
    if (contact.id.startsWith('primary:')) {
      final names = app.activeCharacterProfile.names;
      yield names.chinese;
      yield names.english;
      yield names.japanese;
      return;
    }
    final npc = app.npcChatContacts
        .where((candidate) => candidate.id == contact.id)
        .firstOrNull;
    if (npc == null) return;
    for (final alias in npc.aliases) {
      yield alias;
      final short = alias.split(RegExp(r'[·・\s]+')).first;
      if (short != alias) yield short;
    }
  }

  Future<void> _speak(
    String sentence,
    int session,
    int turn, {
    required VoidCallback onDrained,
  }) async {
    if (!_current(session, turn)) return;
    // Restart after a user interruption; normal consecutive sentences reuse
    // the same bounded AudioTrack buffer.
    if (_phase != CallUiPhase.speaking) {
      await _serializeResources(output.start);
      if (!_current(session, turn)) return;
      if (!_speaker) await output.setSpeaker(false);
      if (!_current(session, turn)) return;
    }
    final speech = _speechFactory(sentence, _voice, _model, _fishKey);
    _speech = speech;
    final audio = StreamIterator(speech.pcm);
    _audio = audio;
    var playbackStarted = false;
    try {
      while (await audio.moveNext()) {
        if (!_current(session, turn)) return;
        final pcm = audio.current;
        for (var offset = 0; offset < pcm.length; offset += 3840) {
          if (!_current(session, turn)) return;
          final end = (offset + 3840).clamp(0, pcm.length);
          final frame = Uint8List.sublistView(pcm, offset, end);
          if (!playbackStarted) {
            await asr.setPlaybackActive(true);
            playbackStarted = true;
            if (!_current(session, turn)) return;
          }
          asr.addPlaybackPcm(frame);
          await output.write(frame);
          if (!_current(session, turn)) return;
          _phase = CallUiPhase.speaking;
          playbackLevel.value = callPcmLevel(frame);
          _notify();
        }
      }
      await output.drain();
      if (!_current(session, turn)) return;
      onDrained();
    } finally {
      await audio.cancel();
      await speech.cancel();
      if (identical(_speech, speech)) _speech = null;
      if (identical(_audio, audio)) _audio = null;
    }
  }

  void _commitTurn(String input, String spoken) {
    app.recordCallExchange(
      _contact!.id,
      input,
      spoken,
      expectedRevision: _revision,
    );
  }

  /// Update the save-scoped call transcript immediately after each successful
  /// AudioTrack drain. This makes completed speech durable even if the user
  /// switches save slots before the rest of the model response finishes.
  void _persistPendingRecordProgress() {
    final input = _pendingInput, spoken = _pendingSpoken;
    final record = _record;
    if (input == null || spoken == null || spoken.isEmpty || record == null) {
      return;
    }
    final turns = [...record.turns];
    final value = {'user': input, 'assistant': spoken.toString()};
    final index = _pendingRecordIndex;
    if (index != null && index >= 0 && index < turns.length) {
      turns[index] = value;
    } else {
      turns.add(value);
      _pendingRecordIndex = turns.length - 1;
    }
    if (turns.length > 100) {
      final overflow = turns.length - 100;
      turns.removeRange(0, overflow);
      _pendingRecordIndex = (_pendingRecordIndex! - overflow).clamp(
        0,
        turns.length - 1,
      );
    }
    _record = record.copyWith(seconds: _seconds.clamp(0, 86400), turns: turns);
    _saveRecord();
  }

  void _commitPending() {
    final input = _pendingInput, spoken = _pendingSpoken;
    if (input != null && spoken != null && spoken.isNotEmpty) {
      _persistPendingRecordProgress();
      _commitTurn(input, spoken.toString());
    }
    _pendingInput = null;
    _pendingSpoken = null;
    _pendingRecordIndex = null;
  }

  Future<void> _cancelActiveProducers() async {
    final llm = _llm;
    _llm = null;
    final audio = _audio;
    _audio = null;
    final speech = _speech;
    _speech = null;
    await Future.wait([
      if (llm != null) llm.cancel().catchError((Object _) {}),
      if (audio != null) audio.cancel().catchError((Object _) {}),
      if (speech != null) speech.cancel().catchError((Object _) {}),
    ]);
  }

  Future<void> _settleTurn(Future<void>? task) async {
    if (task == null) return;
    try {
      await task;
    } on Object {
      // The visible call state already owns error reporting. Teardown only
      // waits until no late callback can append or persist more speech.
    }
  }

  @override
  Future<void> interrupt() {
    if (!active) return Future.value();
    final pending = _interrupting;
    if (pending != null) return pending;
    final session = _sessionEpoch;
    final operation = _interruptTurn(session);
    _interrupting = operation;
    return operation.whenComplete(() {
      if (!identical(_interrupting, operation)) return;
      _interrupting = null;
      final transcript = _bargeTranscript;
      _bargeTranscript = null;
      if (transcript != null &&
          transcript.isNotEmpty &&
          !_muted &&
          !_closed &&
          session == _sessionEpoch &&
          _phase == CallUiPhase.listening) {
        unawaited(sendText(transcript));
      }
    });
  }

  Future<void> _interruptTurn(int session) async {
    final turnTask = _turnTask;
    ++_turnEpoch;
    _phase = CallUiPhase.interrupted;
    playbackLevel.value = 0;
    _notify();
    // Stop the speaker immediately; cancelling a producer can wait on a
    // pending stream callback and must never keep buffered audio audible.
    await Future.wait([
      _serializeResources(output.stop),
      _cancelActiveProducers(),
    ]);
    await _settleTurn(turnTask);
    _commitPending();
    playbackLevel.value = 0;
    if (_closed || !active || session != _sessionEpoch) return;
    _error = null;
    try {
      // Preserve the VAD utterance which caused automatic interruption.
      await asr.setPlaybackActive(false, preserveSpeech: true);
      await asr.setListeningEnabled(true);
      if (_closed || !active || session != _sessionEpoch) return;
      _phase = CallUiPhase.listening;
      _notify();
    } catch (error) {
      if (active) {
        await _finish(CallHistoryStatus.failed, _safeError(error));
      }
    }
  }

  @override
  Future<void> endCall() {
    if ((_phase == CallUiPhase.ended || _phase == CallUiPhase.failed) &&
        _record == null) {
      _phase = CallUiPhase.idle;
      _contact = null;
      _error = null;
      _caption = '';
      _interim = '';
      _seconds = 0;
      _notify();
      return Future.value();
    }
    return _finish(
      _connected == null
          ? CallHistoryStatus.cancelled
          : CallHistoryStatus.completed,
    );
  }

  /// Synchronous half of a save/character reset.
  ///
  /// AppController invokes reset listeners before changing [dataRevision]. All
  /// text confirmed by AudioTrack drain and the cancelled record must be saved
  /// here while the old save scope is still current. Network, ASR and PCM
  /// teardown continues asynchronously and blocks the next call via
  /// [_finishing].
  void prepareForDataReset() {
    if (_closed ||
        (!active &&
            _phase != CallUiPhase.incoming &&
            _record == null &&
            _pendingInput == null)) {
      return;
    }
    final turnTask = _turnTask;
    _bargeTranscript = null;
    ++_sessionEpoch;
    ++_turnEpoch;
    _ringTimeout?.cancel();
    _clock?.cancel();
    _clock = null;
    _commitPending();
    _record = _record?.copyWith(
      seconds: _seconds.clamp(0, 86400),
      status: CallHistoryStatus.cancelled,
    );
    _saveRecord();
    _record = null;
    _connected = null;
    _fishKey = '';
    _phase = CallUiPhase.ended;
    CallAudioPriority.instance.value = false;
    playbackLevel.value = 0;
    _notify();

    final cleanup = () async {
      await _cancelActiveProducers();
      await _serializeResources(() async {
        await Future.wait([
          asr.stop().catchError((Object _) {}),
          output.stop().catchError((Object _) {}),
        ]);
      });
      await _settleTurn(turnTask);
    }();
    _finishing = cleanup;
    unawaited(
      cleanup.whenComplete(() {
        if (identical(_finishing, cleanup)) _finishing = null;
      }),
    );
  }

  Future<void> _finish(CallHistoryStatus status, [String? error]) {
    if (_finishing != null) return _finishing!;
    final next = _finishNow(status, error);
    _finishing = next;
    return next.whenComplete(() {
      if (identical(_finishing, next)) _finishing = null;
    });
  }

  Future<void> _finishNow(CallHistoryStatus status, String? error) async {
    final turnTask = _turnTask;
    _bargeTranscript = null;
    ++_sessionEpoch;
    ++_turnEpoch;
    _ringTimeout?.cancel();
    _clock?.cancel();
    _clock = null;
    _phase = error == null ? CallUiPhase.ended : CallUiPhase.failed;
    _error = error;
    _notify();
    await _cancelActiveProducers();
    await _serializeResources(() async {
      await Future.wait([
        asr.stop().catchError((Object _) {}),
        output.stop().catchError((Object _) {}),
      ]);
    });
    await _settleTurn(turnTask);
    _commitPending();
    playbackLevel.value = 0;
    CallAudioPriority.instance.value = false;
    _record = _record?.copyWith(
      seconds: _seconds.clamp(0, 86400),
      status: status,
    );
    _saveRecord();
    _record = null;
    _connected = null;
    _fishKey = '';
    _notify();
  }

  String _safeError(Object e) => e is FishCallTtsException
      ? e.message
      : e is FormatException
      ? e.message
      : '通话已中断，请检查模型、权限和服务配置后重新拨打；未自动重试。';
  @override
  void dispose() {
    prepareForDataReset();
    _closed = true;
    app.removeListener(_appChanged);
    AndroidCompanionRuntime.instance.removeListener(_externalAudioChanged);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_asrEvents.cancel());
    final cleanup =
        _finishing ??
        (() async {
          await _cancelActiveProducers();
          await _serializeResources(() async {
            await Future.wait([
              asr.stop().catchError((Object _) {}),
              output.stop().catchError((Object _) {}),
            ]);
          });
        })();
    unawaited(cleanup.whenComplete(asr.dispose));
    // A late audio write can still settle, so retire the notifier after cleanup.
    super.dispose();
  }
}
