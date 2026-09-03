import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:spine_flutter/spine_flutter.dart' hide Color;

import 'ai_services.dart';
import 'app_controller.dart';
import 'app_localization.dart';
import 'audio_envelope.dart';
import 'character_appearance.dart';
import 'character_camera.dart';
import 'character_expression.dart';
import 'character_performance.dart';
import 'chat_segments.dart';
import 'enhanced_animation_system.dart';
import 'glass_ui.dart';
import 'tap_reaction.dart';

extension SceneTimeIcon on SceneTime {
  IconData get icon => switch (this) {
    SceneTime.morning => Icons.wb_twilight_outlined,
    SceneTime.afternoon => Icons.light_mode_outlined,
    SceneTime.evening => Icons.wb_twilight,
    SceneTime.night => Icons.dark_mode_outlined,
  };
}

String _mimeTypeForFile(String name) {
  final extension = name.split('.').last.toLowerCase();
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'md' => 'text/markdown',
    'csv' => 'text/csv',
    'json' => 'application/json',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    _ => 'application/octet-stream',
  };
}

double conversationPanelFractionForText({
  required String text,
  required double viewportWidth,
  required double viewportHeight,
  required bool isWide,
  int segmentCount = 1,
  bool hasAttachments = false,
  bool hasImageAttachments = false,
  bool isReplying = false,
}) {
  final charactersPerLine = isWide ? 52 : max(16, (viewportWidth / 18).floor());
  final wrappedLines = text
      .split('\n')
      .fold<int>(
        0,
        (sum, line) => sum + max(1, (line.length / charactersPerLine).ceil()),
      );
  final visibleLines = wrappedLines.clamp(1, 12);
  final separatorHeight = max(0, segmentCount - 1) * 17.0;
  final targetHeight =
      184.0 +
      visibleLines * 20.0 +
      separatorHeight +
      12.0 +
      (hasAttachments ? (hasImageAttachments ? 108.0 : 42.0) : 0.0) +
      (isReplying ? 32.0 : 0.0);
  final availableHeight = viewportHeight.clamp(480.0, 1200.0);
  return (targetHeight / availableHeight).clamp(0.22, 0.68);
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.controller,
    required this.onMenuPressed,
  });

  final AppController controller;
  final VoidCallback onMenuPressed;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _PreparedSpeech {
  const _PreparedSpeech({required this.path, required this.envelope});

  final String path;
  final AudioAmplitudeEnvelope? envelope;
}

class _CachedSpeechSegment {
  const _CachedSpeechSegment({
    required this.path,
    required this.envelope,
    required this.expression,
    required this.action,
  });

  final String path;
  final AudioAmplitudeEnvelope? envelope;
  final CharacterExpression? expression;
  final CharacterAction? action;
}

class _ChatScreenState extends State<ChatScreen> {
  final _audioPlayer = AudioPlayer();
  final _effectPlayer = AudioPlayer();
  final _aiClient = OpenAiCompatibleClient();
  final _fishAudioClient = FishAudioClient();
  final _dashScopeTtsClient = DashScopeTtsClient();
  final _genericTtsClient = GenericTtsClient();
  final _secretStore = const SecretStore();
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _random = Random();
  SpineWidgetController? _spineController;
  late CharacterAppearance _appearance;
  Timer? _idleTimer;
  Timer? _tapLabelTimer;
  Timer? _speechFallbackTimer;
  Timer? _microMotionTimer;
  Timer? _expressionRelaxTimer;
  Timer? _facialDetailTimer;
  Timer? _blinkTimer;
  Timer? _blinkRestoreTimer;
  StreamSubscription<Duration>? _audioPositionSubscription;
  String? _currentIdleAnimation;
  String? _lastTappedPart;
  bool _spineReady = false;
  bool _isReplying = false;
  bool _isCharacterSpeaking = false;
  bool _tapReactionActive = false;
  CharacterExpression _currentExpression = CharacterExpression.neutral;
  CharacterFacialDetail? _activeFacialDetail;
  List<CharacterMotionGroup> _motionGroups = const [];
  final List<String> _recentAmbientGroupIds = <String>[];
  int _motionLoadGeneration = 0;
  String? _lastPerformanceActionKey;
  DateTime? _lastSemanticActionAt;
  final Stopwatch _speechStopwatch = Stopwatch();
  AudioAmplitudeEnvelope? _activeSpeechEnvelope;
  TrackEntry? _lipSyncEntry;
  double _currentSpeechEnergy = 0;
  int _speechPlaybackGeneration = 0;
  Completer<void>? _speechCancellation;
  final Set<String> _temporarySpeechPaths = <String>{};
  List<_CachedSpeechSegment> _lastSpeech = const [];
  int _motionGeneration = 0;
  int _replyGeneration = 0;
  StreamIterator<String>? _replyIterator;
  double? _manualPanelFraction;
  double? _stableBottomSafeInset;
  double? _stableBodyHeight;
  final List<ChatAttachment> _pendingAttachments = [];
  bool _characterToolsExpanded = false;

  double _currentEmotionalIntensity = 0.5;

  @override
  void initState() {
    super.initState();
    _appearance = characterAppearanceById(
      widget.controller.selectedCharacterAppearanceId,
    );
    if (_appearance.animated) {
      _spineController = _createSpineController(_appearance);
    }
    _audioPositionSubscription = _audioPlayer.onPositionChanged.listen(
      _updateLipSyncFromPlaybackPosition,
    );
    widget.controller.addListener(_handleControllerChange);
  }

  SpineWidgetController _createSpineController(CharacterAppearance appearance) {
    late final SpineWidgetController spineController;
    spineController = SpineWidgetController(
      onAfterUpdateWorldTransforms: _applySpeakingHeadMotion,
      onInitialized: (controller) {
        if (!identical(spineController, _spineController)) return;
        controller.animationState.getData().setDefaultMix(0.38);
        _currentIdleAnimation = appearance.idleAnimations.first;
        controller.animationState.setAnimationByName(
          0,
          _currentIdleAnimation!,
          true,
        );

        _scheduleIdleChange();
        if (mounted) setState(() => _spineReady = true);
        _applyExpression(_currentExpression);
        unawaited(_loadMotionGroups(appearance));
      },
    );
    return spineController;
  }

  void _handleControllerChange() {
    final next = characterAppearanceById(
      widget.controller.selectedCharacterAppearanceId,
    );
    if (next.id == _appearance.id) return;
    _idleTimer?.cancel();
    _microMotionTimer?.cancel();
    _facialDetailTimer?.cancel();
    _blinkTimer?.cancel();
    _blinkRestoreTimer?.cancel();
    _motionLoadGeneration += 1;
    setState(() {
      _appearance = next;
      _spineReady = false;
      _currentIdleAnimation = null;
      _motionGroups = const [];
      _recentAmbientGroupIds.clear();
      _lastPerformanceActionKey = null;
      _spineController = next.animated ? _createSpineController(next) : null;
    });
    unawaited(_playSkinChangeEffect());
  }

  Future<void> _loadMotionGroups(CharacterAppearance appearance) async {
    final generation = ++_motionLoadGeneration;
    try {
      final groups = await loadCharacterMotionGroups(appearance);
      if (!mounted || generation != _motionLoadGeneration) return;
      _motionGroups = groups;
      _scheduleMicroMotion();
    } on Object {
      if (generation == _motionLoadGeneration) _motionGroups = const [];
    }
  }

  Future<void> _playSkinChangeEffect() async {
    await _effectPlayer.stop();
    await _effectPlayer.play(AssetSource('audio/se/se_skin_change.m4a'));
  }

  void _scheduleIdleChange() {
    _idleTimer?.cancel();
    _idleTimer = Timer(Duration(seconds: 9 + _random.nextInt(8)), () {
      if (!mounted || !_spineReady) return;
      final candidates = _appearance.idleAnimations
          .where((animation) => animation != _currentIdleAnimation)
          .toList();
      if (candidates.isNotEmpty) {
        _playIdleAnimation(candidates[_random.nextInt(candidates.length)]);
      }
      _scheduleIdleChange();
    });
  }

  void _playIdleAnimation(String animation) {
    final spineController = _spineController;
    if (!_spineReady ||
        spineController == null ||
        spineController.skeletonData.findAnimation(animation) == null) {
      return;
    }
    _resetMotionOverlays(mixDuration: 0.32);
    _currentIdleAnimation = animation;
    spineController.animationState
        .setAnimationByName(0, animation, true)
        .setMixDuration(0.42);
    _scheduleIdleChange();
  }

  void _playOneShotAnimation(String animation) {
    final spineController = _spineController;
    if (!_spineReady ||
        spineController == null ||
        spineController.skeletonData.findAnimation(animation) == null) {
      return;
    }
    _resetMotionOverlays(mixDuration: 0.28);
    final state = spineController.animationState;
    state.setAnimationByName(1, animation, false).setMixDuration(0.34);
    state.addEmptyAnimation(1, 0.36, 0);
    _scheduleIdleChange();
  }

  void _playMotionGroup(CharacterMotionGroup group) {
    final spineController = _spineController;
    if (!_spineReady ||
        spineController == null ||
        spineController.skeletonData.findAnimation(group.animation1) == null) {
      return;
    }
    if (!group.supportsPose(_currentIdleAnimation)) return;
    final tracks = group.occupiedTracks;
    if (tracks.isEmpty) return;

    // ✨ 使用动态混合时间替代固定值
    final dynamicBlend = AnimationBlendCalculator.calculateBlendTime(
      fromType: AnimationType.idle,
      toType: AnimationType.action,
      emotionalIntensity: _currentEmotionalIntensity,
      currentExpression: _currentExpression.name,
    );
    _resetMotionOverlays(mixDuration: dynamicBlend);

    final generation = ++_motionGeneration;
    final state = spineController.animationState;
    state.setEmptyAnimation(1, dynamicBlend);

    final animations = <({String name, double alpha, double speed})>[
      (name: group.animation1, alpha: group.alpha1, speed: group.speed1),
      if (group.animation2 case final second?)
        (name: second, alpha: group.alpha2, speed: group.speed2),
    ];
    TrackEntry? longestEntry;
    var longestDuration = -1.0;
    for (var index = 0; index < animations.length; index++) {
      final animation = animations[index];
      if (index >= tracks.length ||
          spineController.skeletonData.findAnimation(animation.name) == null) {
        continue;
      }

      // ✨ 应用情感权重到动画速度
      final emotionalTimeScale = EmotionalWeights.getTimeScale(
        _currentExpression.name,
      );
      final adjustedSpeed = animation.speed * emotionalTimeScale;

      final entry =
          state.setAnimationByName(tracks[index], animation.name, false)
            ..setAlpha(animation.alpha)
            ..setTimeScale(adjustedSpeed)
            ..setMixBlend(MixBlend.replace)
            ..setMixDuration(max(0.28, group.blendTime));

      // ✨ 应用缓动函数到alpha
      final easedAlpha = AnimationEasing.easeOutQuad(animation.alpha);
      entry.setAlpha(easedAlpha);

      final speed = adjustedSpeed.abs() < 0.01 ? 1.0 : adjustedSpeed.abs();
      final duration = entry.getAnimation().getDuration() / speed;
      if (duration > longestDuration) {
        longestDuration = duration;
        longestEntry = entry;
      }
    }
    longestEntry?.setListener((type, _, _) {
      if (type != EventType.complete || generation != _motionGeneration) return;
      _resetMotionOverlays(mixDuration: max(0.3, group.blendTime));
    });
    _scheduleIdleChange();
  }

