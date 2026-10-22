import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';

void main() {
  testWidgets(
    'phone stops painting the covered scene and preserves its state',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const TextField(),
                VirtualPhoneLauncher(
                  language: AppLanguage.chinese,
                  liquidGlass: true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'draft');
      final state = tester.state(find.byType(TextField));
      await tester.tap(find.byIcon(Icons.smartphone_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(
        tester.state(find.byType(TextField, skipOffstage: false)),
        same(state),
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(TextField)), same(state));
      expect(find.text('draft'), findsOneWidget);
    },
  );

  testWidgets('status assets stay visible and update inside a phone app', (
    tester,
  ) async {
    final indicators = ValueNotifier(const VirtualPhoneStatusInfo());
    addTearDown(indicators.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: VirtualPhoneLauncher(
          language: AppLanguage.chinese,
          liquidGlass: false,
          updates: indicators,
          statusInfoBuilder: () => indicators.value,
          pages: {
            VirtualPhoneApp.status: (_) => const Scaffold(
              body: Center(child: Text('complete-status-page')),
            ),
          },
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pumpAndSettle();
    String asset(String key) =>
        (tester.widget<Image>(find.byKey(ValueKey(key))).image as AssetImage)
            .assetName;
    expect(asset('virtual-phone-signal'), endsWith('signal_0.png'));
    expect(asset('virtual-phone-battery'), endsWith('battery_5.png'));
    final barBefore = tester.getRect(
      find.byKey(const ValueKey('virtual-phone-status-bar')),
    );
    final dock = find.byKey(const ValueKey('virtual-phone-dock'));
    expect(
      find.descendant(of: dock, matching: find.byType(Text)),
      findsNothing,
    );
    await tester.tap(find.byIcon(Icons.favorite_outline_rounded));
    await tester.pumpAndSettle();
    indicators.value = const VirtualPhoneStatusInfo(
      signalBars: 2,
      llmLatency: Duration(seconds: 25),
      satietyEnabled: true,
      satiety: 7,
    );
    await tester.pumpAndSettle();
    expect(asset('virtual-phone-signal'), endsWith('signal_2.png'));
    expect(asset('virtual-phone-battery'), endsWith('battery_1.png'));
    expect(
      tester.getRect(find.byKey(const ValueKey('virtual-phone-status-bar'))),
      barBefore,
    );
    expect(find.text('complete-status-page'), findsOneWidget);
    indicators.value = const VirtualPhoneStatusInfo(
      satietyEnabled: false,
      satiety: 7,
    );
    await tester.pumpAndSettle();
    expect(asset('virtual-phone-battery'), endsWith('battery_5.png'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'phone app rows have more breathing room and the dock stays fixed',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: VirtualPhoneLauncher(
            language: AppLanguage.chinese,
            liquidGlass: false,
            pages: {
              for (final app in VirtualPhoneApp.values)
                app: (_) => const Scaffold(),
            },
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.smartphone_rounded));
      await tester.pumpAndSettle();
      final dock = find.byKey(const ValueKey('virtual-phone-dock'));
      final before = tester.getRect(dock);
      final firstRow = tester.getTopLeft(
        find.byKey(const ValueKey('virtual-phone-app-status')),
      );
      final secondRow = tester.getTopLeft(
        find.byKey(const ValueKey('virtual-phone-app-pcAgent')),
      );
      expect(secondRow.dy - firstRow.dy, greaterThan(100));
      expect(find.text('莱莎手机'), findsNothing);
      expect(find.text('冒险工具'), findsNothing);
      for (final app in ['phone', 'messages', 'wallpaper', 'imageGeneration']) {
        expect(
          find.byKey(ValueKey('virtual-phone-app-$app')).hitTestable(),
          findsOneWidget,
        );
      }
      await tester.drag(find.byType(GridView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(tester.getRect(dock), before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('app fills phone and its confirmation stays inside until back', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VirtualPhoneLauncher(
          language: AppLanguage.chinese,
          liquidGlass: false,
          pages: {
            VirtualPhoneApp.status: (context) => Scaffold(
              key: const ValueKey('full-phone-page'),
              body: Center(
                child: TextButton(
                  child: const Text('open-confirmation'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    useRootNavigator: false,
                    builder: (_) =>
                        const AlertDialog(title: Text('inside-phone')),
                  ),
                ),
              ),
            ),
          },
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.favorite_outline_rounded));
    await tester.pumpAndSettle();
    final phone = tester.getRect(
      find.byKey(const ValueKey('virtual-phone-screen')),
    );
    final page = tester.getRect(find.byKey(const ValueKey('full-phone-page')));
    final header = tester.getRect(
      find.byKey(const ValueKey('virtual-phone-status-bar')),
    );
    expect(header.top, closeTo(phone.top, 1));
    expect(page.top, closeTo(header.bottom, 1));
    expect(page.bottom, closeTo(phone.bottom, 1));
    await tester.tap(find.text('open-confirmation'));
    await tester.pumpAndSettle();
    final dialog = tester.getRect(find.byType(AlertDialog));
    expect(phone.contains(dialog.topLeft), isTrue);
    expect(phone.contains(dialog.bottomRight), isTrue);
    expect(
      find.byKey(const ValueKey('virtual-phone-dynamic-island')),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('inside-phone'), findsNothing);
    expect(find.text('open-confirmation'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('virtual-phone-app-status')).hitTestable(),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('virtual-phone-screen')), findsNothing);
  });

  testWidgets('image gallery replaces the rightmost dock shortcut', (
    tester,
  ) async {
    var shortcutOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: VirtualPhoneLauncher(
          language: AppLanguage.chinese,
          liquidGlass: false,
          shortcutPicker: (_) {
            shortcutOpened = true;
            return const Text('legacy-shortcut-picker');
          },
          pages: {
            VirtualPhoneApp.imageGeneration: (_) =>
                const Scaffold(body: Center(child: Text('image-gallery-page'))),
          },
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pumpAndSettle();
    final gallery = find.byKey(
      const ValueKey('virtual-phone-app-imageGeneration'),
    );
    final dock = find.byKey(const ValueKey('virtual-phone-dock'));
    final wallpaper = find.byKey(const ValueKey('virtual-phone-app-wallpaper'));
    expect(
      find.byKey(const ValueKey('virtual-phone-app-shortcut')),
      findsNothing,
    );
    expect(find.byIcon(Icons.dashboard_customize_outlined), findsNothing);
    expect(find.descendant(of: dock, matching: gallery), findsOneWidget);
    expect(
      tester.getCenter(gallery).dx,
      greaterThan(tester.getCenter(wallpaper).dx),
    );
    expect(
      find.descendant(of: gallery, matching: find.byType(Text)),
      findsNothing,
    );
    final interaction = tester.widget<InkWell>(
      find.descendant(of: gallery, matching: find.byType(InkWell)).first,
    );
    expect(interaction.onLongPress, isNull);
    expect(shortcutOpened, isFalse);
    await tester.tap(gallery);
    await tester.pumpAndSettle();
    expect(find.text('image-gallery-page'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(gallery.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('image gallery activity updates while the phone stays open', (
    tester,
  ) async {
    final activity = ValueNotifier((active: false, unread: false));
    addTearDown(activity.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: VirtualPhoneLauncher(
          language: AppLanguage.chinese,
          liquidGlass: false,
          imageGenerationUpdates: activity,
          imageGenerationActiveBuilder: () => activity.value.active,
          imageGenerationUnreadBuilder: () => activity.value.unread,
          pages: {
            VirtualPhoneApp.imageGeneration: (_) =>
                const Scaffold(body: Center(child: Text('image-gallery-page'))),
          },
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pumpAndSettle();
    final gallery = find.byKey(
      const ValueKey('virtual-phone-app-imageGeneration'),
    );
    final progress = find.byKey(
      const ValueKey('image-generation-toolbar-progress'),
    );
    final unread = find.byKey(const ValueKey('image-generation-unread-dot'));
    final originalRect = tester.getRect(gallery);
    expect(progress, findsNothing);
    expect(unread, findsNothing);
    activity.value = (active: true, unread: false);
    await tester.pump();
    expect(find.descendant(of: gallery, matching: progress), findsOneWidget);
    expect(unread, findsNothing);
    expect(tester.getRect(gallery), originalRect);
    activity.value = (active: false, unread: true);
    await tester.pump();
    expect(progress, findsNothing);
    expect(find.descendant(of: gallery, matching: unread), findsOneWidget);
    expect(tester.getRect(gallery), originalRect);
    await tester.tap(gallery);
    await tester.pumpAndSettle();
    expect(find.text('image-gallery-page'), findsOneWidget);
    activity.value = (active: false, unread: false);
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(gallery.hitTestable(), findsOneWidget);
    expect(unread, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('virtual phone opens and pages to an app', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VirtualPhoneLauncher(
          language: AppLanguage.chinese,
          liquidGlass: false,
          pages: {
            VirtualPhoneApp.status: (_) =>
                const Center(child: Text('status-page')),
          },
          onShopPressed: () {},
          onOutfitPressed: () {},
          onMotionPressed: () {},
          onPcAgentPressed: () {},
          onSavesPressed: () {},
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('virtual-phone-app-status')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('角色状态'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.favorite_outline_rounded));
    await tester.pumpAndSettle();
    expect(find.text('status-page'), findsOneWidget);
  });

  testWidgets('callback-only app opens its existing editor directly', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: VirtualPhoneLauncher(
          language: AppLanguage.chinese,
          liquidGlass: false,
          onMotionPressed: () => opened = true,
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.animation_outlined));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
  });

  testWidgets('system back returns from a phone app to the icon home', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VirtualPhoneLauncher(
          language: AppLanguage.chinese,
          liquidGlass: false,
          pages: {
            VirtualPhoneApp.status: (_) =>
                const Center(child: Text('status-page')),
          },
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.favorite_outline_rounded));
    await tester.pumpAndSettle();
    expect(find.text('status-page'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('virtual-phone-app-status')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('status-page'), findsNothing);
  });

  testWidgets('pull handle dismisses the virtual phone', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VirtualPhoneLauncher(
          language: AppLanguage.chinese,
          liquidGlass: false,
          onStatusPressed: () {},
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('virtual-phone-app-status')).hitTestable(),
      findsOneWidget,
    );

    await tester.drag(
      find.byKey(const ValueKey('virtual-phone-pull-handle')),
      const Offset(0, 220),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('virtual-phone-screen')), findsNothing);
  });
}
