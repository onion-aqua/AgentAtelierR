import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/chat_screen.dart';
import 'package:ryza_chat_mvp/src/local_skin_store.dart';
import 'package:ryza_chat_mvp/src/protected_character_assets.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_session.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_settings.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_ui_models.dart';
import 'package:ryza_chat_mvp/src/realtime_call/main_chat_voice_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <String>{
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers.global/events',
    'xyz.luan/audioplayers',
    'agent_atelier_r/companion_runtime',
    'agent_atelier_r/companion_runtime/events',
    'com.llfbandit.record/messages',
    'agent_atelier_r/realtime_pcm',
    'plugins.flutter.io/path_provider',
  };
  final recorderCalls = <String>[];
  final outputCalls = <String>[];
  late Directory fixtureDirectory;
  late _NetworkGuard network;
  HttpOverrides? previousHttpOverrides;
  const appearance = CharacterAppearance(
    id: 'voice_entry_test_static',
    label: 'Static voice test',
    description: '',
    promptDescription: '',
    assetName: 'voice_entry_test_skin',
    animated: false,
    hasPreview: false,
    idleAnimations: [],
  );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    fixtureDirectory = await Directory.systemTemp.createTemp('voice-entry-');
    await LocalSkinStore.instance.initialize(
      storageDirectory: fixtureDirectory,
    );
    final skin = await Directory(
      '${fixtureDirectory.path}/imported_skins/${appearance.assetName}',
    ).create(recursive: true);
    // The static test appearance never parses or paints this bundle. Register
    // local files so testing call controls does not require encrypted assets
    // or the native Spine library.
    for (final suffix in ['.atlas', '.skel', '_gesture.json', '.png']) {
      await File('${skin.path}/voice_entry_test_base$suffix').writeAsBytes([0]);
    }
    LocalSkinStore.instance.skins.add({
      'id': appearance.assetName,
      'base': 'voice_entry_test_base',
      'label': appearance.label,
    });
    characterAppearances.add(appearance);

    for (final channel in channels.toList()) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => fixtureDirectory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final channel = 'xyz.luan/audioplayers/events/$id';
          channels.add(channel);
          messenger.setMockMethodCallHandler(
            MethodChannel(channel),
            (_) async => null,
          );
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async {
        recorderCalls.add(call.method);
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('agent_atelier_r/realtime_pcm'),
      (call) async {
        outputCalls.add(call.method);
        return null;
      },
    );
    await AudioPlayer.global.ensureInitialized();
  });

  setUp(() {
    recorderCalls.clear();
    outputCalls.clear();
    previousHttpOverrides = HttpOverrides.current;
    network = _NetworkGuard();
    HttpOverrides.global = network;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    HttpOverrides.global = previousHttpOverrides;
  });

  tearDownAll(() async {
    characterAppearances.remove(appearance);
    LocalSkinStore.instance.skins.removeWhere(
      (skin) => skin['id'] == appearance.assetName,
    );
    ProtectedCharacterAssets.clearCache();
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), null);
    }
    await fixtureDirectory.delete(recursive: true);
  });

  Future<AppController> mount(
    WidgetTester tester, {
    String character = 'ryza',
  }) async {
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': character,
      'selected_character_appearance': appearance.id,
      'ai_enabled': false,
      'fish_tts_enabled': false,
      'show_microphone_button': true,
    });
    final controller = await AppController.load();
    controller.setCharacterAppearance(appearance.id);
    controller.setShowMicrophoneButton(true);
    if (character == 'ryza') {
      await tester.runAsync(
        () => ProtectedCharacterAssets.bundleFor(appearance.assetName),
      );
    }
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      controller.dispose();
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
            sceneBackground: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  Finder startButton() => find.byKey(const ValueKey('main-chat-voice-start'));

  void expectNoCaptureOrNetwork() {
    expect(recorderCalls, isEmpty);
    expect(outputCalls.where((method) => method == 'start'), isEmpty);
    expect(network.requests, 0);
  }

  testWidgets('Android Ryza microphone follows its existing setting', (
    tester,
  ) async {
    final controller = await mount(tester);
    expect(startButton(), findsOneWidget);

    controller.setShowMicrophoneButton(false);
    await tester.pump();
    expect(startButton(), findsNothing);

    controller.setShowMicrophoneButton(true);
    await tester.pump();
    expect(startButton(), findsOneWidget);
    expectNoCaptureOrNetwork();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  for (final (platform, character) in [
    (TargetPlatform.windows, 'ryza'),
    (TargetPlatform.android, 'sophie'),
  ]) {
    testWidgets('voice entry stays hidden for $platform $character', (
      tester,
    ) async {
      await mount(tester, character: character);
      expect(startButton(), findsNothing);
      expect(find.byType(MainChatVoicePanel), findsNothing);
      expectNoCaptureOrNetwork();
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }

  testWidgets(
    'missing local recognition files fail before acquiring microphone',
    (tester) async {
      final controller = await mount(tester);
      controller.configureAi(
        enabled: true,
        baseUrl: 'https://voice-test.invalid/v1',
        model: 'offline-config-validation',
      );
      await tester.pump();
      await tester.tap(startButton());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final panel = tester.widget<MainChatVoicePanel>(
        find.byType(MainChatVoicePanel),
      );
      expect(panel.controller.snapshot.phase, CallUiPhase.failed);
      expect(find.text('请先导入有效的 SenseVoice 模型 文件。'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 550));
      expect(
        find.byKey(const ValueKey('main-chat-voice-settings')).hitTestable(),
        findsOneWidget,
      );
      final close = find.byKey(const ValueKey('main-chat-voice-close'));
      expect(close.hitTestable(), findsOneWidget);
      await tester.tap(close);
      await tester.pump();
      expect(find.byType(MainChatVoicePanel), findsNothing);
      expectNoCaptureOrNetwork();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'default voice panel keeps recovery actions reachable while selecting messages',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      // Preserve the real start callback to represent a call starting while
      // the collection state is already open, such as an incoming invitation.
      final start = tester.widget<IconButton>(startButton()).onPressed!;
      await tester.tap(find.byTooltip('多选收藏文字或语音'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(find.byTooltip('保存收藏（未选择则退出）'), findsOneWidget);
      ScaffoldMessenger.of(tester.element(find.byType(ChatScreen)))
          .removeCurrentSnackBar();

      start();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pump();
      final panel = find.byKey(const ValueKey('main-chat-voice-panel'));
      final settings = find.byKey(const ValueKey('main-chat-voice-settings'));
      final close = find.byKey(const ValueKey('main-chat-voice-close'));
      expect(tester.getSize(panel).height.isFinite, isTrue);
      expect(tester.getSize(panel).height, greaterThan(90));
      expect(settings.hitTestable(), findsOneWidget);
      expect(close.hitTestable(), findsOneWidget);
      expect(tester.getRect(close).bottom, lessThanOrEqualTo(1000));

      await tester.tap(settings);
      await tester.pumpAndSettle();
      expect(find.byType(RealtimeCallSettingsPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(close.hitTestable(), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byType(MainChatVoicePanel), findsNothing);
      expect(find.byTooltip('保存收藏（未选择则退出）'), findsOneWidget);
      expectNoCaptureOrNetwork();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'missing call configuration exposes recovery and preserves drafts',
    (tester) async {
      final controller = await mount(tester);
      controller.setSplitNarrationComposer(true);
      await tester.pump();
      const drafts = ['开场旁白草稿', '还没有发送的台词', '结尾旁白草稿'];
      for (var index = 0; index < drafts.length; index++) {
        await tester.enterText(
          find.byKey(ValueKey('narration-input-$index')),
          drafts[index],
        );
      }
      final messages = controller.messages.toList();

      await tester.tap(startButton());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final panel = tester.widget<MainChatVoicePanel>(
        find.byType(MainChatVoicePanel),
      );
      expect(panel.controller, isA<RealtimeCallController>());
      expect(panel.controller.snapshot.phase, CallUiPhase.failed);
      expect(find.text('通话未能开始'), findsOneWidget);
      expect(find.text('请先在 AI 接口中配置并启用主 LLM。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('main-chat-voice-settings')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('main-chat-voice-close')),
        findsOneWidget,
      );
      expectNoCaptureOrNetwork();
      expect(controller.messages, messages);

      await tester.pump(const Duration(milliseconds: 550));
      expect(
        find.byKey(const ValueKey('main-chat-voice-settings')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('main-chat-voice-close')).hitTestable(),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('main-chat-voice-settings')));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(RealtimeCallSettingsPage), findsOneWidget);
      await tester.pageBack();
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('main-chat-voice-close')));
      await tester.pump();

      expect(find.byType(MainChatVoicePanel), findsNothing);
      expect(controller.splitNarrationComposer, isTrue);
      for (var index = 0; index < drafts.length; index++) {
        final field = tester.widget<TextField>(
          find.byKey(ValueKey('narration-input-$index')),
        );
        expect(field.controller!.text, drafts[index]);
      }
      expect(controller.messages, messages);
      expectNoCaptureOrNetwork();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('main response and continuous ASMR disable starting voice chat', (
    tester,
  ) async {
    final controller = await mount(tester);
    controller.setContinuousAsmr(true);
    await tester.pump();
    expect(tester.widget<IconButton>(startButton()).onPressed, isNull);
    await tester.tap(startButton());
    await tester.pump();
    expect(find.byType(MainChatVoicePanel), findsNothing);

    controller.setContinuousAsmr(false);
    await tester.pump();
    expect(tester.widget<IconButton>(startButton()).onPressed, isNotNull);
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '和莱莎说点什么…',
      ),
      '你好',
    );
    await tester.tap(find.byKey(const ValueKey('chat-send-button')));
    await tester.pump();
    expect(tester.widget<IconButton>(startButton()).onPressed, isNull);
    await tester.tap(startButton());
    await tester.pump();
    expect(find.byType(MainChatVoicePanel), findsNothing);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(tester.widget<IconButton>(startButton()).onPressed, isNotNull);
    expectNoCaptureOrNetwork();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}

class _NetworkGuard extends HttpOverrides {
  int requests = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _ObservedHttpClient(() => requests++);
}

class _ObservedHttpClient implements HttpClient {
  _ObservedHttpClient(this.onRequest);
  final VoidCallback onRequest;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    onRequest();
    throw StateError(
      'Voice entry without complete configuration must stay offline',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter || invocation.memberName == #close) return null;
    onRequest();
    throw StateError('Unexpected network operation: ${invocation.memberName}');
  }
}
