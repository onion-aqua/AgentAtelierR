import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:spine_flutter/spine_flutter.dart' hide Color;

import 'ai_services.dart';
import 'continuous_asmr_page.dart';
import 'auxiliary_llm_tasks.dart';
import 'performance_planner.dart';
import 'independent_performance_tools.dart';
import 'motion_recipe.dart';
import 'speech_planner.dart';
import 'app_controller.dart';
import 'conversation_collection_store.dart';
import 'swipe_collection_selection.dart';
import 'voice_playback_progress.dart';
import 'narration_composer_fields.dart';
import 'app_theme.dart';
import 'app_localization.dart';
import 'attachment_thumbnail_store.dart';
import 'audio_envelope.dart';
import 'speech_envelope_loader.dart';
import 'character_speech_driver.dart';
import 'character_resource_behavior.dart';
import 'character_motion_dynamics.dart';
import 'character_motion_layers.dart';
import 'character_track_transition.dart';
import 'character_idle_behavior.dart';
import 'character_posture.dart';
import 'memory_refresh_gate.dart';
import 'mimo_tts_client.dart';
import 'protected_character_assets.dart';
import 'device_agent_tools.dart';
import 'character_appearance.dart';
import 'character_catalog.dart';
import 'character_camera.dart';
import 'character_expression.dart';
import 'character_gaze.dart';
import 'scene_backdrop_bounds.dart';
import 'character_performance.dart';
import 'character_performance_queue.dart';
import 'chat_segments.dart';
import 'frame_rate_controller.dart';
import 'glass_ui.dart';
import 'folding_button_group.dart';
import 'local_save_dialog.dart';
import 'stage_environment_catalog.dart';
import 'runtime_log.dart';
import 'ryza_loading_indicator.dart';
import 'tap_reaction.dart';
import 'tts_text_normalizer.dart';
import 'skin_import_controls.dart';
import 'character_spine_view.dart';

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

Rect conversationPanelBounds({
  required Size viewport,
  required double keyboardInset,
  required double fraction,
  bool fullscreen = false,
}) {
  final width = max(0.0, viewport.width);
  final height = max(0.0, viewport.height);
  final inset = keyboardInset.clamp(0.0, height).toDouble();
  final margin = fullscreen ? 0.0 : min(8.0, (height - inset) / 4);
  final available = max(0.0, height - inset - margin);
  final compact = width < 360 || height < 500;
  final maxHeight = min(available, height * (compact ? 0.85 : 0.68));
  final panelHeight = fullscreen
      ? available
      : (height * fraction).clamp(min(176.0, maxHeight), maxHeight).toDouble();
  final side = fullscreen
      ? 0.0
      : (width >= 720 ? 18.0 : (compact ? 6.0 : 10.0));
  final panelWidth = fullscreen
      ? width
      : min(width >= 720 ? 540.0 : width, max(0.0, width - side * 2));
  return Rect.fromLTWH(
    width - side - panelWidth,
    height - inset - margin - panelHeight,
    panelWidth,
    panelHeight,
  );
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
    this.pageActive = true,
    super.key,
    required this.controller,
    required this.onMenuPressed,
    required this.onShopPressed,
    required this.hideUi,
    this.onFullscreenChanged,
    this.onCharacterReady,
    this.onCharacterLoadFailed,
  });

  final AppController controller;
  final VoidCallback onMenuPressed;
  final VoidCallback onShopPressed;
  final bool hideUi;
  final ValueChanged<bool>? onFullscreenChanged;
  final VoidCallback? onCharacterReady;
  final VoidCallback? onCharacterLoadFailed;
  final bool pageActive;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _PreparedSpeech {
  const _PreparedSpeech({required this.path, required this.envelope});

  final String path;
  final AudioAmplitudeEnvelope? envelope;
}

class _SuspendedMotionGroup {
  const _SuspendedMotionGroup({
    required this.group,
    required this.remaining,
    required this.trackTimes,
    required this.tracks,
  });

  final CharacterMotionGroup group;
  final Duration remaining;
  final Map<int, double> trackTimes;
  final Set<int> tracks;
}

class _CachedSpeechSegment {
  const _CachedSpeechSegment({
    this.text = '',
    this.expressionIntensity = 'normal',
    required this.path,
    required this.envelope,
    required this.expression,
    required this.action,
    this.posture,
    this.motionGroupIds = const [],
  });

  final String path;
  final String text;
  final String expressionIntensity;
  final AudioAmplitudeEnvelope? envelope;
  final CharacterExpression? expression;
  final CharacterAction? action;
  final String? posture;
  final List<String> motionGroupIds;

  _CachedSpeechSegment withPerformance(RyzaPerformanceSegment segment) =>
      _CachedSpeechSegment(
        text: text,
        path: path,
        envelope: envelope,
        expression: segment.expression,
        expressionIntensity: segment.expressionIntensity,
        action: segment.action,
        posture: segment.posture,
        motionGroupIds: segment.motionGroupIds,
      );
}

class _ChatScreenState extends State<ChatScreen> {
  final _audioPlayer = AudioPlayer();
  final _effectPlayer = AudioPlayer();
  late final _aiClient = OpenAiCompatibleClient(
    contextToolExecutor: (name, args) async =>
        widget.controller.queryContextTool(name, args),
    agentToolExecutor: const DeviceAgentTools().execute,
  );
  final _fishAudioClient = FishAudioClient();
  final _dashScopeTtsClient = DashScopeTtsClient();
  final _genericTtsClient = GenericTtsClient();
  final _mimoTtsClient = MimoTtsClient();
  final _secretStore = const SecretStore();
  final _inputController = TextEditingController();
  final _narrationInputController = TextEditingController();
  final _narrationBottomInputController = TextEditingController();
  final _scrollController = ScrollController();
  final _latestAssistantMessageKey = GlobalKey();
  final _random = Random();
  SpineWidgetController? _spineController;
  late Future<ProtectedCharacterAssetBundle> _appearanceBundleFuture;
  late final SpineWidgetController _seatObjectController;
  late CharacterAppearance _appearance;
  Timer? _idleTimer;
  Timer? _tapReactionTimer;
  Timer? _microMotionTimer;
  Timer? _facialDetailTimer;
  Timer? _blinkTimer;
  Timer? _blinkRestoreTimer;
  Timer? _suggestionQuotaTimer;
  StreamSubscription<Duration>? _audioPositionSubscription;
  String? _currentIdleAnimation;
  String? _activePoseType;
  final _postureState = CharacterPostureState();
  String? _lastPostureCue;

  String get _sittingId =>
      _appearance.isStanding ? 'standing' : _postureState.sittingId;

  CharacterMotionGroup? get _crossLeggedGroup => crossLeggedPostureGroup(
    _motionGroups,
    standing: _appearance.isStanding,
    pose: _currentIdleAnimation,
    hasAnimation: (name) =>
        _spineController?.skeletonData.findAnimation(name) != null,
  );

  void _selectPosture(String id, {bool byUser = false}) {
    final group = _crossLeggedGroup;
    if (!_spineReady || _tapReactionActive || _appearance.isStanding) return;
    if (!_postureState.select(
      id,
      supported: id == 'sitting_normal' || group != null,
      byUser: byUser,
    )) {
      return;
    }
    _clearPerformanceQueue();
    _resetMotionOverlays(mixDuration: 0.6);
    final state = _spineController!.animationState;
    if (id == 'sitting_agura') {
      state.setAnimationByName(3, group!.animation1, true)
        ..setMixBlend(MixBlend.replace)
        ..setAlpha(group.alpha1)
        ..setTimeScale(group.speed1)
        ..setMixDuration(max(0.6, group.blendTime));
    } else {
      state.setEmptyAnimation(3, 0.6);
    }
    widget.controller.frameRate.boost(
      FrameRateActivity.characterMotion,
      duration: const Duration(seconds: 2),
    );
  }

  bool _spineReady = false;
  bool _isReplying = false;
  bool _isContinuing = false;
  bool _isSuggestingReply = false;
  bool _isCharacterSpeaking = false;
  bool _tapReactionActive = false;
  Offset? _gazePointer;
  DateTime? _gazeStartedAt;
  bool _gazeHeld = false;
  final _bodyGaze = CharacterBodyGaze();
  CharacterExpression _currentExpression = CharacterExpression.neutral;
  CharacterFacialDetail? _activeFacialDetail;
  CharacterResourceBehavior _resourceBehavior = CharacterResourceBehavior.parse(
    '{}',
  );
  ResourceExpressionSet? _activeResourceExpression;
  List<String> _activeResourceEffects = const [];
  bool _speechBlinkClosed = false;
  CharacterBlinkBeat _blinkBeat = const CharacterBlinkBeat(
    gap: 3,
    closedFor: 0.12,
    fast: false,
  );
  DateTime? _motionBusyUntil;
  String? _activeMotionGroupId;
  final _motionLayers = CharacterMotionLayers();
  final _motionReleaseTimers = <int, Timer>{};
  final _activeMotionVariants = <int, CharacterMotionGroup>{};
  List<_SuspendedMotionGroup> _tapSuspendedMotions = const [];
  int _tapSuspendedMotionLoadGeneration = 0;
  String? _windAnimationName;
  CharacterWindEnvelope _windEnvelope = CharacterWindEnvelope();
  // 0 base, 1 tap, 2–10 gestures, 11–16 face. Wind never owns pose bones.
  static const _windTrack = 17;
  List<CharacterMotionGroup> _motionGroups = const [];
  List<MotionRecipe> _motionRecipes = const [];
  Set<String> _recipeAnimationNames = const {};
  final List<String> _recentAmbientGroupIds = <String>[];
  int _motionLoadGeneration = 0;
  String? _lastPerformanceActionKey;
  DateTime? _lastSemanticActionAt;
  final Stopwatch _speechStopwatch = Stopwatch();
  AudioAmplitudeEnvelope? _activeSpeechEnvelope;
  TrackEntry? _lipSyncEntry;
  double _currentSpeechEnergy = 0;
  CharacterPerformanceDirector _performanceDirector =
      CharacterPerformanceDirector(CharacterPerformanceProfile.fallback());
  final Stopwatch _positionClock = Stopwatch();
  Duration _playbackPosition = Duration.zero;
  bool _syntheticSpeech = false;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  final Map<String, ({double x, double y, double rotation})> _rigBase = {};
  int _speechPlaybackGeneration = 0;
  Completer<void>? _speechCancellation;
  final Set<String> _temporarySpeechPaths = <String>{};
  List<_CachedSpeechSegment> _lastSpeech = const [];
  String? _lastSpeechSource;
  String? _lastSpeechPerformance;
  bool _regeneratingSpeech = false;
  bool _selectingCollection = false;
  bool _savingCollection = false;
  final Map<String, Set<String>> _collectionSelection = {};
  Set<String> _availableCollectionVoices = {};

