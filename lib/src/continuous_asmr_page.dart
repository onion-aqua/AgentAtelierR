import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:audioplayers/audioplayers.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'ai_services.dart';
import 'chat_segments.dart';
import 'mimo_tts_client.dart';
import 'glass_ui.dart';

DateTime asmrDeadline(DateTime now, Duration duration, TimeOfDay? time) {
  if (time == null) return now.add(duration);
  final target = DateTime(now.year, now.month, now.day, time.hour, time.minute);
  return target.isAfter(now) ? target : target.add(const Duration(days: 1));
}

class AsmrSpeechSegment {
  const AsmrSpeechSegment(this.text, this.pauseAfter);

  final String text;
  final Duration pauseAfter;
}

List<AsmrSpeechSegment> splitAsmrScript(String script) {
  final segments = <AsmrSpeechSegment>[];
  final current = StringBuffer();
  final tokens = RegExp(r'\[[^\]]*\]|[\s\S]')
      .allMatches(script.replaceAll('\r\n', '\n').trim());

  void flush(Duration pause) {
    final text = current.toString().trim();
    current.clear();
    if (text.isNotEmpty) segments.add(AsmrSpeechSegment(text, pause));
  }

  for (final token in tokens) {
    final value = token.group(0)!;
    if (value == '\n') {
      flush(const Duration(milliseconds: 650));
      continue;
    }
    current.write(value);
    final length = current.length;
    if ('。！？!?；;'.contains(value) && length >= 24) {
      flush(const Duration(milliseconds: 320));
    } else if ('，,、'.contains(value) && length >= 72) {
      flush(const Duration(milliseconds: 220));
    } else if (length >= 96 && !value.startsWith('[')) {
      flush(const Duration(milliseconds: 180));
    }
  }
  flush(Duration.zero);
  if (segments.isNotEmpty) {
    final last = segments.removeLast();
    segments.add(AsmrSpeechSegment(last.text, Duration.zero));
  }
  return segments;
}

class _AsmrClip {
  _AsmrClip(this.path, this.title, this.pauseAfter);
  final String path;
  String title;
  final Duration pauseAfter;
  Duration? duration;
}

class ContinuousAsmrPage extends StatefulWidget {
  const ContinuousAsmrPage({super.key, required this.controller});
  final AppController controller;
  @override
  State<ContinuousAsmrPage> createState() => _ContinuousAsmrPageState();
}

class _ContinuousAsmrPageState extends State<ContinuousAsmrPage> {
  final _theme = TextEditingController();
  final _voiceListController = ScrollController();
  final _player = AudioPlayer();
  final _llm = OpenAiCompatibleClient();
  final _buffer = Queue<_AsmrClip>();
  Completer<void>? _bufferChanged;
  Completer<void>? _bufferSpace;
  bool _synthesisFinished = false;
  Object? _synthesisError;
  Timer? _clock;
  Completer<void>? _playback;
  int _generation = 0;
  bool _running = false;
  Duration _duration = const Duration(minutes: 15);
  bool _timerEnabled = false;
  bool _atTime = false;
  bool _replaying = false;
  final _clips = <_AsmrClip>[];
  int _nextClipNumber = 1;
  _AsmrClip? _activeClip;
  DateTime? _deadline;
  TimeOfDay? _time;
  String _status = '';
  int _rounds = 0;
  AppController get c => widget.controller;
  String t(String zh, String en, String ja) =>
      c.interfaceLanguage.text(zh, en, ja);

