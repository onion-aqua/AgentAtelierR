import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/settings_detail_page.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';

void main() {
  Future<AppController> setup(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final messenger = tester.binding.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
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
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: SettingsScreen(controller: controller, onMenuPressed: () {}),
      ),
    );
    return controller;
  }

  Future<void> tapVisible(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(target), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'every configuration opens a glass page and returns one level with keyboard',
    (tester) async {
      final controller = await setup(tester);
      for (final category in {
        'appearance': ['主题', '主题色', '语言'],
        'profile': ['称呼与自画像'],
        'ai': ['OpenAI 兼容接口', 'Google Gemini'],
        'roleplay': ['编辑人物设定', '编辑世界书'],
        'data': ['长期记忆'],
        'audio': ['Fish Audio', '百炼 Qwen-TTS', '通用 OpenAI TTS', 'MiMo TTS'],
      }.entries) {
        await tapVisible(
          tester,
          find.byKey(ValueKey('settings-category-${category.key}')),
        );
        for (final title in category.value) {
          await tapVisible(tester, find.text(title));
          expect(
            find.byType(SettingsDetailPage),
            findsOneWidget,
            reason: title,
          );
          expect(find.byType(AlertDialog), findsNothing, reason: title);
          final surface = find.byKey(const ValueKey('settings-detail-glass'));
          expect(tester.getSize(surface).width, 320);
          expect(tester.widget<GlassSurface>(surface).liquidGlass, isFalse);
          controller.setLiquidGlassChatUi(true);
          await tester.pump();
          expect(tester.widget<GlassSurface>(surface).liquidGlass, isTrue);
          expect(tester.widget<GlassSurface>(surface).tone, GlassTone.dark);
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '$title with keyboard',
          );
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byType(SettingsDetailPage), findsNothing);
          expect(find.text(title), findsOneWidget);
          controller.setLiquidGlassChatUi(false);
          await tester.pump();
        }
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey('settings-category-${category.key}')),
          findsOneWidget,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'thinking UI reflects model capabilities without unsupported effort choices',
    (tester) async {
      final controller = await setup(tester);
      controller.configureAi(
        enabled: true,
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
        model: 'qwen3.5-plus',
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('settings-category-ai')),
      );
      final toggle = find.widgetWithText(SwitchListTile, '模型思考');
      await tapVisible(tester, toggle);
      expect(controller.activeThinkingEnabled, isTrue);
      expect(
        find.byType(DropdownButtonFormField<ReasoningEffort>),
        findsNothing,
      );
      controller.configureGemini(
        enabled: true,
        baseUrl:
            'https://generativelanguage.googleapis.com/v1beta/interactions',
        model: 'gemini-3.8-flash',
      );
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
      final effort = tester.widget<DropdownButtonFormField<ReasoningEffort>>(
        find.byType(DropdownButtonFormField<ReasoningEffort>),
      );
      expect(effort.initialValue, ReasoningEffort.medium);
      controller.configureAi(
        enabled: true,
        baseUrl: 'https://example.test/v1',
        model: 'custom-alias',
      );
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
      expect(
        find.byType(DropdownButtonFormField<ReasoningEffort>),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('memory edit saves only on Save and back discards the draft', (
    tester,
  ) async {
    final c = await setup(tester);
    c.configureLongTermMemory(enabled: true, summary: '原记忆');
    await tapVisible(
      tester,
      find.byKey(const ValueKey('settings-category-data')),
    );
    await tapVisible(tester, find.text('长期记忆'));
    await tester.enterText(find.byType(TextField), '新记忆');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(c.memorySummary, '新记忆');
    await tapVisible(tester, find.text('长期记忆'));
    await tester.enterText(find.byType(TextField), '不要保存');
    await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
    await tester.pumpAndSettle();
    expect(c.memorySummary, '新记忆');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'detail route keeps backdrop ticking and uses translucent fallback',
    (tester) async {
      final c = await setup(tester);
      final backdrop = GlobalKey<_BackdropState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              _Backdrop(key: backdrop),
              SettingsScreen(controller: c, onMenuPressed: () {}),
            ],
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('settings-category-appearance')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('主题'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final ticks = backdrop.currentState!.ticks;
      await tester.pump(const Duration(milliseconds: 100));
      expect(backdrop.currentState!.ticks, greaterThan(ticks));
      final glass = tester.widget<GlassSurface>(
        find.byKey(const ValueKey('settings-detail-glass')),
      );
      expect(glass.fallbackColor.a, lessThan(1));
      expect(glass.tone, GlassTone.light);
      expect(
        ModalRoute.of(tester.element(find.byType(SettingsDetailPage)))!.opaque,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _Backdrop extends StatefulWidget {
  const _Backdrop({super.key});
  @override
  State<_Backdrop> createState() => _BackdropState();
}

class _BackdropState extends State<_Backdrop>
    with SingleTickerProviderStateMixin {
  int ticks = 0;
  late final ticker = createTicker((_) => ticks++);
  @override
  void initState() {
    super.initState();
    ticker.start();
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Colors.blue, child: SizedBox.expand());
}