  Future<void> _toggleCollection() async {
    if (_savingCollection) return;
    setState(() => _savingCollection = true);
    try {
      final store = await ConversationCollectionStore.open();
      if (!_selectingCollection) {
        final keys = await store.availableVoiceKeys();
        if (!mounted) return;
        setState(() {
          _availableCollectionVoices = keys;
          _collectionSelection.clear();
          _selectingCollection = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.controller.interfaceLanguage.text(
                '右滑自动选择对话和已有语音，左滑取消；再次点击收藏按钮保存。',
                'Swipe a message right to select it. Cached audio is included automatically; tap the collection button again to save.',
                '会話を右にスワイプして選択。保存済み音声も含めます。もう一度ボタンを押して保存。',
              ),
            ),
          ),
        );
      } else {
        final selections = [
          for (final message in widget.controller.messages)
            if (_collectionSelection[message.collectionKey]?.isNotEmpty ??
                false)
              <String, dynamic>{
                'key': message.collectionKey,
                'text': _glassMessageText(message),
                'sourceText': message.text,
                'isUser': message.isUser,
                'saveText': _collectionSelection[message.collectionKey]!
                    .contains('text'),
                'saveVoice': _collectionSelection[message.collectionKey]!
                    .contains('voice'),
              },
        ];
        if (selections.isNotEmpty) {
          if (!mounted) return;
          final language = widget.controller.interfaceLanguage;
          var draftName = '';
          final formKey = GlobalKey<FormState>();
          final name = await showDialog<String>(
            context: context,
            builder: (dialogContext) {
              void save() {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(dialogContext, draftName.trim());
                }
              }

              return AlertDialog(
                title: Text(
                  language.text('收藏名称', 'Collection name', 'お気に入りの名前'),
                ),
                content: Form(
                  key: formKey,
                  child: TextFormField(
                    autofocus: true,
                    maxLength: 60,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      hintText: language.text(
                        '为这份收藏起个名字',
                        'Name this collection',
                        '名前を入力してください',
                      ),
                    ),
                    onChanged: (value) => draftName = value,
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? language.text(
                            '请输入收藏名称',
                            'Please enter a name',
                            '名前を入力してください',
                          )
                        : null,
                    onFieldSubmitted: (_) => save(),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(
                      language.text(
                        '取消收藏',
                        'Cancel collection',
                        'お気に入り登録をキャンセル',
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: save,
                    child: Text(language.text('保存', 'Save', '保存')),
                  ),
                ],
              );
            },
          );
          if (!mounted) return;
          if (name == null) {
            setState(() {
              _selectingCollection = false;
              _collectionSelection.clear();
            });
            return;
          }
          await store.collect(selections, name: name);
        }
        if (!mounted) return;
        setState(() => _selectingCollection = false);
        if (selections.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                widget.controller.interfaceLanguage.text(
                  '已保存至设置 → 数据管理 → 语音和文字收藏',
                  'Saved to Settings → Local data → Collections',
                  '設定 → データ管理 → お気に入りに保存しました',
                ),
              ),
            ),
          );
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _savingCollection = false);
    }
  }

  int _motionGeneration = 0;
  int _replyGeneration = 0;
  final _memoryRefreshGate = MemoryRefreshGate();
  Future<void> Function()? _pendingMemoryRefresh;
  ChatMessage? _lastConsolidatedUser;
  String _previousSpeechEmotion = 'relaxed';
  int _suggestionGeneration = 0;
  late int _observedDataRevision;
  int? _activeAssistantSegmentIndex;
  Duration _activeSegmentDisplayDuration = Duration.zero;
  StreamIterator<String>? _replyIterator;
  // Start at the same minimum as the drag handle, regardless of saved text.
  // Sending a new message still restores automatic sizing below.
  double? _manualPanelFraction = 0.22;
  double? _lockedPanelFraction;
  Size? _lastChatViewport;
  final List<ChatAttachment> _pendingAttachments = [];
  bool _characterToolsExpanded = false;
  bool _showScrollToBottomIndicator = false;
  bool _conversationFullscreen = false;

  CharacterResourceEmotionProfile? get _resourceEmotion =>
      _resourceBehavior.profile(_currentExpression.name, _expressionIntensity);
  String _expressionIntensity = 'normal';

  bool get _motionBusy =>
      _motionBusyUntil != null && DateTime.now().isBefore(_motionBusyUntil!);

  @override
  void initState() {
    super.initState();
    _appearance = characterAppearanceById(
      widget.controller.selectedCharacterAppearanceId,
    );
    _appearanceBundleFuture = ProtectedCharacterAssets.bundleFor(
      _appearance.assetName,
    );
    _observedDataRevision = widget.controller.dataRevision;
    if (_appearance.animated) {
      _spineController = _createSpineController(_appearance);
    }
    _seatObjectController = SpineWidgetController(
      targetFramesPerSecond:
          widget.controller.frameRate.effectiveFramesPerSecond,
      onInitialized: (controller) {
        // The object has no gameplay animation; keep its setup pose.
        controller.animationState.getData().setDefaultMix(0.2);
      },
    );
    _audioPositionSubscription = _audioPlayer.onPositionChanged.listen(
      _updateLipSyncFromPlaybackPosition,
    );
    _playerStateSubscription = _audioPlayer.onPlayerStateChanged.listen((
      state,
    ) {
      if (state == PlayerState.playing && _isCharacterSpeaking) {
        _positionClock.start();
      } else {
        _positionClock.stop();
      }
    });
    _inputController.addListener(_recordUserActivity);
    _narrationInputController.addListener(_recordUserActivity);
    _narrationBottomInputController.addListener(_recordUserActivity);
    widget.controller.addListener(_handleControllerChange);
    widget.controller.frameRate.addListener(_handleFrameRateChange);
    _scrollController.addListener(_handleConversationScroll);
    _suggestionQuotaTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _checkIdleUser();
      if (mounted && !widget.controller.continuousAsmr) setState(() {});
    });
  }

  SpineWidgetController _createSpineController(CharacterAppearance appearance) {
    late final SpineWidgetController spineController;
    spineController = SpineWidgetController(
      targetFramesPerSecond:
          widget.controller.frameRate.effectiveFramesPerSecond,
      onBeforeUpdateWorldTransforms: _restoreProceduralRig,
      onBeforeApplyAnimation: _prepareSpeechFrame,
      onAfterApplyAnimation: _applySpeakingHeadMotion,
      maxDeltaTime: 0.05,
      paintOverflow: const EdgeInsets.only(top: 160),
      onInitialized: (controller) {
        // fromDrawable initializes synchronously while its parent is building.
        // A skin may also be replaced before this frame has finished.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !identical(spineController, _spineController)) return;
          controller.animationState.getData().setDefaultMix(0.38);
          _currentIdleAnimation = appearance.idleAnimations.first;
          controller.animationState.setAnimationByName(
            0,
            _currentIdleAnimation!,
            true,
          );

          _scheduleIdleChange();
          setState(() => _spineReady = true);
          _applyExpression(_currentExpression);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                _spineReady &&
                identical(spineController, _spineController)) {
              widget.onCharacterReady?.call();
            }
          });
          if (_isCharacterSpeaking) {
            _scheduleFacialDetailChange();
            _scheduleCharacterBlink();
          }
          unawaited(_loadMotionGroups(appearance));
        });
      },
    );
    return spineController;
  }

  void _handleFrameRateChange() {
    final target = widget.controller.frameRate.effectiveFramesPerSecond;
    _spineController?.targetFramesPerSecond = target;
    _seatObjectController.targetFramesPerSecond = target;
  }

  void _handleControllerChange({bool forceAppearanceReload = false}) {
    _syncBackgroundVoicePolicy();
    if (_observedDataRevision != widget.controller.dataRevision) {
      _selectingCollection = false;
      _collectionSelection.clear();
      _observedDataRevision = widget.controller.dataRevision;
      _resetConversationWorkForDataReplacement();
    }
    if (!widget.controller.gazeTrackingEnabled) _endGaze();
    final next = characterAppearanceById(
      widget.controller.selectedCharacterAppearanceId,
    );
    if (next.id == _appearance.id && !forceAppearanceReload) return;
    _clearPerformanceQueue();
    _lipSyncEntry = null;
    _gazeHeld = false;
    _gazePointer = null;
    _gazeStartedAt = null;
    _bodyGaze.reset();
    widget.controller.frameRate.setActivity(
      FrameRateActivity.characterMotion,
      false,
    );
    _rigBase.clear();
    _performanceDirector = CharacterPerformanceDirector(
      CharacterPerformanceProfile.fallback(),
    );
    _resourceBehavior = CharacterResourceBehavior.parse('{}');
    _windAnimationName = null;
    _windEnvelope = CharacterWindEnvelope();
    _activeMotionGroupId = null;
    _activePoseType = null;
    _motionLayers.clear();
    _activeMotionVariants.clear();
    _tapSuspendedMotions = const [];
    for (final timer in _motionReleaseTimers.values) {
      timer.cancel();
    }
    _motionReleaseTimers.clear();
    _activeResourceExpression = null;
    _activeFacialDetail = null;
    _motionBusyUntil = null;
    _speechBlinkClosed = false;
    _tapReactionActive = false;
    _tapReactionTimer?.cancel();
    _motionGeneration += 1;
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
      _postureState.reset();
      _lastPostureCue = null;
      _motionGroups = const [];
      _motionRecipes = const [];
      _recipeAnimationNames = const {};
      _recentAmbientGroupIds.clear();
      _lastPerformanceActionKey = null;
      _appearanceBundleFuture = ProtectedCharacterAssets.bundleFor(
        next.assetName,
      );
      _spineController = next.animated ? _createSpineController(next) : null;
    });
    unawaited(_playSkinChangeEffect());
  }

  void _resetConversationWorkForDataReplacement() {
    _recentDialogueActions.clear();
    _lastConsolidatedUser = null;
    _previousSpeechEmotion = 'relaxed';
    _pendingMemoryRefresh = null;
    _replyGeneration += 1;
    _memoryRefreshGate.invalidate(afterLoad: true);
    _suggestionGeneration += 1;
    final iterator = _replyIterator;
    _replyIterator = null;
    if (iterator != null) unawaited(iterator.cancel());
    _outfitReactionTimer?.cancel();
    _pendingOutfitReaction = null;
    _cancelSpeechPlayback();
    widget.controller.frameRate.setActivity(
      FrameRateActivity.interfaceAnimation,
      false,
    );
    unawaited(_clearLastSpeech());
    _inputController.clear();
    if (!mounted) return;
    setState(() {
      _isReplying = false;
      _isContinuing = false;
      _isSuggestingReply = false;
      _pendingAttachments.clear();
      _manualPanelFraction = null;
      _characterToolsExpanded = false;
    });
  }

  Future<void> _loadMotionGroups(CharacterAppearance appearance) async {
    final generation = ++_motionLoadGeneration;
    try {
      final bundle = await _appearanceBundleFuture;
      final groups = await loadCharacterMotionGroups(
        appearance,
        bundle: bundle,
      );
      final source = await bundle.loadString(appearance.gestureAsset);
      final profile = CharacterPerformanceProfile.parse(source);
      final behavior = CharacterResourceBehavior.parse(source);
      final recipes = MotionRecipe.parse(
        await rootBundle.loadString('assets/data/motion_recipes.json'),
      );
      if (!mounted || generation != _motionLoadGeneration) return;
      _motionGroups = groups;
      _motionRecipes = recipes;
      _performanceDirector = CharacterPerformanceDirector(profile);
      _resourceBehavior = behavior;
      final animations = _spineController?.skeletonData.getAnimations();
      _recipeAnimationNames = animations?.map((a) => a.getName()).toSet() ?? {};
      RuntimeLog.instance.info(
        'ActionPlanner',
        '组合目录已加载：${recipes.length}；当前姿态可用：${recipes.where(_canPlayRecipe).length}',
      );
      _windAnimationName = animations
          ?.map((animation) => animation.getName())
          .where((name) => name.startsWith(behavior.windAnimationPrefix))
          .firstOrNull;
      _activeResourceExpression = null;
      _applyExpression(_currentExpression);
      _scheduleIdleChange();
      _scheduleMicroMotion();
      _scheduleCharacterBlink();
      _scheduleFacialDetailChange();
    } on Object catch (error, stack) {
      if (generation == _motionLoadGeneration) {
        _motionGroups = const [];
        _motionRecipes = const [];
        _recipeAnimationNames = const {};
      }
      RuntimeLog.instance.error('CharacterMotion', error, stack);
    }
  }

  Future<void> _playSkinChangeEffect() async {
    await _effectPlayer.stop();
    await _effectPlayer.play(AssetSource('audio/se/se_skin_change.m4a'));
  }

  void _scheduleIdleChange() {
    if (widget.controller.continuousAsmr) return;
    _idleTimer?.cancel();
    // The bundled original rig locks its base pose. Preserve manual pose choice;
    // emotion and conversation are not reasons to randomly cross sitting axes.
    if (_resourceBehavior.fixedBasePoseMode) return;
    final profile = _resourceEmotion;
    final minimum = profile?.poseRerollIntervalMin ?? 9.0;
    final maximum = profile?.poseRerollIntervalMax ?? 16.0;
    _idleTimer = Timer(_randomDuration(minimum, maximum), () {
      if (!mounted || !_spineReady) return;
      if (_isCharacterSpeaking || _tapReactionActive || _motionBusy) {
        _scheduleIdleChange();
        return;
      }
      final candidates = profile?.basePoses.where(
        (pose) =>
            pose.supportsSitting(_sittingId) &&
            _appearance.idleAnimations.contains(pose.id),
      );
      final selected = chooseResourceWeighted<ResourceBasePose>(
        candidates ?? const [],
        (pose) => pose.weight,
        _random,
      );
      if (selected != null) _playIdleAnimation(selected.id);
      _scheduleIdleChange();
    });
  }

  Duration _randomDuration(double minimum, double maximum) => Duration(
    milliseconds:
        ((minimum + _random.nextDouble() * max(0, maximum - minimum)) * 1000)
            .round(),
  );

  double _poseMixDuration(String animation) {
    final profile = _resourceEmotion;
    return _resourceBehavior.transitions?.poseMix(
          _currentIdleAnimation,
          animation,
          minimum: profile?.mixDurationMin ?? 0.42,
          maximum: profile?.mixDurationMax ?? 0.8,
        ) ??
        0.42;
  }

  void _playIdleAnimation(String animation) {
    final spineController = _spineController;
    if (!_spineReady ||
        spineController == null ||
        spineController.skeletonData.findAnimation(animation) == null) {
      return;
    }
    if (animation == _currentIdleAnimation) return;
    final mix = _poseMixDuration(animation);
    _resetMotionOverlays(mixDuration: mix);
    spineController.animationState.setEmptyAnimation(1, mix);
    _currentIdleAnimation = animation;
    _activePoseType = null;
    spineController.animationState.setAnimationByName(0, animation, true)
      ..setMixDuration(mix)
      ..setTimeScale(_resourceEmotion?.baseAnimTimeScale ?? 1);
    widget.controller.frameRate.boost(
      FrameRateActivity.characterMotion,
      duration: const Duration(milliseconds: 1400),
    );
    _scheduleIdleChange();
  }

  bool _playOneShotAnimation(String animation) {
    final spineController = _spineController;
    if (!_spineReady ||
        spineController == null ||
        spineController.skeletonData.findAnimation(animation) == null) {
      return false;
    }
    _resetMotionOverlays(mixDuration: 0.28);
    final state = spineController.animationState;
    final entry = transitionCharacterTrack(
      state,
      1,
      animation,
      loop: false,
      mixDuration: 0.34,
    );
    // Begin release after the whole authored clip, not 0.36s before its end.
    state.addEmptyAnimation(1, 0.36, entry.getAnimation().getDuration());
    final motionDuration = Duration(
      milliseconds: ((entry.getAnimation().getDuration() + 0.36) * 1000).ceil(),
    );
    _motionBusyUntil = DateTime.now().add(motionDuration);
    widget.controller.frameRate.boost(
      FrameRateActivity.characterMotion,
      duration: motionDuration,
    );
    _scheduleIdleChange();
    return true;
  }

  bool _canPlayMotionGroup(CharacterMotionGroup group) =>
      group.supportsPose(_currentIdleAnimation) &&
      group.supportsSitting(_sittingId) &&
      (_sittingId != 'sitting_agura' || !group.occupancy.contains('C')) &&
      group.occupiedTracks.isNotEmpty &&
      _spineController?.skeletonData.findAnimation(group.animation1) != null &&
      (group.animation2 == null ||
          (group.occupiedTracks.length > 1 &&
              _spineController?.skeletonData.findAnimation(group.animation2!) !=
                  null));

  /// A motion group can be structurally valid but still be authored as
  /// invisible (for example, an alpha of zero). Keep those groups out of the
  /// prompt so the model does not promise a gesture that the renderer cannot
  /// show.
  bool _isPromptPlayableMotionGroup(CharacterMotionGroup group) {
    final authoredDisabled =
        group.label.contains('使わない') ||
        group.animation1.contains('_ignore') ||
        (group.animation2?.contains('_ignore') ?? false);
    if (authoredDisabled) return false;
    final hasVisibleTrack =
        (group.animation1.isNotEmpty && group.alpha1 > 0) ||
        (group.animation2 != null &&
            group.animation2!.isNotEmpty &&
            group.alpha2 > 0);
    return hasVisibleTrack && _canPlayMotionGroup(group);
  }

  String _motionCapabilityDescription(CharacterMotionGroup group) {
    final label = group.label.trim().isEmpty ? '未命名动作' : group.label.trim();
    final pose = group.applicablePoseIds.isEmpty
        ? 'any'
        : group.applicablePoseIds.take(8).join('|');
    final poseSuffix = group.applicablePoseIds.length > 8 ? '|...' : '';
    final sitting = group.applicableSittingIds.isEmpty
        ? 'any'
        : group.applicableSittingIds.join('|');
    final occupancy = group.occupancy.trim().isEmpty
        ? 'unknown'
        : group.occupancy.trim();
    return '${group.id} "$label"; occupancy=$occupancy; '
        'pose=$pose$poseSuffix; sitting=$sitting';
  }

  String _motionPromptDescription(CharacterMotionGroup group) {
    final semantic = switch (group.id) {
      'grp_b_01' => '仅轻微转肩（肩约6至7度），手臂微动；不举臂、不伸懒腰、不做大幅伸展',
      'grp_b_02' => '双手叠放，安静倾听',
      'grp_b_03' => '双手叉腰，自信或佯装不满',
      'grp_b_05' => '双手抱臂，思考或质疑',
      'grp_b_07' => '双手放在胸前，真诚回应',
      'grp_b_12' => '左右伸展或伸懒腰',
      'grp_b_13' => '双手放在大腿内侧，收敛坐姿',
      'grp_c_01' => '双脚轻轻晃荡',
      'grp_c_02' => '改变腿部角度，调整坐姿',
      'grp_c_03' => '调整膝盖开合',
      'grp_c_04' => '调整大腿高度',
      'grp_c_05' => '盘腿姿态变化',
      'grp_eh_10' => '身体左右轻晃',
      'grp_eh_20' => '身体倾斜待机',
      'grp_eh_30' => '身体轻微上下弹动',
      'grp_eh_40' => '身体向后倾斜',
      'grp_eh_50' => '身体向左倾斜',
      'grp_eh_60' => '身体向右倾斜',
      'grp_eh_70' => '身体向前倾听',
      'grp_fg_016' => '双手比耶',
      'grp_fg_018' => '双手配合耳语姿势',
      'grp_fg_019' => '双手张开手掌触碰',
      'grp_fg_020' => '双手做嘘手势',
      'grp_fg_021' => '双手指向或展示',
      'grp_fg_022' => '双手叠放在大腿上',
      'grp_fg_023' => '双手抱臂组合',
      'grp_fg_024' => '双手拍手',
      'grp_fg_025' => '双手放在沙发上支撑',
      'grp_fg_026' => '双手放在大腿上',
      'grp_fg_027' => '盘腿专用手位',
      'grp_fg_028' => '展示双掌并挥手',
      'grp_fg_029' => '展示双掌并慌张摆动',
      'grp_fg_030' => '双手握拳打气',
      'grp_fg_031' => '双手向前伸出或拥抱邀请',
      'grp_fg_032' => '双掌示意等一下',
      'grp_fg_033' => '双手挥手问候',
      'grp_fg_000' => '站姿双臂自然放置',
      'grp_fg_001' => '站姿双手叉腰',
      'grp_fg_002' => '站姿双手抱臂',
      'grp_fg_003' => '站姿双手轻摆',
      'grp_fg_004' => '站姿双手背后交握',
      'grp_fg_g_006' => '站姿右手猫爪般轻抬',
      'grp_fg_g_007' => '站姿右手向前伸出',
      'grp_fg_g_008' => '站姿右手耳语姿势',
      'grp_fg_g_009' => '站姿右手触碰脸颊',
      _ => '资源标签所描述的动作；不要推断未写明的姿势',
    };
    return '$semantic；资源标签：${group.label}。';
  }

  /// Builds the capability snapshot from the resources that are actually
  /// loaded in the active Spine instance. This is intentionally independent
  /// of user text: the model chooses a semantic action, while this snapshot
  /// tells it which semantic actions can be rendered right now.
  CharacterPerformancePromptContext _buildPerformancePromptContext() {
    final spineController = _spineController;
    final ready =
        _spineReady && spineController != null && _motionGroups.isNotEmpty;
    final posture = _sittingId;
    final poseIndex = _currentIdleAnimation == null
        ? -1
        : _appearance.idleAnimations.indexOf(_currentIdleAnimation!);
    // The load generation changes when the outfit/rig is replaced. Including
    // the selected base pose makes a new snapshot visible after a pose switch
    // without coupling prompt construction to animation playback counters.
    final poseOffset = poseIndex < 0 ? 0 : poseIndex.clamp(0, 999).toInt();
    final revision =
        (_motionLoadGeneration * 10000) +
        poseOffset * 4 +
        (_postureState.manual ? 2 : 0) +
        (_sittingId == 'sitting_agura' ? 1 : 0);

    if (!ready) {
      return CharacterPerformancePromptContext(
        appearanceId: _appearance.id,
        posture: posture,
        revision: revision,
        resourcesReady: false,
        playableActionDescriptions: const {},
      );
    }

    final playable = <String, String>{};
    for (final action in CharacterAction.values) {
      if (action == CharacterAction.none) continue;
      final details = _runtimeActionCapabilities(action);
      if (details.isEmpty) continue;
      final semantic =
          CharacterPerformancePromptContext.actionDescriptions[action.name];
      if (semantic == null) continue;
      playable[action.name] = '$semantic 可执行资源：${details.join('；')}。';
    }

    final motionGroups = <String, String>{};
    for (final group in _motionGroups) {
      if (_isPromptPlayableMotionGroup(group)) {
        motionGroups[group.id] = _motionPromptDescription(group);
      }
    }
    for (final recipe in _motionRecipes.where(_canPlayRecipe)) {
      motionGroups[recipe.id] =
          '${recipe.name}：${recipe.description}；'
          '${recipe.stages.length}个阶段，脸部由表情工具独立控制';
    }

    return CharacterPerformancePromptContext(
      appearanceId: _appearance.id,
      posture: posture,
      revision: revision,
      resourcesReady: true,
      playableActionDescriptions: playable,
      playableMotionGroupDescriptions: motionGroups,
      expressionIntensities: {
        for (final emotion in _resourceBehavior.intensityProfiles.entries)
          emotion.key: [
            'normal',
            for (final level in emotion.value.entries)
              if (level.key != 'normal' &&
                  level.value.expressionSets.any(_isPlayableExpression))
                level.key,
          ],
      },
      postureManuallySelected: _postureState.manual,
      availablePostures: {
        if (!_appearance.isStanding) 'sitting_normal': '自然坐姿',
        if (_crossLeggedGroup != null) 'sitting_agura': '放松的盘腿坐姿',
      },
    );
  }

  List<String> _runtimeActionCapabilities(CharacterAction action) {
    final plan = characterActionPlan(
      _appearance.baseAppearanceId ?? _appearance.id,
      action,
    );
    final details = <String>[];
    final seenDetails = <String>{};
    void addDetail(String value) {
      if (value.isNotEmpty && seenDetails.add(value)) details.add(value);
    }

    // A few semantic actions use authored attitude bindings. The playback
    // path gives these bindings precedence over the generic action plan, so
    // the capability snapshot follows the same precedence.
    final attitude = switch (action) {
      CharacterAction.acknowledge => 'agree',
      CharacterAction.disagree => 'deny',
      CharacterAction.think => 'question',
      _ => null,
    };
    final bindings = attitude == null
        ? null
        : _resourceEmotion?.fixedGestureBindingsByAttitude[attitude];
    if (bindings != null) {
      for (final binding in bindings) {
        final oneShotAvailable =
            _resolveResourceClip(binding.oneShotAnimation) != null;
        CharacterMotionGroup? group;
        for (final candidate in _motionGroups) {
          if (candidate.id == binding.fixedGestureId &&
              _isPromptPlayableMotionGroup(candidate)) {
            group = candidate;
            break;
          }
        }
        if (!oneShotAvailable && group == null) continue;
        final parts = <String>[];
        if (oneShotAvailable) parts.add('单次反馈资源可用');
        if (group != null) parts.add(_motionCapabilityDescription(group));
        addDetail(parts.join(', '));
      }
      return details;
    }

    for (final group in _motionGroups) {
      if (!plan.motionGroupIds.contains(group.id) ||
          !_isPromptPlayableMotionGroup(group)) {
        continue;
      }
      addDetail(_motionCapabilityDescription(group));
    }
    if (details.isEmpty && plan.oneShotFallback != null) {
      if (_resolveResourceClip(plan.oneShotFallback) != null) {
        details.add('单次反馈资源可用');
      }
    }
    return details;
  }

  bool _playMotionGroup(
    CharacterMotionGroup group, {
    bool pairFace = false,
    Map<int, double> trackTimes = const {},
    Set<int>? allowedTracks,
    Duration? remainingDuration,
  }) {
    final spineController = _spineController;
    if (!_spineReady ||
        spineController == null ||
        !_canPlayMotionGroup(group)) {
      return false;
    }
    final tracks = group.occupiedTracks;
    if (pairFace) _applyExpression(group.pairedExpression(_currentExpression));

    // Alpha, speed and blend duration are authored together in the gesture.
    // Easing the constant alpha would amplify it, not smooth it over time.
    final blend = smoothCharacterGestureMix(
      _resourceBehavior.transitions?.groupMix(
            _activeMotionGroupId,
            group.id,
            fallback: group.blendTime,
          ) ??
          group.blendTime,
      group.blendTime,
    );
    final generation = ++_motionGeneration;
    final state = spineController.animationState;
    state.setEmptyAnimation(1, blend);

    final animations = <({String name, double alpha, double speed})>[
      (name: group.animation1, alpha: group.alpha1, speed: group.speed1),
      if (group.animation2 case final second?)
        (name: second, alpha: group.alpha2, speed: group.speed2),
    ];
    TrackEntry? longestEntry;
    var longestDuration = -1.0;
    final appliedTracks = <int>[];
    for (var index = 0; index < animations.length; index++) {
      final animation = animations[index];
      if (index >= tracks.length ||
          (allowedTracks != null && !allowedTracks.contains(tracks[index])) ||
          spineController.skeletonData.findAnimation(animation.name) == null) {
        continue;
      }

      final entry =
          transitionCharacterTrack(
              state,
              tracks[index],
              animation.name,
              loop: false,
              mixDuration: blend,
            )
            ..setAlpha(animation.alpha)
            ..setTimeScale(animation.speed)
            ..setMixBlend(MixBlend.replace)
            ..setMixDuration(blend);
      if (trackTimes[tracks[index]] case final time?) {
        entry.setTrackTime(time);
      }
      appliedTracks.add(tracks[index]);

      final speed = animation.speed.abs() < 0.01 ? 1.0 : animation.speed.abs();
      final duration = entry.getAnimation().getDuration() / speed;
      if (duration > longestDuration) {
        longestDuration = duration;
        longestEntry = entry;
      }
    }
    if (longestEntry == null) return false;
    final fullDuration = Duration(
      milliseconds:
          ((max(0, longestDuration) + max(0.3, group.blendTime)) * 1000).ceil(),
    );
    final motionDuration = remainingDuration ?? fullDuration;
    _motionLayers.claim(
      generation,
      group.id,
      appliedTracks,
      DateTime.now().add(motionDuration),
    );
    _activeMotionVariants[generation] = group;
    _activeMotionGroupId = _motionLayers.latestGroupId;
    _motionBusyUntil = _motionLayers.latestExpiry;
    void finish() {
      if (!mounted) return;
      RuntimeLog.instance.info(
        'ActionPlanner',
        '动作完成：${group.id}；generation=$generation',
      );
      final release = smoothCharacterGestureMix(
        _resourceBehavior.transitions?.groupMix(
              group.id,
              null,
              fallback: group.blendTime,
            ) ??
            group.blendTime,
        group.blendTime,
      );
      _releaseMotionLease(generation, release);
    }

    longestEntry.setListener((type, _, _) {
      if (type == EventType.complete) finish();
    });
    _motionReleaseTimers[generation] = Timer(motionDuration, finish);
    RuntimeLog.instance.info(
      'ActionPlanner',
      '动作开始：${group.id}；动画=${animations.map((a) => a.name).join(',')}；轨道=$appliedTracks；时长=${longestDuration.toStringAsFixed(2)}秒；混合=$blend；generation=$generation',
    );
    widget.controller.frameRate.boost(
      FrameRateActivity.characterMotion,
      duration: motionDuration,
    );
    _scheduleIdleChange();
    return true;
  }

  void _releaseMotionLease(int token, double mixDuration) {
    _motionReleaseTimers.remove(token)?.cancel();
    _activeMotionVariants.remove(token);
    final tracks = _motionLayers.release(token);
    if (tracks.isEmpty) return;
    final state = _spineController?.animationState;
    if (state != null) {
      for (final track in tracks) {
        if (track == 3 && _sittingId == 'sitting_agura') continue;
        state.setEmptyAnimation(track, mixDuration);
      }
    }
    _activeMotionGroupId = _motionLayers.latestGroupId;
    _motionBusyUntil =
        _motionLayers.latestExpiry ??
        DateTime.now().add(Duration(milliseconds: (mixDuration * 1000).ceil()));
    _restoreSittingRestTracks(tracks, mixDuration);
    _scheduleIdleChange();
  }

  List<_SuspendedMotionGroup> _captureTapMotions() {
    final state = _spineController?.animationState;
    if (state == null) return const [];
    final now = DateTime.now();
    return [
      for (final lease in _motionLayers.active)
        if (lease.expiresAt.isAfter(now))
          if (_activeMotionVariants[lease.token] case final group?)
            _SuspendedMotionGroup(
              group: group,
              remaining: lease.expiresAt.difference(now),
              tracks: lease.tracks,
              trackTimes: {
                for (final track in lease.tracks)
                  if (state.getCurrent(track) case final entry?)
                    track: entry.getTrackTime(),
              },
            ),
    ];
  }

  void _restoreTapMotions() {
    final suspended = _tapSuspendedMotions;
    _tapSuspendedMotions = const [];
    if (_tapSuspendedMotionLoadGeneration != _motionLoadGeneration) return;
    for (final motion in suspended) {
      if (_motionGroups.contains(motion.group) &&
          _canPlayMotionGroup(motion.group)) {
        _playMotionGroup(
          motion.group,
          trackTimes: motion.trackTimes,
          allowedTracks: motion.tracks,
          remainingDuration: motion.remaining,
        );
      }
    }
  }

  void _restoreSittingRestTracks(Set<int> released, double mixDuration) {
    if (_sittingId != 'sitting_agura') return;
    final restId = _resourceBehavior.restGroupsBySitting[_sittingId];
    final rest = _motionGroups
        .where(
          (group) =>
              group.id == restId &&
              group.occupancy == 'FG' &&
              _canPlayMotionGroup(group),
        )
        .firstOrNull;
    if (rest == null) return;
    final names = [rest.animation1, rest.animation2];
    for (var index = 0; index < rest.occupiedTracks.length; index++) {
      final track = rest.occupiedTracks[index];
      final name = names[index];
      if (name == null || !released.contains(track)) continue;
      _setFacialAnimation(
        track,
        name,
        alpha: index == 0 ? rest.alpha1 : rest.alpha2,
        timeScale: index == 0 ? rest.speed1 : rest.speed2,
        mixDuration: mixDuration,
      );
    }
  }

  bool _canPlayRecipe(MotionRecipe recipe) {
    final controller = _spineController;
    return _spineReady &&
        controller != null &&
        recipe.available(
          _recipeAnimationNames,
          _currentIdleAnimation,
          _sittingId,
        );
  }

  void _playRecipeStage(MotionRecipe recipe, int index) {
    if (!mounted || _tapReactionActive || !_canPlayRecipe(recipe)) {
      RuntimeLog.instance.warning(
        'ActionPlanner',
        '组合阶段拦截：${recipe.id}，阶段=${index + 1}，触碰=$_tapReactionActive，姿态=$_sittingId',
      );
      return;
    }
    RuntimeLog.instance.info(
      'ActionPlanner',
      '组合阶段开始：${recipe.id}；${index + 1}/${recipe.stages.length}',
    );
    final controller = _spineController!;
    final layers = recipe.stages[index];
    const blend = 0.34;
    _resetMotionOverlays(
      mixDuration: blend,
      replacingTracks: layers.map((layer) => layer.track).toList(),
    );
    final generation = _motionGeneration;
    final state = controller.animationState;
    if (!layers.any((layer) => layer.track == 1)) {
      state.setEmptyAnimation(1, blend);
    }
    _activeMotionGroupId = recipe.id;
    TrackEntry? longest;
    var duration = 0.0;
    for (final layer in layers) {
      final entry =
          transitionCharacterTrack(
              state,
              layer.track,
              layer.name,
              loop: false,
              mixDuration: blend,
            )
            ..setAlpha(layer.alpha)
            ..setTimeScale(layer.speed)
            ..setMixBlend(MixBlend.replace);
      final seconds = entry.getAnimation().getDuration() / layer.speed;
      if (longest == null || seconds > duration) {
        longest = entry;
        duration = seconds;
      }
    }
    final busy = Duration(milliseconds: ((duration + blend) * 1000).ceil());
    _motionBusyUntil = DateTime.now().add(busy);
    widget.controller.frameRate.boost(
      FrameRateActivity.characterMotion,
      duration: busy,
    );
    longest?.setListener((type, _, _) {
      if (type != EventType.complete ||
          !mounted ||
          generation != _motionGeneration) {
        return;
      }
      if (index + 1 < recipe.stages.length &&
          _canPlayRecipe(recipe) &&
          !_tapReactionActive) {
        _playRecipeStage(recipe, index + 1);
      } else {
        RuntimeLog.instance.info(
          'ActionPlanner',
          '组合阶段结束：${recipe.id}；${index + 1}/${recipe.stages.length}',
        );
        state.setEmptyAnimation(1, blend);
        _resetMotionOverlays(mixDuration: blend);
        _motionBusyUntil = DateTime.now().add(
          const Duration(milliseconds: 340),
        );
        _scheduleIdleChange();
      }
    });
  }

  void _resetMotionOverlays({
    double mixDuration = 0.28,
    List<int> replacingTracks = const [],
  }) {
    final spineController = _spineController;
    if (!_spineReady || spineController == null) return;
    if (_activeMotionGroupId != null) {
      RuntimeLog.instance.info(
        'ActionPlanner',
        '释放/替换动作层：$_activeMotionGroupId；混合=$mixDuration；保留轨道=$replacingTracks；generation=$_motionGeneration',
      );
    }
    _motionGeneration += 1;
    _motionLayers.clear();
    _activeMotionVariants.clear();
    for (final timer in _motionReleaseTimers.values) {
      timer.cancel();
    }
    _motionReleaseTimers.clear();
    _motionBusyUntil = null;
    _activeMotionGroupId = null;
    for (var track = 2; track <= 10; track++) {
      // The leg layer is a persistent posture, not a one-shot gesture.
      if (track == 3 && _sittingId == 'sitting_agura') continue;
      final restTracks = _sittingId == 'sitting_agura'
          ? _motionGroups
                .where(
                  (g) =>
                      g.id ==
                          _resourceBehavior.restGroupsBySitting[_sittingId] &&
                      g.occupancy == 'FG' &&
                      _canPlayMotionGroup(g),
                )
                .expand((g) => g.occupiedTracks)
          : const <int>[];
      if (!replacingTracks.contains(track) &&
          !restTracks.contains(track) &&
          spineController.animationState.getCurrent(track) != null) {
        spineController.animationState.setEmptyAnimation(track, mixDuration);
      }
    }
    _restoreSittingRestTracks({
      for (var track = 2; track <= 10; track++)
        if (!replacingTracks.contains(track)) track,
    }, mixDuration);
  }

  void _setFacialAnimation(
    int track,
    String animation, {
    bool loop = true,
    double alpha = 1,
    double timeScale = 1,
    double mixDuration = 0.16,
  }) {
    final spineController = _spineController;
    if (!_spineReady ||
        spineController == null ||
        spineController.skeletonData.findAnimation(animation) == null) {
      return;
    }
    final current = spineController.animationState.getCurrent(track);
    if (loop &&
        current?.getAnimation().getName() == animation &&
        current!.getLoop()) {
      current
        ..setAlpha(alpha)
        ..setTimeScale(timeScale);
      return;
    }
    transitionCharacterTrack(
        spineController.animationState,
        track,
        animation,
        loop: loop,
        mixDuration: mixDuration,
      )
      ..setMixBlend(MixBlend.replace)
      ..setMixDuration(mixDuration)
      ..setAlpha(alpha)
      ..setTimeScale(timeScale);
  }

  void _applyExpression(CharacterExpression expression, {String? intensity}) {
    if (intensity != null && intensity != _expressionIntensity) {
      _expressionIntensity = intensity;
      _activeResourceExpression = null;
    }
    if (expression != _currentExpression) _clearPerformanceQueue();
    if (expression != _currentExpression) {
      _activeResourceExpression = null;
      _activeFacialDetail = null;
    }
    _currentExpression = expression;

    if (!_spineReady || _spineController == null || _tapReactionActive) return;
    _blinkRestoreTimer?.cancel();
    _speechBlinkClosed = false;
    _spineController!.animationState
        .getCurrent(0)
        ?.setTimeScale(_resourceEmotion?.baseAnimTimeScale ?? 1);
    final preset = characterExpressionPreset(
      _appearance.baseAppearanceId ?? _appearance.id,
      expression,
    );
    _selectResourceExpression();
    _applyFacialDetails();
    if (_isCharacterSpeaking) {
      final lipSync =
          _resolveResourceClip(
            _resourceEmotion?.lipSyncScrubClip,
            scrub: true,
          ) ??
          preset.lipSync;
      final animation = _spineController!.skeletonData.findAnimation(lipSync);
      final currentMouth = _spineController!.animationState.getCurrent(13);
      _lipSyncEntry = animation == null
          ? null
          : (currentMouth?.getAnimation().getName() == lipSync
                ? currentMouth
                : _spineController!.animationState.setAnimationByName(
                    13,
                    lipSync,
                    false,
                  ));
      _lipSyncEntry
        ?..setMixBlend(MixBlend.replace)
        ..setMixDuration(0.12)
        ..setAlpha(preset.lipSyncAlpha)
        ..setTimeScale(0);
    } else {
      _lipSyncEntry = null;
      final resourceMouth = _resolveResourceClip(
        _activeResourceExpression?.mouth,
      );
      _setFacialAnimation(
        13,
        stableIdleMouthOr(resourceMouth, preset.mouth),
        mixDuration: _resourceEmotion?.mixDurationEye ?? 0.16,
      );
    }
    _setFacialEffect(
      14,
      _appearance.isStanding
          ? 'facial_add_blush_off'
          : 'facial_add_blush_000_off',
      _resourceFacialEffect('blush') ?? preset.blush,
    );
    _setFacialEffect(
      15,
      _appearance.isStanding
          ? 'facial_add_tear_off'
          : 'facial_add_tear_000_off',
      _resourceFacialEffect('tear') ?? preset.tear,
    );
    if (!_appearance.isStanding) {
      _spineController!.animationState.clearTrack(16);
    }
    if (_blinkTimer?.isActive != true) _scheduleCharacterBlink();
  }

  String? _resolveResourceClip(String? stem, {bool scrub = false}) {
    if (stem == null || stem.isEmpty || _spineController == null) return null;
    for (final name in [stem, '${stem}_${scrub ? 'scrub' : 'idle'}']) {
      if (_spineController!.skeletonData.findAnimation(name) != null) {
        return name;
      }
    }
    return null;
  }

  String? _resourceFacialEffect(String family) {
    for (final name in _activeResourceEffects) {
      final clip = _resourceBehavior.effectAnimations[name];
      if (clip != null &&
          clip.contains('facial_add_$family') &&
          _resolveResourceClip(clip) != null) {
        return clip;
      }
    }
    return null;
  }

  void _selectResourceExpression({bool renew = false}) {
    if (!renew && _activeResourceExpression != null) return;
    final effects = _resourceEmotion?.effectSets ?? const <List<String>>[];
    _activeResourceEffects = effects.isEmpty
        ? const []
        : effects[_random.nextInt(effects.length)];
    final candidates = _resourceEmotion?.expressionSets
        .where(
          (set) =>
              _resolveResourceClip(set.eyeOpen) != null &&
              _resolveResourceClip(set.eyeClosed) != null &&
              _resolveResourceClip(set.eyebrow) != null &&
              _resolveResourceClip(set.mouth) != null,
        )
        .toList();
    if (candidates == null || candidates.isEmpty) return;
    // Select a complete authored combination. Do not force a different face
    // every sentence; repeating the current combination is valid.
    _activeResourceExpression = chooseResourceWeighted(
      candidates,
      (set) => set.weight,
      _random,
    );
  }

  bool _isPlayableExpression(ResourceExpressionSet set) =>
      _resolveResourceClip(set.eyeOpen) != null &&
      _resolveResourceClip(set.eyeClosed) != null &&
      _resolveResourceClip(set.eyebrow) != null &&
      _resolveResourceClip(set.mouth) != null;

  String get _openEye =>
      _resolveResourceClip(_activeResourceExpression?.eyeOpen) ??
      _activeFacialDetail?.eye ??
      characterExpressionPreset(
        _appearance.baseAppearanceId ?? _appearance.id,
        _currentExpression,
      ).eye;

  void _applyFacialDetails() {
    final preset = characterExpressionPreset(
      _appearance.baseAppearanceId ?? _appearance.id,
      _currentExpression,
    );
    _setFacialAnimation(
      11,
      _openEye,
      mixDuration: _resourceEmotion?.mixDurationEye ?? 0.24,
    );
    _setFacialAnimation(
      12,
      _resolveResourceClip(_activeResourceExpression?.eyebrow) ??
          _activeFacialDetail?.eyebrow ??
          preset.eyebrow,
      mixDuration: _resourceEmotion?.mixDurationEyebrow ?? 0.24,
    );
  }

  void _setFacialEffect(int track, String offAnimation, String? onAnimation) {
    final spineController = _spineController;
    if (!_spineReady || spineController == null) return;
    final state = spineController.animationState;
    final target =
        onAnimation != null &&
            spineController.skeletonData.findAnimation(onAnimation) != null
        ? onAnimation
        : offAnimation;
    if (state.getCurrent(track)?.getAnimation().getName() == target) return;
    _setFacialAnimation(track, target, loop: false, mixDuration: 0.18);
  }

  void _startSpeakingAnimation({
    AudioAmplitudeEnvelope? envelope,
    bool awaitingAudio = false,
  }) {
    _syntheticSpeech = !awaitingAudio;
    _playbackPosition = Duration.zero;
    _positionClock
      ..stop()
      ..reset();
    _activeSpeechEnvelope = envelope;
    _currentSpeechEnergy = envelope == null ? 0.45 : 0;
    widget.controller.frameRate.setActivity(FrameRateActivity.speech, true);
    if (_isCharacterSpeaking) {
      // A new audio clip continues the same conversation pose and blink cycle.
      return;
    }
    _isCharacterSpeaking = true;
    _speechStopwatch
      ..reset()
      ..start();
    _applyExpression(_currentExpression);
    _scheduleMicroMotion();
    _scheduleFacialDetailChange();
    _scheduleCharacterBlink();
  }

  void _pauseSpeakingBetweenSegments() {
    _syntheticSpeech = false;
    _positionClock.stop();
    _activeSpeechEnvelope = null;
    _currentSpeechEnergy = 0;
    _lipSyncEntry?.setTrackTime(0);
  }

  void _stopSpeakingAnimation() {
    _microMotionTimer?.cancel();
    _facialDetailTimer?.cancel();
    _blinkTimer?.cancel();
    _blinkRestoreTimer?.cancel();
    _speechBlinkClosed = false;
    _speechStopwatch.stop();
    _positionClock.stop();
    _isCharacterSpeaking = false;
    widget.controller.frameRate.setActivity(FrameRateActivity.speech, false);
    _activeSpeechEnvelope = null;
    _lipSyncEntry = null;
    _currentSpeechEnergy = 0;
    _applyExpression(_currentExpression);
    _scheduleMicroMotion();
    _scheduleCharacterBlink();
    _scheduleFacialDetailChange();
  }

  void _restoreProceduralRig(SpineWidgetController controller) {
    for (final entry in _rigBase.entries) {
      controller.skeleton.findBone(entry.key)
        ?..setX(entry.value.x)
        ..setY(entry.value.y)
        ..setRotation(entry.value.rotation);
    }
    _rigBase.clear();
    _updateSceneWind(controller);
  }

  void _updateSceneWind(SpineWidgetController controller) {
    final name = _windAnimationName;
    if (name == null) return;
    final strength = _windEnvelope.advance(
      controller.updateDelta,
      characterWindForStage(widget.controller.selectedStageId),
    );
    final state = controller.animationState;
    final current = state.getCurrent(_windTrack);
    if (strength == 0) {
      if (current?.getAnimation().getName() == name) {
        state.setEmptyAnimation(_windTrack, 0.6);
      }
      return;
    }
    final entry = current?.getAnimation().getName() == name
        ? current!
        : (state.setAnimationByName(_windTrack, name, true)
            ..setMixBlend(MixBlend.replace)
            ..setMixDuration(0.6)
            ..setTimeScale(1.0));
    // This authored clip keys physics wind only. Replace avoids additive
    // accumulation; fading alpha scales it against the authored setup wind.
    entry.setAlpha(strength);
  }

  void _prepareSpeechFrame(SpineWidgetController controller) {
    final playing =
        _isCharacterSpeaking && (_syntheticSpeech || _positionClock.isRunning);
    final position = _syntheticSpeech
        ? _speechStopwatch.elapsed
        : interpolatedSpeechPosition(_playbackPosition, _positionClock.elapsed);
    final seconds = position.inMicroseconds / 1000000;
    if (playing && _activeSpeechEnvelope != null) {
      _sampleSpeechEnvelope(position);
    } else if (!playing) {
      _currentSpeechEnergy = 0;
      _lipSyncEntry?.setTrackTime(0);
    }
    final entry = _lipSyncEntry;
    if (playing && _activeSpeechEnvelope == null && entry != null) {
      final phase = (seconds * 5.2) % 1;
      final closure = phase < 0.28;
      final pulse = closure ? 0.0 : sin((phase - 0.28) / 0.72 * pi).abs();
      _currentSpeechEnergy = closure ? 0 : 0.24 + pulse * 0.46;
      entry.setTrackTime(
        entry.getAnimation().getDuration() * _currentSpeechEnergy * 0.48,
      );
    }
  }

  void _applySpeakingHeadMotion(SpineWidgetController controller) {
    final delta = controller.updateDelta;
    // Resolve gaze against this frame's authored world pose, without advancing
    // physics. The drawable steps physics once AFTER these local offsets.
    controller.skeleton.updateWorldTransform(Physics.none);

    void remember(String name) {
      final bone = resolveOptionalRigBone(name, controller.skeleton.findBone);
      if (bone == null) return;
      _rigBase.putIfAbsent(
        name,
        () => (x: bone.getX(), y: bone.getY(), rotation: bone.getRotation()),
      );
    }

    final profile = _performanceDirector.profile;

    final aimBones = profile.aimBones;
    final rollBones = profile.rollBones;
    for (final name in {
      ...aimBones.values,
      ...rollBones.values,
      ...characterBodyGazeBones,
      'control_aim_eye',
      'control_aim_head',
      'control_aim_body',
      'control_eye',
      'control_handle_eye',
      'control_roll_head',
      'control_roll_neck',
      'control_roll_body_upper',
      'control_roll_body_lower',
      'eyeball_L',
      'eyeball_R',
      'head',
      'neck',
    }) {
      remember(name);
    }
    _applyEyeGaze(controller);

    // This director advances on frame delta, not per-audio-clip position.
    // Its target/hold transitions continue through TTS sentence boundaries.
    final parts = _performanceDirector.sample(
      delta: delta,
      emotion: _currentExpression.name,
      speaking: _isCharacterSpeaking,
      energy: _currentSpeechEnergy,
      suppressed: _tapReactionActive || _gazePointer != null || _motionBusy,
    );
    for (final entry in parts.entries) {
      if (_tapReactionActive) break;
      // Automatic gaze uses the same visible eyeball joints as pointer gaze.
      // Merely moving an aim marker may not drive the eyes in every skin.
      if (entry.key == 'eye') {
        var moved = false;
        for (final side in ['L', 'R']) {
          final eye = controller.skeleton.findBone('eyeball_$side');
          final parent = eye?.getParent();
          if (eye == null || parent == null) continue;
          final a = parent.worldToLocal(eye.getWorldX(), eye.getWorldY());
          final b = parent.worldToLocal(
            eye.getWorldX() + entry.value.yaw * 28,
            eye.getWorldY() + entry.value.pitch * 22,
          );
          eye
            ..setX(eye.getX() + b.x - a.x)
            ..setY(eye.getY() + b.y - a.y);
          moved = true;
        }
        if (moved) continue;
      }
      final aim = resolveOptionalRigBone(
        aimBones[entry.key] ??
            (entry.key == 'head' || entry.key == 'body' || entry.key == 'eye'
                ? 'control_aim_${entry.key}'
                : null),
        controller.skeleton.findBone,
      );
      if (aim != null) {
        // Scale in rig-local units; never translate the skeleton root or hips.
        final reach = max(aim.getData().getY().abs(), 80.0).clamp(80.0, 180.0);
        aim
          ..setX(aim.getX() + entry.value.yaw * reach * 0.45)
          ..setY(aim.getY() + entry.value.pitch * reach * 0.35);
      }
      final roll = resolveOptionalRigBone(
        rollBones[entry.key] ??
            switch (entry.key) {
              'head' => 'control_roll_head',
              'body' => 'control_roll_body_upper',
              _ => null,
            },
        controller.skeleton.findBone,
      );
      if (roll != null) {
        // Authored roll controls are IK targets, not rotating body joints.
        final distance = entry.key == 'body' ? 64.0 : 40.0;
        roll.setX(roll.getX() + entry.value.roll * distance);
      } else if (aim == null && entry.key == 'head') {
        final head = controller.skeleton.findBone('head');
        head?.setRotation(head.getRotation() + entry.value.roll * 14);
      }
    }
  }

  void _applyEyeGaze(SpineWidgetController controller) {
    final pointer = _gazePointer;
    final startedAt = _gazeStartedAt;
    if (pointer == null || startedAt == null) return;
    final skeleton = controller.skeleton;
    final influence = _gazeHeld && widget.controller.gazeTrackingEnabled
        ? 1.0
        : characterGazeInfluence(DateTime.now().difference(startedAt));
    if (influence <= 0) {
      _gazePointer = null;
      _gazeStartedAt = null;
      _bodyGaze.reset();
      return;
    }

    final face = skeleton.findBone('rig_face') ?? skeleton.findBone('head');
    if (face == null) return;
    final origin = Offset(face.getWorldX(), face.getWorldY());
    final offset = gazeControlOffset(face: origin, pointer: pointer);
    final controlTarget =
        skeleton.findBone('control_aim_eye') ??
        skeleton.findBone('control_eye') ??
        skeleton.findBone('control_handle_eye');
    final controlParent = controlTarget?.getParent();
    final rigOffset = controlParent == null
        ? offset
        : () {
            final a = controlParent.worldToLocal(origin.dx, origin.dy);
            final b = controlParent.worldToLocal(
              origin.dx + offset.dx,
              origin.dy + offset.dy,
            );
            return Offset(b.x - a.x, b.y - a.y);
          }();
    var movedEyes = false;
    for (final side in ['L', 'R']) {
      final eye = skeleton.findBone('eyeball_$side');
      final parent = eye?.getParent();
      if (eye == null || parent == null) continue;
      final a = parent.worldToLocal(origin.dx, origin.dy);
      final b = parent.worldToLocal(
        origin.dx + offset.dx,
        origin.dy + offset.dy,
      );
      final localOffset = Offset(b.x - a.x, b.y - a.y);
      eye
        ..setX(eye.getX() + localOffset.dx * influence * 0.20)
        ..setY(eye.getY() + localOffset.dy * influence * 0.20);
      movedEyes = true;
    }
    if (!movedEyes && controlTarget != null) {
      controlTarget
        ..setX(controlTarget.getX() + rigOffset.dx * influence)
        ..setY(controlTarget.getY() + rigOffset.dy * influence);
    }
    final offsets = _bodyGaze.sample(
      direction: offset / 140,
      delta: controller.updateDelta,
      influence: influence,
      standing: _appearance.isStanding,
      crossLegged: _sittingId == 'sitting_agura',
      allowShoulders:
          _currentIdleAnimation == _appearance.idleAnimations.firstOrNull,
      busy: _motionBusy,
      tapReaction: _tapReactionActive,
    );
    for (final entry in offsets.entries) {
      final bone = skeleton.findBone(entry.key);
      if (bone == null) continue;
      final translation = entry.value.translation;
      final parent = bone.getParent();
      // Convert separately for each control: eye, torso and roll controls do
      // not share a parent coordinate system (especially in standing skins).
      final local = parent == null
          ? translation
          : () {
              final a = parent.worldToLocal(bone.getWorldX(), bone.getWorldY());
              final b = parent.worldToLocal(
                bone.getWorldX() + translation.dx,
                bone.getWorldY() + translation.dy,
              );
              return Offset(b.x - a.x, b.y - a.y);
            }();
      bone
        ..setX(bone.getX() + local.dx)
        ..setY(bone.getY() + local.dy)
        ..setRotation(bone.getRotation() + entry.value.rotation);
    }
  }

  void _updateGaze(Offset position) {
    final c = _spineController;
    if (!widget.controller.gazeTrackingEnabled || !_spineReady || c == null) {
      return;
    }
    _gazePointer = c.toSkeletonCoordinates(position);
    if (!_gazeHeld) {
      widget.controller.frameRate.setActivity(
        FrameRateActivity.characterMotion,
        true,
      );
    }
    _gazeHeld = true;
    _gazeStartedAt = DateTime.now();
  }

  void _endGaze() {
    if (_gazePointer != null && _gazeHeld) {
      _gazeHeld = false;
      widget.controller.frameRate.setActivity(
        FrameRateActivity.characterMotion,
        false,
      );
      widget.controller.frameRate.boost(
        FrameRateActivity.characterMotion,
        duration: characterGazeReleaseDuration,
      );
      _gazeStartedAt = DateTime.now().subtract(characterGazeHoldDuration);
    }
  }

  void _updateLipSyncFromPlaybackPosition(Duration position) {
    if (!_isCharacterSpeaking) return;
    _playbackPosition = position;
    _positionClock.reset();
  }

  void _sampleSpeechEnvelope(Duration position) {
    final envelope = _activeSpeechEnvelope;
    final entry = _lipSyncEntry;
    if (!_isCharacterSpeaking || envelope == null) return;
    final energy = envelope.valueAt(position);
    _currentSpeechEnergy = energy;
    final mouthOpen = energy < 0.08
        ? 0.0
        : (pow((energy - 0.08) / 0.92, 0.78) * 0.48).clamp(0.0, 0.48);
    entry?.setTrackTime(entry.getAnimation().getDuration() * mouthOpen);
  }

  void _scheduleFacialDetailChange() {
    if (widget.controller.continuousAsmr) return;
    _facialDetailTimer?.cancel();
    if (!mounted || !_spineReady) return;
    final profile = _resourceEmotion;
    _facialDetailTimer = Timer(
      _isCharacterSpeaking
          ? _randomDuration(6, 10)
          : _randomDuration(
              max(6, profile?.poseRerollIntervalMin ?? 8),
              max(10, profile?.poseRerollIntervalMax ?? 14),
            ),
      _rotateFacialDetail,
    );
  }

  void _rotateFacialDetail() {
    if (_motionBusy) {
      _scheduleFacialDetailChange();
      return;
    }
    if (!mounted ||
        _tapReactionActive ||
        !_spineReady ||
        _spineController == null) {
      _scheduleFacialDetailChange();
      return;
    }
    final skeletonData = _spineController!.skeletonData;
    if (_speechBlinkClosed) {
      _facialDetailTimer = Timer(
        const Duration(milliseconds: 400),
        _rotateFacialDetail,
      );
      return;
    }
    if (_resourceEmotion?.expressionSets.isNotEmpty ?? false) {
      _selectResourceExpression(renew: true);
      // Preserve the authored eye/brow/mouth tuple at rest. During speech,
      // the audio-driven mouth keeps ownership of its animation track.
      _applyFacialDetails();
      if (!_isCharacterSpeaking) {
        final mouth = _resolveResourceClip(_activeResourceExpression?.mouth);
        final preset = characterExpressionPreset(
          _appearance.baseAppearanceId ?? _appearance.id,
          _currentExpression,
        );
        _setFacialAnimation(
          13,
          stableIdleMouthOr(mouth, preset.mouth),
          mixDuration: _resourceEmotion?.mixDurationEye ?? 0.16,
        );
      }
      _scheduleFacialDetailChange();
      return;
    }
    final candidates =
        characterFacialDetails(
              _appearance.baseAppearanceId ?? _appearance.id,
              _currentExpression,
            )
            .where(
              (detail) =>
                  skeletonData.findAnimation(detail.eye) != null &&
                  skeletonData.findAnimation(detail.eyebrow) != null,
            )
            .toList();
    if (candidates.isNotEmpty) {
      final detail = candidates[_random.nextInt(candidates.length)];
      _activeFacialDetail = detail;
      _applyFacialDetails();
    }
    _scheduleFacialDetailChange();
  }

  void _scheduleCharacterBlink() {
    if (widget.controller.continuousAsmr) return;
    _blinkTimer?.cancel();
    if (!mounted || !_spineReady || !_appearance.animated) return;
    _blinkBeat = chooseCharacterBlink(
      _performanceDirector.profile.tensionProfile(
        _currentExpression.name,
        _performanceDirector.tensionBand,
      ),
      _random,
    );
    _blinkTimer = Timer(
      Duration(milliseconds: (_blinkBeat.gap * 1000).round()),
      _performCharacterBlink,
    );
  }

  void _performCharacterBlink() {
    if (!mounted || !_spineReady || _spineController == null) {
      return;
    }
    // Tap animations own the eyes; semantic gestures and held gaze should not
    // be interrupted by a long eyes-closed idle beat.
    if (_tapReactionActive || _motionBusy || _gazeHeld || _speechBlinkClosed) {
      _scheduleCharacterBlink();
      return;
    }
    final details = characterFacialDetails(
      _appearance.baseAppearanceId ?? _appearance.id,
      _currentExpression,
    );
    final detail =
        _activeFacialDetail ?? (details.isEmpty ? null : details.first);
    final closedEye =
        _resolveResourceClip(_activeResourceExpression?.eyeClosed) ??
        detail?.closedEye;
    if (closedEye != null &&
        _spineController!.skeletonData.findAnimation(closedEye) != null) {
      _speechBlinkClosed = true;
      _setFacialAnimation(
        11,
        closedEye,
        loop: false,
        mixDuration: _blinkBeat.fast ? 0.03 : 0.055,
      );
      _blinkRestoreTimer?.cancel();
      _blinkRestoreTimer = Timer(
        Duration(milliseconds: (_blinkBeat.closedFor * 1000).round()),
        () {
          _speechBlinkClosed = false;
          if (!mounted || !_spineReady || _tapReactionActive) return;
          _setFacialAnimation(11, _openEye, mixDuration: 0.09);
        },
      );
    }
    _scheduleCharacterBlink();
  }

  void _scheduleMicroMotion() {
    if (widget.controller.continuousAsmr) return;
    _microMotionTimer?.cancel();
    if (!_spineReady || !_appearance.animated) return;
    // Speech retains resource-authored torso beats. Explicit gestures keep
    // priority; the speaking candidate filter below never selects random arms.
    final delay = _randomDuration(
      _resourceEmotion?.poseRerollIntervalMin ?? 5,
      _resourceEmotion?.poseRerollIntervalMax ?? 8,
    );
    _microMotionTimer = Timer(delay, () {
      if (!mounted) return;
      if (_tapReactionActive || _gazePointer != null) {
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

  void _playAmbientMotion() {
    if (!_spineReady ||
        _motionBusy ||
        _tapReactionActive ||
        _motionGroups.isEmpty) {
      return;
    }
    final band = _performanceDirector.profile.tensionProfile(
      _currentExpression.name,
      _performanceDirector.tensionBand,
    );
    final poseTypes =
        (_resourceEmotion?.basePoses ?? const <ResourceBasePose>[])
            .where((pose) => pose.id == _currentIdleAnimation)
            .expand((pose) => pose.poseTypeIds)
            .toList();
    final torso = idleTorsoWeights(band, poseTypes);
    final poseType = _resourceBehavior.choosePoseType(
      poseTypes,
      _activePoseType,
      _random,
    );
    _activePoseType = poseType;
    final idleWeights = <String, double>{
      if (torso != null)
        for (final group in _motionGroups.where(
          (g) => g.occupancy.contains('E') || g.occupancy.contains('H'),
        ))
          group.id: torso[group.id] is num
              ? (torso[group.id] as num).toDouble()
              : 0,
    };
    // Idle uses authored weights only; explicit zero means disabled. Semantic
    // actions still have access to the full compatible gesture catalogue.
    final candidates = _motionGroups
        .where(
          (group) =>
              _isPromptPlayableMotionGroup(group) &&
              (!_isCharacterSpeaking ||
                  isSpeakingTorsoMotion(group.occupancy, torso?[group.id])) &&
              (idleWeights[group.id] ??
                      group.weightFor(_currentExpression, poseType: poseType)) >
                  0,
        )
        .toList(growable: false);
    if (candidates.isEmpty) return;
    final group = selectCharacterAmbientMotionGroup(
      groups: candidates,
      expression: _currentExpression,
      pose: _currentIdleAnimation,
      recentGroupIds: _recentAmbientGroupIds.toSet(),
      random: _random,
      allowLargePostureChanges:
          !_isCharacterSpeaking && !_resourceBehavior.fixedBasePoseMode,
      authoredOnly: true,
      sittingId: _sittingId,
      poseType: poseType,
      groupWeights: idleWeights,
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
    final posture = postureCueForAssistantResponse(response);
    if (posture != null && posture != _lastPostureCue) {
      _lastPostureCue = posture;
      _selectPosture(posture);
    }
    final cue = performanceCueForAssistantResponse(response);
    final expression = cue.expression;
    if (expression != null &&
        (expression != _currentExpression ||
            cue.expressionIntensity != _expressionIntensity)) {
      _applyExpression(expression, intensity: cue.expressionIntensity);
    }
    final actions = cue.actions.isEmpty && cue.action != null
        ? <CharacterAction>[cue.action!]
        : cue.actions;
    final motionGroupIds = cue.motionGroupIds;
    if (actions.isEmpty && motionGroupIds.isEmpty) return;
    final key =
        '${actions.map((a) => a.name).join('+')}|${motionGroupIds.join('+')}:${cue.actionCueCount}';
    if (_lastPerformanceActionKey == key) {
      RuntimeLog.instance.info('ActionPlanner', '回复动作去重，跳过：$key');
      return;
    }
    _lastPerformanceActionKey = key;
    // Play the first authored gesture immediately; queue the remaining
    // compatible gestures so a line can combine expression, posture and hand
    // intent instead of collapsing to its last tag.
    for (final item in actions.take(3)) {
      if (item != CharacterAction.none) _performSemanticAction(item);
    }
    for (final motionGroupId in motionGroupIds.take(2)) {
      _performMotionGroupIntent(motionGroupId);
    }
  }

  void _applySpeechSegmentPerformance(RyzaPerformanceSegment segment) {
    if (segment.posture case final posture?) _selectPosture(posture);
    if (segment.expression case final expression?) {
      _applyExpression(expression, intensity: segment.expressionIntensity);
    }
    if (segment.action case final action?) _performSemanticAction(action);
    for (final id in segment.motionGroupIds.take(2)) {
      _performMotionGroupIntent(id);
    }
  }

  void _performSemanticAction(CharacterAction action) {
    if (action == CharacterAction.none || !_spineReady || _tapReactionActive) {
      return;
    }
    _performanceQueue.add(action, _currentExpression, DateTime.now());
    _drainPerformanceQueue();
  }

  void _performMotionGroupIntent(String motionGroupId) {
    RuntimeLog.instance.info(
      'ActionPlanner',
      '收到动作：$motionGroupId；皮肤=${_appearance.id}；姿态=$_sittingId；基础动画=$_currentIdleAnimation',
    );
    if (!_spineReady || _tapReactionActive) {
      RuntimeLog.instance.warning(
        'ActionPlanner',
        '动作拦截：$motionGroupId；spineReady=$_spineReady，触碰反应=$_tapReactionActive',
      );
      return;
    }
    final normalized = characterMotionGroupIdFromTag(motionGroupId);
    if (normalized == null) {
      RuntimeLog.instance.warning('ActionPlanner', '动作标签格式无效：$motionGroupId');
      return;
    }
    final group = _motionGroups.cast<CharacterMotionGroup?>().firstWhere(
      (candidate) =>
          candidate?.id == normalized &&
          _isPromptPlayableMotionGroup(candidate!),
      orElse: () => null,
    );
    final recipe = _motionRecipes
        .where((r) => r.id == normalized && _canPlayRecipe(r))
        .firstOrNull;
    if (group == null && recipe == null) {
      RuntimeLog.instance.warning(
        'ActionPlanner',
        '资源或姿态不兼容：$normalized；基础动画=$_currentIdleAnimation，坐姿=$_sittingId',
      );
      return;
    }
    _performanceQueue.addMotionGroup(
      normalized,
      _currentExpression,
      DateTime.now(),
    );
    _drainPerformanceQueue();
  }

  final _performanceQueue = CharacterPerformanceQueue(
    onDiagnostic: (message) =>
        RuntimeLog.instance.info('ActionPlanner', message),
  );
  final List<String> _recentDialogueActions = [];
  void _rememberDialogueAction(String id) {
    _recentDialogueActions.add(id);
    if (_recentDialogueActions.length > 4) _recentDialogueActions.removeAt(0);
  }

  String? _lastQueueWaitReason;
  Timer? _performanceQueueTimer;

  void _clearPerformanceQueue() {
    _lastQueueWaitReason = null;
    _performanceQueueTimer?.cancel();
    _performanceQueue.clear();
  }

  void _drainPerformanceQueue() {
    _performanceQueueTimer?.cancel();
    if (!mounted || !_spineReady || _tapReactionActive) {
      if (_performanceQueue.isNotEmpty) {
        RuntimeLog.instance.warning(
          'ActionPlanner',
          '停止调度：mounted=$mounted，spineReady=$_spineReady，触碰反应=$_tapReactionActive',
        );
      }
      _performanceQueue.clear();
      return;
    }
    final now = DateTime.now();
    final coolingDown =
        _lastSemanticActionAt != null &&
        now.difference(_lastSemanticActionAt!) < const Duration(seconds: 3);
    final queued = _performanceQueue.peek(now);
    final queuedGroup = queued?.motionGroupId == null
        ? null
        : _motionGroups
              .where(
                (group) =>
                    group.id == queued!.motionGroupId &&
                    _isPromptPlayableMotionGroup(group),
              )
              .firstOrNull;
    final canOverlap =
        queuedGroup != null &&
        _motionLayers.canOverlap(queuedGroup.occupiedTracks);
    if ((_motionBusy || coolingDown) && !canOverlap) {
      if (_performanceQueue.isNotEmpty) {
        final reason =
            '等待：当前动作=$_activeMotionGroupId；忙碌=$_motionBusy；冷却=$coolingDown';
        if (_lastQueueWaitReason != reason) {
          RuntimeLog.instance.info('ActionPlanner', reason);
          _lastQueueWaitReason = reason;
        }
        _performanceQueueTimer = Timer(
          const Duration(milliseconds: 200),
          _drainPerformanceQueue,
        );
      }
      return;
    }
    _lastQueueWaitReason = null;
    final cue = _performanceQueue.take(now);
    if (cue == null) return;
    _applyExpression(cue.expression);
    if (cue.motionGroupId case final motionGroupId?) {
      _playMotionGroupNow(motionGroupId);
    } else {
      _playSemanticActionNow(cue.action);
      if (_motionBusy) _rememberDialogueAction(cue.action.name);
    }
    if (_performanceQueue.isNotEmpty) {
      _performanceQueueTimer = Timer(
        const Duration(milliseconds: 200),
        _drainPerformanceQueue,
      );
    }
  }

  void _playMotionGroupNow(String motionGroupId) {
    if (!_spineReady || _tapReactionActive) {
      RuntimeLog.instance.warning(
        'ActionPlanner',
        '播放前拦截：$motionGroupId；ready=$_spineReady，触碰=$_tapReactionActive，忙碌=$_motionBusy',
      );
      return;
    }
    final recipe = _motionRecipes
        .where((r) => r.id == motionGroupId && _canPlayRecipe(r))
        .firstOrNull;
    if (recipe != null) {
      if (_motionBusy) return;
      RuntimeLog.instance.info(
        'ActionPlanner',
        '播放组合：${recipe.id} ${recipe.name}（${recipe.stages.length}阶段）',
      );
      _playRecipeStage(recipe, 0);
      _rememberDialogueAction(recipe.id);
      _lastSemanticActionAt = DateTime.now();
      _recentAmbientGroupIds
        ..remove(recipe.id)
        ..add(recipe.id);
      if (_recentAmbientGroupIds.length > 5) _recentAmbientGroupIds.removeAt(0);
      return;
    }
    final group = _motionGroups.cast<CharacterMotionGroup?>().firstWhere(
      (candidate) =>
          candidate?.id == motionGroupId &&
          _isPromptPlayableMotionGroup(candidate!),
      orElse: () => null,
    );
    if (_motionBusy &&
        (group == null || !_motionLayers.canOverlap(group.occupiedTracks))) {
      RuntimeLog.instance.warning('ActionPlanner', '动作占用冲突：$motionGroupId');
      return;
    }
    // The model already chose face explicitly. Auto-pairing is for manual
    // previews only; otherwise an action silently replaces the dialogue face.
    if (group != null && _playMotionGroup(group)) {
      _rememberDialogueAction(group.id);
      _lastSemanticActionAt = DateTime.now();
    } else {
      RuntimeLog.instance.warning(
        'ActionPlanner',
        '播放失败：$motionGroupId；资源或姿态已变化',
      );
    }
  }

  void _playSemanticActionNow(CharacterAction action) {
    if (!_spineReady ||
        _tapReactionActive ||
        _motionBusy ||
        action == CharacterAction.none) {
      return;
    }
    final now = DateTime.now();
    if (_lastSemanticActionAt != null &&
        now.difference(_lastSemanticActionAt!) < const Duration(seconds: 3)) {
      return;
    }
    final attitude = switch (action) {
      CharacterAction.acknowledge => 'agree',
      CharacterAction.disagree => 'deny',
      CharacterAction.think => 'question',
      _ => null,
    };
    final bindings = _resourceEmotion?.fixedGestureBindingsByAttitude[attitude];
    if (bindings != null) {
      final selected = chooseResourceWeighted(
        bindings.where(
          (binding) =>
              _resolveResourceClip(binding.oneShotAnimation) != null ||
              _motionGroups.any(
                (group) =>
                    group.id == binding.fixedGestureId &&
                    _canPlayMotionGroup(group),
              ),
        ),
        (binding) => binding.weight,
        _random,
      );
      if (selected != null) {
        final animation = _resolveResourceClip(selected.oneShotAnimation);
        if (animation != null && _playOneShotAnimation(animation)) {
          _lastSemanticActionAt = now;
          return;
        }
        for (final group in _motionGroups.where(
          (group) =>
              group.id == selected.fixedGestureId && _canPlayMotionGroup(group),
        )) {
          if (_playMotionGroup(group)) {
            _lastSemanticActionAt = now;
            return;
          }
        }
      }
      // An authored empty/disabled binding means no gesture for this attitude.
      return;
    }
    final plan = characterActionPlan(
      _appearance.baseAppearanceId ?? _appearance.id,
      action,
    );
    final candidates = _motionGroups
        .where(
          (group) =>
              plan.motionGroupIds.contains(group.id) &&
              _canPlayMotionGroup(group),
        )
        .toList();
    final variants = <String, int>{};
    for (final group in candidates) {
      variants[group.id] = (variants[group.id] ?? 0) + 1;
    }
    final group = chooseResourceWeighted(
      candidates,
      (group) => group.weightFor(_currentExpression) / variants[group.id]!,
      _random,
    );
    if (group != null && _playMotionGroup(group)) {
      _lastSemanticActionAt = now;
      return;
    }
    // A casual joke or comforting sentence need not become a double peace sign
    // or a full reach/hug. Keep its face/driver when no authored arm fits.
    if (action == CharacterAction.playful ||
        action == CharacterAction.comfort ||
        action == CharacterAction.shy) {
      return;
    }
    if (candidates.isNotEmpty &&
        (action == CharacterAction.wave ||
            action == CharacterAction.surprised)) {
      if (_playMotionGroup(candidates[_random.nextInt(candidates.length)])) {
        _lastSemanticActionAt = now;
        return;
      }
    }
    final fallback = plan.oneShotFallback;
    if (fallback != null && _playOneShotAnimation(fallback)) {
      _lastSemanticActionAt = now;
    }
  }

  @override
  void dispose() {
    _clearPerformanceQueue();
    _outfitReactionTimer?.cancel();
    _replyGeneration += 1;
    _memoryRefreshGate.invalidate();
    _suggestionGeneration += 1;
    final replyIterator = _replyIterator;
    _replyIterator = null;
    if (replyIterator != null) unawaited(replyIterator.cancel());
    widget.controller.removeListener(_handleControllerChange);
    widget.controller.frameRate.removeListener(_handleFrameRateChange);
    widget.controller.frameRate.setActivity(
      FrameRateActivity.characterMotion,
      false,
    );
    widget.controller.frameRate.setActivity(FrameRateActivity.speech, false);
    widget.controller.frameRate.setActivity(
      FrameRateActivity.interfaceAnimation,
      false,
    );
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
    _playerStateSubscription?.cancel();
    _audioPlayer.dispose();
    _mimoTtsClient.close();
    _effectPlayer.dispose();
    _idleTimer?.cancel();
    _tapReactionTimer?.cancel();
    for (final timer in _motionReleaseTimers.values) {
      timer.cancel();
    }
    _motionReleaseTimers.clear();
    _microMotionTimer?.cancel();
    _facialDetailTimer?.cancel();
    _blinkTimer?.cancel();
    _blinkRestoreTimer?.cancel();
    _suggestionQuotaTimer?.cancel();

    _inputController.dispose();
    _narrationInputController.dispose();
    _narrationBottomInputController.dispose();
    _scrollController.removeListener(_handleConversationScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _reactToTap(Offset localPosition) async {
    final reaction = _hitTestReaction(localPosition);
    if (reaction == null) {
      return;
    }
    _clearPerformanceQueue();
    widget.controller.recordCharacterTouch();
    var restoreDelay = const Duration(milliseconds: 350);
    if (_spineReady && _spineController != null) {
      if (!_tapReactionActive) {
        _tapSuspendedMotions = _captureTapMotions();
        _tapSuspendedMotionLoadGeneration = _motionLoadGeneration;
      }
      _tapReactionActive = true;
      _blinkRestoreTimer?.cancel();
      _speechBlinkClosed = false;
      _resetMotionOverlays();
      _lipSyncEntry = null;
      final state = _spineController!.animationState;
      for (var track = 11; track <= 16; track++) {
        state.clearTrack(track);
      }
      final touchAnimation = _spineController!.skeletonData.findAnimation(
        reaction.animation,
      );
      if (touchAnimation != null) {
        restoreDelay = Duration(
          milliseconds: ((touchAnimation.getDuration() + 0.36) * 1000).ceil(),
        );
        state
          ..setAnimationByName(
            1,
            reaction.animation,
            false,
          ).setMixDuration(0.34)
          ..addEmptyAnimation(1, 0.36, 0);
      } else {
        // A skin may omit an optional touch animation. Keep the tap feedback
        // and voice without calling Spine with an unknown animation name.
        _tapReactionActive = false;
        _restoreTapMotions();
      }
    }
    _tapReactionTimer?.cancel();
    _tapReactionTimer = Timer(restoreDelay, () {
      if (!mounted) return;
      _tapReactionActive = false;
      _restoreTapMotions();
      _applyExpression(_currentExpression);
      if (_isCharacterSpeaking) {
        _scheduleFacialDetailChange();
        _scheduleCharacterBlink();
      }
    });
    widget.controller.frameRate.boost(
      FrameRateActivity.characterMotion,
      duration: restoreDelay,
    );
    if (!widget.controller.voiceEnabled || _isReplying) return;
    await _audioPlayer.stop();
    await _audioPlayer.setVolume(widget.controller.voiceVolume);
    try {
      await _audioPlayer.play(
        AssetSource(
          reaction.localizedVoiceAsset(
            widget.controller.characterReplyLanguage,
            _random.nextInt(3) + 1,
            asmr: widget.controller.asmrModeEnabled,
          ),
        ),
      );
    } on Object {
      await _audioPlayer.play(
        AssetSource(
          reaction.voiceAsset(
            _random.nextInt(3) + 1,
            asmr: widget.controller.asmrModeEnabled,
          ),
        ),
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
      late final List<double> vertices;
      try {
        vertices = attachment.computeWorldVertices(slot);
      } on Object catch (error) {
        RuntimeLog.instance.warning(
          'Interaction',
          '跳过无效点击碰撞体 slot=${slot.getData().getName()} error=$error',
        );
        continue;
      }
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

  String? _pendingOutfitReaction;
  Timer? _outfitReactionTimer;
  void _scheduleOutfitReaction() {
    _outfitReactionTimer?.cancel();
    _outfitReactionTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted || _pendingOutfitReaction == null) return;
      if (_isReplying) {
        _scheduleOutfitReaction();
        return;
      }
      final event = _pendingOutfitReaction!;
      _pendingOutfitReaction = null;
      unawaited(_sendMessage(automaticPrompt: event));
    });
  }

  Future<void> _sendMessage({String? automaticPrompt}) async {
    final rawText = _inputController.text.trim();
    final narration = _narrationInputController.text.trim();
    final narrationBottom = _narrationBottomInputController.text.trim();
    if ((rawText.isEmpty &&
            narration.isEmpty &&
            narrationBottom.isEmpty &&
            _pendingAttachments.isEmpty &&
            automaticPrompt == null) ||
        _isReplying) {
      return;
    }
    final attachments = automaticPrompt == null
        ? List<ChatAttachment>.unmodifiable(_pendingAttachments)
        : <ChatAttachment>[];
    final text =
        automaticPrompt ??
        [
          if (narration.isNotEmpty) '旁白：$narration',
          if (rawText.isNotEmpty || narrationBottom.isNotEmpty) '发言：$rawText',
          if (narrationBottom.isNotEmpty) '旁白：$narrationBottom',
          if (narration.isEmpty && rawText.isEmpty && narrationBottom.isEmpty)
            '请分析我发送的附件。',
        ].join('\n');
    final isAutomatic = automaticPrompt != null;
    if (!isAutomatic) _recordUserActivity();
    widget.controller.removeFailedReplies();

    _cancelSpeechPlayback();
    if (!isAutomatic) _inputController.clear();
    if (!isAutomatic) _narrationInputController.clear();
    if (!isAutomatic) _narrationBottomInputController.clear();
    if (!isAutomatic) {
      widget.controller.addUserMessage(text, attachments: attachments);
    }
    _lastPerformanceActionKey = null;
    _lastPostureCue = null;
    setState(() {
      if (!isAutomatic) _pendingAttachments.clear();
      _isReplying = true;
      _isContinuing = isAutomatic;
      _manualPanelFraction = null;
    });
    widget.controller.frameRate.setActivity(
      FrameRateActivity.interfaceAnimation,
      true,
    );
    final generation = ++_replyGeneration;
    _scrollToBottom();

    if (!widget.controller.aiEnabled) {
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (!mounted || generation != _replyGeneration) return;
      final reply = widget.controller.demoReply(text);
      widget.controller.addAssistantMessage(reply);
      _showLatestAssistantFromStartIfOverflow();
      await _playTtsIfConfigured(reply);
      if (mounted && generation == _replyGeneration) {
        setState(() {
          _isReplying = false;
          _isContinuing = false;
        });
        widget.controller.frameRate.setActivity(
          FrameRateActivity.interfaceAnimation,
          false,
        );
      }
      return;
    }

    final requestProvider = widget.controller.llmProvider;
    final requestBaseUrl = widget.controller.activeLlmBaseUrl;
    final requestModel = widget.controller.activeLlmModel;
    final requestIndependentTranslation =
        widget.controller.independentTranslation;
    final apiKey = await _secretStore.readLlmKey(
      requestProvider,
      openAiSlot: widget.controller.activeOpenAiSlot,
    );
    if (!mounted || generation != _replyGeneration) return;
    if (apiKey.isEmpty) {
      _stopSpeakingAnimation();
      widget.controller.addAssistantMessage(
        '请先在设置中填写 ${widget.controller.llmProvider.label} 的 API Key。',
      );
      if (mounted) {
        setState(() {
          _isReplying = false;
          _isContinuing = false;
        });
        widget.controller.frameRate.setActivity(
          FrameRateActivity.interfaceAnimation,
          false,
        );
      }
      return;
    }

    widget.controller.beginAssistantStream();
    StreamIterator<String>? iterator;
    try {
      RuntimeLog.instance.info(
        'AI',
        '开始流式回复 provider=${widget.controller.llmProvider.name}, '
            'model=${widget.controller.activeLlmModel}, '
            'agent=${widget.controller.agentEnabled}, attachments=${attachments.length}',
      );
      iterator = StreamIterator<String>(
        _aiClient.streamChat(
          provider: requestProvider,
          baseUrl: requestBaseUrl,
          apiKey: apiKey,
          model: requestModel,
          systemPrompt: widget.controller.buildCharacterPrompt(
            independentPerformance: true,
            currentInput: text,
            performanceContext: _buildPerformancePromptContext(),
          ),
          messages: widget.controller.contextMessagesForModel(
            pending: isAutomatic ? ChatMessage(text: text, isUser: true) : null,
          ),
          // Reasoning is opt-in; output budget controls remain disabled.
          reasoningEffort: widget.controller.activeReasoningEffort,
          thinkingEnabled: widget.controller.activeThinkingEnabled,
          outputMultiplier: null,
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
        _showLatestAssistantFromStartIfOverflow();
      }
      if (generation != _replyGeneration) return;
      final reply = widget.controller.messages.last.text;
      widget.controller.finishAssistantStream();
      if (requestIndependentTranslation &&
          widget.controller.messages.isNotEmpty &&
          widget.controller.messages.last.text == reply &&
          reply.trim().isNotEmpty) {
        unawaited(
          _translateReply(
            widget.controller.messages.last,
            apiKey,
            provider: requestProvider,
            baseUrl: requestBaseUrl,
            model: requestModel,
          ),
        );
      }
      _showLatestAssistantFromStartIfOverflow();
      RuntimeLog.instance.info('AI', '流式回复完成，字符数=${reply.length}');
      if (widget.controller.longTermMemoryEnabled &&
          (_memoryRefreshGate.refreshAfterLoad || !isAutomatic) &&
          (_memoryRefreshGate.refreshAfterLoad ||
              widget.controller.userMessageCount % 4 == 0 ||
              AppController.shouldRefreshMemoryImmediately(text))) {
        unawaited(
          _refreshLongTermMemory(
            apiKey,
            provider: requestProvider,
            baseUrl: requestBaseUrl,
            model: requestModel,
          ),
        );
      } else {
        RuntimeLog.instance.info(
          'Memory',
          '未触发整理：enabled=${widget.controller.longTermMemoryEnabled}, automatic=$isAutomatic, userMessages=${widget.controller.userMessageCount}（普通对话每4条触发）',
        );
      }
      final capabilities = _buildPerformancePromptContext();
      final recentDialogue = widget.controller.messages
          .where((m) => m.text != reply)
          .toList();
      final sharedContext = <String, dynamic>{
        'current_reply': reply,
        'user_intent_text': text,
        'previous_dialogue': recentDialogue.reversed
            .take(3)
            .toList()
            .reversed
            .map(
              (m) => {
                'speaker': m.isUser ? 'user' : 'assistant',
                'text': m.text.length > 600 ? m.text.substring(0, 600) : m.text,
              },
            )
            .toList(),
        'emotion': widget.controller.characterState.emotion,
        'state': widget.controller.characterState.values,
        'current_face': _currentExpression.name,
        'previous_voice_emotion': _previousSpeechEmotion,
      };
      // Independent of animation planning: run concurrently, never expose
      // the voice tag catalogue to the roleplay request.
      final speechPlanning = _planSpeechForReply(
        reply,
        (messages) => _aiClient.complete(
          provider: requestProvider,
          baseUrl: requestBaseUrl,
          apiKey: apiKey,
          model: requestModel,
          lightweight: true,
          fastPlanning: true,
          messages: messages,
        ),
        sharedContext: sharedContext,
      );
      // Singing is deliberately opt-in: ordinary dialogue never pays for
      // this extra planner request and is always synthesized as speech.
      final singingPlanning = _planSingingForReply(
        text,
        reply,
        (messages) => _aiClient.complete(
          performancePlanning: true,
          provider: requestProvider,
          baseUrl: requestBaseUrl,
          apiKey: apiKey,
          model: requestModel,
          lightweight: true,
          messages: messages,
        ),
      );
      final stateRevision = widget.controller.dataRevision;
      final stateTurn = '${DateTime.now().microsecondsSinceEpoch}:$generation';
      final performancePlanning = () async {
        var performanceText = PerformancePlanner.withoutControls(reply);
        Map<String, dynamic>? stateProposal;
        try {
          RuntimeLog.instance.info('AI', '独立表情与动作规划已启动，不阻塞语音合成');
          final planned = await IndependentPerformanceTools().plan(
            userInput: text,
            source: reply,
            capabilities: capabilities,
            currentFace: _currentExpression.name,
            currentIntensity: _expressionIntensity,
            sharedContext: sharedContext,
            onMismatch: (reason) {
              if (!mounted || generation != _replyGeneration) return;
              RuntimeLog.instance.warning(
                'ActionPlanner',
                '旁白/动作一致性检查未通过：$reason；未播放替代动作',
              );
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    widget.controller.interfaceLanguage.text(
                      '本轮动作无法准确呈现，已跳过。详情见动作日志。',
                      'This action could not be represented accurately and was skipped. See action logs.',
                      '動作を正確に再現できないためスキップしました。詳細は動作ログをご確認ください。',
                    ),
                  ),
                ),
              );
            },
            characterState: {
              'values': widget.controller.characterState.values,
              'emotion': widget.controller.characterState.emotion,
              if (widget.controller.storyClockEnabled)
                'story_clock': widget.controller.storyClock.toJson(),
              'reason_language':
                  widget.controller.interfaceLanguage.promptLabel,
            },
            storyClockEnabled: widget.controller.storyClockEnabled,
            onStateProposal: (proposal) => stateProposal = proposal,
            recentActions: _recentDialogueActions.reversed.toList(),
            complete: (messages) => _aiClient.complete(
              performancePlanning: true,
              provider: requestProvider,
              baseUrl: requestBaseUrl,
              apiKey: apiKey,
              model: requestModel,
              lightweight: true,
              messages: messages,
            ),
          );
          if (!mounted || generation != _replyGeneration) {
            return performanceText;
          }
          final current = _buildPerformancePromptContext();
          if (current.appearanceId == capabilities.appearanceId &&
              current.revision == capabilities.revision) {
            performanceText = planned;
            RuntimeLog.instance.info('AI', '独立表演规划完成：$planned');
          }
        } on Object catch (error) {
          RuntimeLog.instance.warning('AI', '表演规划跳过，继续原文播放：$error');
        }
        if (mounted &&
            generation == _replyGeneration &&
            stateProposal != null) {
          final settled = widget.controller.settleCharacterState(
            stateTurn,
            stateProposal!,
            stateRevision,
          );
          RuntimeLog.instance.info(
            'CharacterState',
            settled ? '本轮状态已更新' : '状态提议无效或存档已改变，保留原值',
          );
        }
        if (mounted && generation == _replyGeneration) {
          widget.controller.settleStoryTime(
            stateTurn,
            stateProposal,
            stateRevision,
          );
        }
        return performanceText;
      }();
      var speechText = PerformancePlanner.withoutControls(reply);
      final speechPlan = await speechPlanning;
      if (!mounted || generation != _replyGeneration) return;
      if (speechPlan != null) {
        try {
          speechText = speechPlan.apply(speechText);
          _previousSpeechEmotion = speechPlan.lastEmotion;
        } on FormatException catch (error) {
          RuntimeLog.instance.warning('TTS', '语音规划与台词不匹配，回退本地规则：$error');
        }
      }
      final singingPlan = await singingPlanning;
      if (!mounted || generation != _replyGeneration) return;
      if (singingPlan != null) {
        speechText = singingPlan.apply(speechText);
      }
      final plannedPerformance = performancePlanning.then((planned) {
        var result = planned;
        if (speechPlan != null) {
          try {
            result = speechPlan.apply(result);
          } on FormatException catch (error) {
            RuntimeLog.instance.warning('TTS', '表演文本无法复用语音规划：$error');
          }
        }
        if (singingPlan != null) result = singingPlan.apply(result);
        return result;
      });
      await _playTtsIfConfigured(
        speechText,
        displaySource: reply,
        plannedPerformance: plannedPerformance,
      );
      if (generation != _replyGeneration) return;
    } on Object catch (error, stackTrace) {
      if (generation != _replyGeneration) return;
      RuntimeLog.instance.error('AI', error, stackTrace);
      _stopSpeakingAnimation();
      widget.controller.failAssistantStream(error.toString());
    } finally {
      if (identical(_replyIterator, iterator)) _replyIterator = null;
      if (iterator != null) unawaited(iterator.cancel());
      if (mounted && generation == _replyGeneration) {
        setState(() {
          _isReplying = false;
          _isContinuing = false;
        });
        widget.controller.frameRate.setActivity(
          FrameRateActivity.interfaceAnimation,
          false,
        );
      }
    }
  }

  Future<void> _suggestUserReply() async {
    if (_isReplying ||
        _isSuggestingReply ||
        widget.controller.messages.isEmpty) {
      return;
    }
    final generation = ++_suggestionGeneration;
    if (widget.controller.suggestionUsesRemaining() <= 0) {
      final remaining = widget.controller.suggestionTimeUntilNextRefresh();
      final minutes = remaining.inMinutes;
      final seconds = remaining.inSeconds.remainder(60);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '建议回复次数已用完，$minutes分${seconds.toString().padLeft(2, '0')}秒后恢复 1 次',
          ),
        ),
      );
      return;
    }
    if (!widget.controller.aiEnabled) {
      if (!widget.controller.consumeSuggestionUse()) return;
      final suggestion = widget.controller.interfaceLanguage.text(
        '我还不太明白，可以换一种更简单的方式说明吗？',
        'I am not quite sure how to answer that. Could you explain it more simply?',
        'まだうまく答えられないから、もう少し分かりやすく説明してくれる？',
      );
      _replaceComposerText(suggestion);
      return;
    }
    final requestProvider = widget.controller.llmProvider;
    final requestBaseUrl = widget.controller.activeLlmBaseUrl;
    final requestModel = widget.controller.activeLlmModel;
    final apiKey = await _secretStore.readLlmKey(
      requestProvider,
      openAiSlot: widget.controller.activeOpenAiSlot,
    );
    if (!mounted || generation != _suggestionGeneration) return;
    if (apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '请先在设置中填写 ${widget.controller.llmProvider.label} 的 API Key。',
          ),
        ),
      );
      return;
    }
    if (!widget.controller.consumeSuggestionUse()) return;
    setState(() => _isSuggestingReply = true);
    widget.controller.frameRate.setActivity(
      FrameRateActivity.interfaceAnimation,
      true,
    );
    final buffer = StringBuffer();
    try {
      await for (final delta in _aiClient.streamChat(
        provider: requestProvider,
        baseUrl: requestBaseUrl,
        apiKey: apiKey,
        model: requestModel,
        systemPrompt: widget.controller.buildUserReplySuggestionPrompt(),
        messages: widget.controller.recentMessages(limit: 12),
        reasoningEffort: widget.controller.activeReasoningEffort,
        thinkingEnabled: widget.controller.activeThinkingEnabled,
        outputMultiplier: null,
        agentEnabled: false,
      )) {
        if (generation != _suggestionGeneration) return;
        buffer.write(delta);
      }
      if (!mounted || generation != _suggestionGeneration) return;
      final suggestion = _cleanSuggestedReply(buffer.toString());
      if (suggestion.isNotEmpty) _replaceComposerText(suggestion);
    } on Object catch (error, stackTrace) {
      if (generation != _suggestionGeneration) return;
      RuntimeLog.instance.error('AI suggestion', error, stackTrace);
      if (mounted && generation == _suggestionGeneration) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('建议回复生成失败，请稍后重试')));
      }
    } finally {
      if (mounted && generation == _suggestionGeneration) {
        setState(() => _isSuggestingReply = false);
        widget.controller.frameRate.setActivity(
          FrameRateActivity.interfaceAnimation,
          false,
        );
      }
    }
  }

  String _cleanSuggestedReply(String value) {
    var result = value
        .replaceAll('```', '')
        .replaceFirst(RegExp(r'^\s*(?:用户|你|User)\s*[：:]\s*'), '')
        .trim();
    if (result.length >= 2 &&
        ((result.startsWith('“') && result.endsWith('”')) ||
            (result.startsWith('"') && result.endsWith('"')))) {
      result = result.substring(1, result.length - 1).trim();
    }
    return result;
  }

  void _replaceComposerText(String value) {
    _inputController
      ..text = value
      ..selection = TextSelection.collapsed(offset: value.length);
    setState(() => _manualPanelFraction = null);
  }

  DateTime _lastUserActivity = DateTime.now();
  bool _idleAsked = false;
  void _recordUserActivity() {
    _lastUserActivity = DateTime.now();
    _idleAsked = false;
  }

  void _checkIdleUser() {
    if (!mounted ||
        !widget.pageActive ||
        widget.controller.continuousAsmr ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        ModalRoute.of(context)?.isCurrent != true ||
        !widget.controller.aiEnabled) {
      _lastUserActivity = DateTime.now();
      return;
    }
    if (widget.controller.lastUiInteraction.isAfter(_lastUserActivity)) {
      _lastUserActivity = widget.controller.lastUiInteraction;
      _idleAsked = false;
    }
    if (_isReplying || _isCharacterSpeaking) {
      _lastUserActivity = DateTime.now();
      return;
    }
    if (_idleAsked ||
        _isReplying ||
        _inputController.text.trim().isNotEmpty ||
        _narrationInputController.text.trim().isNotEmpty ||
        _narrationBottomInputController.text.trim().isNotEmpty ||
        DateTime.now().difference(_lastUserActivity) <
            const Duration(minutes: 5)) {
      return;
    }
    _idleAsked = true;
    unawaited(
      _sendMessage(
        automaticPrompt:
            '应用事件：用户约五分钟没有回应。用一句自然、不催促的话关心用户在做什么；不要假装能看到用户，不责怪，不重复上一句。',
      ),
    );
  }

  Future<void> _openContinuousAsmr() async {
    if (_isReplying) _cancelReply();
    _cancelSpeechPlayback();
    _stopSpeakingAnimation();
    final previous = widget.controller.ttsVoiceMode;
    if (!widget.controller.setTtsVoiceMode(TtsVoiceMode.asmr)) {
      _selectTtsVoiceMode(TtsVoiceMode.asmr);
      return;
    }
    widget.controller.setContinuousAsmr(true);
    _idleTimer?.cancel();
    _tapReactionTimer?.cancel();
    _outfitReactionTimer?.cancel();
    _microMotionTimer?.cancel();
    _facialDetailTimer?.cancel();
    _blinkTimer?.cancel();
    _blinkRestoreTimer?.cancel();
    await _audioPlayer.stop();
    await _effectPlayer.stop();
    if (!mounted) {
      widget.controller.setContinuousAsmr(false);
      return;
    }
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => ContinuousAsmrPage(controller: widget.controller),
        ),
      );
    } finally {
      widget.controller.setContinuousAsmr(false);
      widget.controller.setTtsVoiceMode(previous);
      _recordUserActivity();
      if (mounted) {
        _scheduleIdleChange();
        _scheduleMicroMotion();
        _scheduleCharacterBlink();
        _scheduleFacialDetailChange();
      }
    }
  }

  void _continueConversation() {
    _sendMessage(
      automaticPrompt:
          '请基于当前对话自然地继续说下去。不要解释这是自动继续，也不要重复上一条内容；用莱莎的口吻补充一个有意义的回应或问题。',
    );
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
    setState(() {
      _isReplying = false;
      _isContinuing = false;
    });
    widget.controller.frameRate.setActivity(
      FrameRateActivity.interfaceAnimation,
      false,
    );
    _scrollToBottom();
  }

  void _undoLastMessage() {
    if (_isReplying) _cancelReply();
    _cancelSpeechPlayback();
    if (widget.controller.removeFailedReplies()) return;
    final withdrawn = widget.controller.undoLastUserTurn();
    if (withdrawn == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没有可以撤回的用户消息')));
      return;
    }
    unawaited(_clearLastSpeech());
    final restoredText = withdrawn.text == '请分析我发送的附件。' ? '' : withdrawn.text;
    final restored = parseUserComposerParts(restoredText);
    _inputController
      ..text = restored.speech
      ..selection = TextSelection.collapsed(offset: restored.speech.length);
    _narrationInputController
      ..text = restored.narration
      ..selection = TextSelection.collapsed(offset: restored.narration.length);
    _narrationBottomInputController
      ..text = restored.bottomNarration
      ..selection = TextSelection.collapsed(
        offset: restored.bottomNarration.length,
      );
    if (restored.narration.isNotEmpty || restored.bottomNarration.isNotEmpty) {
      widget.controller.setSplitNarrationComposer(true);
    }
    setState(() {
      _pendingAttachments
        ..clear()
        ..addAll(
          withdrawn.attachments.where((attachment) => attachment.bytes != null),
        );
      _manualPanelFraction = null;
    });
    _scrollToBottom();
  }

  Future<SpeechPlan?> _planSpeechForReply(
    String reply,
    AuxiliaryCompletion complete, {
    Map<String, dynamic> sharedContext = const {},
  }) async {
    if (!widget.controller.fishTtsEnabled ||
        !widget.controller.independentSpeechPerformance) {
      return null;
    }
    final intensity = widget.controller.ttsEmotionIntensity;
    final density = widget.controller.ttsCueDensity;
    final asmr = widget.controller.asmrModeEnabled;
    final previousEmotion = _previousSpeechEmotion;
    try {
      if ((await _secretStore.readTtsKey(widget.controller.ttsProvider))
          .isEmpty) {
        return null;
      }
      RuntimeLog.instance.info('SpeechPlanner', '独立语音演出规划开始');
      final plan = await SpeechPlanner()
          .plan(
            source: reply,
            sharedContext: sharedContext,
            previousEmotion: previousEmotion,
            intensity: intensity,
            density: density,
            asmr: asmr,
            complete: complete,
          )
          .timeout(const Duration(seconds: 3));
      RuntimeLog.instance.info('SpeechPlanner', '独立语音演出规划完成：${plan.lines}');
      return plan;
    } on Object catch (error) {
      RuntimeLog.instance.warning('SpeechPlanner', '语音演出规划失败，回退本地规则：$error');
      return null;
    }
  }

  bool _isStrongSingingRequest(String input) {
    if (widget.controller.ttsProvider != TtsProvider.fishAudio ||
        !widget.controller.fishTtsEnabled) {
      return false;
    }
    final normalized = input.trim().toLowerCase();
    if (normalized.isEmpty ||
        RegExp(r'不要唱|别唱|不用唱|不要哼|别哼|不会唱|唱得不好|don.?t sing|do not sing|no singing')
            .hasMatch(normalized)) {
      return false;
    }
    final singingIntent = RegExp(
      r'唱歌|唱一首|唱首歌|唱给我|唱出来|歌唱|演唱|哼唱|哼一段|用歌声|唱段|sing(?:ing)?|sing a song|sing for me|hum(?:ming)?',
    ).hasMatch(normalized);
    if (!singingIntent) return false;
    final explicitRequest = RegExp(
      r'请|给我|为我|现在|能不能|可以吗|想听|来一段|来首|唱歌给我|唱给我听|please|can you|i want you to|sing for me|sing a song',
    ).hasMatch(normalized);
    final bareCommand = RegExp(
      r'(?:^|[，,。！？!\s])(唱歌|哼唱|演唱|sing|hum)(?:吧|一下|给我|$)',
    ).hasMatch(normalized);
    return explicitRequest || bareCommand;
  }

  Future<SingingPlan?> _planSingingForReply(
    String userInput,
    String reply,
    AuxiliaryCompletion complete,
  ) async {
    if (!_isStrongSingingRequest(userInput)) return null;
    try {
      if ((await _secretStore.readTtsKey(widget.controller.ttsProvider))
          .isEmpty) {
        return null;
      }
      RuntimeLog.instance.info('SingingPlanner', '明确歌唱请求，独立歌唱标签规划开始');
      final plan = await SingingPlannerTool()
          .plan(userInput: userInput, source: reply, complete: complete)
          .timeout(const Duration(seconds: 3));
      RuntimeLog.instance.info(
        'SingingPlanner',
        '歌唱标签规划完成：${plan.tagsBySegment}',
      );
      return plan;
    } on Object catch (error) {
      RuntimeLog.instance.warning('SingingPlanner', '歌唱标签规划失败，回退普通语音：$error');
      return null;
    }
  }

  Future<void> _playTtsIfConfigured(
    String text, {
    String? displaySource,
    Future<String>? plannedPerformance,
  }) async {
    final replyGeneration = _replyGeneration;
    Future<String> fallbackPerformance() async {
      if (plannedPerformance == null) return text;
      try {
        return await plannedPerformance;
      } on Object catch (error) {
        RuntimeLog.instance.warning('ActionPlanner', '表演回退失败：$error');
        return text;
      }
    }

    final collectionMessage = widget.controller.messages
        .where((m) => !m.isUser && m.text == (displaySource ?? text))
        .lastOrNull;
    if (!_mayPlayVoice) {
      RuntimeLog.instance.warning(
        'ActionPlanner',
        '演出入口跳过：当前页面/前后台状态不允许语音播放，动作也未执行',
      );
      return;
    }
    if (text.trim().isEmpty) {
      _stopSpeakingAnimation();
      return;
    }
    if (!widget.controller.fishTtsEnabled) {
      final fallback = await fallbackPerformance();
      if (!mounted || replyGeneration != _replyGeneration) return;
      _applyPerformanceFromResponse(fallback);
      _stopSpeakingAnimation();
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
      TtsProvider.fishAudio =>
        widget.controller.activeFishAudioReferenceId.isEmpty,
      TtsProvider.dashScope =>
        widget.controller.dashScopeTtsBaseUrl.isEmpty ||
            widget.controller.activeDashScopeTtsVoice.isEmpty,
      TtsProvider.generic =>
        widget.controller.genericTtsBaseUrl.isEmpty ||
            widget.controller.activeGenericTtsVoice.isEmpty,
      TtsProvider.mimo => widget.controller.mimoTts.validationError != null,
    };
    if (apiKey.isEmpty || missingProviderSettings) {
      RuntimeLog.instance.warning(
        'TTS',
        '跳过合成：${widget.controller.ttsProvider.label} 的密钥或必要配置缺失',
      );
      final fallback = await fallbackPerformance();
      if (!mounted || replyGeneration != _replyGeneration) return;
      _applyPerformanceFromResponse(fallback);
      _stopSpeakingAnimation();
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
    List<RyzaPerformanceSegment>? plannedSegments = plannedPerformance == null
        ? segments
        : null;
    String? plannedText;
    var activeIndex = -1;
    var playbackFinished = false;
    final appliedPerformance = <int>{};
    void applyPerformanceAt(int index) {
      final cues = plannedSegments;
      if (cues == null || index < 0 || index >= cues.length) return;
      if (!appliedPerformance.add(index)) return;
      _applySpeechSegmentPerformance(cues[index]);
    }

    if (plannedPerformance != null) {
      unawaited(
        plannedPerformance.then<void>(
          (planned) {
            if (!mounted || generation != _speechPlaybackGeneration) return;
            final aligned = performanceSegmentsMatchingSpeech(
              text,
              planned,
              fallbackMood: widget.controller.characterMood,
            );
            if (aligned == null) {
              RuntimeLog.instance.warning(
                'ActionPlanner',
                '表演规划段落与语音正文不一致，跳过晚到动作',
              );
              return;
            }
            plannedText = planned;
            plannedSegments = aligned;
            for (var i = 0; i < completedSegments.length; i++) {
              completedSegments[i] = completedSegments[i].withPerformance(
                aligned[i],
              );
            }
            if (!playbackFinished) applyPerformanceAt(activeIndex);
            if (playbackFinished &&
                _lastSpeechSource == (displaySource ?? text)) {
              _lastSpeech = List<_CachedSpeechSegment>.unmodifiable(
                completedSegments,
              );
              _lastSpeechPerformance = planned;
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            RuntimeLog.instance.warning('ActionPlanner', '晚到表演规划失败：$error');
          },
        ),
      );
    }
    try {
      final model = switch (widget.controller.ttsProvider) {
        TtsProvider.fishAudio => widget.controller.fishAudioModel,
        TtsProvider.dashScope => widget.controller.dashScopeTtsModel,
        TtsProvider.generic => widget.controller.genericTtsModel,
        TtsProvider.mimo => widget.controller.mimoTts.model,
      };
      RuntimeLog.instance.info(
        'TTS',
        '开始合成 provider=${widget.controller.ttsProvider.label}, model=$model, '
            'segments=${segments.length}, voiceMode=${widget.controller.ttsVoiceMode.name}, '
            'emotion=${widget.controller.ttsEmotionIntensity.name}, '
            'cueDensity=${widget.controller.ttsCueDensity.name}, '
            'fishTemperature=${widget.controller.ttsEmotionIntensity.fishTemperature.toStringAsFixed(2)}',
      );
      Future<_PreparedSpeech> pending = _prepareSpeech(
        segments.first,
        apiKey,
        generation,
      );
      for (var index = 0; index < segments.length; index++) {
        final prepared = await pending;
        if (!mounted ||
            !_mayPlayVoice ||
            generation != _speechPlaybackGeneration) {
          unawaited(_deleteTemporarySpeech(prepared.path));
          return;
        }
        final next = index + 1 < segments.length
            ? _prepareSpeech(segments[index + 1], apiKey, generation)
            : null;
        final segment = segments[index];
        final displayIndex = _displayIndexForRyzaSegment(
          displaySource ?? text,
          index,
        );
        _showAssistantSegment(
          displayIndex,
          _readingDurationFor(segment.speechText),
        );
        activeIndex = index;
        applyPerformanceAt(index);
        await _audioPlayer.stop();
        await _audioPlayer.setVolume(widget.controller.voiceVolume);
        if (!mounted || generation != _speechPlaybackGeneration) {
          await _deleteTemporarySpeech(prepared.path);
          return;
        }
        _startSpeakingAnimation(
          envelope: prepared.envelope,
          awaitingAudio: true,
        );
        final completed = _audioPlayer.onPlayerComplete.first;
        await _audioPlayer.play(DeviceFileSource(prepared.path));
        await Future.any([completed, cancellation.future]);
        activeIndex = -1;
        if (generation != _speechPlaybackGeneration) {
          await _deleteSpeechSegments(completedSegments);
          await _deleteTemporarySpeech(prepared.path);
          return;
        }
        final performance = plannedSegments?[index] ?? segment;
        completedSegments.add(
          _CachedSpeechSegment(
            text: displayTextForAssistantSegment(
              ChatSegment(speaker: ChatSpeaker.ryza, text: segment.speechText),
            ),
            path: prepared.path,
            envelope: prepared.envelope,
            expression: performance.expression,
            expressionIntensity: performance.expressionIntensity,
            action: performance.action,
            posture: performance.posture,
            motionGroupIds: performance.motionGroupIds,
          ),
        );
        if (next != null) {
          _pauseSpeakingBetweenSegments();
          pending = next;
        } else {
          _stopSpeakingAnimation();
        }
      }
      if (collectionMessage != null) {
        try {
          final store = await ConversationCollectionStore.open();
          await store.cacheVoice(
            collectionMessage.collectionKey,
            completedSegments.map((s) => s.path).toList(),
            texts: completedSegments.map((s) => s.text).toList(),
          );
        } catch (error) {
          RuntimeLog.instance.warning('TTS', '语音缓存保存失败：$error');
        }
      }
      if (generation != _speechPlaybackGeneration) {
        await _deleteSpeechSegments(completedSegments);
        return;
      }
      await _replaceLastSpeech(completedSegments);
      _lastSpeechSource = displaySource ?? text;
      _lastSpeechPerformance = plannedText ?? text;
      if (plannedText != null) {
        _lastSpeech = List<_CachedSpeechSegment>.unmodifiable(
          completedSegments,
        );
      }
      playbackFinished = true;
      RuntimeLog.instance.info(
        'TTS',
        '合成与播放完成，分段数=${completedSegments.length}',
      );
      _stopSpeakingAnimation();
      _showAssistantSegment(null, Duration.zero);
      if (identical(_speechCancellation, cancellation)) {
        _speechCancellation = null;
      }
    } on Object catch (error, stackTrace) {
      RuntimeLog.instance.error('TTS', error, stackTrace);
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
      final fallback = await fallbackPerformance();
      if (!mounted || replyGeneration != _replyGeneration) return;
      _applyPerformanceFromResponse(fallback);
      _stopSpeakingAnimation();
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
    // Android MediaPlayer support for WAV varies by vendor. MP3 is used there
    // for reliable playback; desktop keeps WAV for deterministic lip sync.
    final playbackFormat = widget.controller.ttsProvider == TtsProvider.mimo
        ? 'wav'
        : Platform.isAndroid
        ? 'mp3'
        : 'wav';
    final ttsText = compressRepeatedTtsPunctuation(segment.speechText);
    final plainText = displayTextForAssistantSegment(
      ChatSegment(speaker: ChatSpeaker.ryza, text: ttsText),
    );
    final emotionIntensity = widget.controller.ttsEmotionIntensity;
    final plannedEmotion = RegExp(r'^\[([^\]]+)\]')
        .firstMatch(ttsText)
        ?.group(1);
    final voiceDirection = [
      if (emotionIntensity != TtsEmotionIntensity.off &&
          speechEmotionTags.contains(plannedEmotion))
        'Express $plannedEmotion naturally; preserve continuity with the preceding sentence.',
      if (widget.controller.asmrModeEnabled)
        'Speak softly in a close, quiet voice.',
    ].join(' ');
    final path = await switch (widget.controller.ttsProvider) {
      TtsProvider.fishAudio => _fishAudioClient.synthesize(
        apiKey: apiKey,
        referenceId: widget.controller.activeFishAudioReferenceId,
        model: widget.controller.fishAudioModel,
        format: playbackFormat,
        latency: widget.controller.fishAudioLatency,
        speed: widget.controller.fishAudioSpeed,
        baseUrl: widget.controller.fishAudioBaseUrl,
        temperature: emotionIntensity.fishTemperature,
        text: applyFishEmotionIntensityPerSentence(
          ttsText,
          emotionIntensity,
          density: widget.controller.ttsCueDensity,
          asmr: widget.controller.asmrModeEnabled,
        ),
      ),
      TtsProvider.dashScope => _dashScopeTtsClient.synthesize(
        apiKey: apiKey,
        baseUrl: widget.controller.dashScopeTtsBaseUrl,
        model: widget.controller.dashScopeTtsModel,
        voice: widget.controller.activeDashScopeTtsVoice,
        language: widget.controller.dashScopeTtsLanguage,
        instructions:
            widget.controller.dashScopeTtsModel.toLowerCase().contains(
              'instruct',
            )
            ? mergeTtsInstructions(
                '${widget.controller.dashScopeTtsInstructions} $voiceDirection'
                    .trim(),
                emotionIntensity,
              )
            : widget.controller.dashScopeTtsInstructions,
        text: plainText,
      ),
      TtsProvider.generic => _genericTtsClient.synthesize(
        apiKey: apiKey,
        baseUrl: widget.controller.genericTtsBaseUrl,
        model: widget.controller.genericTtsModel,
        voice: widget.controller.activeGenericTtsVoice,
        format: playbackFormat,
        speed: widget.controller.fishAudioSpeed,
        instructions:
            widget.controller.genericTtsModel.toLowerCase().contains(
              'gpt-4o-mini-tts',
            )
            ? '${ttsEmotionInstruction(emotionIntensity)} $voiceDirection'
                  .trim()
            : '',
        text: plainText,
      ),
      TtsProvider.mimo => _mimoTtsClient.synthesize(
        config: widget.controller.mimoTts,
        language: widget.controller.characterReplyLanguage,
        apiKey: apiKey,
        text: ttsText,
        intensity: emotionIntensity,
        density: widget.controller.ttsCueDensity,
        asmr: widget.controller.asmrModeEnabled,
      ),
    };
    _temporarySpeechPaths.add(path);
    if (generation != _speechPlaybackGeneration) {
      await _deleteTemporarySpeech(path);
      throw const AiServiceException('语音播放已取消');
    }
    final bytes = await File(path).readAsBytes();
    RuntimeLog.instance.info(
      'TTS',
      '音频文件已准备 provider=${widget.controller.ttsProvider.label}, '
          'format=$playbackFormat, bytes=${bytes.length}, file=${path.split(Platform.pathSeparator).last}',
    );
    return _PreparedSpeech(
      path: path,
      envelope: await loadSpeechEnvelope(path, bytes),
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
    _lastSpeechSource = null;
    _lastSpeechPerformance = null;
    final previous = _lastSpeech;
    _lastSpeech = const [];
    await _deleteSpeechSegments(previous);
    if (mounted) setState(() {});
  }

  Future<void> _regenerateLastSpeech() async {
    if (_isReplying || _regeneratingSpeech || !_mayPlayVoice) return;
    final message = widget.controller.messages
        .where((m) => !m.isUser && m.text.trim().isNotEmpty)
        .lastOrNull;
    if (message == null) return;
    if (!widget.controller.fishTtsEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.interfaceLanguage.text(
              '请先开启语音合成',
              'Enable speech synthesis first',
              '先に音声合成を有効にしてください',
            ),
          ),
        ),
      );
      return;
    }
    final source = message.text;
    final performance = _lastSpeechSource == source
        ? (_lastSpeechPerformance ?? source)
        : source;
    _cancelSpeechPlayback();
    final generation = ++_replyGeneration;
    setState(() {
      _regeneratingSpeech = true;
      _isReplying = true;
    });
    try {
      await _playTtsIfConfigured(performance, displaySource: source);
    } catch (error, stack) {
      RuntimeLog.instance.error('TTS', error, stack);
    } finally {
      if (mounted) {
        setState(() {
          _regeneratingSpeech = false;
          if (generation == _replyGeneration) _isReplying = false;
        });
      }
    }
  }

  Future<void> _replayLastSpeech() async {
    await _playCachedSpeech(_lastSpeech);
  }

  Future<void> _playMessageSpeech(ChatMessage message, String text) async {
    if (_isReplying || !_mayPlayVoice) return;
    try {
      final store = await ConversationCollectionStore.open();
      final entries = await store.voiceSegments(message.collectionKey);
      final normalized = text.replaceAll(RegExp(r'\s+'), '');
      final index = entries.indexWhere(
        (e) => e.text.replaceAll(RegExp(r'\s+'), '') == normalized,
      );
      if (index < 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                widget.controller.interfaceLanguage.text(
                  '此段没有可定位的缓存语音',
                  'No mapped audio for this passage',
                  'この台詞に対応する音声がありません',
                ),
              ),
            ),
          );
        }
        return;
      }
      final entry = entries[index];
      final bytes = await File(entry.path).readAsBytes();
      final envelope = await loadSpeechEnvelope(entry.path, bytes);
      if (!mounted || _isReplying) return;
      await _playCachedSpeech([
        _CachedSpeechSegment(
          path: entry.path,
          text: entry.text,
          envelope: envelope,
          expression: null,
          action: null,
        ),
      ], highlightLatest: false);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _playCachedSpeech(
    List<_CachedSpeechSegment> source, {
    bool highlightLatest = true,
  }) async {
    if (!_mayPlayVoice) return;
    if (source.isEmpty || _isReplying) return;
    final segments = List<_CachedSpeechSegment>.of(source);
    final generation = ++_speechPlaybackGeneration;
    final previousCancellation = _speechCancellation;
    if (previousCancellation != null && !previousCancellation.isCompleted) {
      previousCancellation.complete();
    }
    final cancellation = Completer<void>();
    _speechCancellation = cancellation;
    try {
      for (var index = 0; index < segments.length; index++) {
        final segment = segments[index];
        if (generation != _speechPlaybackGeneration) return;
        final latestResponse = widget.controller.messages
            .where(
              (message) => !message.isUser && message.text.trim().isNotEmpty,
            )
            .lastOrNull
            ?.text;
        if (latestResponse != null && highlightLatest) {
          _showAssistantSegment(
            _displayIndexForRyzaSegment(latestResponse, index),
            const Duration(seconds: 6),
          );
        }
        if (segment.posture case final posture?) _selectPosture(posture);
        if (segment.expression case final expression?) {
          _applyExpression(expression, intensity: segment.expressionIntensity);
        }
        if (segment.action case final action?) {
          _performSemanticAction(action);
        }
        await _audioPlayer.stop();
        await _audioPlayer.setVolume(widget.controller.voiceVolume);
        _startSpeakingAnimation(
          envelope: segment.envelope,
          awaitingAudio: true,
        );
        for (final id in segment.motionGroupIds.take(2)) {
          _performMotionGroupIntent(id);
        }
        final completed = _audioPlayer.onPlayerComplete.first;
        await _audioPlayer.play(DeviceFileSource(segment.path));
        await Future.any([completed, cancellation.future]);
        if (generation != _speechPlaybackGeneration) return;
        if (index + 1 < segments.length) {
          _pauseSpeakingBetweenSegments();
        } else {
          _stopSpeakingAnimation();
        }
      }
    } on Object {
      if (!mounted || generation != _speechPlaybackGeneration) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('上一条语音文件已失效，请重新生成回复')));
      if (highlightLatest) await _clearLastSpeech();
    } finally {
      if (generation == _speechPlaybackGeneration) _stopSpeakingAnimation();
      _showAssistantSegment(null, Duration.zero);
      if (identical(_speechCancellation, cancellation)) {
        _speechCancellation = null;
      }
    }
  }

  void _cancelSpeechPlayback() {
    _clearPerformanceQueue();
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
    _showAssistantSegment(null, Duration.zero);
  }

  bool get _mayPlayVoice =>
      widget.pageActive || widget.controller.backgroundVoicePlayback;

  void _syncBackgroundVoicePolicy() {
    if (!_mayPlayVoice &&
        (_isCharacterSpeaking || _speechCancellation != null)) {
      _cancelSpeechPlayback();
    }
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageActive != widget.pageActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncBackgroundVoicePolicy();
      });
    }
  }

  Duration _readingDurationFor(String text) => Duration(
    milliseconds: (stripLeadingTtsCues(text).length * 70)
        .clamp(3000, 10000)
        .toInt(),
  );

  int? _displayIndexForRyzaSegment(String response, int ryzaOrdinal) {
    for (final message in widget.controller.messages.reversed) {
      if (!message.isUser && message.text == response) {
        response = message.displayText;
        break;
      }
    }
    var currentRyza = 0;
    final segments = parseAssistantSegments(response)
        .where((segment) => displayTextForAssistantSegment(segment).isNotEmpty);
    var displayIndex = 0;
    for (final segment in segments) {
      if (segment.speaker == ChatSpeaker.ryza) {
        if (currentRyza == ryzaOrdinal) return displayIndex;
        currentRyza += 1;
      }
      displayIndex += 1;
    }
    return null;
  }

  void _showAssistantSegment(int? index, Duration duration) {
    if (!mounted ||
        (_activeAssistantSegmentIndex == index &&
            _activeSegmentDisplayDuration == duration)) {
      return;
    }
    setState(() {
      _activeAssistantSegmentIndex = index;
      _activeSegmentDisplayDuration = duration;
    });
  }

  Future<void> _translateReply(
    ChatMessage message,
    String apiKey, {
    required LlmProvider provider,
    required String baseUrl,
    required String model,
  }) async {
    final language = widget.controller.translationLanguage;
    if (language == TranslationLanguage.none ||
        !widget.controller.independentTranslation) {
      return;
    }
    final revision = widget.controller.dataRevision;
    try {
      final translated = await DialogueTranslator().translate(
        source: message.text,
        language: language.promptLabel!,
        complete: (messages) => _aiClient.complete(
          lightweight: true,
          provider: provider,
          baseUrl: baseUrl,
          apiKey: apiKey,
          model: model,
          messages: messages,
        ),
      );
      if (!mounted ||
          revision != widget.controller.dataRevision ||
          !widget.controller.independentTranslation ||
          language != widget.controller.translationLanguage) {
        return;
      }
      final active = _activeAssistantSegmentIndex;
      final sourceSegments = parseAssistantSegments(message.text)
          .where((s) => displayTextForAssistantSegment(s).isNotEmpty)
          .toList();
      final isLatest = identical(
        widget.controller.messages.lastOrNull,
        message,
      );
      final ordinal = active != null && active < sourceSegments.length
          ? sourceSegments
                    .take(active + 1)
                    .where((s) => s.speaker == ChatSpeaker.ryza)
                    .length -
                1
          : -1;
      if (widget.controller.attachTranslation(message, translated) &&
          isLatest &&
          ordinal >= 0) {
        setState(
          () => _activeAssistantSegmentIndex = _displayIndexForRyzaSegment(
            message.text,
            ordinal,
          ),
        );
      }
    } on Object catch (error, stack) {
      RuntimeLog.instance.error('Translation', error, stack);
      if (!mounted ||
          revision != widget.controller.dataRevision ||
          !widget.controller.messages.contains(message)) {
        return;
      }
      final ui = widget.controller.interfaceLanguage;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ui.text(
              '翻译失败，已保留原文',
              'Translation failed; original text retained',
              '翻訳に失敗しました。原文を表示します',
            ),
          ),
          action: SnackBarAction(
            label: ui.text('重试', 'Retry', '再試行'),
            onPressed: () {
              if (mounted) {
                unawaited(
                  _translateReply(
                    message,
                    apiKey,
                    provider: provider,
                    baseUrl: baseUrl,
                    model: model,
                  ),
                );
              }
            },
          ),
        ),
      );
    }
  }

  Future<void> _refreshLongTermMemory(
    String apiKey, {
    required LlmProvider provider,
    required String baseUrl,
    required String model,
    List<ChatMessage>? completedMessages,
    int? dataRevision,
  }) async {
    final snapshot = (completedMessages ?? widget.controller.messages)
        .where((message) => !message.isFailure)
        .toList();
    final revision = dataRevision ?? widget.controller.dataRevision;
    if (!mounted ||
        revision != widget.controller.dataRevision ||
        !widget.controller.longTermMemoryEnabled) {
      return;
    }
    if (_memoryRefreshGate.running) {
      _pendingMemoryRefresh = () => _refreshLongTermMemory(
        apiKey,
        provider: provider,
        baseUrl: baseUrl,
        model: model,
        completedMessages: snapshot,
        dataRevision: revision,
      );
      RuntimeLog.instance.info('Memory', '整理正在进行，已合并后续请求');
      return;
    }
    final generation = _memoryRefreshGate.begin()!;
    final previousMemory = widget.controller.memorySummary;
    final checkpoint = _lastConsolidatedUser == null
        ? -1
        : snapshot.indexOf(_lastConsolidatedUser!);
    var start = checkpoint < 0 ? max(0, snapshot.length - 12) : checkpoint + 1;
    if (checkpoint >= 0) {
      while (start < snapshot.length && !snapshot[start].isUser) {
        start++;
      }
    }
    final pendingMessages = snapshot.skip(start).toList();
    if (pendingMessages.isEmpty) {
      _memoryRefreshGate.finish(generation);
      RuntimeLog.instance.info('Memory', '没有新的完整对话，跳过整理');
      return;
    }
    final lastUser = snapshot.where((message) => message.isUser).lastOrNull;
    final anchor = snapshot.lastOrNull;
    final dialogue = pendingMessages
        .map(
          (message) => message.isUser
              ? '用户：${message.text}'
              : displayTextForAssistantResponse(message.text),
        )
        .join('\n');
    try {
      RuntimeLog.instance.info(
        'Memory',
        '开始独立整理：model=$model，messages=${pendingMessages.length}，characters=${dialogue.length}',
      );
      final now = DateTime.now();
      final memory = await MemoryConsolidator()
          .consolidate(
            previousMemory: previousMemory,
            dialogue: dialogue,
            now: now,
            complete: (messages) => _aiClient.complete(
              lightweight: true,
              provider: provider,
              baseUrl: baseUrl,
              apiKey: apiKey,
              model: model,
              messages: messages,
            ),
          )
          .timeout(const Duration(seconds: 30));
      if (!mounted ||
          !_memoryRefreshGate.owns(generation) ||
          revision != widget.controller.dataRevision ||
          !widget.controller.longTermMemoryEnabled ||
          previousMemory != widget.controller.memorySummary ||
          anchor == null ||
          !widget.controller.messages.any(
            (message) =>
                identical(message, anchor) ||
                (anchor.id.isNotEmpty && message.id == anchor.id),
          )) {
        RuntimeLog.instance.info('Memory', '丢弃整理结果：记忆、存档、开关或对应对话已改变');
        return;
      }
      if (memory != null) {
        widget.controller.updateMemorySummary(memory);
        _lastConsolidatedUser = lastUser;
        _memoryRefreshGate.refreshAfterLoad = false;
        RuntimeLog.instance.info('Memory', '长期记忆整理成功，已保存');
      } else {
        RuntimeLog.instance.warning('Memory', '长期记忆整理返回了无效 JSON，已保留旧记忆');
      }
    } on Object catch (error, stackTrace) {
      RuntimeLog.instance.error('Memory', error, stackTrace);
      // Memory consolidation is best-effort and must not break normal chat.
    } finally {
      if (_memoryRefreshGate.finish(generation)) {
        final pending = _pendingMemoryRefresh;
        _pendingMemoryRefresh = null;
        if (mounted && pending != null) unawaited(pending());
      }
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

  void _handleConversationScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final shouldShow = position.pixels > position.minScrollExtent + 12;
    if (shouldShow == _showScrollToBottomIndicator || !mounted) return;
    setState(() => _showScrollToBottomIndicator = shouldShow);
  }

  void _showLatestAssistantFromStartIfOverflow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _latestAssistantMessageKey.currentContext;
      if (!mounted || context == null || !_scrollController.hasClients) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.04,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _showCharacterStatus() {
    final language = widget.controller.interfaceLanguage;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black38,
      builder: (dialogContext) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => Dialog(
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
              child: SingleChildScrollView(
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
                            language.text(
                              '角色状态',
                              'Character status',
                              'キャラクター状態',
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (widget.controller.storyClockEnabled)
                          Text(
                            language.text(
                              '第${widget.controller.storyClock.day}天 · ${widget.controller.storyClock.timeLabel}',
                              'Day ${widget.controller.storyClock.day} · ${widget.controller.storyClock.timeLabel}',
                              '${widget.controller.storyClock.day}日目 · ${widget.controller.storyClock.timeLabel}',
                            ),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
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
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _CharacterStatusRow(
                            icon: Icons.mood_outlined,
                            label: language.text('心情', 'Mood', '気分'),
                            value: widget.controller.characterState.summary(
                              language,
                            ),
                          ),
                          if (widget.controller.storyClockEnabled)
                            _CharacterStatusRow(
                              icon: Icons.restaurant_rounded,
                              label: language.text('饱食度', 'Satiety', '満腹度'),
                              value:
                                  '${widget.controller.storyClock.satiety}/100',
                            ),
                          if (widget
                              .controller
                              .characterState
                              .reason
                              .isNotEmpty)
                            _CharacterStatusRow(
                              icon: Icons.history,
                              label: language.text(
                                '最近变化',
                                'Last change',
                                '最近の変化',
                              ),
                              value:
                                  '${widget.controller.characterState.reason}\n${widget.controller.characterState.updatedAt?.toLocal().toString().split('.').first ?? ''}',
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
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
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openFullscreenComposer() async {
    if (!widget.controller.splitNarrationComposer) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final language = widget.controller.interfaceLanguage;
    final send = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black45,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) => Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: GlassSurface(
            liquidGlass: widget.controller.liquidGlassChatUi,
            fallbackColor: const Color(0xE62A2A2A),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Expanded(
                    child: NarrationComposerFields(
                      controllers: [
                        _narrationInputController,
                        _inputController,
                        _narrationBottomInputController,
                      ],
                      hints: [
                        language.text(
                          '旁白（环境、动作、神态）',
                          'Opening narration',
                          '上部ナレーション',
                        ),
                        language.text(
                          '你想说的话',
                          'What you want to say',
                          'あなたが話す内容',
                        ),
                        language.text(
                          '下方旁白（反应、收尾、气氛）',
                          'Closing narration',
                          '下部ナレーション',
                        ),
                      ],
                      expanded: true,
                      onToggleExpanded: () => Navigator.pop(context, false),
                      expandLabel: language.text(
                        '收起输入框',
                        'Collapse input',
                        '入力欄を縮小',
                      ),
                      readOnly:
                          _isReplying &&
                          !widget.controller.unlockInputWhileReplying,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(
                          language.text(
                            '返回（保留草稿）',
                            'Back (keep draft)',
                            '戻る（下書きを保持）',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: _isReplying
                            ? null
                            : () => Navigator.pop(context, true),
                        icon: const Icon(Icons.arrow_upward_rounded),
                        label: Text(language.text('发送', 'Send', '送信')),
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
    if (!mounted) return;
    if (send == true && !_isReplying) await _sendMessage();
  }

  Future<void> _takePhoto() async {
    if (_isReplying) return;
    if (!Platform.isAndroid && !Platform.isIOS) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前平台暂不支持直接拍照，请选择已有图片')));
      return;
    }
    var status = await Permission.camera.status;
    if (!status.isGranted) status = await Permission.camera.request();
    if (!status.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status.isPermanentlyDenied
                ? '相机权限已被禁止，请在系统设置中开启后重试'
                : '未授予相机权限，无法拍照',
          ),
        ),
      );
      return;
    }
    try {
      final photo = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 92,
        requestFullMetadata: false,
      );
      if (photo == null || !mounted) return;
      final size = await photo.length();
      final currentTotal = _pendingAttachments.fold<int>(
        0,
        (total, attachment) => total + attachment.size,
      );
      if (size > 10 * 1024 * 1024 || currentTotal + size > 10 * 1024 * 1024) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('照片或本次附件总大小超过 10MB')));
        return;
      }
      final bytes = await photo.readAsBytes();
      final name = photo.name.isEmpty ? 'camera.jpg' : photo.name;
      final attachment = await _createAttachment(
        name: name,
        mimeType: _mimeTypeForFile(name),
        bytes: bytes,
      );
      if (!mounted) return;
      setState(() {
        _pendingAttachments.add(attachment);
      });
    } on Object catch (error, stackTrace) {
      RuntimeLog.instance.error('Camera', error, stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('拍照失败，请重试或从相册选择图片')));
    }
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
          await _createAttachment(
            name: file.name,
            mimeType: _mimeTypeForFile(file.name),
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
      RuntimeLog.instance.warning(
        'Attachment',
        '附件读取或大小校验失败，数量=${rejected.length}',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('附件读取失败或单次总大小超过 10MB：${rejected.join('、')}')),
      );
    }
  }

  Future<ChatAttachment> _createAttachment({
    required String name,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    Uint8List? thumbnailBytes;
    String? thumbnailKey;
    if (mimeType.startsWith('image/')) {
      thumbnailBytes = await _createImageThumbnail(bytes);
      if (thumbnailBytes != null) {
        thumbnailKey = await AttachmentThumbnailStore.write(thumbnailBytes);
        if (thumbnailKey == null) {
          RuntimeLog.instance.warning('Attachment', '历史图片缩略图写入失败：$name');
        }
      }
    }
    return ChatAttachment(
      name: name,
      mimeType: mimeType,
      size: bytes.length,
      bytes: bytes,
      thumbnailBytes: thumbnailBytes,
      thumbnailKey: thumbnailKey,
    );
  }

  Future<Uint8List?> _createImageThumbnail(Uint8List bytes) async {
    ui.Codec? codec;
    ui.Image? source;
    ui.Image? thumbnail;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      source = (await codec.getNextFrame()).image;
      final scale = min(1.0, min(320 / source.width, 240 / source.height));
      final width = max(1, (source.width * scale).round());
      final height = max(1, (source.height * scale).round());
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        source,
        Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      thumbnail = await picture.toImage(width, height);
      picture.dispose();
      final data = await thumbnail.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } on Object catch (error, stackTrace) {
      RuntimeLog.instance.warning('Attachment', '图片缩略图生成失败：$error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    } finally {
      thumbnail?.dispose();
      source?.dispose();
      codec?.dispose();
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
        liquidGlass: widget.controller.liquidGlassChatUi,
        language: widget.controller.interfaceLanguage,
        recipes: _motionRecipes.where(_canPlayRecipe).toList(),
        postureControls: Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: () {
                _postureState.manual = false;
                _lastPostureCue = null;
                Navigator.pop(context);
              },
              child: Text(
                widget.controller.interfaceLanguage.text(
                  '自动姿态',
                  'Auto posture',
                  '姿勢を自動選択',
                ),
              ),
            ),
            if (!_appearance.isStanding)
              TextButton(
                onPressed: () {
                  _selectPosture('sitting_normal', byUser: true);
                  Navigator.pop(context);
                },
                child: Text(
                  widget.controller.interfaceLanguage.text(
                    '自然坐姿',
                    'Sit normally',
                    '通常座り',
                  ),
                ),
              ),
            if (_crossLeggedGroup != null)
              TextButton(
                onPressed: () {
                  _selectPosture('sitting_agura', byUser: true);
                  Navigator.pop(context);
                },
                child: Text(
                  widget.controller.interfaceLanguage.text(
                    '盘腿坐',
                    'Sit cross-legged',
                    'あぐら',
                  ),
                ),
              ),
          ],
        ),
        onSelected: (recipe) {
          _clearPerformanceQueue();
          _playRecipeStage(recipe, 0);
        },
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
        language: widget.controller.interfaceLanguage,
        onTextureChanged: () {
          if (mounted) _handleControllerChange(forceAppearanceReload: true);
        },
        onSelected: (appearance) {
          final previous = _appearance;
          widget.controller.setCharacterAppearance(appearance.id);
          Navigator.pop(context);
          if (previous.id != appearance.id && widget.controller.aiEnabled) {
            _pendingOutfitReaction =
                '应用事件：莱莎刚从“${previous.label}”切换为“${appearance.label}”。当前样式：${appearance.promptDescription}。请先用简短旁白描写换装后的神态，再以莱莎口吻回应一两句，遵守当前语言、译文及演出格式。不描述换衣过程，不代写用户评价，不编造未提供的服装细节。';
            _scheduleOutfitReaction();
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 720;
    final usesLiquidGlass = widget.controller.liquidGlassChatUi;
    final mediaQuery = MediaQuery.of(context);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: LayoutBuilder(
        builder: (context, viewportConstraints) {
          // A resized Android floating window is not a keyboard inset.
          final bottomSafeInset = mediaQuery.viewPadding.bottom;
          final liquidContentHeight = max(
            0.0,
            viewportConstraints.maxHeight -
                mediaQuery.viewPadding.top -
                bottomSafeInset,
          );
          final keyboardInset = max(
            0.0,
            mediaQuery.viewInsets.bottom - bottomSafeInset,
          );
          return Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: viewportConstraints.maxHeight,
                child: _SceneBackground(
                  sceneTime: widget.controller.sceneTime,
                  stageId: widget.controller.selectedStageId,
                  frameRate: widget.controller.frameRate,
                ),
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
              if (_appearance.animated && !_spineReady)
                Positioned.fill(
                  child: FutureBuilder<ProtectedCharacterAssetBundle>(
                    future: _appearanceBundleFuture,
                    builder: (context, snapshot) => snapshot.hasError
                        ? const SizedBox.shrink()
                        : IgnorePointer(
                            child: Center(
                              child: RyzaLoadingPanel(
                                language: widget.controller.interfaceLanguage,
                              ),
                            ),
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
    final viewport = constraints.biggest;
    final viewportChanged =
        _lastChatViewport != null && _lastChatViewport != viewport;
    _lastChatViewport = viewport;
    final automaticFraction = _automaticPanelFraction(
      constraints.maxWidth,
      constraints.maxHeight,
      isWide,
    );
    final panelFraction =
        _lockedPanelFraction ?? _manualPanelFraction ?? automaticFraction;
    final panelBounds = conversationPanelBounds(
      viewport: viewport,
      keyboardInset: keyboardInset,
      fraction: widget.controller.splitNarrationComposer
          ? max(panelFraction, 290 / max(1.0, viewport.height))
          : panelFraction,
      fullscreen: _conversationFullscreen,
    );
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        Column(
          children: [
            if (!widget.hideUi) const SizedBox(height: 60),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1120),
                child: _buildCharacter(),
              ),
            ),
          ],
        ),
        if (!widget.hideUi)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopBar(
              language: widget.controller.interfaceLanguage,
              liquidGlass: liquidGlass,
              sceneTime: widget.controller.sceneTime,
              onSceneChanged: widget.controller.setSceneTime,
              onMenuPressed: widget.onMenuPressed,
              onStatusPressed: _showCharacterStatus,
            ),
          ),
        if (!widget.hideUi)
          AnimatedPositioned(
            duration: viewportChanged
                ? Duration.zero
                : const Duration(milliseconds: 480),
            curve: Curves.easeOutCubic,
            left: panelBounds.left,
            top: panelBounds.top,
            width: panelBounds.width,
            height: panelBounds.height,
            child: _LiquidGlassConversation(
              language: widget.controller.interfaceLanguage,
              liquidGlass: liquidGlass,
              translationOnly:
                  widget.controller.translationOnly &&
                  widget.controller.translationLanguage.name != 'none',
              messages: widget.controller.messages,
              isReplying: _isReplying,
              scrollController: _scrollController,
              inputController: _inputController,
              narrationController: _narrationInputController,
              bottomNarrationController: _narrationBottomInputController,
              splitNarration: widget.controller.splitNarrationComposer,
              onToggleNarration: () {
                widget.controller.setSplitNarrationComposer(
                  !widget.controller.splitNarrationComposer,
                );
              },
              showMicrophone: widget.controller.showMicrophoneButton,
              unlockInputWhileReplying:
                  widget.controller.unlockInputWhileReplying,
              attachments: _pendingAttachments,
              onTakePhoto: _takePhoto,
              onPickImage: () => _pickAttachments(imagesOnly: true),
              onPickFile: () => _pickAttachments(imagesOnly: false),
              onRemoveAttachment: (attachment) {
                setState(() => _pendingAttachments.remove(attachment));
              },
              onSubmitted: (_) => _sendMessage(),
              onSend: _sendMessage,
              onCancel: _cancelReply,
              expanded: false,
              onToggleExpanded: _openFullscreenComposer,
              canUndo: widget.controller.messages.any(
                (message) => message.isUser,
              ),
              canReplay: _lastSpeech.isNotEmpty && !_isReplying,
              canContinue:
                  widget.controller.messages.any(
                    (message) => !message.isUser,
                  ) &&
                  !_isReplying,
              isContinuing: _isContinuing,
              isSuggestingReply: _isSuggestingReply,
              suggestionUsesRemaining: widget.controller
                  .suggestionUsesRemaining(),
              suggestionRefreshProgress: widget.controller
                  .suggestionRefreshProgress(),
              suggestionRefreshWait: widget.controller
                  .suggestionTimeUntilNextRefresh(),
              activeAssistantSegmentIndex: _activeAssistantSegmentIndex,
              activeSegmentDisplayDuration: _activeSegmentDisplayDuration,
              latestAssistantMessageKey: _latestAssistantMessageKey,
              showScrollToBottomIndicator: _showScrollToBottomIndicator,
              onScrollToBottom: _scrollToBottom,
              onSuggestReply: _suggestUserReply,
              onUndo: _undoLastMessage,
              onReplay: _replayLastSpeech,
              onPlaySpeech: _playMessageSpeech,
              speechProgress: VoicePlaybackProgress(player: _audioPlayer),
              onRegenerateSpeech: _regenerateLastSpeech,
              regeneratingSpeech: _regeneratingSpeech,
              selectingCollection: _selectingCollection,
              savingCollection: _savingCollection,
              collectionSelection: _collectionSelection,
              availableCollectionVoices: _availableCollectionVoices,
              onToggleCollection: _toggleCollection,
              onSelectCollection: (key, type, selected) => setState(() {
                final choices = _collectionSelection.putIfAbsent(
                  key,
                  () => <String>{},
                );
                if (selected) {
                  choices.add(type);
                } else {
                  choices.remove(type);
                }
              }),
              onContinue: _continueConversation,
              showFullscreenButton:
                  _conversationFullscreen || panelFraction >= 0.675,
              conversationFullscreen: _conversationFullscreen,
              onToggleFullscreen: () {
                setState(() {
                  _conversationFullscreen = !_conversationFullscreen;
                  if (_conversationFullscreen) _manualPanelFraction = 0.68;
                });
                widget.onFullscreenChanged?.call(_conversationFullscreen);
              },
              onDragUpdate: (delta) {
                if (_conversationFullscreen || _lockedPanelFraction != null) {
                  return;
                }
                setState(() {
                  _manualPanelFraction =
                      (panelFraction - delta / max(1.0, constraints.maxHeight))
                          .clamp(0.22, 0.68);
                });
              },
              panelLocked: _lockedPanelFraction != null,
              onTogglePanelLock: () => setState(() {
                if (_lockedPanelFraction == null) {
                  _lockedPanelFraction = panelFraction;
                } else {
                  _manualPanelFraction = _lockedPanelFraction;
                  _lockedPanelFraction = null;
                }
              }),
            ),
          ),
      ],
    );
  }

  double _automaticPanelFraction(
    double viewportWidth,
    double viewportHeight,
    bool isWide,
  ) {
    final latest = widget.controller.messages.isEmpty
        ? null
        : widget.controller.messages.last;
    final text = latest == null
        ? ''
        : (latest.isUser ? latest.text : _glassMessageText(latest));
    final segmentCount = latest == null || latest.isUser
        ? 1
        : parseAssistantSegments(latest.displayText)
              .where(
                (segment) => displayTextForAssistantSegment(segment).isNotEmpty,
              )
              .length;
    return conversationPanelFractionForText(
      text: text,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      isWide: isWide,
      segmentCount: max(1, segmentCount),
      hasAttachments: latest?.attachments.isNotEmpty == true,
      hasImageAttachments:
          latest?.attachments.any((attachment) => attachment.isImage) == true,
      isReplying: false,
    );
  }

  Widget _buildProtectedCharacter() {
    final spineController = _spineController;
    if (spineController == null) return const SizedBox.shrink();
    return FutureBuilder<ProtectedCharacterAssetBundle>(
      key: ObjectKey(_appearanceBundleFuture),
      future: _appearanceBundleFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && identical(spineController, _spineController)) {
              widget.onCharacterLoadFailed?.call();
            }
          });
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text(
                    '服装资源读取失败\n请重新选择皮肤并查看运行日志',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          );
        }
        final bundle = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null;
        if (bundle == null) {
          return const SizedBox.shrink();
        }
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            CharacterSpineView(
              atlas: _appearance.atlasAsset,
              skeleton: _appearance.skeletonAsset,
              controller: spineController,
              bundle: bundle,
              onLoadFailed: widget.onCharacterLoadFailed,
              key: ValueKey(spineController),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCharacter() {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        CharacterCamera(
          keepSceneProportions: true,
          onTap: _reactToTap,
          onGazeChanged: widget.controller.gazeTrackingEnabled
              ? _updateGaze
              : null,
          onGazeEnd: widget.controller.gazeTrackingEnabled ? _endGaze : null,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              if (_appearance.animated && !_appearance.isStanding)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Transform.translate(
                      offset: const Offset(0, -204),
                      child: SpineWidget.fromAsset(
                        'assets/spine/objects/obj_001/obj_001.atlas',
                        'assets/spine/objects/obj_001/obj_001.skel',
                        _seatObjectController,
                        fit: BoxFit.contain,
                        alignment: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ),
              if (_appearance.animated)
                _buildProtectedCharacter()
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 28, 12, 0),
                  child: _ProtectedAppearancePreview(
                    appearance: _appearance,
                    fit: BoxFit.contain,
                    alignment: Alignment.bottomCenter,
                  ),
                ),
            ],
          ),
        ),
        if (!widget.hideUi)
          Positioned(
            right: 12,
            top: 10,
            child: _TtsVoiceModeMenu(
              liquidGlass: widget.controller.liquidGlassChatUi,
              currentMode: widget.controller.ttsVoiceMode,
              onModeSelected: _selectTtsVoiceMode,
              onContinuousAsmr: _openContinuousAsmr,
            ),
          ),
        if (!widget.hideUi)
          Positioned(
            right: 12,
            top: 68,
            child: _RoundIcon(
              liquidGlass: widget.controller.liquidGlassChatUi,
              icon: Icons.save_outlined,
              tooltip: widget.controller.interfaceLanguage.text(
                '本地存档',
                'Local saves',
                'ローカルセーブ',
              ),
              onPressed: () => showLocalSaveDialog(context, widget.controller),
            ),
          ),
        if (!widget.hideUi)
          Positioned(
            right: 12,
            top: 126,
            child: _CharacterToolCluster(
              liquidGlass: widget.controller.liquidGlassChatUi,
              language: widget.controller.interfaceLanguage,
              expanded: _characterToolsExpanded,
              onToggle: () => setState(
                () => _characterToolsExpanded = !_characterToolsExpanded,
              ),
              onMotionPressed: _showMotionPicker,
              onAppearancePressed: _showAppearancePicker,
              onShopPressed: widget.onShopPressed,
            ),
          ),
        if (!widget.hideUi && !_appearance.animated)
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

  void _selectTtsVoiceMode(TtsVoiceMode mode) {
    if (!widget.controller.setTtsVoiceMode(mode)) {
      final idName = switch (mode) {
        TtsVoiceMode.normal => '普通 Voice model ID',
        TtsVoiceMode.asmr => 'ASMR 模式 Voice model ID',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.ttsProvider == TtsProvider.mimo
                ? '请先完成 MiMo TTS 的参考音频或音色设置'
                : '请先在 ${widget.controller.ttsProvider.label} 设置中填写$idName',
          ),
        ),
      );
    }
  }
}

