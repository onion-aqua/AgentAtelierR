// Standalone debug entrypoint. Production main never imports this library.
// Build only through build_protected.ps1 -Mode debug -EntryPoint <this file>.
// All settings and SecretStore operations use memory-only mock backends. The
// HTTP transport is simulated inside this process on loopback, never online.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spine_flutter/spine_flutter.dart' hide Color;

import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/character_camera.dart';
import 'package:ryza_chat_mvp/src/character_spine_view.dart';
import 'package:ryza_chat_mvp/src/chat_screen.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/local_skin_store.dart';
import 'package:ryza_chat_mvp/src/runtime_log.dart';

Future<void> main() async {
  if (!kDebugMode) {
    throw StateError('The animation pipeline harness requires a debug build.');
  }
  WidgetsFlutterBinding.ensureInitialized();
  // These replace plugin backends before any controller or key is read. They
  // do not erase, migrate, export, or inspect the device's real preferences.
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  await RuntimeLog.instance.initialize();
  await initSpineFlutter(enableMemoryDebugging: false);
  Atlas.filterQuality = FilterQuality.high;
  await AudioPlayer.global.setAudioContext(
    AudioContext(
      android: const AudioContextAndroid(audioFocus: AndroidAudioFocus.none),
      iOS: AudioContextIOS(
        options: const {AVAudioSessionOptions.mixWithOthers},
      ),
    ),
  );
  // Imports and texture metadata are empty and only inspect this test folder.
  await LocalSkinStore.instance.initialize(
    storageDirectory: await Directory.systemTemp.createTemp('aar-pipeline-'),
  );
  const secrets = SecretStore();
  await secrets.writeOpenAiKey('simulated-loopback-llm');
  await secrets.writeFishAudioKey('simulated-loopback-tts');
  final transport = await _LocalTransport.start();
  final controller = await AppController.load();
  controller
    ..configureAi(
      enabled: true,
      baseUrl: '${transport.baseUrl}/v1',
      model: 'simulated-animation-pipeline',
    )
    ..setAgentEnabled(false)
    ..setLongTermMemoryEnabled(false)
    ..setIndependentTranslation(false)
    ..configureLanguages(
      interface: AppLanguage.chinese,
      narrator: AppLanguage.chinese,
      characterReply: AppLanguage.japanese,
      translation: TranslationLanguage.none,
    )
    ..setCharacterAppearance('seated_01')
    ..setVoiceEnabled(true)
    ..setBgmEnabled(false)
    ..setAmbientEnabled(false)
    ..setIndependentSpeechPerformance(true)
    ..configureFishAudio(
      enabled: false,
      model: 's2-pro',
      referenceId: 'simulated-reference',
      format: 'wav',
      baseUrl: '${transport.baseUrl}/v1/tts',
    )
    ..clearChatHistory(clearLongTermMemory: true);
  runApp(_Harness(controller: controller, transport: transport));
}

enum _Mode {
  noTts('no_tts', '无 TTS / 慢动作'),
  shortTts('short_tts', '1 秒 TTS / 慢动作'),
  recipe('recipe', '组合动作'),
  languageMismatch('language_mismatch', '语言纠正'),
  conversationIdle('conversation_idle', '自然长对话');

  const _Mode(this.id, this.label);
  final String id;
  final String label;

  static _Mode fromId(Object? id) =>
      values.firstWhere((mode) => mode.id == id, orElse: () => noTts);
}

class _Scenario {
  const _Scenario({
    required this.mode,
    required this.targetAction,
    required this.userInput,
    required this.narration,
    required this.reply,
    required this.correctedReply,
    required this.searchQuery,
    required this.actionDelayMs,
    required this.ttsDurationMs,
  });

