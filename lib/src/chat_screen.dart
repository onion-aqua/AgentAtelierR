import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:spine_flutter/spine_flutter.dart' hide Color;

import 'ai_services.dart';
import 'app_controller.dart';
import 'audio_envelope.dart';
import 'character_appearance.dart';
import 'character_camera.dart';
import 'character_expression.dart';
import 'character_performance.dart';
import 'chat_segments.dart';
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

class _ChatScreenState extends State<ChatScreen> {
  final _audioPlayer = AudioPlayer();
  final _effectPlayer = AudioPlayer();
  final _aiClient = OpenAiCompatibleClient();
  final _fishAudioClient = FishAudioClient();
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
  int _motionGeneration = 0;
  double _glassPanelFraction = 0.36;
  double? _stableBottomSafeInset;
  double? _stableBodyHeight;
  final List<ChatAttachment> _pendingAttachments = [];

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
        controller.animationState.getData().setDefaultMix(0.22);
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
    _resetMotionOverlays();
    _currentIdleAnimation = animation;
    spineController.animationState.setAnimationByName(0, animation, true);
    _scheduleIdleChange();
  }

  void _playOneShotAnimation(String animation) {
    final spineController = _spineController;
    if (!_spineReady ||
        spineController == null ||
        spineController.skeletonData.findAnimation(animation) == null) {
      return;
    }
    _resetMotionOverlays();
    spineController.animationState
      ..setAnimationByName(1, animation, false)
      ..addEmptyAnimation(1, 0.3, 0);
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

    _resetMotionOverlays();
    final generation = ++_motionGeneration;
    final state = spineController.animationState;
    state.clearTrack(1);
    spineController.skeleton.setSlotsToSetupPose();
    state.apply(spineController.skeleton);

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
      final entry =
          state.setAnimationByName(tracks[index], animation.name, false)
            ..setAlpha(animation.alpha)
            ..setTimeScale(animation.speed)
            // motion_add_* means an overlay track in the source project. Its
            // keyed transforms are absolute, so Spine's additive math would
            // apply the arm translation twice and stretch the mesh.
            ..setMixBlend(MixBlend.replace)
            ..setMixDuration(group.blendTime);
      final speed = animation.speed.abs() < 0.01 ? 1.0 : animation.speed.abs();
      final duration = entry.getAnimation().getDuration() / speed;
      if (duration > longestDuration) {
        longestDuration = duration;
        longestEntry = entry;
      }
    }
    longestEntry?.setListener((type, _, _) {
      if (type != EventType.complete || generation != _motionGeneration) return;
      _resetMotionOverlays();
    });
    _scheduleIdleChange();
  }

  void _resetMotionOverlays() {
    final spineController = _spineController;
    if (!_spineReady || spineController == null) return;
    _motionGeneration += 1;
    for (var track = 2; track <= 10; track++) {
      spineController.animationState.clearTrack(track);
    }
    spineController.skeleton.setSlotsToSetupPose();
    spineController.animationState.apply(spineController.skeleton);
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
    final phraseEnvelope = pow(sin(seconds * pi * 0.24).abs(), 1.8).toDouble();
    final nod =
        sin(seconds * pi * 0.82 + 0.25) *
        (1.15 + energy * 2.35) *
        (0.38 + phraseEnvelope * 0.62);
    final sway =
        sin(seconds * pi * 0.29 + 0.8) * (3.15 + energy * 1.25) +
        sin(seconds * pi * 0.11 + 1.9) * 0.84;
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
    head?.setRotation(head.getRotation() + nod + sway);
    neck?.setRotation(neck.getRotation() + nod * 0.45 - sway * 0.18);
    upperBody?.setRotation(upperBody.getRotation() + nod * 0.12 + sway * 0.16);
    lowerBody?.setRotation(lowerBody.getRotation() - nod * 0.05 - sway * 0.08);
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
    widget.controller.removeListener(_handleControllerChange);
    final cancellation = _speechCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    for (final path in _temporarySpeechPaths.toList()) {
      unawaited(_deleteTemporarySpeech(path));
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
        ..setAnimationByName(1, reaction.animation, false)
        ..addEmptyAnimation(1, 0.3, 0);
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
    await _audioPlayer.play(
      AssetSource(reaction.voiceAsset(_random.nextInt(3) + 1)),
    );
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
    });
    _scrollToBottom();

    if (!widget.controller.aiEnabled) {
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (!mounted) return;
      final reply = widget.controller.demoReply(text);
      widget.controller.addAssistantMessage(reply);
      await _playFishTtsIfConfigured(reply);
      if (mounted) setState(() => _isReplying = false);
      _scrollToBottom();
      return;
    }

    final apiKey = await _secretStore.readOpenAiKey();
    if (apiKey.isEmpty) {
      _stopSpeakingAnimation();
      widget.controller.addAssistantMessage('请先在设置中填写 OpenAI 兼容接口的 API Key。');
      if (mounted) setState(() => _isReplying = false);
      return;
    }

    widget.controller.beginAssistantStream();
    try {
      await for (final delta in _aiClient.streamChat(
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
      )) {
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
      final reply = widget.controller.messages.last.text;
      widget.controller.finishAssistantStream();
      await _playFishTtsIfConfigured(reply);
      if (widget.controller.longTermMemoryEnabled &&
          widget.controller.userMessageCount % 4 == 0) {
        unawaited(_refreshLongTermMemory(apiKey));
      }
    } on Object catch (error) {
      _stopSpeakingAnimation();
      widget.controller.failAssistantStream(error.toString());
    } finally {
      if (mounted) setState(() => _isReplying = false);
      _scrollToBottom();
    }
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

  Future<void> _playFishTtsIfConfigured(String text) async {
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
    final apiKey = await _secretStore.readFishAudioKey();
    if (apiKey.isEmpty || widget.controller.fishAudioReferenceId.isEmpty) {
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
    try {
      Future<_PreparedSpeech> pending = _prepareFishSpeech(
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
            ? _prepareFishSpeech(segments[index + 1], apiKey, generation)
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
        await _deleteTemporarySpeech(prepared.path);
        if (generation != _speechPlaybackGeneration) return;
        _stopSpeakingAnimation();
        if (next != null) pending = next;
      }
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
        const SnackBar(content: Text('Fish Audio 语音生成失败，文本回复不受影响')),
      );
    }
  }

  Future<_PreparedSpeech> _prepareFishSpeech(
    RyzaPerformanceSegment segment,
    String apiKey,
    int generation,
  ) async {
    // WAV keeps the PCM samples available for deterministic lip sync. The
    // format preference remains useful for the settings-page voice preview.
    final path = await _fishAudioClient.synthesize(
      apiKey: apiKey,
      referenceId: widget.controller.fishAudioReferenceId,
      model: widget.controller.fishAudioModel,
      format: 'wav',
      latency: widget.controller.fishAudioLatency,
      speed: widget.controller.fishAudioSpeed,
      text: segment.speechText,
    );
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
      final target = widget.controller.liquidGlassChatUi
          ? _scrollController.position.minScrollExtent
          : _scrollController.position.maxScrollExtent;
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
      backgroundColor: const Color(0xFFF8F6F1),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _ConversationSheet(
        messages: widget.controller.messages,
        isReplying: _isReplying,
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
                title: const Text('发送图片'),
                subtitle: const Text('JPG、PNG、WebP、GIF'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickAttachments(imagesOnly: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('发送文件'),
                subtitle: const Text('PDF、Office、文本和表格文件'),
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
      backgroundColor: const Color(0xFFF8F6F1),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _MotionPickerSheet(
        appearance: _appearance,
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
      backgroundColor: const Color(0xFFF8F6F1),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _AppearancePickerSheet(
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
      resizeToAvoidBottomInset: !usesLiquidGlass,
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
              if (usesLiquidGlass)
                Positioned(
                  top: mediaQuery.viewPadding.top,
                  left: 0,
                  right: 0,
                  height: liquidContentHeight,
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        _buildGlassChat(constraints, isWide, keyboardInset),
                  ),
                )
              else
                SafeArea(child: _buildClassicChat(isWide)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildClassicChat(bool isWide) {
    return Column(
      children: [
        _TopBar(
          sceneTime: widget.controller.sceneTime,
          onSceneChanged: widget.controller.setSceneTime,
          onMenuPressed: widget.onMenuPressed,
          onHistoryPressed: _showMessages,
        ),
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: isWide
                ? Row(
                    children: [
                      Expanded(flex: 6, child: _buildCharacter()),
                      Expanded(
                        flex: 4,
                        child: _DesktopConversation(
                          messages: widget.controller.messages,
                          isReplying: _isReplying,
                          scrollController: _scrollController,
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(child: _buildCharacter()),
                      _LatestReply(message: widget.controller.messages.last),
                    ],
                  ),
          ),
        ),
        _Composer(
          controller: _inputController,
          enabled: !_isReplying,
          showMicrophone: widget.controller.showMicrophoneButton,
          attachments: _pendingAttachments,
          onAddAttachment: _showAttachmentPicker,
          onRemoveAttachment: (attachment) {
            setState(() => _pendingAttachments.remove(attachment));
          },
          onSubmitted: (_) => _sendMessage(),
          onSend: _sendMessage,
        ),
      ],
    );
  }

  Widget _buildGlassChat(
    BoxConstraints constraints,
    bool isWide,
    double keyboardInset,
  ) {
    final panelHeight = (constraints.maxHeight * _glassPanelFraction).clamp(
      176.0,
      constraints.maxHeight * 0.62,
    );
    final panelWidth = isWide ? 540.0 : constraints.maxWidth - 20;
    return Stack(
      fit: StackFit.expand,
      children: [
        Column(
          children: [
            _TopBar(
              sceneTime: widget.controller.sceneTime,
              onSceneChanged: widget.controller.setSceneTime,
              onMenuPressed: widget.onMenuPressed,
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
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          right: isWide ? 18 : 10,
          bottom: 8 + keyboardInset,
          width: panelWidth,
          height: panelHeight,
          child: _LiquidGlassConversation(
            messages: widget.controller.messages,
            isReplying: _isReplying,
            scrollController: _scrollController,
            inputController: _inputController,
            enabled: !_isReplying,
            showMicrophone: widget.controller.showMicrophoneButton,
            attachments: _pendingAttachments,
            onAddAttachment: _showAttachmentPicker,
            onRemoveAttachment: (attachment) {
              setState(() => _pendingAttachments.remove(attachment));
            },
            onSubmitted: (_) => _sendMessage(),
            onSend: _sendMessage,
            onDragUpdate: (delta) {
              setState(() {
                _glassPanelFraction =
                    (_glassPanelFraction - delta / constraints.maxHeight).clamp(
                      0.22,
                      0.62,
                    );
              });
            },
          ),
        ),
      ],
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
        const Positioned(left: 16, bottom: 10, child: _CharacterLabel()),
        Positioned(
          right: 16,
          top: 10,
          child: Column(
            children: [
              _CharacterToolButton(
                tooltip: '动作',
                icon: Icons.animation_outlined,
                onPressed: _showMotionPicker,
              ),
              const SizedBox(height: 8),
              _CharacterToolButton(
                tooltip: '服装',
                icon: Icons.checkroom_outlined,
                onPressed: _showAppearancePicker,
              ),
            ],
          ),
        ),
        if (_lastTappedPart case final part?)
          Positioned(right: 16, bottom: 10, child: _TapResultLabel(part: part)),
        if (!_appearance.animated)
          const Positioned(
            right: 16,
            bottom: 10,
            child: _StaticAppearanceLabel(),
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
    required this.sceneTime,
    required this.onSceneChanged,
    required this.onMenuPressed,
    required this.onHistoryPressed,
  });

  final SceneTime sceneTime;
  final ValueChanged<SceneTime> onSceneChanged;
  final VoidCallback onMenuPressed;
  final VoidCallback onHistoryPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          _RoundIcon(
            icon: Icons.menu_rounded,
            tooltip: '菜单',
            onPressed: onMenuPressed,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '莱莎',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '在线 · 本地原型',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          PopupMenuButton<SceneTime>(
            tooltip: '切换场景时间',
            initialValue: sceneTime,
            onSelected: onSceneChanged,
            itemBuilder: (context) => SceneTime.values
                .map(
                  (value) => PopupMenuItem(
                    value: value,
                    child: Row(
                      children: [
                        Icon(value.icon, size: 19),
                        const SizedBox(width: 10),
                        Text(value.label),
                      ],
                    ),
                  ),
                )
                .toList(),
            child: _StatusPill(icon: sceneTime.icon, label: sceneTime.label),
          ),
          const SizedBox(width: 8),
          _RoundIcon(
            icon: Icons.forum_outlined,
            tooltip: '对话记录',
            onPressed: onHistoryPressed,
          ),
        ],
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.tooltip, this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      onPressed: onPressed ?? () {},
      tooltip: tooltip,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(42),
        backgroundColor: Colors.black.withValues(alpha: 0.24),
        foregroundColor: Colors.white,
      ),
      icon: Icon(icon, size: 21),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 7),
          Text(label, style: const TextStyle(color: Colors.white)),
          const SizedBox(width: 2),
          const Icon(Icons.arrow_drop_down, color: Colors.white70, size: 18),
        ],
      ),
    );
  }
}

class _CharacterToolButton extends StatelessWidget {
  const _CharacterToolButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xCC1F211F),
      borderRadius: BorderRadius.circular(6),
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        icon: Icon(icon),
        color: Colors.white,
        iconSize: 21,
      ),
    );
  }
}