  void _resetMotionOverlays({double mixDuration = 0.28}) {
    final spineController = _spineController;
    if (!_spineReady || spineController == null) return;
    _motionGeneration += 1;
    for (var track = 2; track <= 10; track++) {
      spineController.animationState.setEmptyAnimation(track, mixDuration);
    }
  }

  void _setFacialAnimation(
    int track,
    String animation, {
    bool loop = true,
    double alpha = 1,
    double timeScale = 1,
  }) {
    final spineController = _spineController;
    if (!_spineReady ||
        spineController == null ||
        spineController.skeletonData.findAnimation(animation) == null) {
      return;
    }
    spineController.animationState.setAnimationByName(track, animation, loop)
      ..setMixBlend(MixBlend.replace)
      ..setMixDuration(0.16)
      ..setAlpha(alpha)
      ..setTimeScale(timeScale);
  }

  void _applyExpression(CharacterExpression expression) {
    _expressionRelaxTimer?.cancel();
    _currentExpression = expression;

    if (!_spineReady || _spineController == null || _tapReactionActive) return;
    if (expression == CharacterExpression.neutral && !_isCharacterSpeaking) {
      for (var track = 11; track <= 16; track++) {
        _spineController!.animationState.clearTrack(track);
      }
      return;
    }
    final preset = characterExpressionPreset(_appearance.id, expression);
    _activeFacialDetail = null;
    _setFacialAnimation(11, preset.eye);
    _setFacialAnimation(12, preset.eyebrow);
    if (_isCharacterSpeaking) {
      final animation = _spineController!.skeletonData.findAnimation(
        preset.lipSync,
      );
      _lipSyncEntry = animation == null
          ? null
          : (_spineController!.animationState.setAnimationByName(
                13,
                preset.lipSync,
                false,
              )
              ..setMixBlend(MixBlend.replace)
              ..setAlpha(preset.lipSyncAlpha)
              ..setTimeScale(0));
    } else {
      _lipSyncEntry = null;
      _setFacialAnimation(13, preset.mouth);
    }
    _setFacialEffect(
      14,
      _appearance.id == 'standing_99'
          ? 'facial_add_blush_off'
          : 'facial_add_blush_000_off',
      preset.blush,
    );
    _setFacialEffect(
      15,
      _appearance.id == 'standing_99'
          ? 'facial_add_tear_off'
          : 'facial_add_tear_000_off',
      preset.tear,
    );
    if (_appearance.id != 'standing_99') {
      _spineController!.animationState.clearTrack(16);
    }
  }

  void _setFacialEffect(int track, String offAnimation, String? onAnimation) {
    final spineController = _spineController;
    if (!_spineReady || spineController == null) return;
    final state = spineController.animationState;
    state.clearTrack(track);
    if (spineController.skeletonData.findAnimation(offAnimation) != null) {
      state.setAnimationByName(track, offAnimation, false)
        ..setMixBlend(MixBlend.replace)
        ..setMixDuration(0.12);
    }
    if (onAnimation != null &&
        spineController.skeletonData.findAnimation(onAnimation) != null) {
      state.addAnimationByName(track, onAnimation, false, 0)
        ..setMixBlend(MixBlend.replace)
        ..setMixDuration(0.12);
    }
  }

  void _startSpeakingAnimation({AudioAmplitudeEnvelope? envelope}) {
    _speechFallbackTimer?.cancel();
    _activeSpeechEnvelope = envelope;
    _currentSpeechEnergy = envelope == null ? 0.45 : 0;
    if (_isCharacterSpeaking) {
      _applyExpression(_currentExpression);
      _scheduleFacialDetailChange();
      _scheduleSpeechBlink();
      return;
    }
    _isCharacterSpeaking = true;
    _speechStopwatch
      ..reset()
      ..start();
    _applyExpression(_currentExpression);
    _scheduleMicroMotion();
    _scheduleFacialDetailChange();
    _scheduleSpeechBlink();
  }

  void _stopSpeakingAnimation() {
    _speechFallbackTimer?.cancel();
    _microMotionTimer?.cancel();
    _facialDetailTimer?.cancel();
    _blinkTimer?.cancel();
    _blinkRestoreTimer?.cancel();
    _speechStopwatch.stop();
    _isCharacterSpeaking = false;
    _activeSpeechEnvelope = null;
    _lipSyncEntry = null;
    _currentSpeechEnergy = 0;
    _activeFacialDetail = null;
    _applyExpression(_currentExpression);
    _scheduleMicroMotion();
    _scheduleExpressionRelax();
  }

  void _scheduleExpressionRelax() {
    _expressionRelaxTimer?.cancel();
    _expressionRelaxTimer = Timer(const Duration(milliseconds: 4600), () {
      if (mounted && !_isCharacterSpeaking && !_tapReactionActive) {
        _applyExpression(CharacterExpression.neutral);
      }
    });
  }

  void _applySpeakingHeadMotion(SpineWidgetController controller) {
    if (!_isCharacterSpeaking || !_speechStopwatch.isRunning) return;
    final seconds = _speechStopwatch.elapsedMicroseconds / 1000000;

    // 保留原有的唇同步逻辑
    final fallbackLipSyncEntry = _lipSyncEntry;
    if (_activeSpeechEnvelope == null && fallbackLipSyncEntry != null) {
      final phase = (seconds * 5.2) % 1;
      final closure = phase < 0.28;
      final pulse = closure ? 0.0 : sin((phase - 0.28) / 0.72 * pi).abs();
      _currentSpeechEnergy = closure ? 0 : 0.24 + pulse * 0.46;
      fallbackLipSyncEntry.setTrackTime(
        fallbackLipSyncEntry.getAnimation().getDuration() *
            _currentSpeechEnergy *
            0.48,
      );
    }

    final energy = _currentSpeechEnergy;
    final phraseEnvelope = pow(sin(seconds * pi * 0.22).abs(), 1.6).toDouble();
    final nod =
        sin(seconds * pi * 0.72 + 0.25) *
        (3.2 + energy * 6.4) *
        (0.42 + phraseEnvelope * 0.58);
    final sway =
        sin(seconds * pi * 0.27 + 0.8) * (7.4 + energy * 3.8) +
        sin(seconds * pi * 0.105 + 1.9) * 2.6;
    final tilt = sin(seconds * pi * 0.16 + 2.35) * (2.2 + phraseEnvelope * 3.6);
    final head =
        controller.skeleton.findBone('control_roll_head') ??
        controller.skeleton.findBone('head');
    final neck =
        controller.skeleton.findBone('control_roll_neck') ??
        controller.skeleton.findBone('neck');
    final upperBody = controller.skeleton.findBone('control_roll_body_upper');
    final lowerBody = controller.skeleton.findBone('control_roll_body_lower');
    if (head == null &&
        neck == null &&
        upperBody == null &&
        lowerBody == null) {
      return;
    }
    final headRotation = (nod + sway + tilt).clamp(-24.0, 24.0).toDouble();
    head?.setRotation(head.getRotation() + headRotation);
    neck?.setRotation(
      neck.getRotation() + nod * 0.58 - sway * 0.22 + tilt * 0.36,
    );
    upperBody?.setRotation(
      upperBody.getRotation() + nod * 0.18 + sway * 0.2 - tilt * 0.12,
    );
    lowerBody?.setRotation(lowerBody.getRotation() - nod * 0.07 - sway * 0.09);
    controller.skeleton.updateWorldTransform(Physics.none);
  }

  void _updateLipSyncFromPlaybackPosition(Duration position) {
    final envelope = _activeSpeechEnvelope;
    final entry = _lipSyncEntry;
    if (!_isCharacterSpeaking || envelope == null || entry == null) return;
    final energy = envelope.valueAt(position);
    _currentSpeechEnergy = energy;
    final mouthOpen = energy < 0.08
        ? 0.0
        : (pow((energy - 0.08) / 0.92, 0.78) * 0.48).clamp(0.0, 0.48);
    entry.setTrackTime(entry.getAnimation().getDuration() * mouthOpen);
  }

  void _scheduleFacialDetailChange() {
    _facialDetailTimer?.cancel();
    if (!_isCharacterSpeaking) return;
    _facialDetailTimer = Timer(
      Duration(milliseconds: 1500 + _random.nextInt(1600)),
      _rotateFacialDetail,
    );
  }

  void _rotateFacialDetail() {
    if (!mounted ||
        !_isCharacterSpeaking ||
        _tapReactionActive ||
        !_spineReady ||
        _spineController == null) {
      return;
    }
    final skeletonData = _spineController!.skeletonData;
    final candidates =
        characterFacialDetails(_appearance.id, _currentExpression)
            .where(
              (detail) =>
                  detail != _activeFacialDetail &&
                  skeletonData.findAnimation(detail.eye) != null &&
                  skeletonData.findAnimation(detail.eyebrow) != null,
            )
            .toList();
    if (candidates.isNotEmpty) {
      final detail = candidates[_random.nextInt(candidates.length)];
      _activeFacialDetail = detail;
      _setFacialAnimation(11, detail.eye);
      _setFacialAnimation(12, detail.eyebrow);
    }
    _scheduleFacialDetailChange();
  }

  void _scheduleSpeechBlink() {
    _blinkTimer?.cancel();
    if (!_isCharacterSpeaking) return;
    _blinkTimer = Timer(
      Duration(milliseconds: 1700 + _random.nextInt(1800)),
      _performSpeechBlink,
    );
  }

  void _performSpeechBlink() {
    if (!mounted ||
        !_isCharacterSpeaking ||
        _tapReactionActive ||
        !_spineReady ||
        _spineController == null) {
      return;
    }
    final details = characterFacialDetails(_appearance.id, _currentExpression);
    final detail =
        _activeFacialDetail ?? (details.isEmpty ? null : details.first);
    final closedEye = detail?.closedEye;
    if (closedEye != null &&
        _spineController!.skeletonData.findAnimation(closedEye) != null) {
      _setFacialAnimation(11, closedEye, loop: false, timeScale: 1.15);
      _blinkRestoreTimer?.cancel();
      _blinkRestoreTimer = Timer(
        Duration(milliseconds: 95 + _random.nextInt(45)),
        () {
          if (!mounted || !_isCharacterSpeaking || _tapReactionActive) return;
          final eye =
              _activeFacialDetail?.eye ??
              characterExpressionPreset(_appearance.id, _currentExpression).eye;
          _setFacialAnimation(11, eye);
        },
      );
    }
    _scheduleSpeechBlink();
  }