  factory _Scenario.fromArgs(_Mode mode, Map<String, dynamic> args) {
    String text(String key, String fallback, int limit) {
      final value = args[key];
      if (value is! String || value.trim().isEmpty) return fallback;
      final normalized = value.replaceAll('\r\n', '\n').trim();
      return normalized.substring(0, math.min(limit, normalized.length));
    }

    final naturalConversation = mode == _Mode.conversationIdle;
    final target = text(
      'target_action',
      naturalConversation
          ? 'none'
          : mode == _Mode.recipe
          ? 'grp_recipe_4673'
          : 'grp_fg_024',
      80,
    );
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(target)) {
      throw const FormatException('target_action must be a catalogue key');
    }
    final japaneseReply = text(
      'reply',
      naturalConversation
          ? '今日はどんなことがあったの？私は新しい調合のことを考えていたんだ。素材を眺めているだけでも、いろんなアイデアが浮かんでくるよ。何でもない小さな発見が、次の冒険につながることもあるしね。あなたの話もゆっくり聞かせて。ここで一緒に、のんびりおしゃべりしよう。'
          : 'うん、手を叩いてみるね。ちゃんと見てね！',
      600,
    );
    final delay = args['action_delay_ms'];
    final ttsDuration = args['tts_duration_ms'];
    return _Scenario(
      mode: mode,
      targetAction: target,
      userInput: text(
        'user_input',
        naturalConversation
            ? '今天有什么有趣的事情？我们随便聊一会儿吧。'
            : mode == _Mode.recipe
            ? '请用双手拍手，选择组合动作。'
            : '请拍手给我看。',
        800,
      ),
      narration: text(
        'narration',
        naturalConversation ? '莱莎笑着和你聊起今天的炼金发现。' : '莱莎抬起双手，准备拍手。',
        500,
      ),
      reply: mode == _Mode.languageMismatch && args['reply'] == null
          ? 'I will clap my hands for you. Watch me!'
          : japaneseReply,
      correctedReply: japaneseReply,
      searchQuery: text(
        'search_query',
        naturalConversation
            ? '自然聊天 不要求新的主要动作'
            : mode == _Mode.recipe
            ? '拍手 双手 胸前 motion_add_F_050 motion_add_G_050'
            : '拍手 clap hands',
        160,
      ),
      actionDelayMs: delay is num && delay.isFinite
          ? delay.round().clamp(0, 10000)
          : naturalConversation
          ? 300
          : 6000,
      ttsDurationMs: ttsDuration is num && ttsDuration.isFinite
          ? ttsDuration.round().clamp(1000, 20000)
          : naturalConversation
          ? 15000
          : 1000,
    );
  }

  final _Mode mode;
  final String targetAction,
      userInput,
      narration,
      reply,
      correctedReply,
      searchQuery;
  final int actionDelayMs, ttsDurationMs;
}