class _SceneBackground extends StatefulWidget {
  const _SceneBackground({
    required this.sceneTime,
    required this.stageId,
    required this.frameRate,
  });

  final SceneTime sceneTime;
  final String stageId;
  final AdaptiveFrameRateController frameRate;

  @override
  State<_SceneBackground> createState() => _SceneBackgroundState();
}

class _SceneBackgroundState extends State<_SceneBackground> {
  late String _activeSceneId;
  String? _incomingSceneId;
  bool _incomingVisible = false;

  String get _targetSceneId =>
      StageEnvironmentCatalog.sceneAssetIdFor(widget.stageId, widget.sceneTime);

  @override
  void initState() {
    super.initState();
    _activeSceneId = _targetSceneId;
  }

  @override
  void didUpdateWidget(covariant _SceneBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _targetSceneId;
    if (target == _activeSceneId) {
      _incomingSceneId = null;
      _incomingVisible = false;
    } else if (target != _incomingSceneId) {
      _incomingSceneId = target;
      _incomingVisible = false;
    }
  }

  void _showIncoming(String sceneId) {
    if (!mounted || sceneId != _incomingSceneId) return;
    setState(() => _incomingVisible = true);
  }

  void _finishTransition() {
    final incoming = _incomingSceneId;
    if (!mounted || incoming == null || !_incomingVisible) return;
    setState(() {
      _activeSceneId = incoming;
      _incomingSceneId = null;
      _incomingVisible = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final overlay = switch (widget.sceneTime) {
      SceneTime.morning => const Color(0x1AFFD28A),
      SceneTime.afternoon => const Color(0x0AFFFFFF),
      SceneTime.evening => const Color(0x33B75B3D),
      SceneTime.night => const Color(0x66312D55),
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset('assets/images/talk_background.png', fit: BoxFit.cover),
        AnimatedOpacity(
          key: ValueKey('scene-$_activeSceneId'),
          opacity: 1,
          duration: const Duration(milliseconds: 280),
          child: _SceneSpineLayer(
            sceneId: _activeSceneId,
            frameRate: widget.frameRate,
          ),
        ),
        if (_incomingSceneId case final incoming?)
          AnimatedOpacity(
            key: ValueKey('scene-$incoming'),
            opacity: _incomingVisible ? 1 : 0,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            onEnd: _finishTransition,
            child: _SceneSpineLayer(
              sceneId: incoming,
              frameRate: widget.frameRate,
              onReady: () => _showIncoming(incoming),
            ),
          ),
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
  const _SceneSpineLayer({
    required this.sceneId,
    required this.frameRate,
    this.onReady,
  });

  final String sceneId;
  final AdaptiveFrameRateController frameRate;
  final VoidCallback? onReady;

  @override
  State<_SceneSpineLayer> createState() => _SceneSpineLayerState();
}

class _SceneSpineLayerState extends State<_SceneSpineLayer> {
  late final SpineWidgetController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SpineWidgetController(
      targetFramesPerSecond: widget.frameRate.effectiveFramesPerSecond,
      onInitialized: (_) {
        if (!mounted) return;
        widget.onReady?.call();
      },
    );
    widget.frameRate.addListener(_syncFrameRate);
  }

  @override
  void didUpdateWidget(covariant _SceneSpineLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frameRate == widget.frameRate) return;
    oldWidget.frameRate.removeListener(_syncFrameRate);
    widget.frameRate.addListener(_syncFrameRate);
    _syncFrameRate();
  }

  void _syncFrameRate() {
    _controller.targetFramesPerSecond =
        widget.frameRate.effectiveFramesPerSecond;
  }

  @override
  void dispose() {
    widget.frameRate.removeListener(_syncFrameRate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final root = 'assets/scenes_runtime';
    return IgnorePointer(
      child: Transform.scale(
        scale: 1.28,
        alignment: Alignment.topCenter,
        child: SpineWidget.fromAsset(
          '$root/${widget.sceneId}.atlas',
          '$root/${widget.sceneId}.skel',
          _controller,
          key: ValueKey(widget.sceneId),
          fit: BoxFit.cover,
          boundsProvider: const SceneBackdropBounds(),
        ),
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
  });

  final AppLanguage language;
  final bool liquidGlass;
  final SceneTime sceneTime;
  final ValueChanged<SceneTime> onSceneChanged;
  final VoidCallback onMenuPressed;
  final VoidCallback onStatusPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: .16),
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(
          children: [
            const SizedBox(width: 58),
            const Spacer(),
            _SceneTimeMenu(
              liquidGlass: liquidGlass,
              language: language,
              sceneTime: sceneTime,
              onSceneChanged: onSceneChanged,
            ),
            const SizedBox(width: 8),
            _RoundIcon(
              liquidGlass: liquidGlass,
              icon: Icons.favorite_border_rounded,
              tooltip: language.text('角色状态', 'Character status', 'キャラクター状態'),
              onPressed: onStatusPressed,
            ),
          ],
        ),
      ),
    );
  }
}

