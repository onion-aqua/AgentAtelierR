import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/local_skin_store.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';
import 'package:ryza_chat_mvp/src/virtual_phone_wallpaper_page.dart';
import 'package:ryza_chat_mvp/src/virtual_phone_wallpapers.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');
const _wallpaperPreference = 'virtual_phone.wallpapers.v1';

Future<Uint8List> _samplePng() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 2, 2),
    ui.Paint()..color = const ui.Color(0xFF315B77),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(2, 2);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<void> _finishWallpaperOperation(
  WidgetTester tester,
  String indicatorKey,
) async {
  // The store was created by AppController.load in a real async zone. Give
  // its queued futures and the widget's fake async zone a chance to progress
  // together; awaiting the store's whole queue inside runAsync can deadlock.
  final indicator = find.byKey(ValueKey(indicatorKey));
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (indicator.evaluate().isEmpty) break;
  }
  expect(indicator, findsNothing);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
  });

  test(
    'bundled wallpapers load and select without a filesystem provider',
    () async {
      final preferences = await SharedPreferences.getInstance();
      var directoryRequests = 0;
      final store = VirtualPhoneWallpaperStore(
        preferences: preferences,
        directoryProvider: () async {
          directoryRequests++;
          throw StateError('Built-in wallpapers must not require a directory');
        },
      );
      addTearDown(store.dispose);
      await store.load();
      expect(store.wallpapers.map((wallpaper) => wallpaper.id), [
        'builtin-bg1',
        'builtin-bg2',
        'builtin-bg3',
      ]);
      expect(store.selected.id, 'builtin-bg1');
      expect(store.selected.assetPath, 'assets/images/virtual_phone/bg1.png');
      expect(
        store.wallpapers.every((wallpaper) => wallpaper.isBuiltIn),
        isTrue,
      );
      await store.select('builtin-bg2');
      expect(store.selected.assetPath, 'assets/images/virtual_phone/bg2.png');
      expect(directoryRequests, 0);
    },
  );

  test(
    'wallpaper persists outside save slots and character sessions',
    () async {
      // A null path_provider makes the optional filesystem unavailable. Loading
      // controller defaults and selecting a bundled image must still succeed.
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final store = controller.virtualPhoneWallpapers;
      expect(store.wallpapers, hasLength(3));
      expect(store.selected.id, 'builtin-bg1');
      await store.load();
      expect(store.selected.filePath, isNull);

      // Save an older slot before selection, so reading it cannot accidentally
      // restore a wallpaper embedded in that slot's character snapshot.
      await controller.saveToLocalSlot(0);
      await store.select('builtin-bg2');
      await controller.saveToLocalSlot(2);
      expect(store.selected.id, 'builtin-bg2');
      await controller.createLocalSlot(1);
      expect(store.selected.id, 'builtin-bg2');
      await controller.loadFromLocalSlot(0);
      expect(store.selected.id, 'builtin-bg2');
      await controller.setActiveCharacter('sophie');
      expect(store.selected.id, 'builtin-bg2');
      // Returning to Ryza initializes its separate skin store. Inject that
      // unrelated fixture directly while keeping path_provider unavailable for
      // the wallpaper's bundled-image persistence checks.
      final skinDirectory = await Directory.systemTemp.createTemp(
        'phone_wallpaper_character_skins_',
      );
      addTearDown(() => skinDirectory.delete(recursive: true));
      await LocalSkinStore.instance.initialize(storageDirectory: skinDirectory);
      await controller.setActiveCharacter('ryza');
      expect(store.selected.id, 'builtin-bg2');

      final restored = await AppController.load();
      addTearDown(restored.dispose);
      expect(restored.virtualPhoneWallpapers.selected.id, 'builtin-bg2');
      final preferences = await SharedPreferences.getInstance();
      expect(
        (jsonDecode(preferences.getString(_wallpaperPreference)!)
            as Map)['selected'],
        'builtin-bg2',
      );
      expect(
        jsonEncode(restored.exportData()),
        isNot(contains(_wallpaperPreference)),
      );
      expect(
        jsonEncode(restored.exportData()),
        isNot(contains('assets/images/virtual_phone/')),
      );
    },
  );

  test(
    'export excludes the private path of a real imported wallpaper',
    () async {
      // This single privacy case supplies a disposable support directory so the
      // exported-data assertion has a real private managed file to protect.
      final directory = await Directory.systemTemp.createTemp(
        'phone_wallpaper_private_export_',
      );
      addTearDown(() => directory.delete(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathProvider, (_) async => directory.path);
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final imported = await controller.virtualPhoneWallpapers.importImage(
        await _samplePng(),
        filename: 'C:/private/source-wallpaper.png',
      );
      expect(imported.isBuiltIn, isFalse);
      expect(imported.filePath, isNotNull);
      expect(await File(imported.filePath!).exists(), isTrue);
      expect(controller.virtualPhoneWallpapers.selected.id, imported.id);
      final restored = await AppController.load();
      addTearDown(restored.dispose);
      expect(restored.virtualPhoneWallpapers.selected.id, imported.id);
      expect(
        restored.virtualPhoneWallpapers.selected.filePath,
        imported.filePath,
      );
      final exported = jsonEncode(restored.exportData());
      expect(exported, isNot(contains(imported.filePath!)));
      expect(exported, isNot(contains(directory.path)));
      expect(exported, isNot(contains(imported.id)));
      expect(exported, isNot(contains('C:/private/source-wallpaper.png')));
      expect(exported, isNot(contains(_wallpaperPreference)));
    },
  );

  testWidgets(
    'wallpaper selection updates phone background and survives reopening',
    (tester) async {
      tester.view.physicalSize = const Size(390, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = (await tester.runAsync(() => AppController.load()))!;
      addTearDown(controller.dispose);
      final store = controller.virtualPhoneWallpapers;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: VirtualPhoneLauncher(
            language: AppLanguage.chinese,
            liquidGlass: false,
            wallpapers: store,
            pages: {
              VirtualPhoneApp.wallpaper: (_) => VirtualPhoneWallpaperPage(
                store: store,
                language: AppLanguage.chinese,
              ),
            },
          ),
        ),
      );
      final background = find.byKey(const ValueKey('virtual-phone-wallpaper'));
      final statusBar = find.byKey(const ValueKey('virtual-phone-status-bar'));
      String backgroundAsset() {
        final provider = tester.widget<Image>(background).image;
        expect(provider, isA<ResizeImage>());
        final source = (provider as ResizeImage).imageProvider;
        expect(source, isA<AssetImage>());
        return (source as AssetImage).assetName;
      }

      await tester.tap(find.byIcon(Icons.smartphone_rounded));
      await tester.pumpAndSettle();
      expect(backgroundAsset(), 'assets/images/virtual_phone/bg1.png');
      final statusRect = tester.getRect(statusBar);
      final glyph = find.byKey(const ValueKey('virtual-phone-glyph-wallpaper'));
      final glyphRect = tester.getRect(glyph);
      await tester.tap(
        find.byKey(const ValueKey('virtual-phone-app-wallpaper')),
      );
      await tester.pump();
      await _finishWallpaperOperation(tester, 'wallpaper-loading');
      expect(find.byType(VirtualPhoneWallpaperPage), findsOneWidget);
      expect(tester.getRect(statusBar), statusRect);
      await tester.tap(
        find.byKey(const ValueKey('wallpaper-card-builtin-bg2')),
      );
      await _finishWallpaperOperation(tester, 'wallpaper-operation-progress');
      expect(store.selected.id, 'builtin-bg2');
      expect(backgroundAsset(), 'assets/images/virtual_phone/bg2.png');
      expect(tester.getRect(statusBar), statusRect);

      final transition = find.byKey(
        const ValueKey('virtual-phone-app-transition'),
      );
      final fullWidth = tester.getRect(transition).width;
      await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(transition).width, lessThan(fullWidth));
      expect(tester.getRect(statusBar), statusRect);
      await tester.pumpAndSettle();
      expect(find.byType(VirtualPhoneWallpaperPage), findsNothing);
      expect(tester.getRect(glyph), glyphRect);
      expect(backgroundAsset(), 'assets/images/virtual_phone/bg2.png');
      expect(store.selected.id, 'builtin-bg2');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('virtual-phone-screen')), findsNothing);
      await tester.tap(find.byIcon(Icons.smartphone_rounded));
      await tester.pumpAndSettle();
      expect(backgroundAsset(), 'assets/images/virtual_phone/bg2.png');
      expect(tester.getRect(statusBar), statusRect);
      expect(store.selected.id, 'builtin-bg2');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'deleting an imported wallpaper unlocks its cached background and thumbnail file',
    (tester) async {
      tester.view.physicalSize = const Size(390, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'phone_wallpaper_cached_delete_',
        );
        final store = VirtualPhoneWallpaperStore(
          preferences: await SharedPreferences.getInstance(),
          directoryProvider: () async => directory,
        );
        await store.load();
        final imported = await store.importImage(
          await _samplePng(),
          filename: 'cached-background.png',
        );
        return (directory: directory, store: store, imported: imported);
      }))!;
      addTearDown(() => fixture.directory.delete(recursive: true));
      addTearDown(fixture.store.dispose);
      final store = fixture.store;
      final imported = fixture.imported;
      final file = File(imported.filePath!);
      expect(await tester.runAsync(file.exists), isTrue);
      expect(store.selected.id, imported.id);
      final builtIns = store.wallpapers
          .where((wallpaper) => wallpaper.isBuiltIn)
          .toList();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: VirtualPhoneLauncher(
            language: AppLanguage.chinese,
            liquidGlass: false,
            wallpapers: store,
            pages: {
              VirtualPhoneApp.wallpaper: (_) => VirtualPhoneWallpaperPage(
                store: store,
                language: AppLanguage.chinese,
              ),
            },
          ),
        ),
      );

      // Keep both decoded images in the real image cache. In particular, do
      // not evict either provider before deletion, which would hide the file
      // lock left by a Windows memory-mapped FileImage codec.
      Future<Object> decodeAndCache(Finder finder) async {
        final provider = tester.widget<Image>(finder).image;
        final configuration = createLocalImageConfiguration(
          tester.element(finder),
        );
        final stream = provider.resolve(configuration);
        var decoded = false;
        Object? decodingError;
        final listener = ImageStreamListener((info, _) {
          decoded = true;
          info.dispose();
        }, onError: (error, _) => decodingError = error);
        stream.addListener(listener);
        try {
          for (var attempt = 0; attempt < 40 && !decoded; attempt++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          expect(decodingError, isNull);
          expect(decoded, isTrue);
          final key = await provider.obtainKey(configuration);
          expect(PaintingBinding.instance.imageCache.containsKey(key), isTrue);
          return key;
        } finally {
          stream.removeListener(listener);
        }
      }

      await tester.tap(find.byIcon(Icons.smartphone_rounded));
      await tester.pumpAndSettle();
      final background = find.byKey(const ValueKey('virtual-phone-wallpaper'));
      final fullImage = tester.widget<Image>(background).image as ResizeImage;
      final backgroundSize = tester.getSize(background);
      expect(fullImage.width, backgroundSize.width.ceil());
      expect(fullImage.height, backgroundSize.height.ceil());
      expect(fullImage.width, greaterThan(300));
      expect(fullImage.height, greaterThan(600));
      expect((fullImage.imageProvider as FileImage).file.path, file.path);
      final backgroundKey = await decodeAndCache(background);
      await tester.tap(
        find.byKey(const ValueKey('virtual-phone-app-wallpaper')),
      );
      await tester.pump();
      await _finishWallpaperOperation(tester, 'wallpaper-loading');
      final importedCard = find.byKey(
        ValueKey('wallpaper-card-${imported.id}'),
      );
      final thumbnail = find.descendant(
        of: importedCard,
        matching: find.byType(Image),
      );
      expect(thumbnail, findsOneWidget);
      final thumbnailKey = await decodeAndCache(thumbnail);
      expect(backgroundKey, isNot(thumbnailKey));
      expect(
        PaintingBinding.instance.imageCache.containsKey(backgroundKey),
        isTrue,
      );
      expect(
        PaintingBinding.instance.imageCache.containsKey(thumbnailKey),
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('wallpaper-delete-mode')));
      await tester.pumpAndSettle();
      await tester.tap(importedCard);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('wallpaper-delete-selected')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('wallpaper-delete-confirmation')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('wallpaper-delete-confirm')));
      await _finishWallpaperOperation(tester, 'wallpaper-operation-progress');

      expect(await tester.runAsync(file.exists), isFalse);
      expect(store.selected.id, 'builtin-bg1');
      expect(store.wallpapers, builtIns);
      expect(store.wallpapers.map((wallpaper) => wallpaper.id), [
        'builtin-bg1',
        'builtin-bg2',
        'builtin-bg3',
      ]);
      final restoredImage =
          tester.widget<Image>(background).image as ResizeImage;
      expect(
        (restoredImage.imageProvider as AssetImage).assetName,
        'assets/images/virtual_phone/bg1.png',
      );
      expect(importedCard, findsNothing);
      expect(find.byKey(const ValueKey('wallpaper-error')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