class _LocalTransport extends ChangeNotifier {
  _LocalTransport(this.server);
  final HttpServer server;
  _Mode mode = _Mode.noTts;
  _Scenario scenario = _Scenario.fromArgs(_Mode.noTts, const {});
  int mainRequests = 0;
  int actionRequests = 0;
  int expressionRequests = 0;
  int speechRequests = 0;
  int ttsRequests = 0;
  int correctionRequests = 0;
  String lastSelected = '';
  final List<String> events = [];
  Future<Map<String, Object?>> Function(String, Map<String, dynamic>)? control;

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_LocalTransport> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final transport = _LocalTransport(server);
    server.listen((request) => unawaited(transport._handle(request)));
    debugPrint(
      'PIPELINE_SIMULATOR loopback=${transport.baseUrl} memory_only=true',
    );
    return transport;
  }

  void record(String value) {
    events.add('${DateTime.now().toIso8601String()} $value');
    if (events.length > 60) events.removeAt(0);
    notifyListeners();
  }

  void reset(_Scenario next) {
    scenario = next;
    mode = next.mode;
    mainRequests = actionRequests = expressionRequests = 0;
    speechRequests = ttsRequests = correctionRequests = 0;
    lastSelected = '';
    events.clear();
    record(
      'RUN mode=${mode.id} target=${scenario.targetAction} action_delay=${scenario.actionDelayMs}ms simulated_tts_audio=${scenario.ttsDurationMs}ms',
    );
  }

  Map<String, Object?> get snapshot => {
    'simulated': true,
    'loopback_only': true,
    'memory_only_settings': true,
    'mode': mode.id,
    'target_action': scenario.targetAction,
    'action_delay_ms': scenario.actionDelayMs,
    'tts_duration_ms': scenario.ttsDurationMs,
    'main_requests': mainRequests,
    'action_requests': actionRequests,
    'expression_requests': expressionRequests,
    'speech_requests': speechRequests,
    'tts_requests': ttsRequests,
    'correction_requests': correctionRequests,
    'selected_candidate': lastSelected,
    'events': events,
  };

  Future<void> _handle(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final data = body.trim().isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(body) as Map);
      if (request.uri.path.startsWith('/debug/')) {
        final result = await control?.call(request.uri.path, data) ?? snapshot;
        _json(request.response, result);
      } else if (request.method != 'POST') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      } else if (request.uri.path == '/v1/tts') {
        final requestScenario = scenario;
        ttsRequests++;
        record(
          'TTS request=$ttsRequests response=PCM_WAV simulated_tone=true duration=${requestScenario.ttsDurationMs}ms',
        );
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.add(_simulatedToneWav(requestScenario.ttsDurationMs));
      } else if (request.uri.path == '/v1/chat/completions') {
        await _complete(request.response, data);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    } on Object catch (error) {
      // The transport never prints request bodies, headers, or key values.
      // Do not print ArgumentError.toString(): a codec error can echo the
      // entire rejected string. The codec name and argument name are enough.
      final detail = error is ArgumentError
          ? ' name=${error.name ?? 'unknown'} message=${error.message}'
          : '';
      record('LOCAL_HTTP_ERROR type=${error.runtimeType}$detail');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } on Object {
        // Cancellation may already have closed the socket.
      }
    }
  }

  void _json(HttpResponse response, Object? data) {
    response.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    response.add(utf8.encode(jsonEncode(data)));
  }

  Future<void> _complete(
    HttpResponse response,
    Map<String, dynamic> body,
  ) async {
    // Each request keeps its own immutable scenario. A cancelled run may
    // finish after /debug/run changes the current scenario.
    final requestScenario = scenario;
    final requestMode = requestScenario.mode;
    final messages = (body['messages'] as List? ?? const []).whereType<Map>();
    final system = messages
        .where((message) => message['role'] == 'system')
        .map((message) => message['content'].toString())
        .join('\n');
    final user = messages
        .where((message) => message['role'] == 'user')
        .lastOrNull;
    Map<String, dynamic> payload = {};
    try {
      payload = Map<String, dynamic>.from(
        jsonDecode(user?['content'] as String) as Map,
      );
    } on Object {
      // Main dialogue input is ordinary text.
    }
    final ids = (payload['line_ids'] as List? ?? const [])
        .whereType<int>()
        .toList();
    if (body['stream'] == true) {
      mainRequests++;
      record('MAIN SSE begin request=$mainRequests mode=${requestMode.id}');
      final text =
          '旁白：${requestScenario.narration}\n莱莎：${requestScenario.reply}';
      response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final split = math.min(16, text.length);
      for (final piece in [text.substring(0, split), text.substring(split)]) {
        response.add(
          utf8.encode(
            'data: ${jsonEncode({
              'id': 'local-simulated-stream',
              'choices': [
                {
                  'index': 0,
                  'delta': {'content': piece},
                },
              ],
            })}\n\n',
          ),
        );
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      response.add(utf8.encode('data: [DONE]\n\n'));
      record('MAIN SSE complete request=$mainRequests');
      return;
    }
    Object result;
    if (system.contains('独立动作规划工具')) {
      actionRequests++;
      final requestNumber = actionRequests;
      final candidates = Map<String, dynamic>.from(
        payload['candidates'] as Map? ?? {},
      );
      final requested = requestScenario.targetAction;
      final selected = candidates.containsKey(requested) ? requested : 'none';
      lastSelected = selected;
      record(
        'ACTION request=$requestNumber ids=$ids target=$requested candidate=$selected waiting=${requestScenario.actionDelayMs}ms',
      );
      await Future<void>.delayed(
        Duration(milliseconds: requestScenario.actionDelayMs),
      );
      result = {
        'segments': [
          for (final id in ids)
            {
              'id': id,
              'action': selected,
              'posture': null,
              'match': requested == 'none'
                  ? 'none'
                  : selected == 'none'
                  ? 'unsupported'
                  : 'exact',
              'reason': requested == 'none'
                  ? '自然对话没有新的主要动作要求'
                  : selected == 'none'
                  ? '模拟器要求的候选不在当前窗口'
                  : '模拟器精确选择当前真实目录候选',
            },
        ],
        if (selected == 'none' && requested != 'none') ...{
          'request_catalog': true,
          'search_query': requestScenario.searchQuery,
        },
      };
      record('ACTION response=$requestNumber candidate=$selected');
    } else if (system.contains('独立表情规划工具')) {
      expressionRequests++;
      final requestNumber = expressionRequests;
      record(
        'EXPRESSION request=$requestNumber ids=$ids waiting=${requestScenario.actionDelayMs}ms',
      );
      await Future<void>.delayed(
        Duration(milliseconds: requestScenario.actionDelayMs),
      );
      result = {
        'segments': [
          for (final id in ids)
            {'id': id, 'face': 'happy', 'intensity': 'normal'},
        ],
        'state_delta': {'mood': 0, 'energy': 0, 'closeness': 0, 'curiosity': 0},
        'emotion': 'happy',
        'reason': '本地动作流程模拟',
        'time_advance': {'kind': 'conversation', 'minutes': 1},
      };
      record('EXPRESSION response=$requestNumber');
    } else if (system.contains('专用语音演出规划器')) {
      speechRequests++;
      final lines = (payload['lines'] as List? ?? const []).whereType<Map>();
      result = {
        'segments': [
          for (final line in lines)
            {'id': line['id'], 'emotion': 'happy', 'cues': <Object>[]},
        ],
      };
      record('SPEECH response=$speechRequests no_delay=true');
    } else if (system.contains('专用语言纠正器')) {
      correctionRequests++;
      result = {
        'corrections': [
          for (final line
              in (payload['lines'] as List? ?? const []).whereType<Map>())
            {'id': line['id'], 'text': requestScenario.correctedReply},
        ],
      };
      record('LANGUAGE correction=$correctionRequests');
    } else {
      result = {'segments': <Object>[]};
      record('AUXILIARY unknown_schema no_network=true');
    }
    _json(response, {
      'id': 'local-simulated-completion',
      'choices': [
        {
          'index': 0,
          'message': {'role': 'assistant', 'content': jsonEncode(result)},
          'finish_reason': 'stop',
        },
      ],
    });
  }
}