class _TtsVoiceModeMenu extends StatefulWidget {
  const _TtsVoiceModeMenu({
    required this.liquidGlass,
    required this.currentMode,
    required this.onModeSelected,
    required this.onContinuousAsmr,
  });

  final bool liquidGlass;
  final TtsVoiceMode currentMode;
  final ValueChanged<TtsVoiceMode> onModeSelected;
  final VoidCallback onContinuousAsmr;

  @override
  State<_TtsVoiceModeMenu> createState() => _TtsVoiceModeMenuState();
}

class _TtsVoiceModeMenuState extends State<_TtsVoiceModeMenu> {
  final LayerLink _layerLink = LayerLink();
  final GlobalKey<_FadeSlideOverlayState> _overlayKey = GlobalKey();
  OverlayEntry? _overlayEntry;

  bool get _expanded => _overlayEntry != null;

  IconData _iconForMode(TtsVoiceMode mode) => switch (mode) {
    TtsVoiceMode.normal => Icons.volume_up_rounded,
    TtsVoiceMode.asmr => Icons.headphones_rounded,
  };

  void _select(TtsVoiceMode mode) {
    _closeMenu();
    widget.onModeSelected(mode);
  }

  void _toggleMenu() {
    if (_expanded) {
      _closeMenu();
      return;
    }
    final overlay = Overlay.of(context);
    _overlayEntry = OverlayEntry(
      builder: (context) => _FadeSlideOverlay(
        key: _overlayKey,
        link: _layerLink,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.topRight,
        offset: const Offset(-8, 0),
        beginOffset: const Offset(0.08, 0),
        onCloseRequested: _closeMenu,
        onClosed: _removeOverlay,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (
              var index = 0;
              index < TtsVoiceMode.values.length;
              index++
            ) ...[
              if (index > 0) const SizedBox(height: 6),
              _VoiceModeOptionPill(
                liquidGlass: widget.liquidGlass,
                icon: _iconForMode(TtsVoiceMode.values[index]),
                label: TtsVoiceMode.values[index].label,
                selected: TtsVoiceMode.values[index] == widget.currentMode,
                onPressed: () => _select(TtsVoiceMode.values[index]),
                onLongPress: TtsVoiceMode.values[index] == TtsVoiceMode.asmr
                    ? () {
                        _removeOverlay();
                        // Commit the visible mode first, then enter the
                        // dedicated continuous ASMR page.
                        widget.onModeSelected(TtsVoiceMode.asmr);
                        widget.onContinuousAsmr();
                      }
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
    overlay.insert(_overlayEntry!);
    setState(() {});
  }

  void _closeMenu() {
    final overlayState = _overlayKey.currentState;
    if (overlayState != null) {
      unawaited(overlayState.close());
      return;
    }
    _removeOverlay();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: GlassIconButton(
        liquidGlass: widget.liquidGlass,
        size: 48,
        icon: _expanded
            ? Icons.close_rounded
            : _iconForMode(widget.currentMode),
        tooltip: _expanded ? '收起语音模式' : widget.currentMode.label,
        onPressed: _toggleMenu,
      ),
    );
  }
}

class _SceneTimeMenu extends StatefulWidget {
  const _SceneTimeMenu({
    required this.liquidGlass,
    required this.language,
    required this.sceneTime,
    required this.onSceneChanged,
  });

  final bool liquidGlass;
  final AppLanguage language;
  final SceneTime sceneTime;
  final ValueChanged<SceneTime> onSceneChanged;

  @override
  State<_SceneTimeMenu> createState() => _SceneTimeMenuState();
}

class _SceneTimeMenuState extends State<_SceneTimeMenu> {
  final LayerLink _layerLink = LayerLink();
  final GlobalKey<_FadeSlideOverlayState> _overlayKey = GlobalKey();
  OverlayEntry? _overlayEntry;

  bool get _expanded => _overlayEntry != null;

  void _select(SceneTime value) {
    _closeMenu();
    widget.onSceneChanged(value);
  }

  void _toggleMenu() {
    if (_expanded) {
      _closeMenu();
      return;
    }
    final reversedTimes = SceneTime.values.reversed.toList(growable: false);
    final overlay = Overlay.of(context);
    _overlayEntry = OverlayEntry(
      builder: (context) => _FadeSlideOverlay(
        key: _overlayKey,
        link: _layerLink,
        targetAnchor: Alignment.bottomRight,
        followerAnchor: Alignment.topRight,
        offset: const Offset(0, 6),
        beginOffset: const Offset(0, -0.08),
        onCloseRequested: _closeMenu,
        onClosed: _removeOverlay,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var index = 0; index < reversedTimes.length; index++) ...[
              if (index > 0) const SizedBox(height: 6),
              _TimeOptionPill(
                liquidGlass: widget.liquidGlass,
                icon: reversedTimes[index].icon,
                label: reversedTimes[index].label,
                selected: reversedTimes[index] == widget.sceneTime,
                tooltip: widget.language.text(
                  '切换到${reversedTimes[index].label}',
                  'Switch to ${reversedTimes[index].label}',
                  '「${reversedTimes[index].label}」へ切り替え',
                ),
                onPressed: () => _select(reversedTimes[index]),
              ),
            ],
          ],
        ),
      ),
    );
    overlay.insert(_overlayEntry!);
    setState(() {});
  }