class _MotionPickerSheet extends StatelessWidget {
  const _MotionPickerSheet({
    required this.appearance,
    required this.currentIdleAnimation,
    required this.onIdleSelected,
    required this.onOneShotSelected,
    required this.onMotionGroupSelected,
  });

  final CharacterAppearance appearance;
  final String? currentIdleAnimation;
  final ValueChanged<String> onIdleSelected;
  final ValueChanged<String> onOneShotSelected;
  final ValueChanged<CharacterMotionGroup> onMotionGroupSelected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '角色动作',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: '关闭',
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
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.loop),
                    title: Text(motionDisplayName(animation)),
                    subtitle: Text(animation),
                    trailing: animation == currentIdleAnimation
                        ? const Icon(Icons.check, color: Color(0xFF2D796A))
                        : const Icon(Icons.play_arrow),
                    onTap: () {
                      onIdleSelected(animation);
                      Navigator.pop(context);
                    },
                  ),
                const _MotionSectionLabel(title: '一次性动作', count: 12),
                for (final animation in characterOneShotAnimations)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.motion_photos_on_outlined),
                    title: Text(motionDisplayName(animation)),
                    subtitle: Text(animation),
                    trailing: const Icon(Icons.play_arrow),
                    onTap: () {
                      onOneShotSelected(animation);
                      Navigator.pop(context);
                    },
                  ),
                FutureBuilder<List<CharacterMotionGroup>>(
                  future: loadCharacterMotionGroups(appearance),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return const ListTile(
                        leading: Icon(Icons.error_outline),
                        title: Text('叠加动作配置读取失败'),
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
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.layers_outlined),
                            title: Text(
                              group.label.isEmpty ? group.id : group.label,
                            ),
                            subtitle: Text(
                              '${group.occupancy} · ${group.animation1}',
                            ),
                            trailing: const Icon(Icons.play_arrow),
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
    required this.selectedId,
    required this.onSelected,
  });

  final String selectedId;
  final ValueChanged<CharacterAppearance> onSelected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
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
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            for (final appearance in characterAppearances)
              ListTile(
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
                title: Text(appearance.label),
                subtitle: Text(
                  appearance.animated ? '完整 Spine 动画资源' : '原包静态预览资源',
                ),
                trailing: appearance.id == selectedId
                    ? const Icon(Icons.check_circle, color: Color(0xFF2D796A))
                    : Icon(
                        appearance.animated
                            ? Icons.animation_outlined
                            : Icons.image_outlined,
                      ),
                onTap: () => onSelected(appearance),
              ),
          ],
        ),
      ),
    );
  }
}

