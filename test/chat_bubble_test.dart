import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/chat_bubble.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/liquid_glass_optics.dart';

Future<void> _mount(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: SizedBox(width: width, child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('bilingual bubble preserves both texts and subtle separator', (
    tester,
  ) async {
    await _mount(
      tester,
      const ChatBubble(
        messageKey: 'bilingual',
        isUser: false,
        originalText: '一緒に出発しよう！',
        translationText: '我们一起出发吧！',
      ),
    );
    expect(find.text('一緒に出発しよう！'), findsOneWidget);
    expect(find.text('我们一起出发吧！'), findsOneWidget);
    final divider = tester.widget<Divider>(find.byType(Divider));
    expect(divider.color!.a, closeTo(.30, .001));
  });

  testWidgets(
    'translation only hides source but falls back when untranslated',
    (tester) async {
      await _mount(
        tester,
        const ChatBubble(
          messageKey: 'translated',
          isUser: false,
          originalText: 'こんにちは',
          translationText: '你好',
          translationOnly: true,
        ),
      );
      expect(find.text('こんにちは'), findsNothing);
      expect(find.text('你好'), findsOneWidget);
      expect(find.byType(Divider), findsNothing);
      await _mount(
        tester,
        const ChatBubble(
          messageKey: 'fallback',
          isUser: false,
          originalText: '还没有译文',
          translationOnly: true,
        ),
      );
      expect(find.text('还没有译文'), findsOneWidget);
    },
  );

  testWidgets('long press reports the bubble position and does not tap', (
    tester,
  ) async {
    Offset? longPressPosition;
    var tapped = false;
    await _mount(
      tester,
      ChatBubble(
        messageKey: 'press',
        isUser: true,
        originalText: '按住打开菜单',
        onLongPressStart: (details) =>
            longPressPosition = details.globalPosition,
        onTap: () => tapped = true,
      ),
    );
    final target = find.text('按住打开菜单');
    final position = tester.getCenter(target);
    await tester.longPress(target);
    expect(longPressPosition, position);
    expect(tapped, isFalse);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'long bilingual content fits 240px in ${dark ? 'dark' : 'light'}',
      (tester) async {
        await _mount(
          tester,
          SingleChildScrollView(
            child: ChatBubble(
              messageKey: 'narrow',
              isUser: false,
              avatar: const CircleAvatar(child: Icon(Icons.person)),
              speakerLabel: '一个需要在小屏幕上换行的较长角色名字',
              originalText: 'A long uninterrupted source to wrap. ' * 8,
              translationText: '这是一条需要自动换行的较长翻译文本。' * 8,
            ),
          ),
          width: 240,
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        expect(tester.takeException(), isNull);
        final bubble = find.byKey(const ValueKey('chat-bubble-content-narrow'));
        expect(tester.getBottomRight(bubble).dx, lessThanOrEqualTo(240));
      },
    );
  }

  for (final isUser in [false, true]) {
    testWidgets(
      'avatar is outside the ${isUser ? 'right' : 'left'} name and bubble column',
      (tester) async {
        await _mount(
          tester,
          ChatBubble(
            messageKey: 'avatar-reference',
            isUser: isUser,
            speakerLabel: isUser ? '你' : '莱莎',
            avatar: const CircleAvatar(child: Icon(Icons.person)),
            originalText: '我们一起出发吧！',
          ),
        );
        final avatar = find.byKey(
          const ValueKey('chat-bubble-avatar-avatar-reference'),
        );
        final bubble = find.byKey(
          const ValueKey('chat-bubble-content-avatar-reference'),
        );
        final header = find.byKey(
          const ValueKey('chat-bubble-header-avatar-reference'),
        );
        final name = find.byKey(
          const ValueKey('chat-bubble-speaker-avatar-reference'),
        );
        final avatarRect = tester.getRect(avatar);
        final bubbleRect = tester.getRect(bubble);
        final headerRect = tester.getRect(header);
        expect(avatarRect.top, closeTo(headerRect.top, .01));
        expect(bubbleRect.top - headerRect.bottom, closeTo(6, .01));
        expect(bubbleRect.top, greaterThan(avatarRect.top));
        expect(
          isUser
              ? avatarRect.left - bubbleRect.right
              : bubbleRect.left - avatarRect.right,
          closeTo(10, .01),
        );
        expect(
          isUser ? headerRect.right : headerRect.left,
          closeTo(isUser ? bubbleRect.right : bubbleRect.left, .01),
        );
        expect(find.descendant(of: header, matching: avatar), findsNothing);
        expect(find.descendant(of: bubble, matching: name), findsNothing);
        expect(
          tester.widget<Text>(name).textAlign,
          isUser ? TextAlign.right : TextAlign.left,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'speaker stays above the ${isUser ? 'right' : 'left'} aligned bubble',
      (tester) async {
        await _mount(
          tester,
          ChatBubble(
            messageKey: 'header',
            isUser: isUser,
            speakerLabel: isUser ? '你' : '莱莎',
            originalText: '我们一起出发吧！',
          ),
        );
        final bubble = find.byKey(const ValueKey('chat-bubble-content-header'));
        final header = find.byKey(const ValueKey('chat-bubble-header-header'));
        final name = find.byKey(const ValueKey('chat-bubble-speaker-header'));
        expect(find.descendant(of: bubble, matching: name), findsNothing);
        final bubbleRect = tester.getRect(bubble);
        final headerRect = tester.getRect(header);
        expect(bubbleRect.top - headerRect.bottom, closeTo(6, .01));
        expect(
          isUser ? headerRect.right : headerRect.left,
          closeTo(isUser ? bubbleRect.right : bubbleRect.left, .01),
        );
        expect(
          tester.widget<Text>(name).textAlign,
          isUser ? TextAlign.right : TextAlign.left,
        );
      },
    );
  }

  testWidgets('bubble theme changes even with an explicit dialogue color', (
    tester,
  ) async {
    const bubble = ChatBubble(
      messageKey: 'theme',
      isUser: false,
      originalText: '主题切换应同步气泡。',
      textStyle: TextStyle(color: Colors.white),
    );
    Color background() {
      return tester
          .widget<ChatBubbleBackground>(
            find.ancestor(
              of: find.byKey(const ValueKey('chat-bubble-content-theme')),
              matching: find.byType(ChatBubbleBackground),
            ),
          )
          .color;
    }

    await _mount(tester, bubble);
    final light = background();
    await _mount(tester, bubble, brightness: Brightness.dark);
    final dark = background();
    expect(light, isNot(dark));
    expect(light.computeLuminance(), greaterThan(dark.computeLuminance()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('panel stays transparent and plain bubbles have no gradient', (
    tester,
  ) async {
    await _mount(
      tester,
      const ChatConversationBackdrop(
        child: ChatBubble(
          messageKey: 'gradient',
          isUser: true,
          originalText: '渐变只影响背景。',
        ),
      ),
    );
    final bubbleDecoration =
        tester
                .widget<Container>(
                  find.byKey(const ValueKey('chat-bubble-content-gradient')),
                )
                .decoration!
            as BoxDecoration;
    final shell = tester.widget<SizedBox>(
      find
          .descendant(
            of: find.byType(ChatConversationBackdrop),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect(shell.width, double.infinity);
    expect(shell.height, double.infinity);
    expect(bubbleDecoration.gradient, isNull);
    expect(bubbleDecoration.color, isNull);
    expect(find.byType(ChatBubbleBackground), findsOneWidget);
    for (final box in tester.widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(ChatConversationBackdrop),
        matching: find.byType(DecoratedBox),
      ),
    )) {
      expect((box.decoration as BoxDecoration).gradient, isNull);
    }
    expect(find.byType(Opacity), findsNothing);
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets(
    'liquid glass switch updates bubble optics without resetting content',
    (tester) async {
      var presses = 0;
      final bubble = ChatBubble(
        messageKey: 'glass',
        isUser: false,
        originalText: '气泡样式跟随液态玻璃开关。',
        onLongPressStart: (_) => presses++,
      );
      Future<void> setGlass(bool enabled) =>
          _mount(tester, GlassStyleScope(enabled: enabled, child: bubble));
      await setGlass(false);
      final content = find.byKey(const ValueKey('chat-bubble-content-glass'));
      final element = tester.element(content);
      expect(
        tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
        isFalse,
      );
      await setGlass(true);
      expect(tester.element(content), same(element));
      expect(
        tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
        isTrue,
      );
      expect(
        tester
            .widget<LiquidGlassOptics>(find.byType(LiquidGlassOptics))
            .blurSigma,
        10,
      );
      final gradients = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((box) => (box.decoration as BoxDecoration).gradient)
          .whereType<LinearGradient>();
      expect(gradients, hasLength(1));
      expect(gradients.single.colors.every((color) => color.a > 0), isTrue);
      await tester.longPress(find.text('气泡样式跟随液态玻璃开关。'));
      expect(presses, 1);
      await setGlass(false);
      expect(tester.element(content), same(element));
      expect(
        tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long speaker name and bilingual text fit with large text scale',
    (tester) async {
      await _mount(
        tester,
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: SingleChildScrollView(
            child: ChatBubble(
              messageKey: 'large-text',
              isUser: true,
              speakerLabel: '一个非常长的用户显示名称需要自动换行',
              avatar: const CircleAvatar(child: Icon(Icons.person)),
              originalText: 'A long source paragraph. ' * 4,
              translationText: '这一段译文也需要在窄屏中换行。' * 4,
            ),
          ),
        ),
        width: 240,
      );
      expect(tester.takeException(), isNull);
      final bubble = find.byKey(
        const ValueKey('chat-bubble-content-large-text'),
      );
      expect(tester.getBottomRight(bubble).dx, lessThanOrEqualTo(240));
    },
  );

  testWidgets('narration is centered and backdrop does not fade children', (
    tester,
  ) async {
    await _mount(
      tester,
      const ChatConversationBackdrop(child: ChatNarration(text: '阳光透过工房的窗户。')),
    );
    final text = tester.widget<Text>(find.text('阳光透过工房的窗户。'));
    expect(text.textAlign, TextAlign.center);
    expect(
      find.descendant(
        of: find.byType(ChatConversationBackdrop),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
    );
    expect(find.byType(Opacity), findsNothing);
    expect(find.byType(ShaderMask), findsNothing);
  });

  test('resize handle remains visible and increases with panel height', () {
    expect(resizeHandleOpacity(0), .10);
    expect(resizeHandleOpacity(.22), .10);
    expect(resizeHandleOpacity(.45), closeTo(.55, .001));
    expect(resizeHandleOpacity(.68), 1);
    expect(resizeHandleOpacity(1), 1);
    expect(resizeHandleOpacity(.22, fullscreen: true), 1);
    expect(resizeHandleOpacity(double.nan), .10);
  });
}