  void _closeMenu() {
    final overlayState = _overlayKey.currentState;
    if (overlayState != null) {
      unawaited(overlayState.close());
      return;
    }
    _removeOverlay();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: Semantics(
        button: true,
        label: widget.language.text('切换场景时间', 'Change scene time', 'シーンの時間を変更'),
        child: GlassSurface(
          liquidGlass: widget.liquidGlass,
          borderRadius: BorderRadius.circular(21),
          fallbackColor: Colors.black.withValues(alpha: 0.38),
          child: SizedBox(
            height: 42,
            child: InkWell(
              borderRadius: BorderRadius.circular(21),
              onTap: _toggleMenu,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _expanded ? Icons.close_rounded : widget.sceneTime.icon,
                      color: Colors.white,
                      size: 18,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      widget.sceneTime.label,
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_left_rounded
                          : Icons.arrow_drop_down,
                      color: Colors.white70,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FadeSlideOverlay extends StatefulWidget {
  const _FadeSlideOverlay({
    super.key,
    required this.link,
    required this.targetAnchor,
    required this.followerAnchor,
    required this.offset,
    required this.beginOffset,
    required this.onCloseRequested,
    required this.onClosed,
    required this.child,
  });

  final LayerLink link;
  final Alignment targetAnchor;
  final Alignment followerAnchor;
  final Offset offset;
  final Offset beginOffset;
  final VoidCallback onCloseRequested;
  final VoidCallback onClosed;
  final Widget child;

  @override
  State<_FadeSlideOverlay> createState() => _FadeSlideOverlayState();
}

class _FadeSlideOverlayState extends State<_FadeSlideOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curve;
  late final Tween<Offset> _positionTween;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 190),
      reverseDuration: const Duration(milliseconds: 150),
    );
    _curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _positionTween = Tween<Offset>(begin: widget.beginOffset, end: Offset.zero);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _controller.value = 1;
      } else {
        _controller.forward();
      }
    });
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    if (!MediaQuery.disableAnimationsOf(context)) {
      await _controller.reverse();
    }
    if (mounted) widget.onClosed();
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onCloseRequested,
          ),
        ),
        CompositedTransformFollower(
          link: widget.link,
          showWhenUnlinked: false,
          targetAnchor: widget.targetAnchor,
          followerAnchor: widget.followerAnchor,
          offset: widget.offset,
          child: FadeTransition(
            opacity: _curve,
            child: SlideTransition(
              position: _positionTween.animate(_curve),
              child: IgnorePointer(
                ignoring: _closing,
                child: Material(
                  type: MaterialType.transparency,
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TimeOptionPill extends StatelessWidget {
  const _TimeOptionPill({
    required this.liquidGlass,
    required this.icon,
    required this.label,
    required this.selected,
    required this.tooltip,
    required this.onPressed,
  });

  final bool liquidGlass;
  final IconData icon;
  final String label;
  final bool selected;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GlassSurface(
        liquidGlass: liquidGlass,
        borderRadius: BorderRadius.circular(22),
        fallbackColor: selected
            ? Colors.white.withValues(alpha: 0.30)
            : Colors.black.withValues(alpha: 0.38),
        child: SizedBox(
          width: 150,
          height: 48,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onPressed,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: Colors.white, size: 21),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 17,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VoiceModeOptionPill extends StatelessWidget {
  final VoidCallback? onLongPress;
  const _VoiceModeOptionPill({
    this.onLongPress,
    required this.liquidGlass,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final bool liquidGlass;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const foreground = Colors.white;
    return GlassSurface(
      liquidGlass: liquidGlass,
      borderRadius: BorderRadius.circular(22),
      fallbackColor: selected
          ? Colors.white.withValues(alpha: 0.30)
          : Colors.black.withValues(alpha: 0.38),
      child: SizedBox(
        width: 184,
        height: 48,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onPressed,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(icon, color: foreground, size: 21),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: foreground),
                  ),
                ),
                if (selected)
                  Icon(Icons.check_rounded, color: foreground, size: 17),
              ],
            ),
          ),
        ),
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
      size: 48,
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

class _CharacterToolCluster extends StatelessWidget {
  const _CharacterToolCluster({
    required this.liquidGlass,
    required this.language,
    required this.expanded,
    required this.onToggle,
    required this.onMotionPressed,
    required this.onAppearancePressed,
    required this.onShopPressed,
  });

  final bool liquidGlass;
  final AppLanguage language;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onMotionPressed;
  final VoidCallback onAppearancePressed;
  final VoidCallback onShopPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _CharacterToolButton(
          liquidGlass: liquidGlass,
          tooltip: expanded
              ? language.text(
                  '收起角色工具',
                  'Close character tools',
                  'キャラクターツールを閉じる',
                )
              : language.text('展开角色工具', 'Open character tools', 'キャラクターツールを開く'),
          icon: expanded ? Icons.close_rounded : Icons.auto_fix_high_outlined,
          onPressed: onToggle,
        ),
        FoldingButtonGroup(
          fromRight: true,
          expanded: expanded,
          children: [
            _CharacterToolButton(
              liquidGlass: liquidGlass,
              tooltip: language.text('动作', 'Motion', '動作'),
              icon: Icons.animation_outlined,
              onPressed: onMotionPressed,
            ),
            _CharacterToolButton(
              liquidGlass: liquidGlass,
              tooltip: language.text('服装与姿态', 'Outfit and posture', '衣装と姿勢'),
              icon: Icons.checkroom_outlined,
              onPressed: onAppearancePressed,
            ),
            _CharacterToolButton(
              liquidGlass: liquidGlass,
              tooltip: language.text('商店', 'Shop', 'ショップ'),
              icon: Icons.storefront_outlined,
              onPressed: onShopPressed,
            ),
          ],
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
      size: 48,
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
    required this.liquidGlass,
    required this.language,
    required this.recipes,
    required this.onSelected,
    required this.postureControls,
  });

  final bool liquidGlass;
  final AppLanguage language;
  final List<MotionRecipe> recipes;
  final ValueChanged<MotionRecipe> onSelected;
  final Widget postureControls;

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
            postureControls,
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${language.text('组合动作', 'Motion combinations', '組み合わせ動作')} · ${recipes.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: language.text('关闭', 'Close', '閉じる'),
                    color: Colors.white,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: recipes.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          language.text(
                            '当前皮肤或姿态暂无可播放的组合动作，请尝试切换为自然坐姿。',
                            'No combinations are available for this skin or posture. Try sitting normally.',
                            '現在の衣装・姿勢では再生できる組み合わせがありません。通常座りをお試しください。',
                          ),
                          style: const TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
                      itemCount: recipes.length,
                      itemBuilder: (context, index) {
                        final recipe = recipes[index];
                        return _GlassPickerTile(
                          liquidGlass: liquidGlass,
                          dense: true,
                          leading: const Icon(
                            Icons.layers_outlined,
                            color: Colors.white70,
                          ),
                          title: Text(
                            recipe.name.replaceFirst(RegExp(r'^\d+_'), ''),
                            style: const TextStyle(color: Colors.white),
                          ),
                          trailing: const Icon(
                            Icons.play_arrow,
                            color: Colors.white70,
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            onSelected(recipe);
                          },
                        );
                      },
                    ),
            ),
          ],
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
    required this.language,
    required this.onTextureChanged,
  });

  final bool liquidGlass;
  final String selectedId;
  final ValueChanged<CharacterAppearance> onSelected;
  final AppLanguage language;
  final VoidCallback onTextureChanged;

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
          child: SingleChildScrollView(
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
                          child: _ProtectedAppearancePreview(
                            appearance: appearance,
                            fit: BoxFit.cover,
                            alignment: appearance.animated
                                ? Alignment.topCenter
                                : Alignment.bottomCenter,
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
                SkinImportControls(
                  appearance: characterAppearanceById(selectedId),
                  language: language,
                  onImported: onSelected,
                  onTextureChanged: onTextureChanged,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProtectedAppearancePreview extends StatelessWidget {
  const _ProtectedAppearancePreview({
    required this.appearance,
    required this.fit,
    required this.alignment,
  });

  final CharacterAppearance appearance;
  final BoxFit fit;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (!appearance.hasPreview) return const SizedBox.expand();
    return FutureBuilder<Uint8List>(
      future: ProtectedCharacterAssets.previewFor(appearance.assetName),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return Image.memory(
            bytes,
            fit: fit,
            alignment: alignment,
            filterQuality: FilterQuality.high,
            gaplessPlayback: true,
          );
        }
        if (snapshot.hasError) {
          return const Icon(Icons.broken_image_outlined, color: Colors.black54);
        }
        return const Center(
          child: SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator.adaptive(strokeWidth: 2),
          ),
        );
      },
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
      child: SizedBox(
        width: icon == Icons.mood_outlined || icon == Icons.history
            ? double.infinity
            : max(
                80.0,
                (min(380.0, MediaQuery.sizeOf(context).width - 48) - 40) / 2,
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Colors.white70, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
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

class _RotatingIcon extends StatefulWidget {
  const _RotatingIcon(this.icon);

  final IconData icon;

  @override
  State<_RotatingIcon> createState() => _RotatingIconState();
}

class _RotatingIconState extends State<_RotatingIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _controller,
    child: Icon(widget.icon, size: 18),
  );
}

class _SuggestionQuotaButton extends StatelessWidget {
  const _SuggestionQuotaButton({
    required this.language,
    required this.liquidGlass,
    required this.isSuggesting,
    required this.remaining,
    required this.progress,
    required this.wait,
    required this.onPressed,
  });

  final AppLanguage language;
  final bool liquidGlass;
  final bool isSuggesting;
  final int remaining;
  final double progress;
  final Duration wait;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final waitText = wait == Duration.zero
        ? ''
        : ' ${wait.inMinutes}:${wait.inSeconds.remainder(60).toString().padLeft(2, '0')}';
    final tooltip = remaining > 0
        ? language.text(
            '生成建议回复（剩余 $remaining 次）',
            'Suggest a reply ($remaining left)',
            '返信案を作成（残り $remaining 回）',
          )
        : language.text(
            '建议回复额度恢复倒计时$waitText',
            'Reply suggestion refreshes in$waitText',
            '返信案の回復まで$waitText',
          );
    return SizedBox(
      width: 44,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.centerLeft,
        children: [
          SizedBox.square(
            dimension: 40,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 2,
              backgroundColor: Colors.white.withValues(alpha: 0.18),
              valueColor: AlwaysStoppedAnimation<Color>(
                remaining == 0
                    ? Colors.amberAccent.withValues(alpha: 0.82)
                    : Colors.white.withValues(alpha: 0.82),
              ),
            ),
          ),
          Positioned(
            left: 2,
            child: GlassIconButton(
              liquidGlass: liquidGlass,
              icon: isSuggesting
                  ? Icons.autorenew_rounded
                  : Icons.auto_awesome_rounded,
              iconWidget: isSuggesting
                  ? const _RotatingIcon(Icons.autorenew_rounded)
                  : null,
              tooltip: tooltip,
              onPressed: onPressed,
              size: 36,
            ),
          ),
          Positioned(
            right: -1,
            top: -2,
            child: IgnorePointer(
              child: Container(
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: remaining == 0
                      ? const Color(0xFFD99636)
                      : const Color(0xFF59636D),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white70, width: 0.8),
                ),
                child: Text(
                  '$remaining',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiquidGlassConversation extends StatelessWidget {
  const _LiquidGlassConversation({
    required this.selectingCollection,
    required this.savingCollection,
    required this.collectionSelection,
    required this.availableCollectionVoices,
    required this.onToggleCollection,
    required this.onSelectCollection,
    required this.language,
    required this.liquidGlass,
    required this.translationOnly,
    required this.messages,
    required this.isReplying,
    required this.scrollController,
    required this.inputController,
    required this.narrationController,
    required this.bottomNarrationController,
    required this.splitNarration,
    required this.onToggleNarration,
    required this.showMicrophone,
    required this.unlockInputWhileReplying,
    required this.attachments,
    required this.onTakePhoto,
    required this.onPickImage,
    required this.onPickFile,
    required this.onRemoveAttachment,
    required this.onSubmitted,
    required this.onSend,
    required this.onCancel,
    required this.expanded,
    required this.onToggleExpanded,
    required this.canUndo,
    required this.canReplay,
    required this.canContinue,
    required this.isContinuing,
    required this.isSuggestingReply,
    required this.suggestionUsesRemaining,
    required this.suggestionRefreshProgress,
    required this.suggestionRefreshWait,
    required this.activeAssistantSegmentIndex,
    required this.activeSegmentDisplayDuration,
    required this.latestAssistantMessageKey,
    required this.showScrollToBottomIndicator,
    required this.onScrollToBottom,
    required this.onSuggestReply,
    required this.onUndo,
    required this.onReplay,
    required this.onPlaySpeech,
    required this.speechProgress,
    required this.onRegenerateSpeech,
    required this.regeneratingSpeech,
    required this.onContinue,
    required this.showFullscreenButton,
    required this.conversationFullscreen,
    required this.onToggleFullscreen,
    required this.onDragUpdate,
    required this.panelLocked,
    required this.onTogglePanelLock,
  });

  final AppLanguage language;
  final bool selectingCollection;
  final bool savingCollection;
  final Map<String, Set<String>> collectionSelection;
  final Set<String> availableCollectionVoices;
  final VoidCallback onToggleCollection;
  final void Function(String, String, bool) onSelectCollection;
  final bool liquidGlass;
  final bool translationOnly;
  final List<ChatMessage> messages;
  final bool isReplying;
  final ScrollController scrollController;
  final TextEditingController inputController;
  final TextEditingController narrationController;
  final TextEditingController bottomNarrationController;
  final bool splitNarration;
  final VoidCallback onToggleNarration;
  final bool showMicrophone;
  final bool unlockInputWhileReplying;
  final List<ChatAttachment> attachments;
  final VoidCallback onTakePhoto;
  final VoidCallback onPickImage;
  final VoidCallback onPickFile;
  final ValueChanged<ChatAttachment> onRemoveAttachment;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final bool canUndo;
  final bool canReplay;
  final bool canContinue;
  final bool isContinuing;
  final bool isSuggestingReply;
  final int suggestionUsesRemaining;
  final double suggestionRefreshProgress;
  final Duration suggestionRefreshWait;
  final int? activeAssistantSegmentIndex;
  final Duration activeSegmentDisplayDuration;
  final GlobalKey latestAssistantMessageKey;
  final bool showScrollToBottomIndicator;
  final VoidCallback onScrollToBottom;
  final VoidCallback onSuggestReply;
  final VoidCallback onUndo;
  final VoidCallback onReplay;
  final void Function(ChatMessage, String) onPlaySpeech;
  final Widget speechProgress;
  final VoidCallback onRegenerateSpeech;
  final bool regeneratingSpeech;
  final VoidCallback onContinue;
  final bool showFullscreenButton;
  final bool conversationFullscreen;
  final VoidCallback onToggleFullscreen;
  final ValueChanged<double> onDragUpdate;
  final bool panelLocked;
  final VoidCallback onTogglePanelLock;
  final bool expanded;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            top: 18,
            child: _LiquidGlassSurface(
              liquidGlass: liquidGlass,
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: MediaQuery(
                            data: MediaQuery.of(context).copyWith(
                              textScaler: TextScaler.linear(
                                MediaQuery.textScalerOf(context).scale(14) /
                                    14 *
                                    (Theme.of(context)
                                            .extension<DialogueAppearance>()
                                            ?.fontScale ??
                                        1),
                              ),
                            ),
                            child: _GlassMessageList(
                              selecting: selectingCollection,
                              selection: collectionSelection,
                              availableVoices: availableCollectionVoices,
                              onSelectionChanged: savingCollection
                                  ? null
                                  : onSelectCollection,
                              onPlaySpeech: onPlaySpeech,
                              language: language,
                              messages: messages,
                              controller: scrollController,
                              activeAssistantSegmentIndex:
                                  activeAssistantSegmentIndex,
                              activeSegmentDisplayDuration:
                                  activeSegmentDisplayDuration,
                              latestAssistantMessageKey:
                                  latestAssistantMessageKey,
                              translationOnly: translationOnly,
                            ),
                          ),
                        ),
                        if (showScrollToBottomIndicator)
                          Positioned(
                            right: 8,
                            bottom: 5,
                            child: _BouncingScrollIndicator(
                              onPressed: onScrollToBottom,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.2),
                  ),
                  speechProgress,
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: min(
                        MediaQuery.sizeOf(context).height * .5,
                        max(0.0, constraints.maxHeight - 90),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: IgnorePointer(
                        ignoring: selectingCollection,
                        child: _GlassComposer(
                          availableHeight: min(
                            MediaQuery.sizeOf(context).height * .5,
                            max(0.0, constraints.maxHeight - 90),
                          ),
                          language: language,
                          controller: inputController,
                          narrationController: narrationController,
                          bottomNarrationController: bottomNarrationController,
                          splitNarration: splitNarration,
                          onToggleNarration: onToggleNarration,
                          isReplying: isReplying,
                          showMicrophone: showMicrophone,
                          unlockInputWhileReplying: unlockInputWhileReplying,
                          attachments: attachments,
                          liquidGlass: liquidGlass,
                          onTakePhoto: onTakePhoto,
                          onPickImage: onPickImage,
                          onPickFile: onPickFile,
                          onRemoveAttachment: onRemoveAttachment,
                          onSubmitted: onSubmitted,
                          onSend: onSend,
                          onCancel: onCancel,
                          expanded: expanded,
                          onToggleExpanded: onToggleExpanded,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: showFullscreenButton ? 116 : 64,
            top: 0,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SuggestionQuotaButton(
                    language: language,
                    liquidGlass: liquidGlass,
                    isSuggesting: isSuggestingReply,
                    remaining: suggestionUsesRemaining,
                    progress: suggestionRefreshProgress,
                    wait: suggestionRefreshWait,
                    onPressed:
                        !isReplying &&
                            !selectingCollection &&
                            !isSuggestingReply &&
                            suggestionUsesRemaining > 0
                        ? onSuggestReply
                        : null,
                  ),
                  const SizedBox(width: 7),
                  GlassIconButton(
                    liquidGlass: liquidGlass,
                    icon: Icons.undo_rounded,
                    tooltip: language.text(
                      '撤回上一条消息',
                      'Undo last message',
                      '直前のメッセージを取り消す',
                    ),
                    onPressed: canUndo && !selectingCollection ? onUndo : null,
                    size: 36,
                  ),
                  const SizedBox(width: 7),
                  GlassIconButton(
                    liquidGlass: liquidGlass,
                    icon: isContinuing
                        ? Icons.autorenew_rounded
                        : Icons.double_arrow_rounded,
                    iconWidget: isContinuing
                        ? const _RotatingIcon(Icons.autorenew_rounded)
                        : null,
                    tooltip: language.text(
                      '让莱莎继续对话',
                      'Let Ryza continue',
                      'ライザに会話を続けてもらう',
                    ),
                    onPressed:
                        canContinue && !isContinuing && !selectingCollection
                        ? onContinue
                        : null,
                    size: 36,
                  ),
                  const SizedBox(width: 7),
                  GlassIconButton(
                    liquidGlass: liquidGlass,
                    icon: Icons.replay_rounded,
                    iconWidget: regeneratingSpeech
                        ? const _RotatingIcon(Icons.autorenew_rounded)
                        : null,
                    onLongPress:
                        !isReplying &&
                            !selectingCollection &&
                            messages.any(
                              (m) => !m.isUser && m.text.trim().isNotEmpty,
                            )
                        ? onRegenerateSpeech
                        : null,
                    tooltip: language.text(
                      '点击重播语音，长按重新生成',
                      'Tap to replay; hold to regenerate speech',
                      'タップで再生、長押しで音声を再生成',
                    ),
                    onPressed: canReplay && !selectingCollection
                        ? onReplay
                        : null,
                    size: 36,
                  ),
                  const SizedBox(width: 7),
                  GlassIconButton(
                    liquidGlass: liquidGlass,
                    icon: selectingCollection
                        ? Icons.bookmark_add_rounded
                        : Icons.checklist_rounded,
                    tooltip: language.text(
                      selectingCollection ? '保存收藏（未选择则退出）' : '多选收藏文字或语音',
                      selectingCollection
                          ? 'Save collection (empty selection exits)'
                          : 'Select text or audio',
                      selectingCollection ? 'お気に入りを保存（未選択で終了）' : 'テキスト・音声を選択',
                    ),
                    onPressed: isReplying || savingCollection
                        ? null
                        : onToggleCollection,
                    size: 36,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 12,
            top: 0,
            child: Semantics(
              label: language.text(
                panelLocked ? '高度已锁定，长按解锁' : '拖动调整高度，长按锁定',
                panelLocked
                    ? 'Height locked; hold to unlock'
                    : 'Drag to resize; hold to lock',
                panelLocked ? '高さ固定中・長押しで解除' : 'ドラッグで高さ変更・長押しで固定',
              ),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: onTogglePanelLock,
                onVerticalDragUpdate: panelLocked
                    ? null
                    : (details) => onDragUpdate(details.delta.dy),
                child: _GlassDragHandle(
                  liquidGlass: liquidGlass,
                  locked: panelLocked,
                ),
              ),
            ),
          ),
          if (showFullscreenButton)
            Positioned(
              right: 64,
              top: 0,
              child: GlassIconButton(
                liquidGlass: liquidGlass,
                size: 44,
                icon: conversationFullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                tooltip: conversationFullscreen ? '退出全屏对话' : '全屏对话',
                onPressed: onToggleFullscreen,
              ),
            ),
        ],
      ),
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
  const _GlassDragHandle({required this.liquidGlass, required this.locked});

  final bool liquidGlass;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      liquidGlass: liquidGlass,
      tone: GlassTone.light,
      borderRadius: BorderRadius.circular(22),
      fallbackColor: Colors.white.withValues(alpha: 0.82),
      boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 10)],
      child: SizedBox.square(
        dimension: 44,
        child: Icon(
          locked ? Icons.lock_rounded : Icons.unfold_more_rounded,
          size: 23,
          color: Color(0xFF4A2F28),
        ),
      ),
    );
  }
}

class _GlassMessageList extends StatelessWidget {
  const _GlassMessageList({
    required this.selecting,
    required this.selection,
    required this.availableVoices,
    required this.onSelectionChanged,
    required this.onPlaySpeech,
    required this.language,
    required this.messages,
    required this.controller,
    required this.activeAssistantSegmentIndex,
    required this.activeSegmentDisplayDuration,
    required this.latestAssistantMessageKey,
    required this.translationOnly,
  });

  final AppLanguage language;
  final void Function(ChatMessage, String) onPlaySpeech;
  final List<ChatMessage> messages;
  final ScrollController controller;
  final int? activeAssistantSegmentIndex;
  final Duration activeSegmentDisplayDuration;
  final GlobalKey latestAssistantMessageKey;
  final bool translationOnly;
  final bool selecting;
  final Map<String, Set<String>> selection;
  final Set<String> availableVoices;
  final void Function(String, String, bool)? onSelectionChanged;

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
        Widget buildMessage() {
          if (!message.isUser) {
            return Padding(
              key: index == 0 ? latestAssistantMessageKey : null,
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: _SeparatedAssistantMessage(
                onSpeechText: selecting
                    ? null
                    : (text) => onPlaySpeech(message, text),
                response: message.displayText,
                translationOnly: translationOnly,
                language: language,
                attachments: message.attachments,
                glass: true,
                activeSegmentIndex: index == 0
                    ? activeAssistantSegmentIndex
                    : null,
                activeSegmentDisplayDuration: activeSegmentDisplayDuration,
              ),
            );
          }
          final userParts = parseUserComposerParts(message.text);
          final avatar = Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
            ),
            child: Icon(
              Icons.person_outline_rounded,
              size: 16,
              color: Colors.white,
            ),
          );
          final body = Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  language.text('你', 'You', 'あなた'),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                _UserComposerBody(text: userParts.speech, glass: true),
                if (message.attachments.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Align(
                    alignment: Alignment.centerRight,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (userParts.narration.isNotEmpty)
                  _NarratorRun(
                    segments: [
                      ChatSegment(
                        speaker: ChatSpeaker.narrator,
                        text: userParts.narration,
                      ),
                    ],
                    glass: true,
                  ),
                if (userParts.narration.isNotEmpty &&
                    userParts.speech.isNotEmpty)
                  const SizedBox(height: 10),
                if (userParts.speech.isNotEmpty ||
                    message.attachments.isNotEmpty)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [body, const SizedBox(width: 10), avatar],
                  ),
                if (userParts.bottomNarration.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _NarratorRun(
                    segments: [
                      ChatSegment(
                        speaker: ChatSpeaker.narrator,
                        text: userParts.bottomNarration,
                      ),
                    ],
                    glass: true,
                  ),
                ],
              ],
            ),
          );
        }

        final content = buildMessage();
        return SwipeCollectionSelection(
          key: ValueKey(message.collectionKey),
          selected:
              selecting &&
              (selection[message.collectionKey]?.contains('text') ?? false),
          selectedLabel: language.text('已选择', 'Selected', '選択済み'),
          onChanged: !selecting || onSelectionChanged == null
              ? null
              : (value) {
                  onSelectionChanged!(message.collectionKey, 'text', value);
                  onSelectionChanged!(
                    message.collectionKey,
                    'voice',
                    value &&
                        !message.isUser &&
                        availableVoices.contains(message.collectionKey),
                  );
                },
          child: content,
        );
      },
    );
  }
}