  void _scheduleMicroMotion() {
    _microMotionTimer?.cancel();
    if (!_spineReady || !_appearance.animated) return;
    final delay = _isCharacterSpeaking
        ? Duration(milliseconds: 1800 + _random.nextInt(2000))
        : Duration(milliseconds: 3800 + _random.nextInt(3600));
    _microMotionTimer = Timer(delay, () {
      if (!mounted || _tapReactionActive) {
        _scheduleMicroMotion();
        return;
      }
      final recentlyActed =
          _lastSemanticActionAt != null &&
          DateTime.now().difference(_lastSemanticActionAt!) <
              const Duration(milliseconds: 2300);
      if (!recentlyActed) _playAmbientMotion();
      _scheduleMicroMotion();
    });
  }

  void _playAmbientMotion({double explorationChance = 0.2}) {
    if (!_spineReady || _tapReactionActive || _motionGroups.isEmpty) return;
    final group = selectCharacterAmbientMotionGroup(
      groups: _motionGroups,
      expression: _currentExpression,
      pose: _currentIdleAnimation,
      recentGroupIds: _recentAmbientGroupIds.toSet(),
      random: _random,
      allowLargePostureChanges: !_isCharacterSpeaking,
      explorationChance: explorationChance,
    );
    if (group == null) return;
    _recentAmbientGroupIds
      ..remove(group.id)
      ..add(group.id);
    if (_recentAmbientGroupIds.length > 5) {
      _recentAmbientGroupIds.removeAt(0);
    }
    _playMotionGroup(group);
  }

  void _applyPerformanceFromResponse(String response) {
    // ✨ 新增：从响应分析情感强度
    _currentEmotionalIntensity = LLMSemanticAnalyzer.analyzeEmotionalIntensity(
      response,
    );
    final cue = performanceCueForAssistantResponse(response);
    final expression = cue.expression;
    if (expression != null && expression != _currentExpression) {
      _applyExpression(expression);
    }
    final action = cue.action;
    if (action == null || action == CharacterAction.none) return;
    final key = '${action.name}:${cue.actionCueCount}';
    if (_lastPerformanceActionKey == key) return;
    _lastPerformanceActionKey = key;
    _performSemanticAction(action);
  }

  void _performSemanticAction(CharacterAction action) {
    if (!_spineReady || _tapReactionActive) return;
    final plan = characterActionPlan(_appearance.id, action);
    for (final id in plan.motionGroupIds) {
      for (final group in _motionGroups) {
        if (group.id == id && group.supportsPose(_currentIdleAnimation)) {
          _lastSemanticActionAt = DateTime.now();
          _playMotionGroup(group);
          return;
        }
      }
    }
    final fallback = plan.oneShotFallback;
    if (fallback != null) {
      _lastSemanticActionAt = DateTime.now();
      _playOneShotAnimation(fallback);
    }
  }

