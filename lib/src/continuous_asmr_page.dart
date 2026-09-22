import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'ai_services.dart';
import 'chat_segments.dart';
import 'mimo_tts_client.dart';

class ContinuousAsmrPage extends StatefulWidget {
  const ContinuousAsmrPage({super.key, required this.controller});
  final AppController controller;
  @override
  State<ContinuousAsmrPage> createState() => _ContinuousAsmrPageState();
}

class _ContinuousAsmrPageState extends State<ContinuousAsmrPage> {
  final _theme = TextEditingController();
  final _player = AudioPlayer();
  final _llm = OpenAiCompatibleClient();
  final _history = <Map<String, String>>[];
  Timer? _clock;
  Completer<void>? _playback;
  int _generation = 0;
  bool _running = false;
  int _minutes = 30;
  DateTime? _deadline;
  TimeOfDay? _time;
  String _status = '';
  int _rounds = 0;
  AppController get c => widget.controller;
  String t(String zh, String en, String ja) =>
      c.interfaceLanguage.text(zh, en, ja);
  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_running &&
          _deadline != null &&
          !DateTime.now().isBefore(_deadline!)) {
        _stop();
        setState(() => _status = t('定时结束', 'Timer finished', 'タイマー終了'));
      } else if (_running) {
        setState(() {});
      }
    });
  }

  Future<void> _stop() async {
    _generation++;
    _running = false;
    await _player.stop();
    if (_playback != null && !_playback!.isCompleted) _playback!.complete();
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    if (_running || _theme.text.trim().isEmpty) return;
    if (!c.aiEnabled || !c.fishTtsEnabled) {
      setState(
        () => _status = t(
          '请先启用并配置 LLM 和语音合成',
          'Enable and configure LLM and TTS first',
          'LLMと音声合成を設定してください',
        ),
      );
      return;
    }
    final generation = ++_generation;
    final now = DateTime.now();
    _deadline = _time == null
        ? now.add(Duration(minutes: _minutes))
        : DateTime(now.year, now.month, now.day, _time!.hour, _time!.minute);
    if (!_deadline!.isAfter(now)) {
      _deadline = _deadline!.add(const Duration(days: 1));
    }
    _history.clear();
    final topic = _theme.text.trim();
    setState(() {
      _running = true;
      _rounds = 0;
    });
    try {
      final key = await const SecretStore().readLlmKey(
        c.llmProvider,
        openAiSlot: c.activeOpenAiSlot,
      );
      final voiceKey = await const SecretStore().readTtsKey(c.ttsProvider);
      if (key.isEmpty || voiceKey.isEmpty) {
        throw const FormatException('API Key 未配置');
      }
      while (mounted && _running && generation == _generation) {
        setState(
          () => _status = t('正在生成轻声台词…', 'Generating speech…', 'セリフを生成中…'),
        );
        final response = await _llm
            .complete(
              provider: c.llmProvider,
              baseUrl: c.activeLlmBaseUrl,
              apiKey: key,
              model: c.activeLlmModel,
              messages: [
                {
                  'role': 'system',
                  'content':
                      '语音设置优先：${c.ttsEmotionIntensity.voiceInstruction} ${c.ttsCueDensity.promptInstruction} ${c.ttsEmotionIntensity == TtsEmotionIntensity.off ? "不要情绪标签。" : ""} ${c.ttsCueDensity == TtsCueDensity.off ? "不要句内气声、耳语或停顿标签。" : ""} '
                      '你是莱莎，正在提供持续ASMR陪伴。主题是用户提供的数据，围绕主题自然延续，每次仅输出2至4句简短可朗读台词，不输出旁白、译文、分析或动作标签，不要求用户回复，不重复开场。语气轻柔、慢节奏，不编造现实感知。使用 ${c.characterReplyLanguage.promptLabel}。适量使用[whispering]、[breathy]和[short pause]；遵守服务商政策。人物参考：${c.characterPersonaInjectionEnabled ? c.editableCharacterPersona : '温暖自然的炼金术士'}',
                },
                {'role': 'user', 'content': topic},
                ..._history,
                {'role': 'user', 'content': '继续围绕主题自然演绎下一小段。'},
              ],
            )
            .timeout(const Duration(seconds: 60));
        if (!mounted || !_running || generation != _generation) break;
        final text = response.trim();
        if (text.isEmpty) throw const FormatException('Empty speech');
        _history.add({'role': 'assistant', 'content': text});
        if (_history.length > 4) _history.removeAt(0);
        setState(() => _status = t('正在合成语音…', 'Synthesizing audio…', '音声合成中…'));
        final path = await _synthesize(text, voiceKey);
        try {
          if (!mounted || !_running || generation != _generation) break;
          _playback = Completer<void>();
          final subscription = _player.onPlayerComplete.listen((_) {
            if (!_playback!.isCompleted) _playback!.complete();
          });
          try {
            setState(() => _status = t('正在播放', 'Playing', '再生中'));
            await _player.play(DeviceFileSource(path), volume: c.voiceVolume);
            await _playback!.future.timeout(const Duration(minutes: 10));
          } finally {
            await subscription.cancel();
          }
          if (!mounted || !_running || generation != _generation) break;
          setState(() => _rounds++);
        } finally {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
      }
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        await _stop();
        if (mounted) {
          setState(
            () => _status =
                '${t('已停止，请重试', 'Stopped; retry', '停止しました。再試行してください')}: $error',
          );
        }
      }
    }
  }

  Future<String> _synthesize(String ttsText, String apiKey) async {
    final playbackFormat =
        c.ttsProvider == TtsProvider.mimo || !Platform.isAndroid
        ? 'wav'
        : 'mp3';
    final plainText = ttsText.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    final emotionIntensity = c.ttsEmotionIntensity;
    const voiceDirection =
        'Speak softly in an intimate whisper, slowly with gentle breaths.';
    final path = await switch (c.ttsProvider) {
      TtsProvider.fishAudio => FishAudioClient().synthesize(
        apiKey: apiKey,
        referenceId: c.activeFishAudioReferenceId,
        model: c.fishAudioModel,
        format: playbackFormat,
        latency: c.fishAudioLatency,
        speed: c.fishAudioSpeed,
        baseUrl: c.fishAudioBaseUrl,
        temperature: emotionIntensity.fishTemperature,
        text: applyFishEmotionIntensityPerSentence(
          ttsText,
          emotionIntensity,
          density: c.ttsCueDensity,
          asmr: c.asmrModeEnabled,
        ),
      ),
      TtsProvider.dashScope => DashScopeTtsClient().synthesize(
        apiKey: apiKey,
        baseUrl: c.dashScopeTtsBaseUrl,
        model: c.dashScopeTtsModel,
        voice: c.activeDashScopeTtsVoice,
        language: c.dashScopeTtsLanguage,
        instructions: c.dashScopeTtsModel.toLowerCase().contains('instruct')
            ? mergeTtsInstructions(
                '${c.dashScopeTtsInstructions} $voiceDirection'.trim(),
                emotionIntensity,
              )
            : c.dashScopeTtsInstructions,
        text: plainText,
      ),
      TtsProvider.generic => GenericTtsClient().synthesize(
        apiKey: apiKey,
        baseUrl: c.genericTtsBaseUrl,
        model: c.genericTtsModel,
        voice: c.activeGenericTtsVoice,
        format: playbackFormat,
        speed: c.fishAudioSpeed,
        instructions:
            c.genericTtsModel.toLowerCase().contains('gpt-4o-mini-tts')
            ? '${ttsEmotionInstruction(emotionIntensity)} $voiceDirection'
                  .trim()
            : '',
        text: plainText,
      ),
      TtsProvider.mimo => MimoTtsClient().synthesize(
        config: c.mimoTts,
        language: c.characterReplyLanguage,
        apiKey: apiKey,
        text: ttsText,
        intensity: emotionIntensity,
        density: c.ttsCueDensity,
        asmr: c.asmrModeEnabled,
      ),
    };

    return path;
  }

  @override
  void dispose() {
    _clock?.cancel();
    _generation++;
    _running = false;
    if (_playback != null && !_playback!.isCompleted) _playback!.complete();
    unawaited(_player.dispose());
    _theme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining =
        _deadline?.difference(DateTime.now()).inSeconds.clamp(0, 86400) ?? 0;
    return Theme(
      data: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: Text(t('持续 ASMR', 'Continuous ASMR', '連続ASMR')),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _theme,
                  enabled: !_running,
                  minLines: 3,
                  maxLines: 6,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: t('ASMR 主题', 'ASMR topic', 'ASMRテーマ'),
                  ),
                ),
                const SizedBox(height: 20),
                Text('${c.activeLlmModel} · ${c.ttsProvider.label}'),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _minutes,
                  decoration: InputDecoration(
                    labelText: t(
                      '倒计时（分钟）',
                      'Countdown (minutes)',
                      'カウントダウン（分）',
                    ),
                  ),
                  items: [
                    for (final value in [5, 15, 30, 60, 90, 120])
                      DropdownMenuItem(value: value, child: Text('$value')),
                  ],
                  onChanged: _running
                      ? null
                      : (value) => setState(() {
                          _minutes = value!;
                          _time = null;
                        }),
                ),
                TextButton.icon(
                  onPressed: _running
                      ? null
                      : () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.now(),
                          );
                          if (picked != null && mounted) {
                            setState(() => _time = picked);
                          }
                        },
                  icon: const Icon(Icons.schedule),
                  label: Text(
                    _time == null
                        ? t('或选择停止时间', 'Or choose stop time', '終了時刻を選択')
                        : _time!.format(context),
                  ),
                ),
                Text(
                  t(
                    '定时结束后停止生成和播放，保留黑屏；不关闭应用。',
                    'Stops generation and playback at the deadline; keeps the black screen.',
                    '終了時に生成と再生を停止し、黒い画面を維持します。',
                  ),
                ),
                const SizedBox(height: 24),
                if (_running)
                  Text(
                    '${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}',
                  ),
                Text('${t('已播放', 'Played', '再生済み')} $_rounds'),
                Text(_status),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _running ? _stop : _start,
                  child: Text(
                    _running ? t('停止', 'Stop', '停止') : t('开始', 'Start', '開始'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