String _glassMessageText(ChatMessage message) {
  if (message.isUser) return _userComposerDisplayText(message.text);
  return displayTextForAssistantResponse(message.displayText)
      .replaceAll(
        RegExp(r'^\s*(旁白|莱莎|译文|角色\s*\[[^\]]+\])\s*[：:]\s*', multiLine: true),
        '',
      )
      .trim();
}

/// Composer labels are transport markers for the LLM only. Keep them in the
/// stored message so resend/withdraw and prompt history retain the structure,
/// but hide the markers in the user's chat bubble.
String _userComposerDisplayText(String text) {
  return text
      .replaceAll(RegExp(r'^\s*(?:旁白|发言)\s*[：:]\s*', multiLine: true), '')
      .trim();
}

class _UserComposerBody extends StatelessWidget {
  const _UserComposerBody({required this.text, required this.glass});

  final String text;
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final lines = text
        .replaceAll('\r\n', '\n')
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .map((line) {
          final match = RegExp(r'^\s*(旁白|发言)\s*[：:]\s*(.*)$').firstMatch(line);
          return (
            isNarration: match?.group(1) == '旁白',
            value: (match?.group(2) ?? line).trim(),
          );
        })
        .where((line) => line.value.isNotEmpty)
        .toList(growable: false);
    final color = glass
        ? Colors.white
        : Theme.of(context).colorScheme.onPrimary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final line in lines) ...[
          if (line.isNarration)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.menu,
                    size: 24,
                    color: color.withValues(alpha: 0.9),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      line.value,
                      textAlign: TextAlign.left,
                      style: TextStyle(
                        color: color.withValues(alpha: 0.82),
                        fontSize: 14,
                        height: 1.35,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                line.value,
                textAlign: TextAlign.right,
                style: TextStyle(color: color, fontSize: 14, height: 1.35),
              ),
            ),
        ],
      ],
    );
  }
}

