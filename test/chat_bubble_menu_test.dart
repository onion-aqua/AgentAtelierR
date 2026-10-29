import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/chat_bubble_menu.dart';
import 'package:ryza_chat_mvp/src/chat_glass_surface.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';

const _actions = [
  ChatBubbleMenuAction(
    key: ValueKey('test-undo'),
    value: 'undo',
    icon: Icons.undo_rounded,
    label: '回退上一轮对话、状态与时间',
  ),
  ChatBubbleMenuAction(
    key: ValueKey('test-replay'),
    value: 'replay',
    icon: Icons.volume_up_outlined,
    label: '重播语音',
    enabled: false,
  ),
  ChatBubbleMenuAction(
    key: ValueKey('test-regenerate'),
    value: 'regenerate',
    icon: Icons.refresh_rounded,
    label: '重新生成语音',
  ),
  ChatBubbleMenuAction(
    key: ValueKey('test-select'),
    value: 'select',
    icon: Icons.checklist_rounded,
    label: '选择文字与语音',
  ),
];

Future<BuildContext> _mount(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  ValueNotifier<MediaQueryData>? media,
}) async {
  late BuildContext page;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: media == null
          ? null
          : (context, child) => ValueListenableBuilder<MediaQueryData>(
              valueListenable: media,
              builder: (_, data, _) => MediaQuery(data: data, child: child!),
            ),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            page = context;
            return const ColoredBox(
              color: Color(0xFFB8E0C8),
              child: SizedBox.expand(),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return page;
}

Future<void> _open(
  WidgetTester tester,
  BuildContext context, {
  Offset position = const Offset(400, 300),
  bool glass = true,
  ValueChanged<String?>? selected,
}) async {
  showChatBubbleMenu<String>(
    context: context,
    position: position,
    liquidGlass: glass,
    actions: _actions,
  ).then((value) => selected?.call(value));
  await tester.pumpAndSettle();
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name} menu shares a single bounded glass surface',
      (tester) async {
        final page = await _mount(tester, brightness: brightness);
        await _open(tester, page);
        final menu = find.byKey(const ValueKey('chat-message-glass-menu'));
        final surface = tester.widget<ChatGlassSurface>(menu);
        expect(surface.variant, ChatGlassVariant.menu);
        expect(surface.liquidGlass, isTrue);
        final filters = find.descendant(
          of: menu,
          matching: find.byType(BackdropFilter),
        );
        expect(filters, findsOneWidget);
        expect(tester.getSize(filters).width, lessThanOrEqualTo(316));
        expect(tester.getSize(filters).height, lessThan(400));
        final barriers = tester.widgetList<ModalBarrier>(
          find.byType(ModalBarrier),
        );
        expect(
          barriers.any(
            (barrier) =>
                barrier.dismissible &&
                (barrier.color == null || barrier.color!.a == 0),
          ),
          isTrue,
        );
        expect(find.byType(InkWell), findsNWidgets(4));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'disabled actions cannot close menu; enabled action returns once',
    (tester) async {
      final page = await _mount(tester);
      final results = <String?>[];
      await _open(tester, page, selected: results.add);
      final disabled = tester.widget<InkWell>(
        find.byKey(const ValueKey('test-replay')),
      );
      expect(disabled.onTap, isNull);
      await tester.tap(find.byKey(const ValueKey('test-replay')));
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(
        find.byKey(const ValueKey('chat-message-glass-menu')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('test-select')));
      await tester.pumpAndSettle();
      expect(results, ['select']);
      expect(
        find.byKey(const ValueKey('chat-message-glass-menu')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('outside tap and back dismiss without a selected action', (
    tester,
  ) async {
    final page = await _mount(tester);
    final results = <String?>[];
    await _open(tester, page, selected: results.add);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(results, [null]);
    await _open(tester, page, glass: false, selected: results.add);
    expect(
      tester
          .widget<ChatGlassSurface>(
            find.byKey(const ValueKey('chat-message-glass-menu')),
          )
          .liquidGlass,
      isFalse,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(results, [null, null]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion opens the menu without a scale animation', (
    tester,
  ) async {
    final media = ValueNotifier(const MediaQueryData(disableAnimations: true));
    addTearDown(media.dispose);
    final page = await _mount(tester, media: media);
    showChatBubbleMenu<String>(
      context: page,
      position: const Offset(400, 300),
      liquidGlass: true,
      actions: _actions,
    );
    await tester.pump();
    final menu = find.byKey(const ValueKey('chat-message-glass-menu'));
    final scale = tester.widget<ScaleTransition>(
      find.ancestor(of: menu, matching: find.byType(ScaleTransition)).first,
    );
    expect(scale.scale.value, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('open menu follows the inherited global glass switch', (
    tester,
  ) async {
    final enabled = ValueNotifier(false);
    addTearDown(enabled.dispose);
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (_, value, _) =>
              GlassStyleScope(enabled: value, child: child!),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              page = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    await _open(tester, page);
    final menu = find.byKey(const ValueKey('chat-message-glass-menu'));
    final filter = find.descendant(
      of: menu,
      matching: find.byType(BackdropFilter),
    );
    expect(tester.widget<BackdropFilter>(filter).enabled, isFalse);
    enabled.value = true;
    await tester.pumpAndSettle();
    expect(tester.widget<BackdropFilter>(filter).enabled, isTrue);
    expect(find.byKey(const ValueKey('test-select')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow large-text menu stays above keyboard and relayouts', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(240, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final media = ValueNotifier(
      const MediaQueryData(
        size: Size(240, 640),
        padding: EdgeInsets.only(top: 24, bottom: 12),
        viewInsets: EdgeInsets.only(bottom: 300),
        textScaler: TextScaler.linear(2),
      ),
    );
    addTearDown(media.dispose);
    final page = await _mount(tester, media: media);
    await _open(tester, page, position: const Offset(235, 620));
    final menu = find.byKey(const ValueKey('chat-message-glass-menu'));
    var rect = tester.getRect(menu);
    expect(rect.left, greaterThanOrEqualTo(12));
    expect(rect.right, lessThanOrEqualTo(228));
    expect(rect.top, greaterThanOrEqualTo(36));
    expect(rect.bottom, lessThanOrEqualTo(328));
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('test-select')),
      150,
      scrollable: find.byType(Scrollable).last,
    );
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(640, 240);
    media.value = const MediaQueryData(
      size: Size(640, 240),
      padding: EdgeInsets.only(left: 32, right: 16),
      textScaler: TextScaler.linear(2),
    );
    await tester.pumpAndSettle();
    rect = tester.getRect(menu);
    expect(rect.left, greaterThanOrEqualTo(44));
    expect(rect.right, lessThanOrEqualTo(612));
    expect(rect.top, greaterThanOrEqualTo(12));
    expect(rect.bottom, lessThanOrEqualTo(228));
    expect(tester.takeException(), isNull);
  });
}