Uint8List _simulatedToneWav(int durationMs) {
  const sampleRate = 24000;
  final sampleCount = sampleRate * durationMs.clamp(1000, 20000) ~/ 1000;
  final bytes = Uint8List(44 + sampleCount * 2);
  final data = ByteData.sublistView(bytes);
  void ascii(int offset, String text) {
    bytes.setRange(
      offset,
      offset + text.length,
      const AsciiCodec().encode(text),
    );
  }

  ascii(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, sampleCount * 2, Endian.little);
  for (var i = 0; i < sampleCount; i++) {
    final fade = math.min(1.0, math.min(i / 1200, (sampleCount - i) / 1200));
    final sample = (900 * fade * math.sin(i * math.pi * 2 * 440 / sampleRate))
        .round();
    data.setInt16(44 + i * 2, sample, Endian.little);
  }
  return bytes;
}

class _Harness extends StatefulWidget {
  const _Harness({required this.controller, required this.transport});
  final AppController controller;
  final _LocalTransport transport;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final _chatTree = GlobalKey();
  final _seenLogIds = <String>{};
  final _trace = <String>[];
  _Mode _selected = _Mode.noTts;
  bool _characterReady = false;
  bool _spineReady = false;
  bool _catalogueReady = false;
  bool _hideUi = false;
  String _status = '加载真实加密角色资源…';
  int _starts = 0;
  int _finishes = 0;
  int _releases = 0;
  final List<Map<String, Object?>> _samples = [];
  final Set<String> _nonFiniteSampleFields = {};
  final Stopwatch _sampleClock = Stopwatch();
  Timer? _sampleTimer;
  int _sampleTicks = 0;