class _CharacterLabel extends StatelessWidget {
  const _CharacterLabel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xCC1F211F),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.touch_app_outlined, color: Colors.white70, size: 16),
          SizedBox(width: 6),
          Text('点击互动', style: TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }
}

class _StaticAppearanceLabel extends StatelessWidget {
  const _StaticAppearanceLabel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xCC1F211F),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_outlined, color: Colors.white70, size: 16),
          SizedBox(width: 6),
          Text('静态服装', style: TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }
}

class _TapResultLabel extends StatelessWidget {
  const _TapResultLabel({required this.part});

  final String part;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xDD2D796A),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '触发：$part',
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }
}

class _LiquidGlassConversation extends StatelessWidget {
  const _LiquidGlassConversation({
    required this.messages,
    required this.isReplying,
    required this.scrollController,
    required this.inputController,
    required this.enabled,
    required this.showMicrophone,
    required this.attachments,
    required this.onAddAttachment,
    required this.onRemoveAttachment,
    required this.onSubmitted,
    required this.onSend,
    required this.onDragUpdate,
  });

  final List<ChatMessage> messages;
  final bool isReplying;
  final ScrollController scrollController;
  final TextEditingController inputController;
  final bool enabled;
  final bool showMicrophone;
  final List<ChatAttachment> attachments;
  final VoidCallback onAddAttachment;
  final ValueChanged<ChatAttachment> onRemoveAttachment;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onSend;
  final ValueChanged<double> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          top: 18,
          child: _LiquidGlassSurface(
            child: Column(
              children: [
                Expanded(
                  child: _GlassMessageList(
                    messages: messages,
                    isReplying: isReplying,
                    controller: scrollController,
                  ),
                ),
                Container(
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.2),
                ),
                _GlassComposer(
                  controller: inputController,
                  enabled: enabled,
                  showMicrophone: showMicrophone,
                  attachments: attachments,
                  onAddAttachment: onAddAttachment,
                  onRemoveAttachment: onRemoveAttachment,
                  onSubmitted: onSubmitted,
                  onSend: onSend,
                ),
              ],
            ),
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
              child: const _GlassDragHandle(),
            ),
          ),
        ),
      ],
    );
  }
}

