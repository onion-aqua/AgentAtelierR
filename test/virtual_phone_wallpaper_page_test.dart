import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/virtual_phone_wallpaper_page.dart';
import 'package:ryza_chat_mvp/src/virtual_phone_wallpapers.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Uint8List> _image() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 4, 8),
    ui.Paint()..color = const ui.Color(0xFF779DB3),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(4, 8);
  picture.dispose();
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
  }
}

Finder _card(String id) => find.byKey(ValueKey('wallpaper-card-$id'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VirtualPhoneWallpaperStore store;
  late Directory directory;
  late Uint8List image;
  late GlobalKey<NavigatorState> phoneNavigator;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    directory = await Directory.systemTemp.createTemp('phone_wallpaper_page_');
    store = VirtualPhoneWallpaperStore(
      preferences: preferences,
      directoryProvider: () async => directory,
    );
    await store.load();
    image = await _image();
    phoneNavigator = GlobalKey<NavigatorState>();
  });

  tearDown(() async {
    store.dispose();
    // Windows may still be finishing a thumbnail read from the last frame.
    for (var attempt = 0; ; attempt++) {
      try {
        await directory.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt >= 8) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  Future<void> mount(
    WidgetTester tester, {
    Future<VirtualPhoneWallpaperImageSelection?> Function()? picker,
    Size size = const Size(390, 740),
    ValueNotifier<bool>? glass,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: glass == null
            ? null
            : (context, child) => ValueListenableBuilder<bool>(
                valueListenable: glass,
                child: child,
                builder: (context, enabled, child) =>
                    GlassStyleScope(enabled: enabled, child: child!),
              ),
        home: Navigator(
          key: phoneNavigator,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('phone-home')),
          ),
        ),
      ),
    );
    phoneNavigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => VirtualPhoneWallpaperPage(
          store: store,
          language: AppLanguage.chinese,
          imagePicker: picker,
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find.byKey(const ValueKey('wallpaper-loading')).evaluate().isEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
    for (
      var i = 0;
      i < 40 && PaintingBinding.instance.imageCache.pendingImageCount > 0;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> finishOperation(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find
          .byKey(const ValueKey('wallpaper-operation-progress'))
          .evaluate()
          .isEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
    for (
      var i = 0;
      i < 40 && PaintingBinding.instance.imageCache.pendingImageCount > 0;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  testWidgets('three portrait cards per row and an add card after defaults', (
    tester,
  ) async {
    await mount(tester);
    final grid = tester.widget<GridView>(
      find.byKey(const ValueKey('wallpaper-grid')),
    );
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 3);
    expect(delegate.childAspectRatio, .56);
    final first = tester.getRect(_card('builtin-bg1'));
    final second = tester.getRect(_card('builtin-bg2'));
    final third = tester.getRect(_card('builtin-bg3'));
    final add = tester.getRect(
      find.byKey(const ValueKey('wallpaper-add-card')),
    );
    expect(first.top, second.top);
    expect(second.top, third.top);
    expect(second.left, greaterThan(first.right));
    expect(third.left, greaterThan(second.right));
    expect(add.top, greaterThan(first.bottom));
    expect(add.left, first.left);
    expect(
      find.byKey(const ValueKey('wallpaper-selected-builtin-bg1')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('choosing a card selects it without leaving the page', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(_card('builtin-bg2'));
    await finishOperation(tester);
    expect(store.selected.id, 'builtin-bg2');
    expect(
      find.byKey(const ValueKey('wallpaper-selected-builtin-bg2')),
      findsOneWidget,
    );
    expect(find.byType(VirtualPhoneWallpaperPage), findsOneWidget);
  });

  testWidgets('picker cancellation keeps cards and selected wallpaper', (
    tester,
  ) async {
    var picks = 0;
    await mount(
      tester,
      picker: () async {
        picks++;
        return null;
      },
    );
    await tester.tap(find.byKey(const ValueKey('wallpaper-add-card')));
    await finishOperation(tester);
    expect(picks, 1);
    expect(store.wallpapers.length, 3);
    expect(store.selected.id, 'builtin-bg1');
    expect(find.byKey(const ValueKey('wallpaper-error')), findsNothing);
  });

  testWidgets(
    'import adds a card before plus and selects an independent copy',
    (tester) async {
      await mount(
        tester,
        picker: () async => VirtualPhoneWallpaperImageSelection(
          bytes: image,
          filename: 'my-wallpaper.png',
        ),
      );
      await tester.tap(find.byKey(const ValueKey('wallpaper-add-card')));
      await finishOperation(tester);
      expect(store.wallpapers.length, 4);
      final imported = store.selected;
      expect(imported.isBuiltIn, isFalse);
      expect(_card(imported.id), findsOneWidget);
      expect(
        await tester.runAsync(() => File(imported.filePath!).exists()),
        isTrue,
      );
      final importedRect = tester.getRect(_card(imported.id));
      final addRect = tester.getRect(
        find.byKey(const ValueKey('wallpaper-add-card')),
      );
      expect(importedRect.top, addRect.top);
      expect(importedRect.right, lessThan(addRect.left));
      expect(
        find.byKey(ValueKey('wallpaper-selected-${imported.id}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid image leaves the selected wallpaper and shows an error',
    (tester) async {
      await mount(
        tester,
        picker: () async => VirtualPhoneWallpaperImageSelection(
          bytes: Uint8List.fromList([1, 2, 3]),
          filename: 'broken.png',
        ),
      );
      await tester.tap(find.byKey(const ValueKey('wallpaper-add-card')));
      await finishOperation(tester);
      expect(store.wallpapers.length, 3);
      expect(store.selected.id, 'builtin-bg1');
      expect(find.byKey(const ValueKey('wallpaper-error')), findsOneWidget);
      expect(find.textContaining('图片导入失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pending picker cannot be opened twice', (tester) async {
    final completion = Completer<VirtualPhoneWallpaperImageSelection?>();
    var picks = 0;
    await mount(
      tester,
      picker: () {
        picks++;
        return completion.future;
      },
    );
    final add = find.byKey(const ValueKey('wallpaper-add-card'));
    await tester.tap(add);
    await tester.pump();
    await tester.tap(add);
    await tester.pump();
    expect(picks, 1);
    expect(
      find.byKey(const ValueKey('wallpaper-operation-progress')),
      findsOneWidget,
    );
    completion.complete(null);
    await finishOperation(tester);
    expect(
      find.byKey(const ValueKey('wallpaper-operation-progress')),
      findsNothing,
    );
  });

  testWidgets('default wallpaper cards cannot be selected for deletion', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('wallpaper-delete-mode')));
    await tester.pumpAndSettle();
    await tester.tap(_card('builtin-bg1'));
    await tester.tap(_card('builtin-bg2'));
    await tester.pump();
    final delete = tester.widget<IconButton>(
      find.byKey(const ValueKey('wallpaper-delete-selected')),
    );
    expect(delete.onPressed, isNull);
    expect(find.text('已选 0'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsNWidgets(3));
    expect(store.selected.id, 'builtin-bg1');
    expect(store.wallpapers.length, 3);
  });

  testWidgets('delete confirmation can cancel or remove imported selections', (
    tester,
  ) async {
    final imported = await tester.runAsync(
      () => store.importImage(image, filename: 'imported.png'),
    );
    final second = await tester.runAsync(
      () => store.importImage(image, filename: 'second.png'),
    );
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('wallpaper-delete-mode')));
    await tester.pumpAndSettle();
    await tester.tap(_card(imported!.id));
    await tester.pump();
    await tester.tap(_card(second!.id));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('wallpaper-delete-selected')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('wallpaper-delete-confirmation')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('wallpaper-delete-cancel')));
    await tester.pumpAndSettle();
    expect(store.wallpapers.length, 5);
    expect(find.text('已选 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wallpaper-delete-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wallpaper-delete-confirm')));
    await finishOperation(tester);
    expect(store.wallpapers.length, 3);
    expect(store.selected.id, 'builtin-bg1');
    expect(_card(imported.id), findsNothing);
    expect(_card(second.id), findsNothing);
    expect(
      find.byKey(const ValueKey('wallpaper-delete-selected')),
      findsNothing,
    );
    expect(
      await tester.runAsync(() => File(imported.filePath!).exists()),
      isFalse,
    );
    expect(
      await tester.runAsync(() => File(second.filePath!).exists()),
      isFalse,
    );
    expect(find.byType(VirtualPhoneWallpaperPage), findsOneWidget);
  });

  testWidgets('back exits selection mode before leaving the wallpaper page', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('wallpaper-delete-mode')));
    await tester.pumpAndSettle();
    await phoneNavigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(VirtualPhoneWallpaperPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey('wallpaper-delete-selected')),
      findsNothing,
    );
    await phoneNavigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(VirtualPhoneWallpaperPage), findsNothing);
    expect(find.text('phone-home'), findsOneWidget);
  });

  testWidgets(
    'narrow screen preserves three columns and usable delete controls',
    (tester) async {
      await mount(tester, size: const Size(280, 620));
      final edit = tester.getRect(
        find.byKey(const ValueKey('wallpaper-delete-mode')),
      );
      expect(edit.left, greaterThanOrEqualTo(56));
      expect(edit.width, greaterThanOrEqualTo(40));
      await tester.tap(find.byKey(const ValueKey('wallpaper-delete-mode')));
      await tester.pumpAndSettle();
      for (final id in ['builtin-bg1', 'builtin-bg2', 'builtin-bg3']) {
        expect(_card(id).hitTestable(), findsOneWidget);
      }
      final delete = tester.getRect(
        find.byKey(const ValueKey('wallpaper-delete-selected')),
      );
      expect(delete.right, lessThanOrEqualTo(280));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'open wallpaper page and confirmation follow the global glass switch',
    (tester) async {
      final glass = ValueNotifier(false);
      addTearDown(glass.dispose);
      final imported = await tester.runAsync(
        () => store.importImage(image, filename: 'custom.png'),
      );
      await mount(tester, glass: glass);
      final pageState = tester.state(find.byType(VirtualPhoneWallpaperPage));
      expect(find.byType(BackdropFilter), findsNothing);
      glass.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(
        tester.state(find.byType(VirtualPhoneWallpaperPage)),
        same(pageState),
      );
      expect(store.selected.id, imported!.id);
      expect(
        find.descendant(
          of: _card(imported.id),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('wallpaper-delete-mode')));
      await tester.pumpAndSettle();
      await tester.tap(_card(imported.id));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('wallpaper-delete-selected')));
      await tester.pumpAndSettle();
      Color dialogColor() => tester
          .widget<AlertDialog>(
            find.byKey(const ValueKey('wallpaper-delete-confirmation')),
          )
          .backgroundColor!;
      final glassAlpha = dialogColor().a;
      glass.value = false;
      await tester.pumpAndSettle();
      expect(dialogColor().a, greaterThan(glassAlpha));
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('已选 1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('wallpaper-delete-cancel')));
      await tester.pumpAndSettle();
      expect(store.wallpapers.length, 4);
      expect(tester.takeException(), isNull);
    },
  );
}