class _SeparatedAssistantMessage extends StatelessWidget {
  const _SeparatedAssistantMessage({
    this.onSpeechText,
    required this.response,
    required this.translationOnly,
    required this.language,
    required this.attachments,
    required this.glass,
    this.activeSegmentIndex,
    this.activeSegmentDisplayDuration = Duration.zero,
  });

  final String response;
  final ValueChanged<String>? onSpeechText;
  final bool translationOnly;
  final AppLanguage language;
  final List<ChatAttachment> attachments;
  final bool glass;
  final int? activeSegmentIndex;
  final Duration activeSegmentDisplayDuration;

  @override
  Widget build(BuildContext context) {
    final runs = groupAssistantSegmentsForDisplay(response);
    var segmentOffset = 0;
    final children = <Widget>[];
    for (var index = 0; index < runs.length; index++) {
      final run = runs[index];
      final activeInRun =
          activeSegmentIndex != null &&
              activeSegmentIndex! >= segmentOffset &&
              activeSegmentIndex! < segmentOffset + run.length
          ? activeSegmentIndex! - segmentOffset
          : null;
      if (index > 0) children.add(const SizedBox(height: 10));
      if (run.first.speaker == ChatSpeaker.narrator) {
        children.add(
          _NarratorRun(
            segments: run,
            glass: glass,
            activeSegmentIndex: activeInRun,
            activeSegmentDisplayDuration: activeSegmentDisplayDuration,
          ),
        );
      } else if (run.first.speaker == ChatSpeaker.character) {
        children.add(
          _CharacterRun(
            segments: run,
            language: language,
            glass: glass,
            translationOnly: translationOnly,
            activeSegmentIndex: activeInRun,
            activeSegmentDisplayDuration: activeSegmentDisplayDuration,
          ),
        );
      } else {
        children.add(
          _RyzaRun(
            onSpeechText: onSpeechText,
            segments: run,
            language: language,
            glass: glass,
            translationOnly: translationOnly,
            activeSegmentIndex: activeInRun,
            activeSegmentDisplayDuration: activeSegmentDisplayDuration,
          ),
        );
      }
      segmentOffset += run.length;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...children,
        if (attachments.isNotEmpty) ...[
          const SizedBox(height: 7),
          _SentAttachmentLabels(attachments: attachments, glass: glass),
        ],
      ],
    );
  }
}