class _LiquidGlassSurface extends StatelessWidget {
  const _LiquidGlassSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(18));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x52000000),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.24),
                  const Color(0xFF3B2F2A).withValues(alpha: 0.46),
                  const Color(0xFF171514).withValues(alpha: 0.54),
                ],
              ),
              borderRadius: radius,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.34),
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _GlassDragHandle extends StatelessWidget {
  const _GlassDragHandle();

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.72),
            border: Border.all(color: Colors.white.withValues(alpha: 0.86)),
            boxShadow: const [
              BoxShadow(color: Color(0x33000000), blurRadius: 10),
            ],
          ),
          child: const Icon(
            Icons.unfold_more_rounded,
            size: 23,
            color: Color(0xFF4A2F28),
          ),
        ),
      ),
    );
  }
}

class _GlassMessageList extends StatelessWidget {
  const _GlassMessageList({
    required this.messages,
    required this.isReplying,
    required this.controller,
  });

  final List<ChatMessage> messages;
  final bool isReplying;
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
      itemCount: visibleMessages.length + (isReplying ? 1 : 0),
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.2)),
      itemBuilder: (context, index) {
        if (isReplying && index == 0) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                SizedBox(width: 10),
                Text('莱莎正在回复…', style: TextStyle(color: Colors.white70)),
              ],
            ),
          );
        }
        final replyOffset = isReplying ? 1 : 0;
        final messageIndex = visibleMessages.length - 1 - (index - replyOffset);
        final message = visibleMessages[messageIndex];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.24),
                  ),
                ),
                child: Icon(
                  message.isUser
                      ? Icons.person_outline_rounded
                      : Icons.auto_awesome_rounded,
                  size: 16,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message.isUser ? '你' : '莱莎',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _glassMessageText(message),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        height: 1.35,
                      ),
                    ),
                    if (message.attachments.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      _SentAttachmentLabels(
                        attachments: message.attachments,
                        glass: true,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String _glassMessageText(ChatMessage message) {
  if (message.isUser) return message.text;
  return displayTextForAssistantResponse(message.text)
      .replaceAll(RegExp(r'^\s*(旁白|莱莎)\s*[：:]\s*', multiLine: true), '')
      .trim();
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
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 6),
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final attachment = attachments[index];
          return InputChip(
            avatar: Icon(
              attachment.isImage
                  ? Icons.image_outlined
                  : Icons.description_outlined,
              size: 17,
              color: glass ? Colors.white : const Color(0xFF2D796A),
            ),
            label: Text(
              '${attachment.name} · ${_attachmentSizeLabel(attachment.size)}',
              overflow: TextOverflow.ellipsis,
            ),
            labelStyle: TextStyle(
              color: glass ? Colors.white : const Color(0xFF262521),
              fontSize: 11,
            ),
            backgroundColor: glass
                ? Colors.white.withValues(alpha: 0.13)
                : const Color(0xFFE7E4DD),
            side: BorderSide(color: glass ? Colors.white24 : Colors.black12),
            deleteIconColor: glass ? Colors.white70 : Colors.black54,
            onDeleted: () => onRemove(attachment),
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
                Icon(
                  attachment.isImage
                      ? Icons.image_outlined
                      : Icons.description_outlined,
                  size: 15,
                  color: foreground,
                ),
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

class _GlassComposer extends StatelessWidget {
  const _GlassComposer({
    required this.controller,
    required this.enabled,
    required this.showMicrophone,
    required this.attachments,
    required this.onAddAttachment,
    required this.onRemoveAttachment,
    required this.onSubmitted,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool showMicrophone;
  final List<ChatAttachment> attachments;
  final VoidCallback onAddAttachment;
  final ValueChanged<ChatAttachment> onRemoveAttachment;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onSend;

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
                  tooltip: '语音输入（待接入）',
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
                    enabled: enabled,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.send,
                    onSubmitted: onSubmitted,
                    style: const TextStyle(color: Colors.white),
                    cursorColor: Colors.white,
                    decoration: InputDecoration(
                      hintText: enabled ? '和莱莎说点什么…' : '莱莎正在回复…',
                      hintStyle: const TextStyle(color: Colors.white60),
                      border: InputBorder.none,
                      suffixIcon: IconButton(
                        onPressed: enabled ? onAddAttachment : null,
                        tooltip: '添加图片或文件',
                        color: Colors.white,
                        icon: const Icon(Icons.add_rounded, size: 30),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: enabled ? onSend : null,
                tooltip: '发送',
                style: IconButton.styleFrom(
                  fixedSize: const Size.square(46),
                  backgroundColor: const Color(0xFFF65C2D),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.white24,
                  disabledForegroundColor: Colors.white54,
                ),
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LatestReply extends StatelessWidget {
  const _LatestReply({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 74, maxHeight: 112),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xEEFBF9F4),
        borderRadius: BorderRadius.circular(8),
        border: const Border(
          left: BorderSide(color: Color(0xFF2D796A), width: 4),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x29000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message.isUser ? '你' : '莱莎',
            style: const TextStyle(
              color: Color(0xFF2D796A),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Flexible(
            child: Text(
              message.isUser
                  ? message.text
                  : displayTextForAssistantResponse(message.text),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.showMicrophone,
    required this.attachments,
    required this.onAddAttachment,
    required this.onRemoveAttachment,
    required this.onSubmitted,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool showMicrophone;
  final List<ChatAttachment> attachments;
  final VoidCallback onAddAttachment;
  final ValueChanged<ChatAttachment> onRemoveAttachment;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF8F6F1),
      elevation: 12,
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 7, 12, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (attachments.isNotEmpty)
                    _PendingAttachmentBar(
                      attachments: attachments,
                      onRemove: onRemoveAttachment,
                      glass: false,
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (showMicrophone) ...[
                        IconButton(
                          onPressed: () {},
                          tooltip: '语音输入（待接入）',
                          icon: const Icon(Icons.mic_none_rounded),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Container(
                          constraints: const BoxConstraints(
                            minHeight: 46,
                            maxHeight: 108,
                          ),
                          padding: const EdgeInsets.only(left: 14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFECEAE5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: TextField(
                            controller: controller,
                            enabled: enabled,
                            minLines: 1,
                            maxLines: 4,
                            textInputAction: TextInputAction.send,
                            onSubmitted: onSubmitted,
                            decoration: InputDecoration(
                              hintText: enabled ? '和莱莎说点什么…' : '莱莎正在回复…',
                              suffixIcon: IconButton(
                                onPressed: enabled ? onAddAttachment : null,
                                tooltip: '添加图片或文件',
                                icon: const Icon(Icons.add_rounded, size: 30),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: enabled ? onSend : null,
                        tooltip: '发送',
                        style: IconButton.styleFrom(
                          fixedSize: const Size.square(46),
                        ),
                        icon: const Icon(Icons.arrow_upward_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopConversation extends StatelessWidget {
  const _DesktopConversation({
    required this.messages,
    required this.isReplying,
    required this.scrollController,
  });

  final List<ChatMessage> messages;
  final bool isReplying;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 18, 18, 18),
      decoration: BoxDecoration(
        color: const Color(0xE6F8F6F1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: _MessageList(
        messages: messages,
        isReplying: isReplying,
        controller: scrollController,
      ),
    );
  }
}

class _ConversationSheet extends StatefulWidget {
  const _ConversationSheet({required this.messages, required this.isReplying});

  final List<ChatMessage> messages;
  final bool isReplying;

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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '对话记录',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 12, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '显示原始输出',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                Switch.adaptive(
                  value: _showRawOutput,
                  onChanged: (value) {
                    setState(() => _showRawOutput = value);
                  },
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
            ),
          ),
        ],
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
  });

  final List<ChatMessage> messages;
  final bool isReplying;
  final ScrollController? controller;
  final bool reverse;
  final bool showRawOutput;

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
          return const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
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
                  ? const Color(0xFF2D796A)
                  : const Color(0xFFE7E4DD),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message.isUser
                      ? message.text
                      : conversationTextForAssistantResponse(
                          message.text,
                          showRawOutput: showRawOutput,
                        ),
                  style: TextStyle(
                    color: message.isUser
                        ? Colors.white
                        : const Color(0xFF262521),
                    height: 1.4,
                  ),
                ),
                if (message.attachments.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  _SentAttachmentLabels(
                    attachments: message.attachments,
                    glass: message.isUser,
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