  @override
  void dispose() {
    _replyGeneration += 1;
    final replyIterator = _replyIterator;
    _replyIterator = null;
    if (replyIterator != null) unawaited(replyIterator.cancel());
    widget.controller.removeListener(_handleControllerChange);
    final cancellation = _speechCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    for (final path in _temporarySpeechPaths.toList()) {
      unawaited(_deleteTemporarySpeech(path));
    }
    for (final segment in _lastSpeech) {
      unawaited(_deleteTemporarySpeech(segment.path));
    }
    _audioPositionSubscription?.cancel();
    _audioPlayer.dispose();
    _effectPlayer.dispose();
    _idleTimer?.cancel();
    _tapLabelTimer?.cancel();
    _speechFallbackTimer?.cancel();
    _microMotionTimer?.cancel();
    _expressionRelaxTimer?.cancel();
    _facialDetailTimer?.cancel();
    _blinkTimer?.cancel();
    _blinkRestoreTimer?.cancel();

    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _reactToTap(Offset localPosition) async {
    final reaction = _hitTestReaction(localPosition);
    if (reaction == null) return;
    widget.controller.recordCharacterTouch();
    if (_spineReady && _spineController != null) {
      _tapReactionActive = true;
      _resetMotionOverlays();
      final state = _spineController!.animationState;
      for (var track = 11; track <= 16; track++) {
        state.clearTrack(track);
      }
      state
        ..setAnimationByName(1, reaction.animation, false).setMixDuration(0.34)
        ..addEmptyAnimation(1, 0.36, 0);
    }
    _tapLabelTimer?.cancel();
    if (mounted) setState(() => _lastTappedPart = reaction.label);
    _tapLabelTimer = Timer(const Duration(milliseconds: 1350), () {
      if (!mounted) return;
      _tapReactionActive = false;
      _applyExpression(_currentExpression);
      if (!_isCharacterSpeaking) _scheduleExpressionRelax();
      setState(() => _lastTappedPart = null);
    });
    if (!widget.controller.voiceEnabled || _isReplying) return;
    await _audioPlayer.stop();
    await _audioPlayer.setVolume(widget.controller.voiceVolume);
    try {
      await _audioPlayer.play(
        AssetSource(
          reaction.localizedVoiceAsset(
            widget.controller.characterReplyLanguage,
            _random.nextInt(3) + 1,
          ),
        ),
      );
    } on Object {
      await _audioPlayer.play(
        AssetSource(reaction.voiceAsset(_random.nextInt(3) + 1)),
      );
    }
  }

  TapReaction? _hitTestReaction(Offset localPosition) {
    final spineController = _spineController;
    if (!_spineReady || spineController == null) return null;
    final point = spineController.toSkeletonCoordinates(localPosition);
    final hits = <({TapReaction reaction, double area})>[];
    for (final slot in spineController.skeleton.getSlots()) {
      final partName = hitPartNames[slot.getData().getName()];
      if (partName == null) continue;
      final attachment = slot.getAttachment();
      if (attachment is! BoundingBoxAttachment) continue;
      final vertices = attachment.computeWorldVertices(slot);
      if (!polygonContainsPoint(vertices, point.dx, point.dy)) continue;
      final reactions = tapReactionsByPart[partName];
      if (reactions == null || reactions.isEmpty) continue;
      hits.add((
        reaction: reactions[_random.nextInt(reactions.length)],
        area: _polygonArea(vertices),
      ));
    }
    if (hits.isEmpty) return null;
    hits.sort((a, b) => a.area.compareTo(b.area));
    return hits.first.reaction;
  }

  double _polygonArea(List<double> vertices) {
    var area = 0.0;
    var j = vertices.length - 2;
    for (var i = 0; i < vertices.length; i += 2) {
      area += vertices[j] * vertices[i + 1] - vertices[i] * vertices[j + 1];
      j = i;
    }
    return area.abs() / 2;
  }

  Future<void> _sendMessage() async {
    final rawText = _inputController.text.trim();
    if ((rawText.isEmpty && _pendingAttachments.isEmpty) || _isReplying) return;
    final attachments = List<ChatAttachment>.unmodifiable(_pendingAttachments);
    final text = rawText.isEmpty ? '请分析我发送的附件。' : rawText;

    _cancelSpeechPlayback();

    _inputController.clear();
    widget.controller.addUserMessage(text, attachments: attachments);
    _applyMoodAnimation();
    _playAmbientMotion(explorationChance: 0.12);
    _lastPerformanceActionKey = null;
    setState(() {
      _pendingAttachments.clear();
      _isReplying = true;
      _manualPanelFraction = null;
    });
    final generation = ++_replyGeneration;
    _scrollToBottom();

    if (!widget.controller.aiEnabled) {
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (!mounted || generation != _replyGeneration) return;
      final reply = widget.controller.demoReply(text);
      widget.controller.addAssistantMessage(reply);
      await _playTtsIfConfigured(reply);
      if (mounted && generation == _replyGeneration) {
        setState(() => _isReplying = false);
      }
      _scrollToBottom();
      return;
    }

    final apiKey = await _secretStore.readOpenAiKey();
    if (!mounted || generation != _replyGeneration) return;
    if (apiKey.isEmpty) {
      _stopSpeakingAnimation();
      widget.controller.addAssistantMessage('请先在设置中填写 OpenAI 兼容接口的 API Key。');
      if (mounted) setState(() => _isReplying = false);
      return;
    }

    widget.controller.beginAssistantStream();
    StreamIterator<String>? iterator;
    try {
      iterator = StreamIterator<String>(
        _aiClient.streamChat(
          baseUrl: widget.controller.openAiBaseUrl,
          apiKey: apiKey,
          model: widget.controller.openAiModel,
          systemPrompt: widget.controller.buildCharacterPrompt(),
          messages: widget.controller.recentMessages(),
          reasoningEffort:
              widget.controller.openAiAdvancedEnabled &&
                  widget.controller.supportsOpenAiAdvancedControls
              ? widget.controller.openAiReasoningEffort.name
              : null,
          outputMultiplier:
              widget.controller.openAiAdvancedEnabled &&
                  widget.controller.supportsOpenAiAdvancedControls
              ? widget.controller.openAiOutputMultiplier
              : null,
          agentEnabled: widget.controller.agentEnabled,
        ),
      );
      _replyIterator = iterator;
      while (await iterator.moveNext()) {
        if (generation != _replyGeneration) return;
        final delta = iterator.current;
        if (!widget.controller.fishTtsEnabled &&
            !_isCharacterSpeaking &&
            delta.trim().isNotEmpty) {
          _startSpeakingAnimation();
        }
        widget.controller.appendAssistantDelta(delta);
        if (!widget.controller.fishTtsEnabled) {
          _applyPerformanceFromResponse(widget.controller.messages.last.text);
        }
        _scrollToBottom();
      }
      if (generation != _replyGeneration) return;
      final reply = widget.controller.messages.last.text;
      widget.controller.finishAssistantStream();
      await _playTtsIfConfigured(reply);
      if (generation != _replyGeneration) return;
      if (widget.controller.longTermMemoryEnabled &&
          widget.controller.userMessageCount % 4 == 0) {
        unawaited(_refreshLongTermMemory(apiKey));
      }
    } on Object catch (error) {
      if (generation != _replyGeneration) return;
      _stopSpeakingAnimation();
      widget.controller.failAssistantStream(error.toString());
    } finally {
      if (identical(_replyIterator, iterator)) _replyIterator = null;
      if (iterator != null) unawaited(iterator.cancel());
      if (mounted && generation == _replyGeneration) {
        setState(() => _isReplying = false);
        _scrollToBottom();
      }
    }
  }

  void _cancelReply() {
    if (!_isReplying) return;
    _replyGeneration += 1;
    final iterator = _replyIterator;
    _replyIterator = null;
    if (iterator != null) unawaited(iterator.cancel());
    _cancelSpeechPlayback();
    _stopSpeakingAnimation();
    widget.controller.finishAssistantStream();
    setState(() => _isReplying = false);
    _scrollToBottom();
  }

  void _undoLastMessage() {
    if (_isReplying) _cancelReply();
    _cancelSpeechPlayback();
    final withdrawn = widget.controller.undoLastUserTurn();
    if (withdrawn == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没有可以撤回的用户消息')));
      return;
    }
    unawaited(_clearLastSpeech());
    final restoredText = withdrawn.text == '请分析我发送的附件。' ? '' : withdrawn.text;
    _inputController
      ..text = restoredText
      ..selection = TextSelection.collapsed(offset: restoredText.length);
    setState(() {
      _pendingAttachments
        ..clear()
        ..addAll(
          withdrawn.attachments.where((attachment) => attachment.bytes != null),
        );
      _manualPanelFraction = null;
    });
    _applyMoodAnimation();
    _scrollToBottom();
  }

  void _applyMoodAnimation() {
    if (!_spineReady) return;
    final animation = switch (widget.controller.characterMood) {
      CharacterMood.neutral => 'motion_A_001_idle',
      CharacterMood.happy => 'motion_A_003_idle',
      CharacterMood.concerned =>
        _appearance.id == 'standing_99'
            ? 'motion_A_004_idle'
            : 'motion_A_008_idle',
      CharacterMood.excited => 'motion_A_006_idle',
    };
    _playIdleAnimation(animation);
  }

  Future<void> _playTtsIfConfigured(String text) async {
    if (text.trim().isEmpty) {
      _stopSpeakingAnimation();
      return;
    }
    if (!widget.controller.fishTtsEnabled) {
      _startSpeakingAnimation();
      _applyPerformanceFromResponse(text);
      _scheduleSpeechFallback(text);
      return;
    }
    final segments = performanceSegmentsForAssistantResponse(
      text,
      fallbackMood: widget.controller.characterMood,
    );
    if (segments.isEmpty) {
      _stopSpeakingAnimation();
      return;
    }
    final apiKey = await _secretStore.readTtsKey(widget.controller.ttsProvider);
    final missingProviderSettings = switch (widget.controller.ttsProvider) {
      TtsProvider.fishAudio => widget.controller.fishAudioReferenceId.isEmpty,
      TtsProvider.dashScope =>
        widget.controller.dashScopeTtsBaseUrl.isEmpty ||
            widget.controller.dashScopeTtsVoice.isEmpty,
      TtsProvider.generic => widget.controller.genericTtsBaseUrl.isEmpty,
    };
    if (apiKey.isEmpty || missingProviderSettings) {
      _startSpeakingAnimation();
      _applyPerformanceFromResponse(text);
      _scheduleSpeechFallback(text);
      return;
    }
    final generation = ++_speechPlaybackGeneration;
    final previousCancellation = _speechCancellation;
    if (previousCancellation != null && !previousCancellation.isCompleted) {
      previousCancellation.complete();
    }
    final cancellation = Completer<void>();
    _speechCancellation = cancellation;
    final completedSegments = <_CachedSpeechSegment>[];
    try {
      Future<_PreparedSpeech> pending = _prepareSpeech(
        segments.first,
        apiKey,
        generation,
      );
      for (var index = 0; index < segments.length; index++) {
        final prepared = await pending;
        if (!mounted || generation != _speechPlaybackGeneration) {
          unawaited(_deleteTemporarySpeech(prepared.path));
          return;
        }
        final next = index + 1 < segments.length
            ? _prepareSpeech(segments[index + 1], apiKey, generation)
            : null;
        final segment = segments[index];
        if (segment.expression case final expression?) {
          _applyExpression(expression);
        }
        if (segment.action case final action?) {
          _performSemanticAction(action);
        }
        _startSpeakingAnimation(envelope: prepared.envelope);
        await _audioPlayer.stop();
        await _audioPlayer.setVolume(widget.controller.voiceVolume);
        final completed = _audioPlayer.onPlayerComplete.first;
        await _audioPlayer.play(DeviceFileSource(prepared.path));
        await Future.any([completed, cancellation.future]);
        if (generation != _speechPlaybackGeneration) {
          await _deleteSpeechSegments(completedSegments);
          await _deleteTemporarySpeech(prepared.path);
          return;
        }
        completedSegments.add(
          _CachedSpeechSegment(
            path: prepared.path,
            envelope: prepared.envelope,
            expression: segment.expression,
            action: segment.action,
          ),
        );
        _stopSpeakingAnimation();
        if (next != null) pending = next;
      }
      await _replaceLastSpeech(completedSegments);
      _stopSpeakingAnimation();
      if (identical(_speechCancellation, cancellation)) {
        _speechCancellation = null;
      }
    } on Object {
      _stopSpeakingAnimation();
      if (generation != _speechPlaybackGeneration) return;
      _speechPlaybackGeneration += 1;
      if (!cancellation.isCompleted) cancellation.complete();
      if (identical(_speechCancellation, cancellation)) {
        _speechCancellation = null;
      }
      for (final path in _temporarySpeechPaths.toList()) {
        unawaited(_deleteTemporarySpeech(path));
      }
      _startSpeakingAnimation();
      _applyPerformanceFromResponse(text);
      _scheduleSpeechFallback(text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${widget.controller.ttsProvider.label} 语音生成失败，文本回复不受影响',
          ),
        ),
      );
    }
  }

  Future<_PreparedSpeech> _prepareSpeech(
    RyzaPerformanceSegment segment,
    String apiKey,
    int generation,
  ) async {
    // WAV keeps the PCM samples available for deterministic lip sync. The
    // format preference remains useful for the settings-page voice preview.
    final plainText = segment.speechText
        .replaceFirst(RegExp(r'^\s*\[[^\]]+\]\s*'), '')
        .trim();
    final path = await switch (widget.controller.ttsProvider) {
      TtsProvider.fishAudio => _fishAudioClient.synthesize(
        apiKey: apiKey,
        referenceId: widget.controller.fishAudioReferenceId,
        model: widget.controller.fishAudioModel,
        format: 'wav',
        latency: widget.controller.fishAudioLatency,
        speed: widget.controller.fishAudioSpeed,
        text: segment.speechText,
      ),
      TtsProvider.dashScope => _dashScopeTtsClient.synthesize(
        apiKey: apiKey,
        baseUrl: widget.controller.dashScopeTtsBaseUrl,
        model: widget.controller.dashScopeTtsModel,
        voice: widget.controller.dashScopeTtsVoice,
        language: widget.controller.dashScopeTtsLanguage,
        instructions: widget.controller.dashScopeTtsInstructions,
        text: plainText,
      ),
      TtsProvider.generic => _genericTtsClient.synthesize(
        apiKey: apiKey,
        baseUrl: widget.controller.genericTtsBaseUrl,
        model: widget.controller.genericTtsModel,
        voice: widget.controller.genericTtsVoice,
        format: 'wav',
        speed: widget.controller.fishAudioSpeed,
        text: plainText,
      ),
    };
    _temporarySpeechPaths.add(path);
    if (generation != _speechPlaybackGeneration) {
      await _deleteTemporarySpeech(path);
      throw const AiServiceException('语音播放已取消');
    }
    final bytes = await File(path).readAsBytes();
    return _PreparedSpeech(
      path: path,
      envelope: AudioAmplitudeEnvelope.tryParseWav(bytes),
    );
  }

  Future<void> _deleteTemporarySpeech(String path) async {
    _temporarySpeechPaths.remove(path);
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The OS may still hold the decoder handle briefly; temp cleanup is best effort.
    }
  }

  Future<void> _deleteSpeechSegments(
    Iterable<_CachedSpeechSegment> segments,
  ) async {
    for (final segment in segments) {
      await _deleteTemporarySpeech(segment.path);
    }
  }

  Future<void> _replaceLastSpeech(List<_CachedSpeechSegment> segments) async {
    final previous = _lastSpeech;
    _lastSpeech = List<_CachedSpeechSegment>.unmodifiable(segments);
    for (final segment in segments) {
      _temporarySpeechPaths.remove(segment.path);
    }
    await _deleteSpeechSegments(previous);
    if (mounted) setState(() {});
  }

  Future<void> _clearLastSpeech() async {
    final previous = _lastSpeech;
    _lastSpeech = const [];
    await _deleteSpeechSegments(previous);
    if (mounted) setState(() {});
  }

  Future<void> _replayLastSpeech() async {
    if (_lastSpeech.isEmpty || _isReplying) return;
    final segments = List<_CachedSpeechSegment>.of(_lastSpeech);
    final generation = ++_speechPlaybackGeneration;
    final previousCancellation = _speechCancellation;
    if (previousCancellation != null && !previousCancellation.isCompleted) {
      previousCancellation.complete();
    }
    final cancellation = Completer<void>();
    _speechCancellation = cancellation;
    try {
      for (final segment in segments) {
        if (generation != _speechPlaybackGeneration) return;
        if (segment.expression case final expression?) {
          _applyExpression(expression);
        }
        if (segment.action case final action?) {
          _performSemanticAction(action);
        }
        _startSpeakingAnimation(envelope: segment.envelope);
        await _audioPlayer.stop();
        await _audioPlayer.setVolume(widget.controller.voiceVolume);
        final completed = _audioPlayer.onPlayerComplete.first;
        await _audioPlayer.play(DeviceFileSource(segment.path));
        await Future.any([completed, cancellation.future]);
        if (generation != _speechPlaybackGeneration) return;
        _stopSpeakingAnimation();
      }
    } on Object {
      if (!mounted || generation != _speechPlaybackGeneration) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('上一条语音文件已失效，请重新生成回复')));
      await _clearLastSpeech();
    } finally {
      if (generation == _speechPlaybackGeneration) _stopSpeakingAnimation();
      if (identical(_speechCancellation, cancellation)) {
        _speechCancellation = null;
      }
    }
  }

  void _cancelSpeechPlayback() {
    _speechPlaybackGeneration += 1;
    final cancellation = _speechCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    _speechCancellation = null;
    unawaited(_audioPlayer.stop());
    for (final path in _temporarySpeechPaths.toList()) {
      unawaited(_deleteTemporarySpeech(path));
    }
    if (_isCharacterSpeaking) _stopSpeakingAnimation();
  }

  void _scheduleSpeechFallback(String text) {
    final visibleLength = displayTextForAssistantResponse(text).length;
    final durationMs = (visibleLength * 55).clamp(900, 4200).toInt();
    _speechFallbackTimer?.cancel();
    _speechFallbackTimer = Timer(Duration(milliseconds: durationMs), () {
      if (mounted) _stopSpeakingAnimation();
    });
  }

  Future<void> _refreshLongTermMemory(String apiKey) async {
    final dialogue = widget.controller
        .recentMessages(limit: 12)
        .map(
          (message) => message.isUser
              ? '用户：${message.text}'
              : displayTextForAssistantResponse(message.text),
        )
        .join('\n');
    try {
      final memory = await _aiClient.complete(
        baseUrl: widget.controller.openAiBaseUrl,
        apiKey: apiKey,
        model: widget.controller.openAiModel,
        messages: [
          {
            'role': 'system',
            'content':
                '把对话整理为不超过200字的长期记忆。只保留用户稳定偏好、重要经历、关系变化和未完成约定。不要编造。直接输出中文记忆。',
          },
          {
            'role': 'user',
            'content':
                '旧记忆：${widget.controller.memorySummary}\n\n近期对话：\n$dialogue',
          },
        ],
      );
      widget.controller.updateMemorySummary(memory);
    } on Object {
      // Memory consolidation is best-effort and must not break normal chat.
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.minScrollExtent;
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    });
  }

  void _showMessages() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black38,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _ConversationSheet(
        messages: widget.controller.messages,
        isReplying: _isReplying,
        language: widget.controller.interfaceLanguage,
        liquidGlass: widget.controller.liquidGlassChatUi,
      ),
    );
  }

  void _showCharacterStatus() {
    final language = widget.controller.interfaceLanguage;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black38,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: GlassSurface(
            liquidGlass: widget.controller.liquidGlassChatUi,
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 30,
                offset: Offset(0, 14),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.favorite_border_rounded,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          language.text('角色状态', 'Character status', 'キャラクター状態'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        tooltip: language.text('关闭', 'Close', '閉じる'),
                        color: Colors.white,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white24),
                  _CharacterStatusRow(
                    icon: Icons.mood_outlined,
                    label: language.text('心情', 'Mood', '気分'),
                    value: widget.controller.characterMood.label,
                  ),
                  _CharacterStatusRow(
                    icon: Icons.favorite_rounded,
                    label: language.text('关系点数', 'Bond', '親密度'),
                    value: '${widget.controller.relationshipPoints}',
                  ),
                  _CharacterStatusRow(
                    icon: Icons.checkroom_outlined,
                    label: language.text('服装姿态', 'Outfit', '衣装と姿勢'),
                    value: _appearance.label,
                  ),
                  _CharacterStatusRow(
                    icon: widget.controller.sceneTime.icon,
                    label: language.text('场景时间', 'Scene time', 'シーン時間'),
                    value: widget.controller.sceneTime.label,
                  ),
                  _CharacterStatusRow(
                    icon: Icons.psychology_alt_outlined,
                    label: language.text('长期记忆', 'Memory', '長期記憶'),
                    value: widget.controller.longTermMemoryEnabled
                        ? language.text('启用', 'Enabled', '有効')
                        : language.text('关闭', 'Disabled', '無効'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showAttachmentPicker() {
    if (_isReplying) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFFF8F6F1),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: Text(
                  widget.controller.interfaceLanguage.text(
                    '发送图片',
                    'Send image',
                    '画像を送信',
                  ),
                ),
                subtitle: const Text('JPG, PNG, WebP, GIF'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickAttachments(imagesOnly: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(
                  widget.controller.interfaceLanguage.text(
                    '发送文件',
                    'Send file',
                    'ファイルを送信',
                  ),
                ),
                subtitle: Text(
                  widget.controller.interfaceLanguage.text(
                    'PDF、Office、文本和表格文件',
                    'PDF, Office, text and spreadsheet files',
                    'PDF、Office、テキスト、表計算ファイル',
                  ),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickAttachments(imagesOnly: false);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAttachments({required bool imagesOnly}) async {
    const maxBytes = 10 * 1024 * 1024;
    final files = await FilePicker.pickFiles(
      type: imagesOnly ? FileType.image : FileType.custom,
      allowedExtensions: imagesOnly
          ? null
          : const [
              'pdf',
              'txt',
              'md',
              'csv',
              'json',
              'doc',
              'docx',
              'xls',
              'xlsx',
              'ppt',
              'pptx',
            ],
    );
    if (files.isEmpty || !mounted) return;
    var totalBytes = _pendingAttachments.fold<int>(
      0,
      (total, attachment) => total + attachment.size,
    );
    final accepted = <ChatAttachment>[];
    final rejected = <String>[];
    for (final file in files) {
      final size = await file.length();
      if (size > maxBytes || totalBytes + size > maxBytes) {
        rejected.add(file.name);
        continue;
      }
      try {
        final bytes = await file.readAsBytes();
        accepted.add(
          ChatAttachment(
            name: file.name,
            mimeType: _mimeTypeForFile(file.name),
            size: bytes.length,
            bytes: bytes,
          ),
        );
        totalBytes += bytes.length;
      } on Object {
        rejected.add(file.name);
      }
    }
    if (!mounted) return;
    if (accepted.isNotEmpty) {
      setState(() => _pendingAttachments.addAll(accepted));
    }
    if (rejected.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('附件读取失败或单次总大小超过 10MB：${rejected.join('、')}')),
      );
    }
  }

  void _showMotionPicker() {
    if (!_appearance.animated) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_appearance.label}只有原包静态预览，没有可播放的 Spine 动作资源'),
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black38,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _MotionPickerSheet(
        appearance: _appearance,
        liquidGlass: widget.controller.liquidGlassChatUi,
        currentIdleAnimation: _currentIdleAnimation,
        onIdleSelected: _playIdleAnimation,
        onOneShotSelected: _playOneShotAnimation,
        onMotionGroupSelected: _playMotionGroup,
      ),
    );
  }

  void _showAppearancePicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black38,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _AppearancePickerSheet(
        liquidGlass: widget.controller.liquidGlassChatUi,
        selectedId: _appearance.id,
        onSelected: (appearance) {
          widget.controller.setCharacterAppearance(appearance.id);
          Navigator.pop(context);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 720;
    final usesLiquidGlass = widget.controller.liquidGlassChatUi;
    final mediaQuery = MediaQuery.of(context);
    final currentBottomSafeInset =
        mediaQuery.padding.bottom < mediaQuery.viewPadding.bottom
        ? mediaQuery.padding.bottom
        : mediaQuery.viewPadding.bottom;
    _stableBottomSafeInset ??= currentBottomSafeInset;
    final stableBottomSafeInset = _stableBottomSafeInset!;
    final animatedBottomInset =
        mediaQuery.padding.bottom > mediaQuery.viewPadding.bottom
        ? mediaQuery.padding.bottom
        : mediaQuery.viewPadding.bottom;
    final paddingKeyboardInset = (animatedBottomInset - stableBottomSafeInset)
        .clamp(0.0, double.infinity);
    final mediaKeyboardInset =
        mediaQuery.viewInsets.bottom > paddingKeyboardInset
        ? mediaQuery.viewInsets.bottom
        : paddingKeyboardInset;
    final liquidContentHeight =
        mediaQuery.size.height -
        mediaQuery.viewPadding.top -
        stableBottomSafeInset;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: LayoutBuilder(
        builder: (context, viewportConstraints) {
          if (_stableBodyHeight == null ||
              viewportConstraints.maxHeight > _stableBodyHeight!) {
            _stableBodyHeight = viewportConstraints.maxHeight;
          }
          final bodyKeyboardInset =
              (_stableBodyHeight! - viewportConstraints.maxHeight).clamp(
                0.0,
                double.infinity,
              );
          final keyboardInset = mediaKeyboardInset > bodyKeyboardInset
              ? mediaKeyboardInset
              : bodyKeyboardInset;
          return Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: mediaQuery.size.height,
                child: _SceneBackground(sceneTime: widget.controller.sceneTime),
              ),
              Positioned(
                top: mediaQuery.viewPadding.top,
                left: 0,
                right: 0,
                height: liquidContentHeight,
                child: LayoutBuilder(
                  builder: (context, constraints) => _buildGlassChat(
                    constraints,
                    isWide,
                    keyboardInset,
                    liquidGlass: usesLiquidGlass,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildGlassChat(
    BoxConstraints constraints,
    bool isWide,
    double keyboardInset, {
    required bool liquidGlass,
  }) {
    final automaticFraction = _automaticPanelFraction(
      constraints.maxWidth,
      isWide,
    );
    final panelFraction = _manualPanelFraction ?? automaticFraction;
    final panelHeight = (constraints.maxHeight * panelFraction).clamp(
      176.0,
      constraints.maxHeight * 0.68,
    );
    final panelWidth = isWide ? 540.0 : constraints.maxWidth - 20;
    return Stack(
      fit: StackFit.expand,
      children: [
        Column(
          children: [
            _TopBar(
              language: widget.controller.interfaceLanguage,
              liquidGlass: liquidGlass,
              sceneTime: widget.controller.sceneTime,
              onSceneChanged: widget.controller.setSceneTime,
              onMenuPressed: widget.onMenuPressed,
              onStatusPressed: _showCharacterStatus,
              onHistoryPressed: _showMessages,
            ),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1120),
                child: _buildCharacter(),
              ),
            ),
          ],
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 480),
          curve: Curves.easeOutBack,
          right: isWide ? 18 : 10,
          bottom: 8 + keyboardInset,
          width: panelWidth,
          height: panelHeight,
          child: _LiquidGlassConversation(
            language: widget.controller.interfaceLanguage,
            liquidGlass: liquidGlass,
            messages: widget.controller.messages,
            isReplying: _isReplying,
            scrollController: _scrollController,
            inputController: _inputController,
            showMicrophone: widget.controller.showMicrophoneButton,
            attachments: _pendingAttachments,
            onAddAttachment: _showAttachmentPicker,
            onRemoveAttachment: (attachment) {
              setState(() => _pendingAttachments.remove(attachment));
            },
            onSubmitted: (_) => _sendMessage(),
            onSend: _sendMessage,
            onCancel: _cancelReply,
            canUndo: widget.controller.messages.any(
              (message) => message.isUser,
            ),
            canReplay: _lastSpeech.isNotEmpty && !_isReplying,
            onUndo: _undoLastMessage,
            onReplay: _replayLastSpeech,
            onDragUpdate: (delta) {
              setState(() {
                _manualPanelFraction =
                    (panelFraction - delta / constraints.maxHeight).clamp(
                      0.22,
                      0.68,
                    );
              });
            },
          ),
        ),
      ],
    );
  }

  double _automaticPanelFraction(double viewportWidth, bool isWide) {
    final latest = widget.controller.messages.isEmpty
        ? null
        : widget.controller.messages.last;
    final text = latest == null
        ? ''
        : (latest.isUser ? latest.text : _glassMessageText(latest));
    final segmentCount = latest == null || latest.isUser
        ? 1
        : parseAssistantSegments(latest.text)
              .where(
                (segment) => displayTextForAssistantSegment(segment).isNotEmpty,
              )
              .length;
    return conversationPanelFractionForText(
      text: text,
      viewportWidth: viewportWidth,
      viewportHeight: _stableBodyHeight ?? 720,
      isWide: isWide,
      segmentCount: max(1, segmentCount),
      hasAttachments: latest?.attachments.isNotEmpty == true,
      hasImageAttachments:
          latest?.attachments.any((attachment) => attachment.isImage) == true,
      isReplying: false,
    );
  }

  Widget _buildCharacter() {
    return Stack(
      fit: StackFit.expand,
      children: [
        CharacterCamera(
          onTap: _reactToTap,
          child: _appearance.animated
              ? SpineWidget.fromAsset(
                  _appearance.atlasAsset,
                  _appearance.skeletonAsset,
                  _spineController!,
                  key: ValueKey(_appearance.id),
                  fit: BoxFit.contain,
                  alignment: Alignment.bottomCenter,
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(12, 28, 12, 0),
                  child: Image.asset(
                    _appearance.previewAsset,
                    fit: BoxFit.contain,
                    alignment: Alignment.bottomCenter,
                    filterQuality: FilterQuality.high,
                  ),
                ),
        ),
        if (_appearance.animated && !_spineReady)
          const Center(child: CircularProgressIndicator.adaptive()),
        Positioned(
          left: 16,
          bottom: 10,
          child: _CharacterLabel(
            liquidGlass: widget.controller.liquidGlassChatUi,
          ),
        ),
        Positioned(
          right: 16,
          top: 10,
          child: _CharacterToolCluster(
            liquidGlass: widget.controller.liquidGlassChatUi,
            expanded: _characterToolsExpanded,
            onToggle: () => setState(
              () => _characterToolsExpanded = !_characterToolsExpanded,
            ),
            onMotionPressed: _showMotionPicker,
            onAppearancePressed: _showAppearancePicker,
          ),
        ),
        if (_lastTappedPart case final part?)
          Positioned(
            right: 16,
            bottom: 10,
            child: _TapResultLabel(
              part: part,
              liquidGlass: widget.controller.liquidGlassChatUi,
            ),
          ),
        if (!_appearance.animated)
          Positioned(
            right: 16,
            bottom: 10,
            child: _StaticAppearanceLabel(
              liquidGlass: widget.controller.liquidGlassChatUi,
            ),
          ),
      ],
    );
  }
}

class _SceneBackground extends StatelessWidget {
  const _SceneBackground({required this.sceneTime});

  final SceneTime sceneTime;

  @override
  Widget build(BuildContext context) {
    final overlay = switch (sceneTime) {
      SceneTime.morning => const Color(0x1AFFD28A),
      SceneTime.afternoon => const Color(0x0AFFFFFF),
      SceneTime.evening => const Color(0x33B75B3D),
      SceneTime.night => const Color(0x66312D55),
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset('assets/images/talk_background.png', fit: BoxFit.cover),
        _SceneSpineLayer(sceneTime: sceneTime),
        ColoredBox(color: overlay),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withValues(alpha: 0.04), Colors.black26],
              stops: const [0.45, 1],
            ),
          ),
        ),
      ],
    );
  }
}