class _NarratorRun extends StatelessWidget {
  const _NarratorRun({
    required this.segments,
    required this.glass,
    this.activeSegmentIndex,
    this.activeSegmentDisplayDuration = Duration.zero,
  });

  final List<ChatSegment> segments;
  final bool glass;
  final int? activeSegmentIndex;
  final Duration activeSegmentDisplayDuration;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1, right: 8),
          child: Icon(
            Icons.menu_rounded,
            size: 18,
            color: glass
                ? Colors.white70
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Expanded(
          child: _AutoVisibleDialogueSegment(
            active: activeSegmentIndex != null,
            displayDuration: activeSegmentDisplayDuration,
            child: Text(
              segments.map(displayTextForAssistantSegment).join('\n'),
              style: TextStyle(
                color:
                    Theme.of(context)
                        .extension<DialogueAppearance>()
                        ?.textColor ??
                    (glass
                        ? Colors.white70
                        : Theme.of(context).colorScheme.onSurfaceVariant),
                fontSize: 13,
                fontStyle: FontStyle.italic,
                height: 1.38,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RyzaRun extends StatelessWidget {
  const _RyzaRun({
    this.onSpeechText,
    required this.segments,
    required this.language,
    required this.glass,
    this.translationOnly = false,
    this.activeSegmentIndex,
    this.activeSegmentDisplayDuration = Duration.zero,
  });

  final List<ChatSegment> segments;
  final ValueChanged<String>? onSpeechText;
  final AppLanguage language;
  final bool glass;
  final bool translationOnly;
  final int? activeSegmentIndex;
  final Duration activeSegmentDisplayDuration;

  @override
  Widget build(BuildContext context) {
    final avatar = Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: glass
            ? Colors.white.withValues(alpha: 0.16)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border.all(
          color: glass
              ? Colors.white.withValues(alpha: 0.24)
              : Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/images/chara_icons/ryza.png',
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Icon(
          Icons.person_outline_rounded,
          size: 16,
          color: glass ? Colors.white : Theme.of(context).colorScheme.primary,
        ),
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        avatar,
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                language.text('莱莎', 'Ryza', 'ライザ'),
                style: TextStyle(
                  color: glass
                      ? Colors.white70
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              _DialogueSegmentBody(
                onSpeechText: onSpeechText,
                segments: segments,
                translationOnly: translationOnly,
                glass: glass,
                activeSegmentIndex: activeSegmentIndex,
                activeSegmentDisplayDuration: activeSegmentDisplayDuration,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CharacterRun extends StatelessWidget {
  const _CharacterRun({
    required this.segments,
    required this.language,
    required this.glass,
    this.translationOnly = false,
    this.activeSegmentIndex,
    this.activeSegmentDisplayDuration = Duration.zero,
  });

  final List<ChatSegment> segments;
  final AppLanguage language;
  final bool glass;
  final bool translationOnly;
  final int? activeSegmentIndex;
  final Duration activeSegmentDisplayDuration;

  @override
  Widget build(BuildContext context) {
    final id = segments.first.characterId ?? 'unknown';
    final catalog = CharacterCatalog.current;
    final profile = catalog?.profile(id);
    final name = catalog?.displayName(id, language) ?? id;
    final fallbackColor = glass
        ? Colors.white.withValues(alpha: 0.16)
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    final avatar = Container(
      width: 28,
      height: 28,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fallbackColor,
        border: Border.all(
          color: glass
              ? Colors.white.withValues(alpha: 0.24)
              : Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: profile == null
          ? Icon(
              Icons.person_outline_rounded,
              size: 16,
              color: glass
                  ? Colors.white
                  : Theme.of(context).colorScheme.primary,
            )
          : Image.asset(
              profile.avatarAsset,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Icon(
                Icons.person_outline_rounded,
                size: 16,
                color: glass
                    ? Colors.white
                    : Theme.of(context).colorScheme.primary,
              ),
            ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        avatar,
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: TextStyle(
                  color: glass
                      ? Colors.white70
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              _DialogueSegmentBody(
                segments: segments,
                translationOnly: translationOnly,
                glass: glass,
                activeSegmentIndex: activeSegmentIndex,
                activeSegmentDisplayDuration: activeSegmentDisplayDuration,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DialogueSegmentBody extends StatelessWidget {
  const _DialogueSegmentBody({
    this.onSpeechText,
    required this.segments,
    required this.glass,
    this.translationOnly = false,
    this.activeSegmentIndex,
    this.activeSegmentDisplayDuration = Duration.zero,
  });

  final List<ChatSegment> segments;
  final ValueChanged<String>? onSpeechText;
  final bool glass;
  final bool translationOnly;
  final int? activeSegmentIndex;
  final Duration activeSegmentDisplayDuration;

  @override
  Widget build(BuildContext context) {
    final appearance = Theme.of(context).extension<DialogueAppearance>();
    final visibleIndices = dialogueDisplayIndices(
      segments,
      translationOnly || appearance?.translationOnly == true,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final index in visibleIndices) ...[
          if (index != visibleIndices.first)
            Divider(
              height: 17,
              thickness: 1,
              color: glass
                  ? Colors.white.withValues(alpha: 0.22)
                  : Colors.black.withValues(alpha: 0.13),
            ),
          _AutoVisibleDialogueSegment(
            active: activeSegmentIndex == index,
            displayDuration: activeSegmentDisplayDuration,
            child: GestureDetector(
              onTap: onSpeechText == null
                  ? null
                  : () {
                      final original = segments
                          .take(index + 1)
                          .where((s) => s.speaker == ChatSpeaker.ryza)
                          .lastOrNull;
                      if (original != null) {
                        onSpeechText!(displayTextForAssistantSegment(original));
                      }
                    },
              child: Text(
                '${segments[index].speaker == ChatSpeaker.translation ? '译文：' : ''}'
                '${displayTextForAssistantSegment(segments[index])}',
                style: TextStyle(
                  color:
                      appearance?.textColor ??
                      (glass
                          ? Colors.white
                          : Theme.of(context).colorScheme.onSurface),
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _AutoVisibleDialogueSegment extends StatefulWidget {
  const _AutoVisibleDialogueSegment({
    required this.active,
    required this.displayDuration,
    required this.child,
  });

  final bool active;
  final Duration displayDuration;
  final Widget child;

  @override
  State<_AutoVisibleDialogueSegment> createState() =>
      _AutoVisibleDialogueSegmentState();
}

class _AutoVisibleDialogueSegmentState
    extends State<_AutoVisibleDialogueSegment> {
  @override
  Widget build(BuildContext context) => widget.child;
}

class _BouncingScrollIndicator extends StatefulWidget {
  const _BouncingScrollIndicator({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_BouncingScrollIndicator> createState() =>
      _BouncingScrollIndicatorState();
}

class _BouncingScrollIndicatorState extends State<_BouncingScrollIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '回到最新消息底部',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: SizedBox.square(
          dimension: 34,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Transform.translate(
              offset: Offset(0, 4 * _controller.value),
              child: child,
            ),
            child: const Icon(
              Icons.arrow_drop_down_rounded,
              color: Colors.white,
              size: 32,
              shadows: [Shadow(color: Colors.black54, blurRadius: 5)],
            ),
          ),
        ),
      ),
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
          if (attachment.isImage && attachment.previewBytes != null)
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
    final bytes = attachment.previewBytes;
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
    required this.availableHeight,
    required this.language,
    required this.controller,
    required this.narrationController,
    required this.bottomNarrationController,
    required this.splitNarration,
    required this.onToggleNarration,
    required this.isReplying,
    required this.showMicrophone,
    required this.unlockInputWhileReplying,
    required this.attachments,
    required this.liquidGlass,
    required this.onTakePhoto,
    required this.onPickImage,
    required this.onPickFile,
    required this.onRemoveAttachment,
    required this.onSubmitted,
    required this.onSend,
    required this.onCancel,
    required this.expanded,
    required this.onToggleExpanded,
  });

  final AppLanguage language;
  final TextEditingController controller;
  final TextEditingController narrationController;
  final TextEditingController bottomNarrationController;
  final bool splitNarration;
  final VoidCallback onToggleNarration;
  final bool isReplying;
  final bool showMicrophone;
  final bool unlockInputWhileReplying;
  final List<ChatAttachment> attachments;
  final bool liquidGlass;
  final VoidCallback onTakePhoto;
  final VoidCallback onPickImage;
  final VoidCallback onPickFile;
  final ValueChanged<ChatAttachment> onRemoveAttachment;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final bool expanded;
  final double availableHeight;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      bottom: false,
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
              IconButton(
                tooltip: language.text(
                  '旁白与发言分栏',
                  'Split narration and speech',
                  'ナレーションと発言を分ける',
                ),
                icon: Icon(
                  splitNarration
                      ? Icons.view_agenda_rounded
                      : Icons.view_agenda_outlined,
                ),
                onPressed: onToggleNarration,
                color: Colors.white,
              ),
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
                  height: splitNarration
                      ? min(
                          expanded ? availableHeight : 174.0,
                          max(
                            28.0,
                            availableHeight -
                                18 -
                                (attachments.isNotEmpty ? 108 : 0),
                          ),
                        )
                      : null,
                  constraints: BoxConstraints(
                    minHeight: 46,
                    maxHeight: splitNarration ? double.infinity : 96,
                  ),
                  padding: const EdgeInsets.only(left: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.28),
                    ),
                  ),
                  child: splitNarration
                      ? NarrationComposerFields(
                          controllers: [
                            narrationController,
                            controller,
                            bottomNarrationController,
                          ],
                          hints: [
                            language.text(
                              '旁白（环境、动作、神态）',
                              'Opening narration',
                              '上部ナレーション',
                            ),
                            language.text(
                              '你想说的话',
                              'What you want to say',
                              'あなたが話す内容',
                            ),
                            language.text(
                              '下方旁白（反应、收尾、气氛）',
                              'Closing narration',
                              '下部ナレーション',
                            ),
                          ],
                          expanded: expanded,
                          onToggleExpanded: onToggleExpanded,
                          expandLabel: expanded
                              ? language.text(
                                  '收起输入框',
                                  'Collapse input',
                                  '入力欄を縮小',
                                )
                              : language.text(
                                  '放大输入框',
                                  'Enlarge input',
                                  '入力欄を拡大',
                                ),
                          readOnly: isReplying && !unlockInputWhileReplying,
                        )
                      : TextField(
                          controller: controller,
                          readOnly: isReplying && !unlockInputWhileReplying,
                          minLines: 1,
                          maxLines: 3,
                          textAlignVertical: TextAlignVertical.center,
                          textInputAction: TextInputAction.send,
                          onSubmitted: isReplying ? null : onSubmitted,
                          style: const TextStyle(color: Colors.white),
                          cursorColor: Colors.white,
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 13,
                            ),
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
                            suffixIcon: _AttachmentMenuButton(
                              language: language,
                              liquidGlass: liquidGlass,
                              enabled: !isReplying,
                              onTakePhoto: onTakePhoto,
                              onPickImage: onPickImage,
                              onPickFile: onPickFile,
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
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
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

class _AttachmentMenuButton extends StatefulWidget {
  const _AttachmentMenuButton({
    required this.language,
    required this.liquidGlass,
    required this.enabled,
    required this.onTakePhoto,
    required this.onPickImage,
    required this.onPickFile,
  });

  final AppLanguage language;
  final bool liquidGlass;
  final bool enabled;
  final VoidCallback onTakePhoto;
  final VoidCallback onPickImage;
  final VoidCallback onPickFile;

  @override
  State<_AttachmentMenuButton> createState() => _AttachmentMenuButtonState();
}

class _AttachmentMenuButtonState extends State<_AttachmentMenuButton> {
  final _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  bool get _expanded => _overlayEntry != null;

  void _toggle() {
    if (_expanded) {
      _close();
      return;
    }
    if (!widget.enabled) return;
    _overlayEntry = OverlayEntry(
      builder: (overlayContext) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _close,
            ),
          ),
          CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topRight,
            followerAnchor: Alignment.bottomRight,
            offset: const Offset(0, -8),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _AttachmentMenuOption(
                    liquidGlass: widget.liquidGlass,
                    icon: Icons.camera_alt_outlined,
                    label: widget.language.text('拍照', 'Camera', '撮影'),
                    onPressed: () => _select(widget.onTakePhoto),
                  ),
                  const SizedBox(height: 6),
                  _AttachmentMenuOption(
                    liquidGlass: widget.liquidGlass,
                    icon: Icons.image_outlined,
                    label: widget.language.text('图片', 'Image', '画像'),
                    onPressed: () => _select(widget.onPickImage),
                  ),
                  const SizedBox(height: 6),
                  _AttachmentMenuOption(
                    liquidGlass: widget.liquidGlass,
                    icon: Icons.description_outlined,
                    label: widget.language.text('文件', 'File', 'ファイル'),
                    onPressed: () => _select(widget.onPickFile),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
    setState(() {});
  }

  void _select(VoidCallback callback) {
    _close();
    callback();
  }

  void _close() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _AttachmentMenuButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _expanded) _close();
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: IconButton(
        onPressed: widget.enabled ? _toggle : null,
        tooltip: _expanded
            ? widget.language.text(
                '收起附件菜单',
                'Close attachment menu',
                '添付メニューを閉じる',
              )
            : widget.language.text('添加附件', 'Add attachment', '添付を追加'),
        color: Colors.white,
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Icon(
            _expanded ? Icons.close_rounded : Icons.add_rounded,
            key: ValueKey(_expanded),
            size: 30,
          ),
        ),
      ),
    );
  }
}

class _AttachmentMenuOption extends StatelessWidget {
  const _AttachmentMenuOption({
    required this.liquidGlass,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final bool liquidGlass;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      liquidGlass: liquidGlass,
      borderRadius: BorderRadius.circular(20),
      fallbackColor: Colors.black.withValues(alpha: 0.58),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onPressed,
        child: SizedBox(
          width: 116,
          height: 40,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 19),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(color: Colors.white)),
            ],
          ),
        ),
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
                language: widget.language,
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
    required this.language,
    this.controller,
    this.reverse = false,
    this.showRawOutput = false,
    this.glass = false,
  });

  final List<ChatMessage> messages;
  final bool isReplying;
  final AppLanguage language;
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
        if (message.isUser && !showRawOutput) {
          final parts = parseUserComposerParts(message.text);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (parts.narration.isNotEmpty)
                  _NarratorRun(
                    segments: [
                      ChatSegment(
                        speaker: ChatSpeaker.narrator,
                        text: parts.narration,
                      ),
                    ],
                    glass: glass,
                  ),
                if (parts.narration.isNotEmpty &&
                    (parts.speech.isNotEmpty || message.attachments.isNotEmpty))
                  const SizedBox(height: 10),
                if (parts.speech.isNotEmpty || message.attachments.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 520),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: glass
                            ? Colors.white.withValues(alpha: 0.20)
                            : Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (parts.speech.isNotEmpty)
                            Text(
                              parts.speech,
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                color: glass
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.onPrimary,
                                height: 1.4,
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
                  ),
                if (parts.bottomNarration.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _NarratorRun(
                    segments: [
                      ChatSegment(
                        speaker: ChatSpeaker.narrator,
                        text: parts.bottomNarration,
                      ),
                    ],
                    glass: glass,
                  ),
                ],
              ],
            ),
          );
        }
        if (!message.isUser && !showRawOutput) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              margin: const EdgeInsets.symmetric(vertical: 5),
              child: _SeparatedAssistantMessage(
                response: message.displayText,
                translationOnly: false,
                language: language,
                attachments: message.attachments,
                glass: glass,
              ),
            ),
          );
        }
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
                        : Theme.of(context).colorScheme.primary)
                  : (glass
                        ? Colors.black.withValues(alpha: 0.18)
                        : const Color(0xFFE7E4DD)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                message.isUser && !showRawOutput
                    ? _UserComposerBody(text: message.text, glass: glass)
                    : Text(
                        message.text,
                        style: TextStyle(
                          color: glass ? Colors.white : const Color(0xFF262521),
                          height: 1.4,
                        ),
                      ),
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