  void _wakeBuffer() {
    final waiter = _bufferChanged;
    _bufferChanged = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void _wakeSpace() {
    final waiter = _bufferSpace;
    _bufferSpace = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  bool _isCurrent(int generation) =>
      mounted && _running && generation == _generation;

  Future<void> _fillBuffer(
    List<AsmrSpeechSegment> segments,
    String topic,
    String voiceKey,
    int generation,
  ) async {
    try {
      for (
        var index = 0;
        index < segments.length && _isCurrent(generation);
        index++
      ) {
        while (_isCurrent(generation) && _buffer.length >= 3) {
          await (_bufferSpace ??= Completer<void>()).future;
        }
        if (!_isCurrent(generation)) break;
        final segment = segments[index];
        final path = await _synthesize(segment.text, voiceKey);
        if (!_isCurrent(generation)) {
          await _deleteClipFile(path);
          break;
        }
        final clip = _AsmrClip(
          path,
          '$topic · $_nextClipNumber',
          segment.pauseAfter,
        );
        _nextClipNumber++;
        final followLatest =
            !_voiceListController.hasClients ||
            _voiceListController.position.extentAfter < 80;
        _AsmrClip? retired;
        setState(() {
          _clips.add(clip);
          _buffer.add(clip);
          if (_clips.length > 50) {
            final index = _clips.indexWhere(
              (item) => item != _activeClip && !_buffer.contains(item),
            );
            if (index >= 0) retired = _clips.removeAt(index);
          }
        });
        if (followLatest) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _voiceListController.hasClients) {
              _voiceListController.animateTo(
                _voiceListController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
              );
            }
          });
        }
        if (retired != null) await _deleteClipFile(retired!.path);
        _wakeBuffer();
      }
    } on Object catch (error) {
      if (_isCurrent(generation)) _synthesisError = error;
    } finally {
      if (generation == _generation) {
        _synthesisFinished = true;
        _wakeBuffer();
      }
    }
  }

  Future<void> _waitForPrebuffer(int count, int generation) async {
    while (_isCurrent(generation) &&
        !_synthesisFinished &&
        _buffer.length < count) {
      await (_bufferChanged ??= Completer<void>()).future;
    }
  }

  Future<_AsmrClip?> _takeBufferedClip(int generation) async {
    while (_isCurrent(generation)) {
      if (_buffer.isNotEmpty) {
        final clip = _buffer.removeFirst();
        _wakeSpace();
        return clip;
      }
      if (_synthesisFinished) {
        if (_synthesisError != null) throw _synthesisError!;
        return null;
      }
      await (_bufferChanged ??= Completer<void>()).future;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if ((_running || _replaying) &&
          _deadline != null &&
          !DateTime.now().isBefore(_deadline!)) {
        _stop();
        setState(() => _status = t('定时结束', 'Timer finished', 'タイマー終了'));
      } else if (_running || _replaying) {
        setState(() {});
      }
    });
  }

  Future<void> _stop() async {
    _generation++;
    _running = false;
    _replaying = false;
    _activeClip = null;
    _buffer.clear();
    _wakeBuffer();
    _wakeSpace();
    final playback = _playback;
    _playback = null;
    await _player.stop();
    if (playback != null && !playback.isCompleted) playback.complete();
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    if (_running || _replaying || _theme.text.trim().isEmpty) return;
    if (_timerEnabled && !_atTime && _duration == Duration.zero) {
      setState(
        () => _status = t(
          '请设置大于零的倒计时',
          'Set a countdown greater than zero',
          '0より長い時間を設定してください',
        ),
      );
      return;
    }
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
    _deadline = _timerEnabled
        ? asmrDeadline(
            now,
            _duration,
            _atTime ? (_time ?? TimeOfDay.now()) : null,
          )
        : null;
    _buffer.clear();
    _synthesisFinished = false;
    _synthesisError = null;
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

      final targetMinutes = (_deadline?.difference(now).inMinutes ?? 15).clamp(
        3,
        60,
      );
      final targetChars = (targetMinutes * 110).clamp(350, 6600);
      setState(
        () => _status = t('正在准备完整朗读稿…', 'Preparing script…', '朗読原稿を準備中…'),
      );
      final response = await _llm.complete(
        provider: c.llmProvider,
        baseUrl: c.activeLlmBaseUrl,
        apiKey: key,
        model: c.activeLlmModel,
        lightweight: true,
        messages: [
          {
            'role': 'system',
            'content':
                '语音设置优先：${c.ttsEmotionIntensity.voiceInstruction} ${c.ttsCueDensity.promptInstruction} '
                '${c.ttsEmotionIntensity == TtsEmotionIntensity.off ? "不要情绪标签。" : ""} '
                '${c.ttsCueDensity == TtsCueDensity.off ? "不要句内气声、耳语或停顿标签。" : ""} '
                '你是莱莎，正在提供持续ASMR陪伴。一次写完本次要朗读的完整稿件，围绕用户主题自然发展并收束，'
                '目标约$targetChars字，分成多个自然段，每段1至3句。不要输出提纲、编号、旁白、译文、分析或动作标签；'
                '不要要求用户回复，不重复开场。语气轻柔、慢节奏，不编造现实感知。'
                '使用${c.characterReplyLanguage.promptLabel}。适量使用[whispering]、[breathy]和[short pause]；'
                '台词中禁止将省略号与日语促音“っ”连用，如“……っ”“…っ”“...っ”；自然改写，普通词中的促音照常使用。'
                '遵守服务商政策。人物参考：${c.characterPersonaInjectionEnabled ? c.editableCharacterPersona : '温暖自然的炼金术士'}',
          },
          {'role': 'user', 'content': topic},
        ],
      );
      if (!_isCurrent(generation)) return;
      final segments = splitAsmrScript(response);
      if (segments.isEmpty) throw const FormatException('Empty speech');
      setState(() => _status = t('正在缓冲语音…', 'Buffering audio…', '音声を準備中…'));
      unawaited(_fillBuffer(segments, topic, voiceKey, generation));
      await _waitForPrebuffer(
        segments.length < 3 ? segments.length : 3,
        generation,
      );
      while (_isCurrent(generation)) {
        final clip = await _takeBufferedClip(generation);
        if (clip == null) break;
        setState(() {
          _activeClip = clip;
          _status = t('正在播放', 'Playing', '再生中');
        });
        final playback = Completer<void>();
        _playback = playback;
        final subscription = _player.onPlayerComplete.listen((_) {
          if (!playback.isCompleted) playback.complete();
        });
        try {
          await _player.play(
            DeviceFileSource(clip.path),
            volume: c.voiceVolume,
          );
          clip.duration = await _player.getDuration();
          await playback.future.timeout(const Duration(minutes: 10));
        } finally {
          await subscription.cancel();
          if (identical(_playback, playback)) _playback = null;
        }
        if (!_isCurrent(generation)) break;
        setState(() => _rounds++);
        if (clip.pauseAfter > Duration.zero) {
          await Future<void>.delayed(clip.pauseAfter);
        }
      }
      if (_isCurrent(generation)) {
        setState(() {
          _running = false;
          _activeClip = null;
          _deadline = null;
          _status = t('朗读结束', 'Playback finished', '朗読終了');
        });
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

  Future<void> _deleteClipFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      /* Temporary cache cleanup is best effort. */
    }
  }

  Future<void> _replay(_AsmrClip clip) async {
    if (_running || _replaying) await _stop();
    if (!mounted) return;
    final generation = ++_generation;
    final now = DateTime.now();
    _deadline = _timerEnabled
        ? asmrDeadline(
            now,
            _duration,
            _atTime ? (_time ?? TimeOfDay.now()) : null,
          )
        : null;
    setState(() {
      _replaying = true;
      _activeClip = clip;
      _status = t('正在播放', 'Playing', '再生中');
    });
    final done = Completer<void>();
    _playback = done;
    final subscription = _player.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    try {
      await _player.play(DeviceFileSource(clip.path), volume: c.voiceVolume);
      clip.duration = await _player.getDuration();
      await done.future.timeout(const Duration(minutes: 10));
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _status = '${t('播放失败', 'Playback failed', '再生失敗')}: $error',
        );
      }
    } finally {
      await subscription.cancel();
      if (mounted && generation == _generation) await _stop();
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
    _buffer.clear();
    _wakeBuffer();
    _wakeSpace();
    if (_playback != null && !_playback!.isCompleted) _playback!.complete();
    unawaited(
      _player.dispose().then((_) async {
        for (final clip in _clips) {
          await _deleteClipFile(clip.path);
        }
      }),
    );
    _theme.dispose();
    _voiceListController.dispose();
    super.dispose();
  }

  String _clockText(Duration value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(value.inHours)}:${two(value.inMinutes.remainder(60))}:${two(value.inSeconds.remainder(60))}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final busy = _running || _replaying;
    final remaining = _deadline?.difference(DateTime.now()) ?? Duration.zero;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('ASMR')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'ASMR',
                style: Theme.of(context).textTheme.displaySmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: GlassSurface(
                      liquidGlass: c.liquidGlassChatUi,
                      tone: Theme.of(context).brightness == Brightness.dark
                          ? GlassTone.dark
                          : GlassTone.light,
                      borderRadius: BorderRadius.circular(32),
                      child: TextField(
                        controller: _theme,
                        enabled: !busy,
                        minLines: 1,
                        maxLines: 3,
                        decoration: InputDecoration(
                          hintText: t(
                            '输入 ASMR 主题',
                            'Enter ASMR topic',
                            'ASMRテーマを入力',
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 22,
                            vertical: 18,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: busy ? null : _start,
                    child: Text(t('生成', 'Generate', '生成')),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text(t('倒计时关闭', 'Countdown', 'カウントダウン')),
                    icon: const Icon(Icons.timer_outlined),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text(t('指定时刻关闭', 'At time', '終了時刻')),
                    icon: const Icon(Icons.schedule),
                  ),
                ],
                selected: {_atTime},
                onSelectionChanged: busy
                    ? null
                    : (value) => setState(() => _atTime = value.single),
              ),
              const SizedBox(height: 12),
              IgnorePointer(
                ignoring: busy,
                child: SizedBox(
                  height: 200,
                  child: CupertinoTheme(
                    data: CupertinoThemeData(
                      brightness: Theme.of(context).brightness,
                      primaryColor: colors.primary,
                      textTheme: CupertinoTextThemeData(
                        dateTimePickerTextStyle: TextStyle(
                          color: colors.onSurface,
                          fontSize: 26,
                        ),
                      ),
                    ),
                    child: _atTime
                        ? CupertinoDatePicker(
                            key: const ValueKey('asmr-clock'),
                            mode: CupertinoDatePickerMode.time,
                            use24hFormat: true,
                            initialDateTime: DateTime(
                              2026,
                              1,
                              1,
                              _time?.hour ?? DateTime.now().hour,
                              _time?.minute ?? DateTime.now().minute,
                            ),
                            onDateTimeChanged: (value) => setState(
                              () => _time = TimeOfDay.fromDateTime(value),
                            ),
                          )
                        : CupertinoTimerPicker(
                            key: const ValueKey('asmr-countdown'),
                            mode: CupertinoTimerPickerMode.hms,
                            initialTimerDuration: _duration,
                            onTimerDurationChanged: (value) =>
                                setState(() => _duration = value),
                          ),
                  ),
                ),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.timer_outlined),
                title: Text(
                  _atTime
                      ? '${t('到时间关闭', 'Stop at', '終了時刻')} · ${(_time ?? TimeOfDay.now()).format(context)}'
                      : '${t('定时关闭', 'Sleep timer', 'タイマー')} · ${_clockText(_duration)}',
                ),
                subtitle: _atTime
                    ? Text(
                        t(
                          '已过的时刻按明天计算',
                          'Past times mean tomorrow',
                          '過ぎた時刻は翌日になります',
                        ),
                      )
                    : null,
                value: _timerEnabled,
                onChanged: busy
                    ? null
                    : (value) => setState(() => _timerEnabled = value),
              ),
              if (busy && _deadline != null)
                Text(
                  _clockText(remaining.isNegative ? Duration.zero : remaining),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              if (_status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(_status, textAlign: TextAlign.center),
                ),
              const SizedBox(height: 16),
              DecoratedBox(
                key: const ValueKey('asmr-voice-area'),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SizedBox(
                  height: 300,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                        child: Row(
                          children: [
                            const Icon(Icons.graphic_eq_rounded, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                t('生成的语音', 'Generated audio', '生成した音声'),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            Text('${_clips.length}'),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: colors.outlineVariant),
                      Expanded(
                        child: _clips.isEmpty
                            ? Center(
                                child: Text(
                                  t(
                                    '输入主题后开始生成，语音会显示在这里',
                                    'Generate a topic to see audio here',
                                    'テーマから生成すると音声がここに表示されます',
                                  ),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              )
                            : ListView.builder(
                                key: const ValueKey('asmr-voice-list'),
                                controller: _voiceListController,
                                itemCount: _clips.length,
                                itemBuilder: (context, index) {
                                  final clip = _clips[index];
                                  return ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    leading: IconButton.filledTonal(
                                      tooltip:
                                          identical(_activeClip, clip) && busy
                                          ? t('停止', 'Stop', '停止')
                                          : t('播放', 'Play', '再生'),
                                      onPressed: () =>
                                          identical(_activeClip, clip) && busy
                                          ? _stop()
                                          : _replay(clip),
                                      icon: Icon(
                                        identical(_activeClip, clip) && busy
                                            ? Icons.stop_rounded
                                            : Icons.play_arrow_rounded,
                                      ),
                                    ),
                                    title: Text(
                                      clip.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: clip.duration == null
                                        ? null
                                        : Text(_clockText(clip.duration!)),
                                    trailing: IconButton(
                                      tooltip: t('删除', 'Delete', '削除'),
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () async {
                                        if (identical(_activeClip, clip)) {
                                          await _stop();
                                        }
                                        if (!mounted) return;
                                        setState(() {
                                          _clips.remove(clip);
                                          _buffer.remove(clip);
                                        });
                                        _wakeSpace();
                                        await _deleteClipFile(clip.path);
                                      },
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Center(
                child: IconButton.filled(
                  iconSize: 48,
                  padding: const EdgeInsets.all(20),
                  tooltip: busy ? t('停止', 'Stop', '停止') : t('播放', 'Play', '再生'),
                  onPressed: busy
                      ? _stop
                      : () =>
                            _clips.isNotEmpty ? _replay(_clips.last) : _start(),
                  icon: Icon(
                    busy ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                t(
                  '到时停止生成和播放，不退出应用。语音仅保留本次页面会话，最多50条。',
                  'Timer stops generation and playback, not the app. Up to 50 clips are kept for this page session.',
                  '終了時に生成と再生を停止します。アプリは終了しません。音声はこの画面の利用中のみ最大50件保持します。',
                ),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
