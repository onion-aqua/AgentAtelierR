import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';
import 'package:ryza_chat_mvp/src/virtual_phone_wallpapers.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _captureKey = ValueKey('phone-contrast-capture');
const _desktopBlurKey = ValueKey('virtual-phone-settings-desktop-blur');
const _size = Size(640, 1280);

class _Environment {
  _Environment(
    this.controller,
    this.wallpapers,
    this.blackWallpaperId,
    this.whiteWallpaperId,
  );
  final AppController controller;
  final VirtualPhoneWallpaperStore wallpapers;
  final String blackWallpaperId;
  final String whiteWallpaperId;
}

Future<Uint8List> _solidPng(Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(4, 4);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<_Environment> _mount(
  WidgetTester tester, {
  bool blackWallpaper = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (_) async => null,
  );
  addTearDown(
    () => messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    ),
  );
  final environment = (await tester.runAsync(() async {
    final controller = await AppController.load();
    controller.setThemePreference(AppThemePreference.light);
    controller.setLiquidGlassChatUi(true);
    final directory = await Directory.systemTemp.createTemp('phone_contrast_');
    final wallpapers = VirtualPhoneWallpaperStore(
      preferences: await SharedPreferences.getInstance(),
      directoryProvider: () async => directory,
      catalogProvider: () async => const [],
    );
    await wallpapers.load();
    final black = await wallpapers.importImage(
      await _solidPng(Colors.black),
      filename: 'black.png',
    );
    final white = await wallpapers.importImage(
      await _solidPng(Colors.white),
      filename: 'white.png',
    );
    await wallpapers.select(blackWallpaper ? black.id : 'builtin-bg1');
    addTearDown(controller.dispose);
    addTearDown(wallpapers.dispose);
    addTearDown(() async {
      imageCache.clear();
      imageCache.clearLiveImages();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    return _Environment(controller, wallpapers, black.id, white.id);
  }))!;
  final controller = environment.controller;
  await tester.pumpWidget(
    AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        theme: atelierTheme(
          controller.accentTheme,
          controller.themePreference == AppThemePreference.dark
              ? Brightness.dark
              : Brightness.light,
        ),
        builder: (context, child) => RepaintBoundary(
          key: _captureKey,
          child: GlassStyleScope(
            enabled: controller.liquidGlassChatUi,
            child: child!,
          ),
        ),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: VirtualPhoneLauncher(
              language: AppLanguage.chinese,
              liquidGlass: controller.liquidGlassChatUi,
              liquidGlassBuilder: () => controller.liquidGlassChatUi,
              updates: controller,
              wallpapers: environment.wallpapers,
              fullBleedApps: const {VirtualPhoneApp.settings},
              pages: {
                VirtualPhoneApp.settings: (_) => SettingsScreen(
                  controller: controller,
                  onMenuPressed: () {},
                  embedded: true,
                ),
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byIcon(Icons.smartphone_rounded));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('virtual-phone-app-settings')));
  await tester.pumpAndSettle();
  return environment;
}

Future<(ByteData, int)> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
  final rgba = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  await tester.runAsync(() async {
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    final folder = Directory('build/glass-contrast');
    await folder.create(recursive: true);
    await File('${folder.path}/$name.png').writeAsBytes(
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
    );
  });
  final width = image.width;
  image.dispose();
  return (rgba, width);
}

Color _pixel(ByteData bytes, int width, Offset point) {
  final index = (point.dy.floor() * width + point.dx.floor()) * 4;
  return Color.fromARGB(
    bytes.getUint8(index + 3),
    bytes.getUint8(index),
    bytes.getUint8(index + 1),
    bytes.getUint8(index + 2),
  );
}

double _contrast(Color foreground, Color background) {
  final text = Color.alphaBlend(foreground, background).computeLuminance();
  final surface = background.computeLuminance();
  return (text > surface)
      ? (text + .05) / (surface + .05)
      : (surface + .05) / (text + .05);
}

Future<void> _expectReadable(
  WidgetTester tester,
  String screenshot,
  List<String> labels,
) async {
  final (pixels, width) = await _capture(tester, screenshot);
  var minimum = double.infinity;
  for (final label in labels) {
    final finder = find.text(label);
    expect(finder, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(finder);
    final foreground = (paragraph.text as TextSpan).style!.color!;
    final rect = tester.getRect(finder);
    // The blank gap immediately before the glyphs shares the card background
    // without sampling a text or icon pixel; account for actual alpha styling.
    final point = Offset(rect.left - 4, rect.center.dy);
    final background = _pixel(pixels, width, point);
    final ratio = _contrast(foreground, background);
    if (ratio < minimum) minimum = ratio;
    expect(
      ratio,
      greaterThanOrEqualTo(4.5),
      reason: '$label against rendered $background ($foreground): $ratio',
    );
  }
  debugPrint(
    '$screenshot: minimum text contrast ${minimum.toStringAsFixed(2)}:1',
  );
  expect(tester.takeException(), isNull);
}

const _categoryLabels = [
  '界面与场景',
  '主题、语言、玻璃效果、视线与帧率',
  '声音与语音',
  '点击语音、背景音乐、环境音与 TTS',
];

void main() {
  for (final black in [false, true]) {
    testWidgets(
      'light glass settings remain readable (black wallpaper=$black)',
      (tester) async {
        await _mount(tester, blackWallpaper: black);
        await _expectReadable(tester, 'light-home-$black', _categoryLabels);
        await tester.tap(
          find.byKey(const ValueKey('settings-category-appearance')),
        );
        await tester.pumpAndSettle();
        await _expectReadable(tester, 'light-category-$black', ['主题', '主题色']);
        await tester.tap(find.text('主题'));
        await tester.pumpAndSettle();
        await _expectReadable(tester, 'light-detail-$black', ['浅色模式', '暗色模式']);
      },
    );
  }

  testWidgets(
    'settings blur the retained desktop through nested detail routes',
    (tester) async {
      final environment = await _mount(tester);
      final desktop = find.byKey(const ValueKey('virtual-phone-home-clock'));
      final blur = find.byKey(_desktopBlurKey);
      // The home route must paint underneath the translucent settings page.
      // maintainState alone is insufficient: an opaque route makes it offstage.
      expect(desktop, findsOneWidget);
      expect(blur, findsOneWidget);
      final filter = tester.widget<BackdropFilter>(blur);
      expect(filter.enabled, isTrue);
      expect(
        filter.filter,
        ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24, tileMode: TileMode.clamp),
      );
      final retainedFilter = tester.renderObject<RenderBackdropFilter>(blur);
      expect(
        tester
            .widgetList<BackdropFilter>(
              find.descendant(of: blur, matching: find.byType(BackdropFilter)),
            )
            .where((filter) => filter.enabled),
        isEmpty,
        reason: 'Settings must reuse the route blur instead of nesting a full-screen shader or card filters',
      );
      await tester.tap(
        find.byKey(const ValueKey('settings-category-appearance')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('主题'));
      await tester.pumpAndSettle();
      expect(desktop, findsOneWidget);
      expect(
        tester.renderObject<RenderBackdropFilter>(blur),
        same(retainedFilter),
      );
      await _expectReadable(tester, 'desktop-blur-detail', ['浅色模式', '暗色模式']);
      final detailGlass = find.byKey(const ValueKey('settings-detail-glass'));
      expect(
        tester
            .widgetList<BackdropFilter>(
              find.descendant(
                of: detailGlass,
                matching: find.byType(BackdropFilter),
              ),
            )
            .where((filter) => filter.enabled),
        isEmpty,
        reason: 'A pushed detail page reuses the persistent phone route blur',
      );
      environment.controller.setLiquidGlassChatUi(false);
      await tester.pumpAndSettle();
      expect(tester.widget<BackdropFilter>(blur).enabled, isFalse);
      expect(
        tester.renderObject<RenderBackdropFilter>(blur),
        same(retainedFilter),
      );
      expect(find.text('浅色模式'), findsOneWidget);
      environment.controller.setLiquidGlassChatUi(true);
      await tester.pumpAndSettle();
      expect(tester.widget<BackdropFilter>(blur).enabled, isTrue);
      expect(
        tester.renderObject<RenderBackdropFilter>(blur),
        same(retainedFilter),
      );
      await _expectReadable(tester, 'desktop-blur-restored', ['浅色模式', '暗色模式']);
    },
  );

  testWidgets(
    'open settings keep contrast across live themes, wallpaper and glass',
    (tester) async {
      final environment = await _mount(tester);
      final controller = environment.controller;
      await tester.runAsync(
        () => environment.wallpapers.select(environment.blackWallpaperId),
      );
      await tester.pumpAndSettle();
      await _expectReadable(tester, 'wallpaper-black', _categoryLabels);
      controller.setThemePreference(AppThemePreference.dark);
      await tester.pumpAndSettle();
      await _expectReadable(tester, 'dark-glass', _categoryLabels);
      await tester.runAsync(
        () => environment.wallpapers.select(environment.whiteWallpaperId),
      );
      await tester.pumpAndSettle();
      await _expectReadable(tester, 'dark-white-wallpaper', _categoryLabels);
      controller.setThemePreference(AppThemePreference.light);
      await tester.pumpAndSettle();
      await _expectReadable(tester, 'light-again', _categoryLabels);
      controller.setLiquidGlassChatUi(false);
      await tester.pumpAndSettle();
      await _expectReadable(tester, 'light-fallback', _categoryLabels);
      await tester.runAsync(() => environment.wallpapers.select('builtin-bg2'));
      controller.setLiquidGlassChatUi(true);
      await tester.pumpAndSettle();
      await _expectReadable(tester, 'wallpaper-bg2', _categoryLabels);
    },
  );
}