class _SceneSpineLayer extends StatefulWidget {
  const _SceneSpineLayer({required this.sceneTime});

  final SceneTime sceneTime;

  @override
  State<_SceneSpineLayer> createState() => _SceneSpineLayerState();
}

class _SceneSpineLayerState extends State<_SceneSpineLayer> {
  late final SpineWidgetController _controller = SpineWidgetController();

  @override
  Widget build(BuildContext context) {
    final suffix = switch (widget.sceneTime) {
      SceneTime.morning => 'mor',
      SceneTime.afternoon => 'aft',
      SceneTime.evening => 'eve',
      SceneTime.night => 'ngt',
    };
    final root = 'assets/scenes/stage_00_000_00_$suffix/spine';
    return IgnorePointer(
      child: SpineWidget.fromAsset(
        '$root/stage_00_000_00_$suffix.atlas',
        '$root/stage_00_000_00_$suffix.skel',
        _controller,
        fit: BoxFit.cover,
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.language,
    required this.liquidGlass,
    required this.sceneTime,
    required this.onSceneChanged,
    required this.onMenuPressed,
    required this.onStatusPressed,
    required this.onHistoryPressed,
  });

  final AppLanguage language;
  final bool liquidGlass;
  final SceneTime sceneTime;
  final ValueChanged<SceneTime> onSceneChanged;
  final VoidCallback onMenuPressed;
  final VoidCallback onStatusPressed;
  final VoidCallback onHistoryPressed;

  Future<void> _showSceneTimeMenu(BuildContext context) async {
    final selected = await showDialog<SceneTime>(
      context: context,
      barrierColor: Colors.black38,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: GlassSurface(
            liquidGlass: liquidGlass,
            fallbackColor: const Color(0xD9201D1B),
            boxShadow: const [
              BoxShadow(
                color: Color(0x55000000),
                blurRadius: 28,
                offset: Offset(0, 12),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 4, 4, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            language.text(
                              '切换场景时间',
                              'Change scene time',
                              'シーンの時間を変更',
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          tooltip: language.text('关闭', 'Close', '閉じる'),
                          color: Colors.white,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  for (final value in SceneTime.values)
                    _GlassPickerTile(
                      liquidGlass: liquidGlass,
                      leading: Icon(value.icon, color: Colors.white),
                      title: Text(
                        value.label,
                        style: const TextStyle(color: Colors.white),
                      ),
                      trailing: value == sceneTime
                          ? const Icon(
                              Icons.check_circle_rounded,
                              color: Colors.white,
                            )
                          : null,
                      onTap: () => Navigator.pop(dialogContext, value),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (selected != null) onSceneChanged(selected);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          _RoundIcon(
            liquidGlass: liquidGlass,
            icon: Icons.menu_rounded,
            tooltip: language.text('菜单', 'Menu', 'メニュー'),
            onPressed: onMenuPressed,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  language.text('莱莎', 'Ryza', 'ライザ'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  language.text(
                    '在线 · 本地原型',
                    'Online · Local prototype',
                    'オンライン · ローカル版',
                  ),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          Tooltip(
            message: language.text('切换场景时间', 'Change scene time', 'シーンの時間を変更'),
            child: Semantics(
              button: true,
              label: language.text('切换场景时间', 'Change scene time', 'シーンの時間を変更'),
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: () => _showSceneTimeMenu(context),
                child: _StatusPill(
                  liquidGlass: liquidGlass,
                  icon: sceneTime.icon,
                  label: sceneTime.label,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _RoundIcon(
            liquidGlass: liquidGlass,
            icon: Icons.favorite_border_rounded,
            tooltip: language.text('角色状态', 'Character status', 'キャラクター状態'),
            onPressed: onStatusPressed,
          ),
          const SizedBox(width: 8),
          _RoundIcon(
            liquidGlass: liquidGlass,
            icon: Icons.forum_outlined,
            tooltip: language.text('对话记录', 'Conversation history', '会話履歴'),
            onPressed: onHistoryPressed,
          ),
        ],
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({
    required this.liquidGlass,
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final bool liquidGlass;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return GlassIconButton(
      liquidGlass: liquidGlass,
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.liquidGlass,
    required this.icon,
    required this.label,
  });

  final bool liquidGlass;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      liquidGlass: liquidGlass,
      borderRadius: BorderRadius.circular(21),
      fallbackColor: Colors.black.withValues(alpha: 0.38),
      child: SizedBox(
        height: 42,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 7),
              Text(label, style: const TextStyle(color: Colors.white)),
              const SizedBox(width: 2),
              const Icon(
                Icons.arrow_drop_down,
                color: Colors.white70,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CharacterToolCluster extends StatelessWidget {
  const _CharacterToolCluster({
    required this.liquidGlass,
    required this.expanded,
    required this.onToggle,
    required this.onMotionPressed,
    required this.onAppearancePressed,
  });

  final bool liquidGlass;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onMotionPressed;
  final VoidCallback onAppearancePressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _CharacterToolButton(
          liquidGlass: liquidGlass,
          tooltip: expanded ? '收起角色工具' : '展开角色工具',
          icon: expanded ? Icons.close_rounded : Icons.auto_fix_high_outlined,
          onPressed: onToggle,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutBack,
          alignment: Alignment.topCenter,
          child: expanded
              ? Column(
                  children: [
                    const SizedBox(height: 8),
                    _CharacterToolButton(
                      liquidGlass: liquidGlass,
                      tooltip: '动作',
                      icon: Icons.animation_outlined,
                      onPressed: onMotionPressed,
                    ),
                    const SizedBox(height: 8),
                    _CharacterToolButton(
                      liquidGlass: liquidGlass,
                      tooltip: '服装与姿态',
                      icon: Icons.checkroom_outlined,
                      onPressed: onAppearancePressed,
                    ),
                  ],
                )
              : const SizedBox(width: 42),
        ),
      ],
    );
  }
}

class _CharacterToolButton extends StatelessWidget {
  const _CharacterToolButton({
    required this.liquidGlass,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final bool liquidGlass;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GlassIconButton(
      liquidGlass: liquidGlass,
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

class _GlassPickerTile extends StatelessWidget {
  const _GlassPickerTile({
    required this.liquidGlass,
    required this.title,
    required this.onTap,
    this.leading,
    this.subtitle,
    this.trailing,
    this.dense = false,
    this.minVerticalPadding,
  });

  final bool liquidGlass;
  final Widget title;
  final Widget? leading;
  final Widget? subtitle;
  final Widget? trailing;
  final bool dense;
  final double? minVerticalPadding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: GlassSurface(
        liquidGlass: liquidGlass,
        borderRadius: BorderRadius.circular(10),
        fallbackColor: Colors.white.withValues(alpha: 0.08),
        child: ListTile(
          dense: dense,
          minVerticalPadding: minVerticalPadding,
          leading: leading,
          title: title,
          subtitle: subtitle,
          trailing: trailing,
          onTap: onTap,
        ),
      ),
    );
  }
}

class _MotionPickerSheet extends StatelessWidget {
  const _MotionPickerSheet({
    required this.appearance,
    required this.liquidGlass,
    required this.currentIdleAnimation,
    required this.onIdleSelected,
    required this.onOneShotSelected,
    required this.onMotionGroupSelected,
  });

  final CharacterAppearance appearance;
  final bool liquidGlass;
  final String? currentIdleAnimation;
  final ValueChanged<String> onIdleSelected;
  final ValueChanged<String> onOneShotSelected;
  final ValueChanged<CharacterMotionGroup> onMotionGroupSelected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: GlassSurface(
        liquidGlass: liquidGlass,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        fallbackColor: const Color(0xE8201D1B),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '角色动作',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: '关闭',
                    color: Colors.white,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
                children: [
                  _MotionSectionLabel(
                    title: '闲置姿势',
                    count: appearance.idleAnimations.length,
                  ),
                  for (final animation in appearance.idleAnimations)
                    _GlassPickerTile(
                      liquidGlass: liquidGlass,
                      dense: true,
                      leading: const Icon(Icons.loop, color: Colors.white70),
                      title: Text(
                        motionDisplayName(animation),
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        animation,
                        style: const TextStyle(color: Colors.white60),
                      ),
                      trailing: animation == currentIdleAnimation
                          ? const Icon(Icons.check, color: Colors.white)
                          : const Icon(Icons.play_arrow, color: Colors.white70),
                      onTap: () {
                        onIdleSelected(animation);
                        Navigator.pop(context);
                      },
                    ),
                  const _MotionSectionLabel(title: '一次性动作', count: 12),
                  for (final animation in characterOneShotAnimations)
                    _GlassPickerTile(
                      liquidGlass: liquidGlass,
                      dense: true,
                      leading: const Icon(
                        Icons.motion_photos_on_outlined,
                        color: Colors.white70,
                      ),
                      title: Text(
                        motionDisplayName(animation),
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        animation,
                        style: const TextStyle(color: Colors.white60),
                      ),
                      trailing: const Icon(
                        Icons.play_arrow,
                        color: Colors.white70,
                      ),
                      onTap: () {
                        onOneShotSelected(animation);
                        Navigator.pop(context);
                      },
                    ),
                  FutureBuilder<List<CharacterMotionGroup>>(
                    future: loadCharacterMotionGroups(appearance),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return _GlassPickerTile(
                          liquidGlass: liquidGlass,
                          leading: const Icon(
                            Icons.error_outline,
                            color: Colors.white70,
                          ),
                          title: const Text(
                            '叠加动作配置读取失败',
                            style: TextStyle(color: Colors.white),
                          ),
                          onTap: null,
                        );
                      }
                      final groups = snapshot.data;
                      if (groups == null) {
                        return const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(
                            child: CircularProgressIndicator.adaptive(),
                          ),
                        );
                      }
                      return Column(
                        children: [
                          _MotionSectionLabel(
                            title: '组合动作',
                            count: groups.length,
                          ),
                          for (final group in groups)
                            _GlassPickerTile(
                              liquidGlass: liquidGlass,
                              dense: true,
                              leading: const Icon(
                                Icons.layers_outlined,
                                color: Colors.white70,
                              ),
                              title: Text(
                                group.label.isEmpty ? group.id : group.label,
                                style: const TextStyle(color: Colors.white),
                              ),
                              subtitle: Text(
                                '${group.occupancy} · ${group.animation1}',
                                style: const TextStyle(color: Colors.white60),
                              ),
                              trailing: const Icon(
                                Icons.play_arrow,
                                color: Colors.white70,
                              ),
                              onTap: () {
                                onMotionGroupSelected(group);
                                Navigator.pop(context);
                              },
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MotionSectionLabel extends StatelessWidget {
  const _MotionSectionLabel({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Text(
        '$title · $count',
        style: const TextStyle(
          color: Color(0xFF2D796A),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AppearancePickerSheet extends StatelessWidget {
  const _AppearancePickerSheet({
    required this.liquidGlass,
    required this.selectedId,
    required this.onSelected,
  });

  final bool liquidGlass;
  final String selectedId;
  final ValueChanged<CharacterAppearance> onSelected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: GlassSurface(
        liquidGlass: liquidGlass,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        fallbackColor: const Color(0xE8201D1B),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 18, 12, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '服装与姿态',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      tooltip: '关闭',
                      color: Colors.white,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              for (final appearance in characterAppearances)
                _GlassPickerTile(
                  liquidGlass: liquidGlass,
                  minVerticalPadding: 8,
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: ColoredBox(
                      color: const Color(0xFFE4E0D8),
                      child: SizedBox.square(
                        dimension: 54,
                        child: Image.asset(
                          appearance.previewAsset,
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                        ),
                      ),
                    ),
                  ),
                  title: Text(
                    appearance.label,
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    appearance.animated ? '完整 Spine 动画资源' : '原包静态预览资源',
                    style: const TextStyle(color: Colors.white60),
                  ),
                  trailing: appearance.id == selectedId
                      ? const Icon(Icons.check_circle, color: Colors.white)
                      : Icon(
                          appearance.animated
                              ? Icons.animation_outlined
                              : Icons.image_outlined,
                          color: Colors.white70,
                        ),
                  onTap: () => onSelected(appearance),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CharacterLabel extends StatelessWidget {
  const _CharacterLabel({required this.liquidGlass});

  final bool liquidGlass;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      liquidGlass: liquidGlass,
      borderRadius: BorderRadius.circular(16),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.touch_app_outlined, color: Colors.white70, size: 16),
            SizedBox(width: 6),
            Text('点击互动', style: TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _CharacterStatusRow extends StatelessWidget {
  const _CharacterStatusRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white70)),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StaticAppearanceLabel extends StatelessWidget {
  const _StaticAppearanceLabel({required this.liquidGlass});

  final bool liquidGlass;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      liquidGlass: liquidGlass,
      borderRadius: BorderRadius.circular(16),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_outlined, color: Colors.white70, size: 16),
            SizedBox(width: 6),
            Text('静态服装', style: TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _TapResultLabel extends StatelessWidget {
  const _TapResultLabel({required this.part, required this.liquidGlass});

  final String part;
  final bool liquidGlass;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      liquidGlass: liquidGlass,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        child: Text(
          '触发：$part',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }
}

class _LiquidGlassConversation extends StatelessWidget {
  const _LiquidGlassConversation({
    required this.language,
    required this.liquidGlass,
    required this.messages,
    required this.isReplying,
    required this.scrollController,
    required this.inputController,
    required this.showMicrophone,
    required this.attachments,
    required this.onAddAttachment,
    required this.onRemoveAttachment,
    required this.onSubmitted,
    required this.onSend,
    required this.onCancel,
    required this.canUndo,
    required this.canReplay,
    required this.onUndo,
    required this.onReplay,
    required this.onDragUpdate,
  });

  final AppLanguage language;
  final bool liquidGlass;
  final List<ChatMessage> messages;
  final bool isReplying;
  final ScrollController scrollController;
  final TextEditingController inputController;
  final bool showMicrophone;
  final List<ChatAttachment> attachments;
  final VoidCallback onAddAttachment;
  final ValueChanged<ChatAttachment> onRemoveAttachment;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final bool canUndo;
  final bool canReplay;
  final VoidCallback onUndo;
  final VoidCallback onReplay;
  final ValueChanged<double> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          top: 18,
          child: _LiquidGlassSurface(
            liquidGlass: liquidGlass,
            child: Column(
              children: [
                Expanded(
                  child: _GlassMessageList(
                    language: language,
                    messages: messages,
                    controller: scrollController,
                  ),
                ),
                Container(
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.2),
                ),
                _GlassComposer(
                  language: language,
                  controller: inputController,
                  isReplying: isReplying,
                  showMicrophone: showMicrophone,
                  attachments: attachments,
                  onAddAttachment: onAddAttachment,
                  onRemoveAttachment: onRemoveAttachment,
                  onSubmitted: onSubmitted,
                  onSend: onSend,
                  onCancel: onCancel,
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 12,
          top: 0,
          child: Row(
            children: [
              GlassIconButton(
                liquidGlass: liquidGlass,
                icon: Icons.undo_rounded,
                tooltip: language.text(
                  '撤回上一条消息',
                  'Undo last message',
                  '直前のメッセージを取り消す',
                ),
                onPressed: canUndo ? onUndo : null,
                size: 36,
              ),
              const SizedBox(width: 7),
              GlassIconButton(
                liquidGlass: liquidGlass,
                icon: Icons.replay_rounded,
                tooltip: language.text(
                  '重播上一条语音',
                  'Replay last voice',
                  '直前の音声を再生',
                ),
                onPressed: canReplay ? onReplay : null,
                size: 36,
              ),
            ],
          ),
        ),
        Positioned(
          right: 12,
          top: 0,
          child: Semantics(
            label: '拖动调整对话框高度',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) => onDragUpdate(details.delta.dy),
              child: _GlassDragHandle(liquidGlass: liquidGlass),
            ),
          ),
        ),
      ],
    );
  }
}

class _LiquidGlassSurface extends StatelessWidget {
  const _LiquidGlassSurface({required this.child, required this.liquidGlass});

  final Widget child;
  final bool liquidGlass;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      liquidGlass: liquidGlass,
      fallbackColor: const Color(0xFF201D1B).withValues(alpha: 0.72),
      boxShadow: const [
        BoxShadow(
          color: Color(0x52000000),
          blurRadius: 24,
          offset: Offset(0, 10),
        ),
      ],
      child: child,
    );
  }
}

class _GlassDragHandle extends StatelessWidget {
  const _GlassDragHandle({required this.liquidGlass});

  final bool liquidGlass;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      liquidGlass: liquidGlass,
      tone: GlassTone.light,
      borderRadius: BorderRadius.circular(22),
      fallbackColor: Colors.white.withValues(alpha: 0.82),
      boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 10)],
      child: const SizedBox.square(
        dimension: 44,
        child: Icon(
          Icons.unfold_more_rounded,
          size: 23,
          color: Color(0xFF4A2F28),
        ),
      ),
    );
  }
}

class _GlassMessageList extends StatelessWidget {
  const _GlassMessageList({
    required this.language,
    required this.messages,
    required this.controller,
  });

  final AppLanguage language;
  final List<ChatMessage> messages;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final visibleMessages = messages
        .where((message) => message.text.trim().isNotEmpty)
        .toList(growable: false);
    return ListView.separated(
      controller: controller,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(14, 32, 14, 8),
      itemCount: visibleMessages.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.2)),
      itemBuilder: (context, index) {
        final messageIndex = visibleMessages.length - 1 - index;
        final message = visibleMessages[messageIndex];
        final avatar = Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
          ),
          child: Icon(
            message.isUser
                ? Icons.person_outline_rounded
                : Icons.auto_awesome_rounded,
            size: 16,
            color: Colors.white,
          ),
        );
        final body = Expanded(
          child: Column(
            crossAxisAlignment: message.isUser
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Text(
                message.isUser
                    ? language.text('你', 'You', 'あなた')
                    : language.text('莱莎', 'Ryza', 'ライザ'),
                textAlign: message.isUser ? TextAlign.right : TextAlign.left,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              message.isUser
                  ? Text(
                      message.text,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        height: 1.35,
                      ),
                    )
                  : _AssistantSegmentBody(response: message.text, glass: true),
              if (message.attachments.isNotEmpty) ...[
                const SizedBox(height: 7),
                Align(
                  alignment: message.isUser
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: _SentAttachmentLabels(
                    attachments: message.attachments,
                    glass: true,
                  ),
                ),
              ],
            ],
          ),
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: message.isUser
                ? [body, const SizedBox(width: 10), avatar]
                : [avatar, const SizedBox(width: 10), body],
          ),
        );
      },
    );
  }
}

String _glassMessageText(ChatMessage message) {
  if (message.isUser) return message.text;
  return displayTextForAssistantResponse(message.text)
      .replaceAll(RegExp(r'^\s*(旁白|莱莎|译文)\s*[：:]\s*', multiLine: true), '')
      .trim();
}

class _AssistantSegmentBody extends StatelessWidget {
  const _AssistantSegmentBody({required this.response, required this.glass});

  final String response;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final segments = parseAssistantSegments(response)
        .where((segment) => displayTextForAssistantSegment(segment).isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) {
      return Text(
        response.trim(),
        style: TextStyle(
          color: glass ? Colors.white : Theme.of(context).colorScheme.onSurface,
          height: 1.4,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < segments.length; index++) ...[
          if (index > 0)
            Divider(
              height: 17,
              thickness: 1,
              color: glass
                  ? Colors.white.withValues(alpha: 0.22)
                  : Colors.black.withValues(alpha: 0.13),
            ),
          Text(
            '${segments[index].speaker == ChatSpeaker.translation ? '译文：' : ''}'
            '${displayTextForAssistantSegment(segments[index])}',
            style: TextStyle(
              color: glass
                  ? Colors.white
                  : Theme.of(context).colorScheme.onSurface,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }
}

class _PendingAttachmentBar extends StatelessWidget {
  const _PendingAttachmentBar({
    required this.attachments,
    required this.onRemove,
    required this.glass,
  });

  final List<ChatAttachment> attachments;
  final ValueChanged<ChatAttachment> onRemove;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 62,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 6),
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final attachment = attachments[index];
          final foreground = glass ? Colors.white : const Color(0xFF262521);
          return Container(
            width: attachment.isImage ? 150 : 190,
            decoration: BoxDecoration(
              color: glass
                  ? Colors.white.withValues(alpha: 0.13)
                  : const Color(0xFFE7E4DD),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: glass ? Colors.white24 : Colors.black12,
              ),
            ),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: _AttachmentThumbnail(
                    attachment: attachment,
                    size: 46,
                    foreground: foreground,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '${attachment.name}\n${_attachmentSizeLabel(attachment.size)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: foreground, fontSize: 10.5),
                  ),
                ),
                IconButton(
                  onPressed: () => onRemove(attachment),
                  tooltip: '移除',
                  visualDensity: VisualDensity.compact,
                  color: glass ? Colors.white70 : Colors.black54,
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

String _attachmentSizeLabel(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
  return '${(bytes / 1024).ceil()}KB';
}

class _SentAttachmentLabels extends StatelessWidget {
  const _SentAttachmentLabels({required this.attachments, required this.glass});

  final List<ChatAttachment> attachments;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final foreground = glass ? Colors.white : const Color(0xFF262521);
    return Wrap(
      spacing: 6,
      runSpacing: 5,
      children: [
        for (final attachment in attachments)
          if (attachment.isImage && attachment.bytes != null)
            Container(
              constraints: const BoxConstraints(maxWidth: 180),
              decoration: BoxDecoration(
                color: glass
                    ? Colors.white.withValues(alpha: 0.12)
                    : Colors.black.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: glass ? Colors.white24 : Colors.black12,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _AttachmentThumbnail(
                    attachment: attachment,
                    width: 178,
                    height: 96,
                    foreground: foreground,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    child: Text(
                      attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: foreground, fontSize: 11),
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              constraints: const BoxConstraints(maxWidth: 240),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: glass
                    ? Colors.white.withValues(alpha: 0.12)
                    : Colors.black.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: glass ? Colors.white24 : Colors.black12,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.description_outlined, size: 15, color: foreground),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: foreground, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

class _AttachmentThumbnail extends StatelessWidget {
  const _AttachmentThumbnail({
    required this.attachment,
    required this.foreground,
    this.size,
    this.width,
    this.height,
  });

  final ChatAttachment attachment;
  final Color foreground;
  final double? size;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final previewWidth = width ?? size ?? 46;
    final previewHeight = height ?? size ?? 46;
    final bytes = attachment.bytes;
    if (attachment.isImage && bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Image.memory(
          bytes,
          width: previewWidth,
          height: previewHeight,
          fit: BoxFit.cover,
          cacheWidth: (previewWidth * 2).round(),
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _attachmentFallback(
            previewWidth,
            previewHeight,
            Icons.broken_image_outlined,
          ),
        ),
      );
    }
    return _attachmentFallback(
      previewWidth,
      previewHeight,
      attachment.isImage ? Icons.image_outlined : Icons.description_outlined,
    );
  }

  Widget _attachmentFallback(double width, double height, IconData icon) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(7),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: foreground, size: 22),
    );
  }
}

class _GlassComposer extends StatelessWidget {
  const _GlassComposer({
    required this.language,
    required this.controller,
    required this.isReplying,
    required this.showMicrophone,
    required this.attachments,
    required this.onAddAttachment,
    required this.onRemoveAttachment,
    required this.onSubmitted,
    required this.onSend,
    required this.onCancel,
  });

  final AppLanguage language;
  final TextEditingController controller;
  final bool isReplying;
  final bool showMicrophone;
  final List<ChatAttachment> attachments;
  final VoidCallback onAddAttachment;
  final ValueChanged<ChatAttachment> onRemoveAttachment;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (attachments.isNotEmpty)
            _PendingAttachmentBar(
              attachments: attachments,
              onRemove: onRemoveAttachment,
              glass: true,
            ),
          Row(
            children: [
              if (showMicrophone) ...[
                IconButton(
                  onPressed: () {},
                  tooltip: language.text(
                    '语音输入（待接入）',
                    'Voice input (coming later)',
                    '音声入力（未実装）',
                  ),
                  color: Colors.white,
                  icon: const Icon(Icons.mic_none_rounded),
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: 46,
                    maxHeight: 96,
                  ),
                  padding: const EdgeInsets.only(left: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(23),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.28),
                    ),
                  ),
                  child: TextField(
                    controller: controller,
                    readOnly: isReplying,
                    minLines: 1,
                    maxLines: 3,
                    textAlignVertical: TextAlignVertical.center,
                    textInputAction: TextInputAction.send,
                    onSubmitted: isReplying ? null : onSubmitted,
                    style: const TextStyle(color: Colors.white),
                    cursorColor: Colors.white,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 13),
                      hintText: !isReplying
                          ? language.text(
                              '和莱莎说点什么…',
                              'Say something to Ryza…',
                              'ライザに話しかける…',
                            )
                          : language.text(
                              '莱莎正在回复…',
                              'Ryza is replying…',
                              'ライザが返信中…',
                            ),
                      hintStyle: const TextStyle(color: Colors.white60),
                      border: InputBorder.none,
                      suffixIcon: IconButton(
                        onPressed: !isReplying ? onAddAttachment : null,
                        tooltip: language.text(
                          '添加图片或文件',
                          'Add image or file',
                          '画像またはファイルを追加',
                        ),
                        color: Colors.white,
                        icon: const Icon(Icons.add_rounded, size: 30),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: isReplying ? onCancel : onSend,
                tooltip: isReplying
                    ? language.text('停止回复', 'Stop response', '返信を停止')
                    : language.text('发送', 'Send', '送信'),
                style: IconButton.styleFrom(
                  fixedSize: const Size.square(46),
                  backgroundColor: const Color(0xFFF65C2D),
                  foregroundColor: Colors.white,
                ),
                icon: isReplying
                    ? Stack(
                        alignment: Alignment.center,
                        children: [
                          const SizedBox.square(
                            dimension: 27,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white70,
                            ),
                          ),
                          const Icon(Icons.close_rounded, size: 19),
                        ],
                      )
                    : const Icon(Icons.arrow_upward_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConversationSheet extends StatefulWidget {
  const _ConversationSheet({
    required this.messages,
    required this.isReplying,
    required this.language,
    required this.liquidGlass,
  });

  final List<ChatMessage> messages;
  final bool isReplying;
  final AppLanguage language;
  final bool liquidGlass;

  @override
  State<_ConversationSheet> createState() => _ConversationSheetState();
}

class _ConversationSheetState extends State<_ConversationSheet> {
  final _controller = ScrollController();
  bool _showRawOutput = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: GlassSurface(
        liquidGlass: widget.liquidGlass,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        fallbackColor: const Color(0xE8201D1B),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white38,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.language.text(
                        '对话记录',
                        'Conversation history',
                        '会話履歴',
                      ),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: widget.language.text('关闭', 'Close', '閉じる'),
                    color: Colors.white,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.language.text(
                        '显示原始输出',
                        'Show raw output',
                        '生の出力を表示',
                      ),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Switch.adaptive(
                    value: _showRawOutput,
                    onChanged: (value) {
                      setState(() => _showRawOutput = value);
                    },
                    activeTrackColor: Colors.white38,
                  ),
                ],
              ),
            ),
            Flexible(
              child: _MessageList(
                messages: widget.messages,
                isReplying: widget.isReplying,
                controller: _controller,
                reverse: true,
                showRawOutput: _showRawOutput,
                glass: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.messages,
    required this.isReplying,
    this.controller,
    this.reverse = false,
    this.showRawOutput = false,
    this.glass = false,
  });

  final List<ChatMessage> messages;
  final bool isReplying;
  final ScrollController? controller;
  final bool reverse;
  final bool showRawOutput;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      reverse: reverse,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 22),
      itemCount: messages.length + (isReplying ? 1 : 0),
      itemBuilder: (context, index) {
        final isReplyIndicator =
            isReplying && (reverse ? index == 0 : index == messages.length);
        if (isReplyIndicator) {
          return const SizedBox.shrink();
        }
        final messageIndex = reverse
            ? messages.length - 1 - (index - (isReplying ? 1 : 0))
            : index;
        final message = messages[messageIndex];
        return Align(
          alignment: message.isUser
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 520),
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              color: message.isUser
                  ? (glass
                        ? Colors.white.withValues(alpha: 0.20)
                        : const Color(0xFF2D796A))
                  : (glass
                        ? Colors.black.withValues(alpha: 0.18)
                        : const Color(0xFFE7E4DD)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.isUser || showRawOutput)
                  Text(
                    message.text,
                    style: TextStyle(
                      color: message.isUser
                          ? Colors.white
                          : (glass ? Colors.white : const Color(0xFF262521)),
                      height: 1.4,
                    ),
                  )
                else
                  _AssistantSegmentBody(response: message.text, glass: glass),
                if (message.attachments.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  _SentAttachmentLabels(
                    attachments: message.attachments,
                    glass: glass || message.isUser,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