  @override
  void initState() {
    super.initState();
    RuntimeLog.instance.addListener(_logsChanged);
    widget.transport.addListener(_transportChanged);
    widget.transport.control = _handleControl;
  }

  @override
  void dispose() {
    _sampleTimer?.cancel();
    _sampleClock.stop();
    RuntimeLog.instance.removeListener(_logsChanged);
    widget.transport.removeListener(_transportChanged);
    widget.transport.control = null;
    unawaited(widget.transport.server.close(force: true));
    widget.controller.dispose();
    super.dispose();
  }

  void _transportChanged() {
    if (mounted) setState(() {});
  }

  void _logsChanged() {
    for (final entry in RuntimeLog.instance.entries) {
      if (!_seenLogIds.add(entry.identity) ||
          entry.module != RuntimeLogModule.action) {
        continue;
      }
      final message = entry.displayMessage;
      if (message.contains('组合目录已加载：')) {
        _catalogueReady = true;
        _updateReady();
      }
      if (message.contains('动作开始：') || message.contains('组合阶段开始：')) _starts++;
      if (message.contains('动作完成：') || message.contains('组合阶段结束：')) _finishes++;
      if (message.contains('释放/替换动作层：')) _releases++;
      final row =
          '${entry.timestamp.toIso8601String()} ${entry.source} $message';
      _trace.add(row);
      if (_trace.length > 60) _trace.removeAt(0);
      debugPrint('PIPELINE_ACTION $row');
    }
    if (mounted) setState(() {});
  }

  void _updateReady() {
    _characterReady = _spineReady && _catalogueReady;
    _status = _characterReady ? '真实角色与动作目录已就绪；可提交测试。' : '真实骨架已就绪，等待完整动作目录…';
  }

  List<Widget> _chatWidgets() {
    final root = _chatTree.currentContext;
    if (root == null) return const [];
    final result = <Widget>[];
    void visit(Element element) {
      result.add(element.widget);
      element.visitChildren(visit);
    }

    (root as Element).visitChildren(visit);
    return result;
  }

