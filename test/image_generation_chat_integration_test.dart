import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/chat_screen.dart';
import 'package:ryza_chat_mvp/src/character_status_panel.dart';
import 'package:ryza_chat_mvp/src/body_sensitivity.dart';
import 'package:ryza_chat_mvp/src/image_generation_config.dart';
import 'package:ryza_chat_mvp/src/image_generation_manager_page.dart';
import 'package:ryza_chat_mvp/src/image_generation_service.dart';
import 'package:ryza_chat_mvp/src/image_generation_store.dart';
import 'package:ryza_chat_mvp/src/story_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final audioChannels = <String>{
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers.global/events',
    'xyz.luan/audioplayers',
    'agent_atelier_r/companion_runtime',
    'agent_atelier_r/companion_runtime/events',
  };
  setUpAll(() async {
    for (final name in audioChannels) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final channel = 'xyz.luan/audioplayers/events/$id';
          audioChannels.add(channel);
          messenger.setMockMethodCallHandler(
            MethodChannel(channel),
            (_) async => null,
          );
        }
        return null;
      },
    );
    await AudioPlayer.global.ensureInitialized();
  });
  tearDownAll(() {
    for (final name in audioChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  testWidgets('phone status diagram follows current stats and turn rollback', (
    tester,
  ) async {
    final harness = await _mountChat(tester, aiEnabled: false);
    final controller = harness.controller;
    controller.setStoryClockEnabled(true);
    final mood = controller.characterState.values['mood']!;
    final before = controller.storyClock.totalMinutes;
    final id = controller.addUserMessage('休息片刻');
    await _openPhoneHome(tester);
    await tester.tap(find.byKey(const ValueKey('virtual-phone-app-status')));
    await tester.pumpAndSettle();
    expect(find.byType(CharacterStatusPanel), findsOneWidget);
    const proposal = {
      'state_delta': {'mood': 5},
      'emotion': 'happy',
      'reason': '休息后更有精神',
      'time_advance': {'kind': 'rest', 'minutes': 30},
    };
    controller.settleCharacterState(id, proposal, controller.dataRevision);
    controller.settleStoryTime(id, proposal, controller.dataRevision);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('body-status-value-mood')))
          .data,
      '${mood + 5}',
    );
    expect(
      tester
          .widget<CharacterStatusPanel>(find.byType(CharacterStatusPanel))
          .clock
          .totalMinutes,
      before + 30,
    );
    controller.undoLastUserTurn();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('body-status-value-mood')))
          .data,
      '$mood',
    );
    expect(
      tester
          .widget<CharacterStatusPanel>(find.byType(CharacterStatusPanel))
          .clock
          .totalMinutes,
      before,
    );
    await tester.tap(find.byKey(const ValueKey('body-map-sensitivity-tab')));
    await tester.pumpAndSettle();
    final legs = find.byKey(const ValueKey('body-sensitivity-legs'));
    await tester.ensureVisible(legs);
    await tester.tap(legs);
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('body-sensitivity-slider'));
    expect(slider, findsNothing);
    final title = find.byKey(const ValueKey('status-numeric-edit-title'));
    for (var tap = 0; tap < 9; tap++) {
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(slider, findsNothing);
    await tester.tap(title);
    await tester.pump(const Duration(milliseconds: 80));
    expect(slider, findsOneWidget);
    await tester.ensureVisible(slider);
    final sliderRect = tester.getRect(slider);
    await tester.tapAt(sliderRect.center + const Offset(35, 0));
    await tester.pumpAndSettle();
    final sensitivity = controller.bodySensitivity.valueFor(
      BodySensitivityPart.legs,
    );
    expect(sensitivity, greaterThan(50));
    expect(controller.recordBodySensitivityTouch('legs'), isTrue);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('body-sensitivity-value-legs')),
          )
          .data,
      '${sensitivity + 1}',
    );
    final intimate = find.byKey(const ValueKey('body-sensitivity-intimate'));
    await tester.ensureVisible(intimate);
    await tester.tap(intimate);
    await tester.pumpAndSettle();
    expect(
      controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
      isFalse,
    );
    expect(find.byKey(const ValueKey('body-sensitivity-slider')), findsNothing);
    final unlock = find.byKey(const ValueKey('body-sensitivity-unlock'));
    await tester.ensureVisible(unlock);
    await tester.tap(unlock);
    await tester.pumpAndSettle();
    expect(
      controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
      isTrue,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('body-sensitivity-value-intimate')),
          )
          .data,
      '50',
    );
    expect(
      find.byKey(const ValueKey('body-sensitivity-slider')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('virtual-phone-app-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('body-map-sensitivity-tab')));
    await tester.pumpAndSettle();
    expect(slider, findsNothing);
    expect(
      find.byKey(const ValueKey('status-numeric-edit-enabled')),
      findsNothing,
    );
    expect(
      controller.bodySensitivity.valueFor(BodySensitivityPart.legs),
      sensitivity + 1,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('undo button restores stats and time and refills the composer', (
    tester,
  ) async {
    final harness = await _mountChat(tester, aiEnabled: false);
    final controller = harness.controller;
    controller.setStoryClockEnabled(true);
    controller.storyClock = StoryClock(totalMinutes: 23 * 60 + 55, satiety: 8);
    controller.sceneTime = SceneTime.night;
    final before = jsonDecode(jsonEncode(controller.characterState.toJson()));
    final id = controller.addUserMessage('我们先休息一会儿');
    final revision = controller.dataRevision;
    const proposal = {
      'state_delta': {'mood': 5, 'energy': -5},
      'emotion': 'happy',
      'reason': '对话中的状态变化',
      'time_advance': {'kind': 'rest', 'minutes': 60},
    };
    controller.settleCharacterState(id, proposal, revision);
    controller.settleStoryTime(id, proposal, revision);
    controller.addAssistantMessage('好呀，休息一会儿。');
    await tester.pump();
    await tester.tap(find.byTooltip('回退上一轮对话、状态与时间'));
    await tester.pump();
    expect(controller.characterState.toJson(), before);
    expect(controller.storyClock.totalMinutes, 23 * 60 + 55);
    expect(controller.storyClock.satiety, 8);
    expect(controller.sceneTime, SceneTime.night);
    expect(controller.messages.any((m) => m.id == id), isFalse);
    expect(
      tester.widget<TextField>(_ordinaryInput()).controller!.text,
      '我们先休息一会儿',
    );
    expect(controller.settleStoryTime(id, proposal, revision), isFalse);
  });

  testWidgets('a failed reply is undone with its user turn in one click', (
    tester,
  ) async {
    final harness = await _mountChat(tester, aiEnabled: false);
    final controller = harness.controller;
    controller.storyClock = StoryClock(totalMinutes: 800);
    final id = controller.addUserMessage('失败后再修改的输入');
    controller.storyClock = StoryClock(totalMinutes: 860);
    controller.failAssistantStream('offline test');
    await tester.pump();
    await tester.tap(find.byTooltip('回退上一轮对话、状态与时间'));
    await tester.pump();
    expect(controller.messages.any((m) => m.id == id || m.isFailure), isFalse);
    expect(controller.storyClock.totalMinutes, 800);
    expect(
      tester.widget<TextField>(_ordinaryInput()).controller!.text,
      '失败后再修改的输入',
    );
  });

  testWidgets(
    'chat image request shows progress, unread result, history image and clears unread on open',
    (tester) async {
      final harness = await _mountChat(tester, aiEnabled: false);
      expect(
        find.byKey(const ValueKey('image-generation-manager-button')),
        findsNothing,
      );
      final initialAssistantCount = harness.controller.messages
          .where((message) => !message.isUser)
          .length;

      await tester.enterText(_ordinaryInput(), '帮我生成一张图片，画一只戴帽子的猫');
      await tester.tap(find.byKey(const ValueKey('chat-send-button')));
      await tester.pump();
      expect(harness.controller.messages.last.isUser, isTrue);
      await _pumpUntil(tester, () => harness.imageService.started.isCompleted);

      expect(harness.imageService.prompt, contains('戴帽子的猫'));
      expect(harness.imageService.prompt, contains('莱莎'));
      expect(harness.imageService.apiKey, 'optional-image-key');
      expect(harness.store.activeCount, 1);
      await _openPhoneHome(tester);
      expect(
        find.byKey(const ValueKey('image-generation-toolbar-progress')),
        findsOneWidget,
      );

      // Let the ordinary assistant reply finish first. The image result is a
      // separate assistant message and must never replace that reply.
      await tester.pump(const Duration(milliseconds: 500));
      final assistantBeforeImage = harness.controller.messages
          .where((message) => !message.isUser)
          .toList();
      expect(assistantBeforeImage, hasLength(initialAssistantCount + 1));
      final ordinaryReply = assistantBeforeImage.last;
      expect(ordinaryReply.attachments, isEmpty);

      harness.imageService.complete(_result());
      await _pumpUntil(
        tester,
        () =>
            harness.store.tasks.single.status ==
            ImageGenerationTaskStatus.completed,
      );
      await _pumpUntil(
        tester,
        () => harness.controller.messages.any(
          (message) =>
              !message.isUser &&
              message.attachments.any(
                (attachment) => attachment.generatedImageTaskId != null,
              ),
        ),
      );

      final assistantMessages = harness.controller.messages
          .where((message) => !message.isUser)
          .toList();
      expect(assistantMessages, hasLength(initialAssistantCount + 2));
      expect(
        assistantMessages[assistantMessages.length - 2].text,
        ordinaryReply.text,
      );
      expect(
        assistantMessages[assistantMessages.length - 2].attachments,
        isEmpty,
      );
      final imageMessage = assistantMessages.last;
      expect(imageMessage.text, contains('图片已生成'));
      expect(imageMessage.attachments, hasLength(1));
      expect(imageMessage.attachments.single.bytes, _pngBytes);
      expect(
        imageMessage.attachments.single.generatedImageTaskId,
        harness.store.tasks.single.id,
      );
      await tester.pump(const Duration(milliseconds: 300));
      // Chat history stays mounted while the opaque phone avoids painting it.
      expect(
        find.text(imageMessage.attachments.single.name, skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Image &&
              (widget.image is MemoryImage ||
                  widget.image is ResizeImage &&
                      (widget.image as ResizeImage).imageProvider
                          is MemoryImage),
          skipOffstage: false,
        ),
        findsWidgets,
      );
      expect(
        find.byKey(const ValueKey('image-generation-toolbar-progress')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('image-generation-unread-dot')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('virtual-phone-app-imageGeneration')),
      );
      await _pumpUntil(
        tester,
        () => find.byType(ImageGenerationManagerPage).evaluate().isNotEmpty,
      );
      expect(find.byType(ImageGenerationManagerPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('virtual-phone-screen')),
        findsOneWidget,
      );
      await _pumpUntil(tester, () => !harness.store.hasUnseenCompleted);
      expect(harness.store.hasUnseenCompleted, isFalse);
      expect(
        find.byKey(
          const ValueKey('image-generation-unread-dot'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.tap(
        find.byKey(const ValueKey('image-generation-manager-back')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byType(ImageGenerationManagerPage), findsNothing);
      expect(
        find.byKey(const ValueKey('virtual-phone-app-imageGeneration')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a received image that cannot be saved requires retry confirmation',
    (tester) async {
      final harness = await _mountChat(tester, aiEnabled: false);
      await tester.enterText(_ordinaryInput(), '画一张库肯岛的图片');
      await tester.tap(find.byKey(const ValueKey('chat-send-button')));
      await _pumpUntil(tester, () => harness.imageService.started.isCompleted);
      harness.imageService.complete(
        ImageGenerationResult(
          bytes: Uint8List.fromList([0xff, 0xd8, 0xff]),
          mimeType: 'image/jpeg',
          protocol: ImageGenerationProtocol.comfyUi,
          model: 'offline-test',
        ),
      );
      await _pumpUntil(
        tester,
        () =>
            harness.store.tasks.single.status ==
            ImageGenerationTaskStatus.failed,
      );
      expect(harness.store.tasks.single.outcomeUnknown, isTrue);
      await tester.pump(const Duration(milliseconds: 500));
      await _openPhoneHome(tester);
      await tester.tap(
        find.byKey(const ValueKey('virtual-phone-app-imageGeneration')),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(
              ValueKey(
                'image-generation-retry-${harness.store.tasks.single.id}',
              ),
            )
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(
        find.byKey(
          ValueKey('image-generation-retry-${harness.store.tasks.single.id}'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('image-generation-unknown-retry-dialog')),
        findsOneWidget,
      );
      expect(
        harness.store.tasks.single.status,
        ImageGenerationTaskStatus.failed,
      );
    },
  );

  testWidgets(
    'completed image waits without mutating an active streamed assistant message',
    (tester) async {
      final ai = _ControlledAiClient();
      final harness = await _mountChat(tester, aiEnabled: true, aiClient: ai);

      await tester.enterText(_ordinaryInput(), '画一张炼金工坊的图片');
      await tester.tap(find.byKey(const ValueKey('chat-send-button')));
      await tester.pump();
      await _pumpUntil(
        tester,
        () =>
            ai.listened.isCompleted && harness.imageService.started.isCompleted,
      );

      ai.add('第一段流式回复');
      await tester.pump();
      var streamed = harness.controller.messages.last;
      expect(streamed.isUser, isFalse);
      expect(streamed.text, '第一段流式回复');
      expect(streamed.attachments, isEmpty);

      harness.imageService.complete(_result());
      await _pumpUntil(
        tester,
        () =>
            harness.store.tasks.singleOrNull?.status ==
            ImageGenerationTaskStatus.completed,
      );
      expect(harness.store.hasUnseenCompleted, isTrue);
      streamed = harness.controller.messages.last;
      expect(streamed.text, '第一段流式回复');
      expect(streamed.attachments, isEmpty);
      expect(
        harness.controller.messages.where(
          (message) => message.attachments.isNotEmpty,
        ),
        isEmpty,
      );

      ai.add('，第二段仍可继续');
      await tester.pump();
      streamed = harness.controller.messages.last;
      expect(streamed.text, '第一段流式回复，第二段仍可继续');
      expect(streamed.attachments, isEmpty);
      await _openPhoneHome(tester);
      expect(
        find.byKey(const ValueKey('image-generation-unread-dot')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      ai.finish();
      await _pumpUntil(
        tester,
        () => harness.controller.messages.any(
          (message) => message.attachments.isNotEmpty,
        ),
      );
      expect(
        harness
            .controller
            .messages[harness.controller.messages.length - 2]
            .text,
        '第一段流式回复，第二段仍可继续',
      );
      expect(harness.controller.messages.last.attachments, hasLength(1));
    },
  );

  testWidgets('bare image command captures current dialogue and background', (
    tester,
  ) async {
    final harness = await _mountChat(tester, aiEnabled: false);
    harness.controller.setCharacterPersona('苏菲是戴着红帽子的炼金术士。');
    harness.controller.setWorldSetting('这座漂浮小岛上开满了发光的花。');
    harness.controller.selectedAreaName = '漂浮小岛';
    harness.controller.selectedStageName = '日落海岸';
    harness.controller.sceneTime = SceneTime.evening;
    harness.controller.addUserMessage('我们带着热茶到海边看夕阳吧。');
    harness.controller.addAssistantMessage('旁白：苏菲抱着茶壶，坐在开满发光花朵的海岸边。');
    await tester.pump();
    await tester.enterText(_ordinaryInput(), '生图');
    await tester.tap(find.byKey(const ValueKey('chat-send-button')));
    // The prompt must use the scene at submission, including if settings change
    // while the task is being persisted and the model request has not started.
    harness.controller.selectedStageName = '后来切换的地点';
    await _pumpUntil(tester, () => harness.imageService.started.isCompleted);
    final prompt = harness.imageService.prompt!;
    expect(prompt, contains('莱莎'));
    expect(prompt, contains('苏菲'));
    expect(prompt, isNot(contains('红帽子')));
    expect(prompt, contains('发光的花'));
    expect(prompt, contains('日落海岸'));
    expect(prompt, contains('热茶'));
    expect(prompt, contains('茶壶'));
    expect(prompt, isNot(contains('后来切换的地点')));
    expect(harness.store.tasks.single.prompt, prompt);
    harness.imageService.complete(_result());
    await tester.pump(const Duration(milliseconds: 500));
    await _pumpUntil(
      tester,
      () =>
          harness.store.tasks.single.status ==
          ImageGenerationTaskStatus.completed,
    );
    await _pumpUntil(
      tester,
      () => harness.controller.messages.any(
        (message) => message.attachments.any(
          (attachment) => attachment.generatedImageTaskId != null,
        ),
      ),
    );
    expect(harness.controller.messages.last.text, '图片已生成：当前对话场景');
  });
}

Future<void> _openPhoneHome(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.smartphone_rounded));
  await tester.pump(); // Lay out the opaque phone route before its transition.
  await tester.pump(const Duration(milliseconds: 400));
  expect(
    find.byKey(const ValueKey('virtual-phone-app-imageGeneration')),
    findsOneWidget,
  );
  expect(
    find.byKey(const ValueKey('virtual-phone-app-shortcut')),
    findsNothing,
  );
}

Finder _ordinaryInput() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      widget.decoration?.hintText?.contains('说点什么') == true,
);

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int attempts = 40,
}) async {
  for (var attempt = 0; attempt < attempts && !condition(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
  expect(condition(), isTrue, reason: 'condition did not become true');
}

Future<_ChatHarness> _mountChat(
  WidgetTester tester, {
  required bool aiEnabled,
  _ControlledAiClient? aiClient,
}) async {
  tester.view.physicalSize = const Size(430, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({
    'active_character_id_v1': 'sophie',
    'ai_enabled': aiEnabled,
    'fish_tts_enabled': false,
  });
  final controller = (await tester.runAsync(AppController.load))!;
  controller.configureLanguages(
    interface: AppLanguage.chinese,
    narrator: AppLanguage.chinese,
    characterReply: AppLanguage.chinese,
    translation: TranslationLanguage.none,
  );
  if (aiEnabled) {
    controller.configureAi(
      enabled: true,
      baseUrl: 'https://llm.example.test/v1',
      model: 'stream-test',
    );
  }
  controller.configureImageGeneration(
    const ImageGenerationConfig(
      enabled: true,
      baseUrl: 'http://127.0.0.1:8188',
      model: 'offline-test',
      protocol: ImageGenerationProtocol.comfyUi,
    ),
  );
  final directory = Directory.systemTemp.createTempSync(
    'chat_image_generation_test_',
  );
  final store = ImageGenerationStore(directoryProvider: () async => directory);
  await tester.runAsync(store.load);
  final imageService = _ControlledImageService();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    store.dispose();
    controller.dispose();
    if (directory.existsSync()) {
      try {
        directory.deleteSync(recursive: true);
      } on FileSystemException {
        // The Windows image decoder can release its file handle one frame late.
      }
    }
  });
  await tester.pumpWidget(
    MaterialApp(
      home: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => ChatScreen(
          controller: controller,
          onMenuPressed: () {},
          onShopPressed: () {},
          hideUi: false,
          imageGenerationService: imageService,
          imageGenerationStore: store,
          aiClient: aiClient,
          secretStore: const _FakeSecretStore(),
          imageThumbnailer: (_) async => null,
        ),
      ),
    ),
  );
  await tester.pump();
  return _ChatHarness(
    controller: controller,
    store: store,
    imageService: imageService,
  );
}

class _ChatHarness {
  const _ChatHarness({
    required this.controller,
    required this.store,
    required this.imageService,
  });

  final AppController controller;
  final ImageGenerationStore store;
  final _ControlledImageService imageService;
}

class _ControlledImageService extends ImageGenerationService {
  final Completer<void> started = Completer<void>();
  final Completer<ImageGenerationResult> _result =
      Completer<ImageGenerationResult>();
  String? prompt;
  String? apiKey;

  @override
  Future<ImageGenerationResult> generate({
    required ImageGenerationConfig config,
    required String apiKey,
    required String prompt,
    String negativePrompt = '',
    ImageGenerationCancellationToken? cancellationToken,
    ImageGenerationProgressCallback? onProgress,
    Map<String, dynamic>? comfyWorkflow,
  }) {
    this.prompt = prompt;
    this.apiKey = apiKey;
    if (!started.isCompleted) started.complete();
    return _result.future;
  }

  void complete(ImageGenerationResult result) {
    if (!_result.isCompleted) _result.complete(result);
  }

  @override
  void close() {}
}

class _ControlledAiClient extends OpenAiCompatibleClient {
  _ControlledAiClient() {
    _stream = StreamController<String>(
      onListen: () {
        if (!listened.isCompleted) listened.complete();
      },
    );
  }

  late final StreamController<String> _stream;
  final Completer<void> listened = Completer<void>();

  void add(String delta) => _stream.add(delta);

  void finish() => unawaited(_stream.close());

  @override
  Future<String> complete({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, String>> messages,
    LlmProvider provider = LlmProvider.openAiCompatible,
    bool lightweight = false,
    bool fastPlanning = false,
    bool performancePlanning = false,
    int? maxCompletionTokens,
  }) async => '{"segments":[]}';

  @override
  Stream<String> streamChat({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String systemPrompt,
    required List<ChatMessage> messages,
    String? reasoningEffort,
    bool? thinkingEnabled,
    double? outputMultiplier,
    bool agentEnabled = false,
    String characterId = 'ryza',
    LlmProvider provider = LlmProvider.openAiCompatible,
  }) => _stream.stream;
}

class _FakeSecretStore extends SecretStore {
  const _FakeSecretStore();

  @override
  Future<String> readImageGenerationKey() async => 'optional-image-key';

  @override
  Future<String> readLlmKey(LlmProvider provider, {int openAiSlot = 0}) async =>
      'offline-test-key';
}

ImageGenerationResult _result() => ImageGenerationResult(
  bytes: _pngBytes,
  mimeType: 'image/png',
  protocol: ImageGenerationProtocol.comfyUi,
  model: 'offline-test',
);

final Uint8List _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
