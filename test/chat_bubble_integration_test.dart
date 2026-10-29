import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/chat_bubble.dart';
import 'package:ryza_chat_mvp/src/chat_glass_surface.dart';
import 'package:ryza_chat_mvp/src/chat_message_edge_transition.dart';
import 'package:ryza_chat_mvp/src/chat_screen.dart';
import 'package:ryza_chat_mvp/src/conversation_collection_store.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/image_generation_store.dart';
import 'package:ryza_chat_mvp/src/narration_composer_fields.dart';
import 'package:ryza_chat_mvp/src/story_clock.dart';
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
    'plugins.flutter.io/path_provider',
  };
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('chat-bubble-integration-');
    for (final name in channels) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
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
    await AudioPlayer.global.ensureInitialized();
  });

  tearDownAll(() async {
    for (final name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets('bubbles pair original and translation and center narration', (
    tester,
  ) async {
    final controller = await _mountChat(tester, root);
    controller.configureLanguages(
      interface: AppLanguage.chinese,
      narrator: AppLanguage.chinese,
      characterReply: AppLanguage.japanese,
      translation: TranslationLanguage.chinese,
    );
    controller.addUserMessage('早上好');
    controller.addAssistantMessage('旁白：树叶轻轻摇晃。\n苏菲：こんにちは。\n译文：你好。');
    final source = controller.messages.last.text;
    await _expandConversation(tester);
    expect(find.byType(ChatBubble), findsNWidgets(2));
    final narration = tester.widget<Text>(find.text('树叶轻轻摇晃。'));
    expect(narration.textAlign, TextAlign.center);
    final bubble = find.byWidgetPredicate(
      (widget) => widget is ChatBubble && !widget.isUser,
    );
    expect(
      find.descendant(of: bubble, matching: find.text('こんにちは。')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bubble, matching: find.text('你好。')),
      findsOneWidget,
    );
    final divider = find.descendant(of: bubble, matching: find.byType(Divider));
    expect(divider, findsOneWidget);
    expect(tester.widget<Divider>(divider).color!.a, closeTo(.30, .001));

    controller.setTranslationOnly(true);
    await tester.pump();
    expect(find.text('こんにちは。'), findsNothing);
    expect(find.text('你好。'), findsOneWidget);
    expect(
      find.descendant(of: bubble, matching: find.byType(Divider)),
      findsNothing,
    );
    expect(controller.messages.last.text, source);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bubble undo restores state and clock and refills the composer', (
    tester,
  ) async {
    final controller = await _mountChat(tester, root);
    controller.setStoryClockEnabled(true);
    controller.storyClock = StoryClock(totalMinutes: 1435, satiety: 8);
    controller.sceneTime = SceneTime.night;
    final before = jsonDecode(jsonEncode(controller.characterState.toJson()));
    final id = controller.addUserMessage('我们先休息一会儿');
    final revision = controller.dataRevision;
    const proposal = {
      'state_delta': {'mood': 5, 'energy': -5},
      'emotion': 'happy',
      'reason': '休息片刻',
      'time_advance': {'kind': 'rest', 'minutes': 60},
    };
    controller.settleCharacterState(id, proposal, revision);
    controller.settleStoryTime(id, proposal, revision);
    controller.addAssistantMessage('苏菲：好呀，休息一会儿。');
    await _expandConversation(tester);
    expect(find.byTooltip('回退上一轮对话、状态与时间'), findsNothing);
    expect(find.byTooltip('点击重播语音，长按重新生成'), findsNothing);
    expect(find.byTooltip('多选收藏文字或语音'), findsNothing);
    await _openAssistantMenu(tester);
    for (final action in ['undo', 'replay', 'regenerate', 'select']) {
      expect(
        find.byKey(ValueKey('chat-message-action-$action')),
        findsOneWidget,
      );
    }
    await tester.tap(find.byKey(const ValueKey('chat-message-action-undo')));
    await tester.pumpAndSettle();
    expect(controller.characterState.toJson(), before);
    expect(controller.storyClock.totalMinutes, 1435);
    expect(controller.storyClock.satiety, 8);
    expect(controller.sceneTime, SceneTime.night);
    expect(controller.messages.any((message) => message.id == id), isFalse);
    expect(
      tester.widget<TextField>(_ordinaryInput()).controller!.text,
      '我们先休息一会儿',
    );
    expect(controller.settleStoryTime(id, proposal, revision), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bubble selection can cancel and save the chosen message', (
    tester,
  ) async {
    final controller = await _mountChat(tester, root);
    controller.addUserMessage('留下这一句');
    controller.addAssistantMessage('苏菲：把这段温柔的话收藏起来吧。');
    await _expandConversation(tester);
    await _openAssistantMenu(tester);
    await tester.tap(find.byKey(const ValueKey('chat-message-action-select')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('chat-bubble-selection-bar'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey('chat-bubble-selection-cancel')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('chat-bubble-selection-bar')),
      findsNothing,
    );

    await _openAssistantMenu(tester);
    await tester.tap(find.byKey(const ValueKey('chat-message-action-select')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('chat-bubble-selection-bar'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('chat-bubble-selection-save')));
    await _pumpUntil(tester, () => find.text('收藏名称').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextFormField), '气泡收藏测试');
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('chat-bubble-selection-bar'))
          .evaluate()
          .isEmpty,
    );
    final store = await tester.runAsync(
      () => ConversationCollectionStore.open(characterId: 'sophie'),
    );
    final cards = await tester.runAsync(store!.cards);
    final card = cards!.singleWhere((card) => card['name'] == '气泡收藏测试');
    final item = (card['items'] as List).single as Map;
    expect(item['text'], contains('把这段温柔的话收藏起来吧。'));
    expect(item['isUser'], isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plus menu carries reply actions in ordinary and split inputs', (
    tester,
  ) async {
    final controller = await _mountChat(tester, root);
    controller.addUserMessage('你好');
    controller.addAssistantMessage('苏菲：下午好！');
    await tester.pumpAndSettle();
    for (final split in [false, true]) {
      controller.setSplitNarrationComposer(split);
      await tester.pumpAndSettle();
      final plus = find.byTooltip('添加附件');
      expect(plus, findsOneWidget);
      await tester.tap(plus);
      await tester.pumpAndSettle();
      expect(find.textContaining('生成建议回复'), findsOneWidget);
      expect(find.textContaining('继续对话'), findsOneWidget);
      expect(find.text('拍照'), findsOneWidget);
      expect(find.text('图片'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);
      await tester.tapAt(const Offset(10, 200));
      await tester.pumpAndSettle();
      if (split) {
        expect(find.byKey(const ValueKey('narration-input-0')), findsOneWidget);
        expect(find.byKey(const ValueKey('narration-input-1')), findsOneWidget);
        expect(find.byKey(const ValueKey('narration-input-2')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('light bubble split composer keeps dark readable input text', (
    tester,
  ) async {
    final controller = await _mountChat(tester, root, theme: ThemeData.light());
    controller.setSplitNarrationComposer(true);
    await tester.pumpAndSettle();
    final fields = tester.widget<NarrationComposerFields>(
      find.byType(NarrationComposerFields),
    );
    expect(fields.foregroundColor, isNot(Colors.white));
    expect(fields.foregroundColor.computeLuminance(), lessThan(.15));
    for (var index = 0; index < 3; index++) {
      final input = tester.widget<TextField>(
        find.byKey(ValueKey('narration-input-$index')),
      );
      expect(input.style!.color, isNot(Colors.white));
      expect(input.style!.color!.computeLuminance(), lessThan(.15));
      expect(input.decoration!.hintStyle!.color, isNot(Colors.white));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'bubble panel starts below fullscreen height and meets screen edges',
    (tester) async {
      final controller = await _mountChat(tester, root);
      controller.addAssistantMessage('苏菲：默认高度保留更多对话空间。');
      await tester.pumpAndSettle();
      final panel = tester.getRect(find.byType(ChatConversationBackdrop));
      expect(panel.left, 0);
      expect(panel.right, 430);
      expect(panel.bottom, 1000);
      expect(panel.height, closeTo(650, 1));
      expect(find.byTooltip('全屏对话'), findsNothing);
      final initialText = controller.messages.last.text;
      controller.setChatBubbleStyle(false);
      await tester.pumpAndSettle();
      controller.setChatBubbleStyle(true);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(ChatConversationBackdrop)).height,
        closeTo(650, 1),
      );
      expect(controller.messages.last.text, initialText);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('plus stays inside the right side of ordinary and split input', (
    tester,
  ) async {
    final controller = await _mountChat(tester, root);
    for (final split in [false, true]) {
      controller.setSplitNarrationComposer(split);
      await tester.pumpAndSettle();
      final plus = find.byTooltip('添加附件');
      final input = split
          ? find.byKey(const ValueKey('narration-input-1'))
          : _ordinaryInput();
      final plusRect = tester.getRect(plus);
      final inputRect = tester.getRect(input);
      final sendRect = tester.getRect(
        find.byKey(const ValueKey('chat-send-button')),
      );
      expect(plusRect.center.dx, greaterThan(inputRect.center.dx));
      expect(plusRect.right, lessThan(sendRect.left));
      expect(plusRect.left, greaterThan(inputRect.left));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'right edge bubble height handle remains draggable and lockable',
    (tester) async {
      final controller = await _mountChat(tester, root);
      controller.addAssistantMessage('苏菲：可以在右上角调整对话框高度。');
      await tester.pumpAndSettle();
      final handle = find.byKey(const ValueKey('chat-panel-resize-handle'));
      final backdrop = find.byType(ChatConversationBackdrop);
      var panel = tester.getRect(backdrop);
      var handleRect = tester.getRect(handle);
      expect(handleRect.right, closeTo(panel.right - 12, .01));
      expect(handleRect.top, closeTo(panel.top, .01));
      expect(handle.hitTestable(), findsOneWidget);

      await tester.drag(handle, const Offset(0, 600));
      await tester.pumpAndSettle();
      panel = tester.getRect(backdrop);
      expect(panel.height, closeTo(220, 1));
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('chat-panel-resize-opacity')),
            )
            .opacity,
        closeTo(.10, .001),
      );
      expect(tester.getRect(handle).right, closeTo(panel.right - 12, .01));

      await tester.longPress(handle);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('高度已锁定，长按解锁'), findsOneWidget);
      final lockedHeight = tester.getSize(backdrop).height;
      await tester.drag(handle, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(tester.getSize(backdrop).height, lockedHeight);
      await tester.longPress(handle);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('拖动调整高度，长按锁定'), findsOneWidget);
      await tester.drag(handle, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(tester.getSize(backdrop).height, greaterThan(lockedHeight));
      expect(
        tester.getRect(handle).right,
        closeTo(tester.getRect(backdrop).right - 12, .01),
      );

      controller.setChatBubbleStyle(false);
      await tester.pumpAndSettle();
      final classicPanel = tester.getRect(
        find.byKey(const ValueKey('chat-conversation-panel')),
      );
      handleRect = tester.getRect(handle);
      expect(handleRect.right, closeTo(classicPanel.right - 12, .01));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('fullscreen control remains left of the right edge handle', (
    tester,
  ) async {
    final controller = await _mountChat(tester, root);
    controller.addAssistantMessage('苏菲：放大后仍能使用全屏按钮。');
    await tester.pumpAndSettle();
    final handle = find.byKey(const ValueKey('chat-panel-resize-handle'));
    await tester.drag(handle, const Offset(0, -100));
    await tester.pumpAndSettle();
    final fullscreen = find.byTooltip('全屏对话');
    expect(fullscreen.hitTestable(), findsOneWidget);
    final handleRect = tester.getRect(handle);
    final fullscreenRect = tester.getRect(fullscreen);
    expect(handleRect.left - fullscreenRect.right, closeTo(8, .01));
    expect(fullscreenRect.overlaps(handleRect), isFalse);
    expect(fullscreenRect.center.dy, closeTo(handleRect.center.dy, .01));
    await tester.tap(fullscreen);
    await tester.pumpAndSettle();
    final backdrop = tester.getRect(find.byType(ChatConversationBackdrop));
    expect(backdrop.top, 0);
    expect(backdrop.height, 1000);
    expect(tester.getRect(handle).right, closeTo(backdrop.right - 12, .01));
    final exitFullscreen = find.byTooltip('退出全屏对话');
    expect(exitFullscreen.hitTestable(), findsOneWidget);
    expect(
      tester.getRect(exitFullscreen).overlaps(tester.getRect(handle)),
      isFalse,
    );
    await tester.tap(exitFullscreen);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(ChatConversationBackdrop)).height,
      closeTo(680, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('soft top edge applies to messages without fading the composer', (
    tester,
  ) async {
    final controller = await _mountChat(tester, root);
    controller.addUserMessage('看看顶部过渡');
    controller.addAssistantMessage('苏菲：缩短窗口时，消息顶部会自然过渡。');
    await tester.pumpAndSettle();
    final transition = find.byType(ChatMessageEdgeTransition);
    expect(transition, findsOneWidget);
    expect(
      find.descendant(of: transition, matching: find.byType(ListView)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: transition, matching: find.byType(TextField)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: transition,
        matching: find.byKey(const ValueKey('chat-send-button')),
      ),
      findsNothing,
    );
    final transitionRect = tester.getRect(transition);
    expect(
      transitionRect.bottom,
      lessThanOrEqualTo(tester.getTopLeft(_ordinaryInput()).dy),
    );
    expect(
      find.byKey(const ValueKey('chat-send-button')).hitTestable(),
      findsOneWidget,
    );
    controller.setChatBubbleStyle(false);
    await tester.pumpAndSettle();
    expect(transition, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'bubbles composer and audio share the visible glass setting in both themes',
    (tester) async {
      final controller = await _mountChat(tester, root);
      controller.addUserMessage('玻璃样式测试');
      controller.addAssistantMessage('苏菲：气泡和输入框都跟随液态玻璃设置。');
      controller.setLiquidGlassChatUi(false);
      await tester.pumpAndSettle();
      await tester.enterText(_ordinaryInput(), '切换效果时保留输入草稿');

      for (final preference in [
        AppThemePreference.light,
        AppThemePreference.dark,
      ]) {
        controller.setThemePreference(preference);
        for (final enabled in [true, false]) {
          controller.setLiquidGlassChatUi(enabled);
          await tester.pumpAndSettle();
          final bubbles = tester.widgetList<ChatBubbleBackground>(
            find.byType(ChatBubbleBackground),
          );
          expect(bubbles, hasLength(2));
          expect(
            bubbles.every((bubble) => bubble.liquidGlass == enabled),
            isTrue,
          );
          final localGlass = [
            ...find
                .descendant(
                  of: find.byType(ChatBubbleBackground),
                  matching: find.byType(ChatGlassSurface),
                )
                .evaluate()
                .map((element) => find.byElementPredicate((e) => e == element)),
            find.byKey(const ValueKey('chat-bubble-composer-surface')),
            find.byKey(const ValueKey('chat-bubble-playback-surface')),
          ];
          expect(localGlass, hasLength(4));
          for (final surface in localGlass) {
            expect(surface, findsOneWidget);
            expect(
              tester.widget<ChatGlassSurface>(surface).liquidGlass,
              enabled,
            );
            final material = tester.widget<GlassSurface>(
              find.descendant(of: surface, matching: find.byType(GlassSurface)),
            );
            expect(material.liquidGlass, enabled);
            expect(
              material.fillOpacity,
              enabled ? lessThan(.75) : equals(1),
              reason: 'glass must expose the scene instead of an opaque card',
            );
            expect(
              tester
                  .widget<BackdropFilter>(
                    find
                        .descendant(
                          of: surface,
                          matching: find.byType(BackdropFilter),
                        )
                        .first,
                  )
                  .enabled,
              enabled,
            );
            expect(
              tester.getSize(surface).height,
              lessThan(
                tester.getSize(find.byType(ChatMessageEdgeTransition)).height,
              ),
              reason: 'glass effects are confined to local message controls',
            );
          }
          expect(
            tester
                .widget<GlassSurface>(
                  find.byKey(const ValueKey('chat-bubble-send-surface')),
                )
                .liquidGlass,
            enabled,
          );
          final list = find.descendant(
            of: find.byType(ChatMessageEdgeTransition),
            matching: find.byType(ListView),
          );
          expect(
            find.ancestor(of: list, matching: find.byType(GlassSurface)),
            findsNothing,
          );
          expect(
            tester.widget<TextField>(_ordinaryInput()).controller!.text,
            '切换效果时保留输入草稿',
          );
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  testWidgets('glass changes preserve the scrolled list and composer draft', (
    tester,
  ) async {
    final controller = await _mountChat(tester, root);
    for (var i = 0; i < 12; i++) {
      controller.addUserMessage('较长历史消息 $i');
      controller.addAssistantMessage('苏菲：为滚动验证保留的历史回复 $i。');
    }
    await tester.pumpAndSettle();
    final list = find.descendant(
      of: find.byType(ChatMessageEdgeTransition),
      matching: find.byType(ListView),
    );
    final listElement = tester.element(list);
    final scroll = tester.widget<ListView>(list).controller!;
    expect(scroll.position.maxScrollExtent, greaterThan(80));
    scroll.jumpTo(80);
    // The scroll-to-bottom affordance intentionally keeps animating.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(_ordinaryInput(), '玻璃切换前的草稿');
    await tester.pump(const Duration(milliseconds: 600));
    for (final enabled in [true, false, true]) {
      controller.setLiquidGlassChatUi(enabled);
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.element(list), same(listElement));
      expect(scroll.offset, closeTo(80, .01));
      expect(scroll.positions, hasLength(1));
      expect(
        tester.widget<TextField>(_ordinaryInput()).controller!.text,
        '玻璃切换前的草稿',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('real message bubbles share one backdrop input', (tester) async {
    final controller = await _mountChat(tester, root);
    controller.setLiquidGlassChatUi(true);
    controller.addUserMessage('共享背景采样测试');
    controller.addAssistantMessage('苏菲：原文保持清晰。');
    await _expandConversation(tester);
    final group = find.byType(ChatBubbleBackdropGroup);
    expect(group, findsOneWidget);
    final backdrop = tester.widget<BackdropGroup>(
      find.descendant(of: group, matching: find.byType(BackdropGroup)),
    );
    expect(backdrop.backdropKey, isNotNull);
    final bubbles = find.descendant(
      of: group,
      matching: find.byType(ChatBubbleBackground),
    );
    expect(bubbles, findsNWidgets(2));
    for (final element in bubbles.evaluate()) {
      final filter = tester.widget<BackdropFilter>(
        find.descendant(
          of: find.byWidget(element.widget),
          matching: find.byType(BackdropFilter),
        ),
      );
      expect(filter.enabled, isTrue);
      expect(filter.backdropGroupKey, same(backdrop.backdropKey));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'plain composer and audio controls follow accent and brightness',
    (tester) async {
      final controller = await _mountChat(tester, root);
      controller.setLiquidGlassChatUi(false);
      controller.addUserMessage('检查输入栏和播放条的主题颜色');
      controller.addAssistantMessage('苏菲：普通材质也跟随主题。');
      await tester.pumpAndSettle();
      await tester.enterText(_ordinaryInput(), '保留主题切换草稿');
      final backgrounds = <Color>[];
      for (final preference in [
        AppThemePreference.light,
        AppThemePreference.dark,
      ]) {
        controller.setThemePreference(preference);
        for (final accent in [AppAccentTheme.ocean, AppAccentTheme.rose]) {
          controller.setAccentTheme(accent);
          await tester.pumpAndSettle();
          final input = tester.widget<TextField>(_ordinaryInput());
          final colors = Theme.of(tester.element(_ordinaryInput())).colorScheme;
          expect(input.style!.color, colors.onSurface);
          expect(input.cursorColor, colors.onSurface);
          expect(
            input.decoration!.hintStyle!.color,
            colors.onSurface.withValues(alpha: .55),
          );
          expect(input.controller!.text, '保留主题切换草稿');
          for (final key in [
            'chat-bubble-composer-surface',
            'chat-bubble-playback-surface',
          ]) {
            final surface = tester.widget<ChatGlassSurface>(
              find.byKey(ValueKey(key)),
            );
            expect(
              surface.fallbackColor,
              colors.surfaceContainerHigh.withValues(alpha: .90),
            );
          }
          backgrounds.add(
            tester
                .widget<ChatGlassSurface>(
                  find.byKey(const ValueKey('chat-bubble-composer-surface')),
                )
                .fallbackColor,
          );
          final playback = find.byKey(
            const ValueKey('chat-bubble-playback-surface'),
          );
          final slider = find.descendant(
            of: playback,
            matching: find.byType(Slider),
          );
          final sliderTheme = SliderTheme.of(tester.element(slider));
          expect(sliderTheme.activeTrackColor, colors.primary);
          expect(sliderTheme.thumbColor, colors.primary);
          expect(
            sliderTheme.inactiveTrackColor,
            colors.primary.withValues(alpha: .18),
          );
          expect(
            sliderTheme.disabledThumbColor,
            colors.onSurface.withValues(alpha: .38),
          );
          expect(
            DefaultTextStyle.of(tester.element(find.text('0:00 / 0:00')))
                .style
                .color,
            colors.onSurface,
          );
          final audioIcon = find.descendant(
            of: playback,
            matching: find.byIcon(Icons.graphic_eq),
          );
          expect(
            IconTheme.of(tester.element(audioIcon)).color,
            colors.onSurface,
          );
          final plus = find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == '添加附件',
          );
          expect(tester.widget<IconButton>(plus).color, colors.onSurface);
          expect(
            tester.getCenter(plus).dx,
            greaterThan(tester.getCenter(_ordinaryInput()).dx),
          );
          final send = tester.widget<IconButton>(
            find.byKey(const ValueKey('chat-send-button')),
          );
          expect(send.style!.foregroundColor!.resolve({}), colors.onPrimary);
          expect(tester.takeException(), isNull);
        }
      }
      expect(backgrounds.toSet(), hasLength(4));
    },
  );

  testWidgets(
    'split composer shares theme text colors and glass keeps its style',
    (tester) async {
      final controller = await _mountChat(tester, root);
      controller.setSplitNarrationComposer(true);
      for (final preference in [
        AppThemePreference.light,
        AppThemePreference.dark,
      ]) {
        controller.setThemePreference(preference);
        controller.setAccentTheme(AppAccentTheme.lavender);
        for (final enabled in [false, true, false]) {
          controller.setLiquidGlassChatUi(enabled);
          await tester.pumpAndSettle();
          final fieldsFinder = find.byType(NarrationComposerFields);
          final fields = tester.widget<NarrationComposerFields>(fieldsFinder);
          final theme = Theme.of(tester.element(fieldsFinder));
          final foreground = enabled
              ? (theme.brightness == Brightness.dark
                    ? Colors.white
                    : const Color(0xFF203830))
              : theme.colorScheme.onSurface;
          expect(fields.foregroundColor, foreground);
          for (var index = 0; index < 3; index++) {
            final input = tester.widget<TextField>(
              find.byKey(ValueKey('narration-input-$index')),
            );
            expect(
              input.style!.color,
              index == 1 ? foreground : foreground.withValues(alpha: .7),
            );
            expect(
              input.decoration!.hintStyle!.color,
              foreground.withValues(alpha: .6),
            );
          }
          expect(
            tester
                .widget<IconButton>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is IconButton && widget.tooltip == '添加附件',
                  ),
                )
                .color,
            foreground,
          );
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  testWidgets(
    'theme settings update bubbles and dialogue preferences without panel fill',
    (tester) async {
      final controller = await _mountChat(tester, root);
      controller.addUserMessage('主题切换测试');
      controller.addAssistantMessage('苏菲：明暗主题都会跟随设置。');
      controller.setThemePreference(AppThemePreference.light);
      await tester.pumpAndSettle();

      final assistant = find.byWidgetPredicate(
        (widget) => widget is ChatBubble && !widget.isUser,
      );
      final bubble = tester.widget<ChatBubble>(assistant);
      final bubbleContent = find.byKey(
        ValueKey('chat-bubble-content-${bubble.messageKey}'),
      );
      Color bubbleColor() => tester
          .widget<ChatBubbleBackground>(
            find
                .ancestor(
                  of: bubbleContent,
                  matching: find.byType(ChatBubbleBackground),
                )
                .first,
          )
          .color;
      final lightBubble = bubbleColor();
      expect(Theme.of(tester.element(assistant)).brightness, Brightness.light);
      final list = find.descendant(
        of: find.byType(ChatMessageEdgeTransition),
        matching: find.byType(ListView),
      );
      expect(
        find.ancestor(of: list, matching: find.byType(GlassSurface)),
        findsNothing,
      );

      controller.setThemePreference(AppThemePreference.dark);
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(assistant)).brightness, Brightness.dark);
      expect(bubbleColor(), isNot(lightBubble));
      expect(
        bubbleColor().computeLuminance(),
        lessThan(lightBubble.computeLuminance()),
      );

      controller.setAccentTheme(AppAccentTheme.rose);
      controller.setTextColorTheme(AppAccentTheme.ocean);
      controller.setDialogueFontScale(1.25);
      await tester.pumpAndSettle();
      final theme = Theme.of(tester.element(assistant));
      expect(bubbleColor(), theme.colorScheme.surfaceContainerHigh);
      expect(
        theme.colorScheme.primary,
        atelierTheme(AppAccentTheme.rose, Brightness.dark).colorScheme.primary,
      );
      final appearance = theme.extension<DialogueAppearance>()!;
      expect(appearance.fontScale, 1.25);
      expect(appearance.textColor, isNotNull);
      expect(
        tester.widget<ChatBubble>(assistant).textStyle!.color,
        appearance.textColor,
      );

      controller.setThemePreference(AppThemePreference.light);
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(assistant)).brightness, Brightness.light);
      expect(bubbleColor().computeLuminance(), greaterThan(.5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'open plus menu closes when viewport or keyboard metrics change',
    (tester) async {
      final controller = await _mountChat(tester, root);
      controller.addUserMessage('你好');
      controller.addAssistantMessage('苏菲：菜单会跟随界面调整。');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('添加附件'));
      await tester.pumpAndSettle();
      expect(find.text('图片'), findsOneWidget);
      expect(find.textContaining('生成建议回复'), findsOneWidget);

      tester.view.physicalSize = const Size(240, 1000);
      await tester.pumpAndSettle();
      expect(find.text('图片'), findsNothing);
      expect(find.byTooltip('收起附件菜单'), findsNothing);
      expect(find.byTooltip('添加附件'), findsOneWidget);

      await tester.tap(find.byTooltip('添加附件'));
      await tester.pumpAndSettle();
      expect(find.text('图片'), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(find.text('图片'), findsNothing);
      expect(find.byTooltip('收起附件菜单'), findsNothing);
      expect(find.byTooltip('添加附件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [240.0, 320.0]) {
    testWidgets('five plus menu items fit ${width.toInt()}px with keyboard', (
      tester,
    ) async {
      final controller = await _mountChat(
        tester,
        root,
        size: Size(width, 1000),
      );
      controller.addUserMessage('你好');
      controller.addAssistantMessage('苏菲：下午好！');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      for (final split in [false, true]) {
        controller.setSplitNarrationComposer(split);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('添加附件'));
        await tester.pumpAndSettle();
        final items = [
          find.text('拍照'),
          find.text('图片'),
          find.text('文件'),
          find.textContaining('生成建议回复'),
          find.textContaining('继续对话'),
        ];
        for (final itemText in items) {
          expect(itemText, findsOneWidget);
          final item = find
              .ancestor(of: itemText, matching: find.byType(InkWell))
              .first;
          final rect = tester.getRect(item);
          expect(rect.left, greaterThanOrEqualTo(0), reason: '$width, $split');
          expect(
            rect.right,
            lessThanOrEqualTo(width),
            reason: '$width, $split',
          );
          expect(rect.top, greaterThanOrEqualTo(0), reason: '$width, $split');
          expect(rect.bottom, lessThanOrEqualTo(700), reason: '$width, $split');
          expect(item.hitTestable(), findsOneWidget, reason: '$width, $split');
        }
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('收起附件菜单'));
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets(
    'disabling bubble style restores the classic conversation tools',
    (tester) async {
      final controller = await _mountChat(tester, root);
      controller.addUserMessage('你好');
      controller.addAssistantMessage('苏菲：你好呀！');
      await _expandConversation(tester);
      expect(find.byType(ChatBubble), findsNWidgets(2));
      controller.setChatBubbleStyle(false);
      await tester.pumpAndSettle();
      expect(find.byType(ChatBubble), findsNothing);
      expect(find.byTooltip('回退上一轮对话、状态与时间'), findsOneWidget);
      expect(find.byTooltip('点击重播语音，长按重新生成'), findsOneWidget);
      expect(find.byTooltip('多选收藏文字或语音'), findsOneWidget);
      expect(controller.messages.last.text, '苏菲：你好呀！');
      expect(tester.takeException(), isNull);
    },
  );
}

Future<AppController> _mountChat(
  WidgetTester tester,
  Directory root, {
  Size size = const Size(430, 1000),
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  SharedPreferences.setMockInitialValues({
    'active_character_id_v1': 'sophie',
    'ai_enabled': false,
    'fish_tts_enabled': false,
  });
  final controller = (await tester.runAsync(AppController.load))!;
  controller.setChatBubbleStyle(true);
  controller.configureLanguages(
    interface: AppLanguage.chinese,
    narrator: AppLanguage.chinese,
    characterReply: AppLanguage.chinese,
    translation: TranslationLanguage.none,
  );
  controller.messages.clear();
  final store = ImageGenerationStore(directoryProvider: () async => root);
  await tester.runAsync(store.load);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    store.dispose();
    controller.dispose();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });
  await tester.pumpWidget(
    AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        theme:
            theme ??
            withDialogueAppearance(
              atelierTheme(controller.accentTheme, Brightness.light),
              controller.textColorTheme,
              controller.translationOnly &&
                  controller.translationLanguage.name != 'none',
              controller.dialogueFontScale,
              controller.textColorChoice,
            ),
        darkTheme: theme == null
            ? withDialogueAppearance(
                atelierTheme(controller.accentTheme, Brightness.dark),
                controller.textColorTheme,
                controller.translationOnly &&
                    controller.translationLanguage.name != 'none',
                controller.dialogueFontScale,
                controller.textColorChoice,
              )
            : null,
        themeMode: theme == null
            ? switch (controller.themePreference) {
                AppThemePreference.system => ThemeMode.system,
                AppThemePreference.light => ThemeMode.light,
                AppThemePreference.dark => ThemeMode.dark,
              }
            : ThemeMode.light,
        home: ChatScreen(
          controller: controller,
          onMenuPressed: () {},
          onShopPressed: () {},
          hideUi: false,
          imageGenerationStore: store,
          secretStore: const _NoNetworkSecretStore(),
          imageThumbnailer: (_) async => null,
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

Future<void> _expandConversation(WidgetTester tester) async {
  await tester.pump();
  final handle = find.bySemanticsLabel('拖动调整高度，长按锁定');
  await tester.drag(handle, const Offset(0, -600));
  await tester.pumpAndSettle();
}

Future<void> _openAssistantMenu(WidgetTester tester) async {
  final assistant = find
      .byWidgetPredicate((widget) => widget is ChatBubble && !widget.isUser)
      .last;
  final bubble = tester.widget<ChatBubble>(assistant);
  final target = find.byKey(
    ValueKey('chat-bubble-content-${bubble.messageKey}'),
  );
  await tester.ensureVisible(target);
  await tester.longPress(target);
  await tester.pumpAndSettle();
}

Finder _ordinaryInput() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      widget.decoration?.hintText?.contains('说点什么') == true,
);

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 60 && !condition(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
  expect(condition(), isTrue, reason: 'condition did not become true');
}

class _NoNetworkSecretStore extends SecretStore {
  const _NoNetworkSecretStore();

  @override
  Future<String> readLlmKey(LlmProvider provider, {int openAiSlot = 0}) async =>
      '';
}