  Future<bool> _run(_Mode mode, {Map<String, dynamic> args = const {}}) async {
    if (!_characterReady) return false;
    // Restore the real input field before locating its submission callback.
    // Keeping ChatScreen mounted preserves its genuine runtime state.
    if (_hideUi) {
      setState(() => _hideUi = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
    }
    final input = _chatWidgets()
        .whereType<EditableText>()
        .where(
          (widget) =>
              widget.textInputAction == TextInputAction.send &&
              !widget.readOnly,
        )
        .firstOrNull;
    if (input == null || input.onSubmitted == null) {
      setState(() => _status = '输入框正忙，先取消当前回复或等待完成。');
      return false;
    }
    final scenario = _Scenario.fromArgs(mode, args);
    _selected = mode;
    await RuntimeLog.instance.clear();
    _trace.clear();
    _seenLogIds.clear();
    _starts = _finishes = _releases = 0;
    widget.transport.reset(scenario);
    _startSampling();
    widget.controller.configureFishAudio(
      enabled: mode != _Mode.noTts,
      model: 's2-pro',
      referenceId: 'simulated-reference',
      format: 'wav',
      baseUrl: '${widget.transport.baseUrl}/v1/tts',
    );
    final sample = scenario.userInput;
    input.controller.text = sample;
    // Invoke the public EditableText callback wired by real ChatScreen. No
    // private state method, controller message insertion, or fake playback.
    input.onSubmitted!(sample);
    setState(() {
      _hideUi = args['hide_ui'] == true;
      _status =
          '真实聊天链已提交 ${scenario.targetAction}；等待 ${scenario.actionDelayMs}ms 规划。';
    });
    return true;
  }

  void _cancel() {
    final widgets = _chatWidgets();
    final inputIsBusy = widgets.whereType<EditableText>().any(
      (field) => field.readOnly,
    );
    if (inputIsBusy) {
      widgets
          .whereType<IconButton>()
          .where((button) => button.key == const ValueKey('chat-send-button'))
          .firstOrNull
          ?.onPressed
          ?.call();
    }
    setState(() => _status = inputIsBusy ? '已通过真实取消按钮取消回复。' : '当前没有生成中的回复。');
  }

  void _newSave() {
    widget.controller.clearChatHistory(clearLongTermMemory: true);
    setState(() => _status = '已重置仅内存测试存档；等待中的旧回复应失效。');
  }

  Map<String, Object?> _state() => {
    ...widget.transport.snapshot,
    'character_ready': _characterReady,
    'status': _status,
    'starts': _starts,
    'finishes': _finishes,
    'releases': _releases,
    'action_trace': List<String>.of(_trace),
    'hide_ui': _hideUi,
    'sample_interval_ms': 100,
    'samples': List<Map<String, Object?>>.of(_samples),
    'non_finite_sample_fields': _nonFiniteSampleFields.toList(),
  };

  double? _finiteSample(double value, String field) {
    if (value.isFinite) return value;
    // Empty-animation sentinel values are diagnostic data, never valid JSON
    // numbers. Preserve other samples and report only the field name.
    _nonFiniteSampleFields.add(field);
    return null;
  }

  void _startSampling() {
    _sampleTimer?.cancel();
    _samples.clear();
    _nonFiniteSampleFields.clear();
    _sampleTicks = 0;
    _sampleClock
      ..reset()
      ..start();
    _sampleTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted || _sampleTicks++ >= 300) {
        timer.cancel();
        _sampleClock.stop();
        return;
      }
      final view = _chatWidgets().whereType<CharacterSpineView>().firstOrNull;
      if (view == null || !_spineReady) return;
      try {
        final controller = view.controller;
        final state = controller.animationState;
        final tracks = <String, Object?>{};
        for (var track = 1; track <= 10; track++) {
          final entry = state.getCurrent(track);
          if (entry == null) continue;
          tracks['$track'] = {
            'animation': entry.getAnimation().getName(),
            'track_time': _finiteSample(
              entry.getTrackTime(),
              'tracks.$track.track_time',
            ),
            'mix_time': _finiteSample(
              entry.getMixTime(),
              'tracks.$track.mix_time',
            ),
            'time_scale': _finiteSample(
              entry.getTimeScale(),
              'tracks.$track.time_scale',
            ),
          };
        }
        final skeleton = controller.skeleton;
        final names = <String>{
          'head',
          'body',
          'body3',
          'neck',
          'rig_face',
          'rig_body1',
          'rig_body2',
          'rig_body3',
          'rig_breast',
          'arm_L3',
          'arm_R3',
          for (final side in ['L', 'R']) ...[
            for (var index = 1; index <= 3; index++) 'leg_$side$index',
            'leg_${side}_A',
            'leg_${side}_A3',
            'leg_${side}_A5',
            'foot_$side',
          ],
          for (final bone in skeleton.getBones())
            if (bone.getData().getName().startsWith('control_'))
              bone.getData().getName(),
        };
        final bones = <String, Object?>{};
        for (final name in names) {
          final bone = skeleton.findBone(name);
          if (bone == null) continue;
          bones[name] = {
            'world_x': _finiteSample(bone.getWorldX(), 'bones.$name.world_x'),
            'world_y': _finiteSample(bone.getWorldY(), 'bones.$name.world_y'),
            'rotation': _finiteSample(
              bone.getRotation(),
              'bones.$name.rotation',
            ),
            'world_rotation_x': _finiteSample(
              bone.getWorldRotationX(),
              'bones.$name.world_rotation_x',
            ),
          };
        }
        _samples.add({
          'elapsed_ms': _sampleClock.elapsedMilliseconds,
          'tracks': tracks,
          'bones': bones,
          'spine_playing': controller.isPlaying,
          'spine_update_delta': _finiteSample(
            controller.updateDelta,
            'spine_update_delta',
          ),
        });
      } on Object catch (error) {
        // A disappearing/reloading view is not an excuse to drive its tracks.
        _samples.add({
          'elapsed_ms': _sampleClock.elapsedMilliseconds,
          'read_error_type': '${error.runtimeType}',
        });
      }
    });
  }

  Future<bool> _view(Map<String, dynamic> args) async {
    if (args['hide_ui'] is bool) {
      setState(() => _hideUi = args['hide_ui'] as bool);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
    }
    final gesture = _chatWidgets()
        .whereType<GestureDetector>()
        .where((widget) => widget.key == characterCameraGestureKey)
        .firstOrNull;
    if (gesture == null) return false;
    final requestedScale = args['scale_factor'];
    final requestedDelta = args['vertical_delta'];
    final scale = requestedScale is num && requestedScale.isFinite
        ? requestedScale.toDouble().clamp(0.2, 3.0)
        : 0.64;
    final delta = requestedDelta is num && requestedDelta.isFinite
        ? requestedDelta.toDouble().clamp(-500.0, 500.0)
        : -120.0;
    gesture.onScaleStart?.call(ScaleStartDetails(pointerCount: 2));
    gesture.onScaleUpdate?.call(
      ScaleUpdateDetails(
        pointerCount: 2,
        scale: scale,
        focalPointDelta: Offset(0, delta),
      ),
    );
    gesture.onScaleEnd?.call(ScaleEndDetails(pointerCount: 0));
    await WidgetsBinding.instance.endOfFrame;
    return true;
  }

  Future<Map<String, Object?>> _handleControl(
    String path,
    Map<String, dynamic> args,
  ) async {
    switch (path) {
      case '/debug/run':
        final submitted = await _run(_Mode.fromId(args['mode']), args: args);
        return {..._state(), 'submitted': submitted};
      case '/debug/cancel':
        _cancel();
      case '/debug/new-save':
        _newSave();
      case '/debug/view':
        final applied = await _view(args);
        return {..._state(), 'view_applied': applied};
      case '/debug/state':
        break;
    }
    return _state();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: true,
      title: 'Animation pipeline - local simulation',
      theme: ThemeData.dark(useMaterial3: true),
      builder: (context, child) =>
          GlassStyleScope(enabled: false, child: child!),
      home: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '本地模拟 · 真实 ChatScreen / 加密 Spine',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '凭据/存档仅内存；TTS 为模拟提示音。 ${widget.transport.baseUrl}',
                      style: const TextStyle(fontSize: 10),
                    ),
                    Wrap(
                      spacing: 5,
                      children: [
                        for (final mode in _Mode.values)
                          ChoiceChip(
                            label: Text(
                              mode.label,
                              style: const TextStyle(fontSize: 10),
                            ),
                            selected: _selected == mode,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => setState(() => _selected = mode),
                          ),
                      ],
                    ),
                    Row(
                      children: [
                        FilledButton(
                          onPressed: _characterReady
                              ? () => unawaited(_run(_selected))
                              : null,
                          child: const Text('提交拍手测试'),
                        ),
                        TextButton(onPressed: _cancel, child: const Text('取消')),
                        TextButton(
                          onPressed: _newSave,
                          child: const Text('新测试档'),
                        ),
                      ],
                    ),
                    Text(_status, style: const TextStyle(fontSize: 11)),
                    Text(
                      '轨道开始 $_starts · 完成 $_finishes · 释放 $_releases  / LLM动作 ${widget.transport.actionRequests} · TTS ${widget.transport.ttsRequests}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: KeyedSubtree(
                  key: _chatTree,
                  child: ChatScreen(
                    controller: widget.controller,
                    onMenuPressed: () {},
                    onShopPressed: () {},
                    hideUi: _hideUi,
                    onCharacterReady: () {
                      setState(() {
                        _spineReady = true;
                        _updateReady();
                      });
                    },
                    onCharacterLoadFailed: () =>
                        setState(() => _status = '角色资源加载失败，检查加密构建。'),
                  ),
                ),
              ),
              SizedBox(
                height: 70,
                width: double.infinity,
                child: ColoredBox(
                  color: Colors.black,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(5),
                    child: Text(
                      _trace.reversed.take(3).join('\n'),
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
