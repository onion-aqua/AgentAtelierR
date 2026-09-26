import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/appearance_picker_page.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/local_skin_store.dart';
import 'package:ryza_chat_mvp/src/skin_import_controls.dart';

final class _PickedPng extends PlatformFile {
  @override
  String get name => 'test.png';

  @override
  Uri get uri => Uri.dataFromBytes(const [1, 2, 3]);

  @override
  XFile get xFile => XFile.fromData(Uint8List.fromList(const [1, 2, 3]));

  @override
  Future<int> length() async => 3;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List.fromList(const [1, 2, 3]);

  @override
  Stream<Uint8List> readAsByteStream() =>
      Stream.value(Uint8List.fromList(const [1, 2, 3]));
}

class _FakeFilePicker extends FilePickerPlatform {
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => [_PickedPng()];
}

void main() {
  Future<void> showPicker(
    WidgetTester tester, {
    required Size size,
    required ValueChanged<CharacterAppearance> onSelected,
    List<CharacterAppearance>? appearances,
    String? selectedId,
    bool liquidGlass = false,
  }) async {
    final items = appearances ?? characterAppearances.take(3).toList();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: AppearancePickerPage(
          appearances: items,
          selectedId: selectedId ?? items.first.id,
          language: AppLanguage.chinese,
          liquidGlass: liquidGlass,
          previewBuilder: (_) => const ColoredBox(color: Colors.white24),
          onSelected: onSelected,
          onTextureChanged: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('swiping browses cards and only the equip button selects', (
    tester,
  ) async {
    CharacterAppearance? selected;
    await showPicker(
      tester,
      size: const Size(390, 760),
      onSelected: (appearance) => selected = appearance,
    );

    expect(find.text('1 / 4'), findsOneWidget);
    await tester.drag(find.byType(AppearancePickerPage), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(find.text('2 / 4'), findsOneWidget);
    expect(selected, isNull);
    await tester.tap(find.byKey(const ValueKey('outfit-equip-button')));
    expect(selected?.id, characterAppearances[1].id);
  });

  testWidgets(
    'exposed card is tappable and import actions live in final card',
    (tester) async {
      await showPicker(tester, size: const Size(320, 568), onSelected: (_) {});

      await tester.tapAt(const Offset(300, 260));
      await tester.pumpAndSettle();
      expect(find.text('2 / 4'), findsOneWidget);
      expect(find.byKey(const ValueKey('outfit-import-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('import-outfit-zip')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('import-outfit-texture')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('outfit-equip-button')), findsOneWidget);
      expect(find.byTooltip('上一套'), findsNothing);
      expect(find.byTooltip('下一套'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('landscape picker keeps controls on screen', (tester) async {
    await showPicker(tester, size: const Size(640, 360), onSelected: (_) {});
    expect(find.text('导入 ZIP'), findsOneWidget);
    expect(find.text('导入贴图'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'last card splits ZIP and texture actions and asks texture target',
    (tester) async {
      final originalPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _FakeFilePicker();
      addTearDown(() => FilePickerPlatform.instance = originalPicker);
      await showPicker(
        tester,
        size: const Size(390, 760),
        onSelected: (_) => fail('Import card cannot equip an outfit'),
      );
      for (var step = 0; step < 3; step++) {
        await tester.drag(
          find.byType(AppearancePickerPage),
          const Offset(-220, 0),
        );
        await tester.pumpAndSettle();
      }
      expect(find.text('4 / 4'), findsOneWidget);
      final zip = find.byKey(const ValueKey('import-outfit-zip'));
      final texture = find.byKey(const ValueKey('import-outfit-texture'));
      expect(
        tester.getSize(zip).height,
        closeTo(tester.getSize(texture).height, 1),
      );
      expect(
        tester.getBottomLeft(zip).dy,
        lessThan(tester.getTopLeft(texture).dy),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('outfit-equip-button')),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(texture);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('选择贴图对应的服装'), findsOneWidget);
      expect(
        find.byKey(ValueKey('texture-target-${characterAppearances.first.id}')),
        findsOneWidget,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('选择贴图对应的服装'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'newly imported outfit appears before import card without equipping',
    (tester) async {
      CharacterAppearance? selected;
      await showPicker(
        tester,
        size: const Size(390, 760),
        onSelected: (value) => selected = value,
      );
      tester
          .widget<SkinImportControls>(find.byType(SkinImportControls))
          .onImported(characterAppearances[3]);
      await tester.pumpAndSettle();
      expect(find.text('4 / 5'), findsOneWidget);
      expect(selected, isNull);
      expect(find.byKey(ValueKey(characterAppearances[3].id)), findsOneWidget);
      expect(find.byKey(const ValueKey('outfit-import-card')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('outfit-equip-button')));
      expect(selected?.id, characterAppearances[3].id);
    },
  );

  testWidgets('right card paints over the focused card', (tester) async {
    await showPicker(
      tester,
      size: const Size(390, 760),
      appearances: characterAppearances.take(6).toList(),
      selectedId: characterAppearances[4].id,
      onSelected: (_) {},
    );

    expect(find.text('5 / 7'), findsOneWidget);
    final cards = tester
        .widgetList<Positioned>(find.byType(Positioned))
        .where((card) => card.key is ValueKey<String>)
        .map((card) => (card.key! as ValueKey<String>).value)
        .toList();
    expect(cards, [
      characterAppearances[1].id,
      'outfit-import-card',
      characterAppearances[2].id,
      characterAppearances[3].id,
      characterAppearances[4].id,
      characterAppearances[5].id,
    ]);

    await tester.tapAt(const Offset(310, 340));
    await tester.pumpAndSettle();
    expect(find.text('6 / 7'), findsOneWidget);
  });

  testWidgets('incoming right card eases longer and follows glass setting', (
    tester,
  ) async {
    await showPicker(
      tester,
      size: const Size(390, 760),
      liquidGlass: true,
      onSelected: (_) {},
    );
    expect(
      tester
          .widget<GlassPageSurface>(find.byType(GlassPageSurface))
          .liquidGlass,
      isTrue,
    );
    expect(
      tester
          .widget<GlassSurface>(
            find.byKey(
              ValueKey('outfit-surface-${characterAppearances.first.id}'),
            ),
          )
          .liquidGlass,
      isTrue,
    );

    await tester.drag(find.byType(AppearancePickerPage), const Offset(-220, 0));
    await tester.pump();
    final focused = tester.widget<AnimatedSlide>(
      find.descendant(
        of: find.byKey(ValueKey(characterAppearances[1].id)),
        matching: find.byType(AnimatedSlide),
      ),
    );
    final incoming = tester.widget<AnimatedSlide>(
      find.descendant(
        of: find.byKey(ValueKey(characterAppearances[2].id)),
        matching: find.byType(AnimatedSlide),
      ),
    );
    final outgoing = tester.widget<AnimatedSlide>(
      find.descendant(
        of: find.byKey(ValueKey(characterAppearances.first.id)),
        matching: find.byType(AnimatedSlide),
      ),
    );
    expect(focused.duration, const Duration(milliseconds: 680));
    expect(incoming.duration, const Duration(milliseconds: 760));
    expect(outgoing.duration, const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('outfit and import cards use a restrained translucent fill', (
    tester,
  ) async {
    for (final liquidGlass in [false, true]) {
      await showPicker(
        tester,
        size: const Size(390, 760),
        liquidGlass: liquidGlass,
        onSelected: (_) {},
      );
      for (final key in [
        ValueKey('outfit-surface-${characterAppearances.first.id}'),
        const ValueKey('outfit-import-surface'),
      ]) {
        final finder = find.byKey(key);
        final surface = tester.widget<GlassSurface>(finder);
        expect(surface.transparentFill, isFalse);
        expect(surface.fillOpacity, .65);
        final fills = tester
            .widgetList<DecoratedBox>(
              find.descendant(of: finder, matching: find.byType(DecoratedBox)),
            )
            .map((box) => box.decoration)
            .whereType<BoxDecoration>();
        final fill = fills.firstWhere((decoration) => decoration.color != null);
        expect(fill.color!.a, inInclusiveRange(.2, .6));
        expect(fill.gradient, liquidGlass ? isNotNull : isNull);
      }
    }
  });

  testWidgets('next right card slides in from offscreen on each left swipe', (
    tester,
  ) async {
    const screenWidth = 390.0;
    await showPicker(
      tester,
      size: const Size(screenWidth, 760),
      appearances: characterAppearances.take(5).toList(),
      onSelected: (_) {},
    );

    for (final index in [2, 3]) {
      final card = find.byKey(ValueKey(characterAppearances[index].id));
      final surface = find.byKey(
        ValueKey('outfit-surface-${characterAppearances[index].id}'),
      );
      final initialLeft = tester.getTopLeft(surface).dx;
      expect(initialLeft, greaterThanOrEqualTo(screenWidth));

      await tester.drag(
        find.byType(AppearancePickerPage),
        const Offset(-220, 0),
      );
      await tester.pump();
      expect(tester.getTopLeft(surface).dx, closeTo(initialLeft, 0.01));
      final slide = tester.widget<AnimatedSlide>(
        find.descendant(of: card, matching: find.byType(AnimatedSlide)),
      );
      expect(slide.curve, Curves.easeInOutSine);
      expect(slide.duration, const Duration(milliseconds: 760));

      await tester.pump(const Duration(milliseconds: 80));
      final earlyLeft = tester.getTopLeft(surface).dx;
      await tester.pump(const Duration(milliseconds: 120));
      final middleLeft = tester.getTopLeft(surface).dx;

      await tester.pumpAndSettle();
      final finalLeft = tester.getTopLeft(surface).dx;
      expect(earlyLeft, lessThan(initialLeft));
      expect(middleLeft, lessThan(earlyLeft));
      expect(finalLeft, lessThan(middleLeft));
      expect(initialLeft - earlyLeft, lessThan((initialLeft - finalLeft) * .2));
      expect(finalLeft, lessThan(screenWidth));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('imported texture can be deleted from its card menu', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalSkinStore.instance;
    final png = Uint8List(33)
      ..setAll(0, [137, 80, 78, 71, 13, 10, 26, 10])
      ..setAll(12, 'IHDR'.codeUnits);
    ByteData.sublistView(png)
      ..setUint32(16, 2)
      ..setUint32(20, 2);
    final appearance = characterAppearances.first;
    final directory = await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('outfit_delete_');
      await store.initialize(storageDirectory: directory);
      await store.importTexture(appearance.assetName, png, png);
      return directory;
    });
    addTearDown(() => directory?.delete(recursive: true));
    final textureFile = Directory('${directory!.path}/imported_skins')
        .listSync()
        .whereType<File>()
        .single;
    await showPicker(tester, size: const Size(390, 760), onSelected: (_) {});

    Future<void> openMenu() async {
      await tester.tap(
        find.byKey(ValueKey('outfit-texture-menu-${appearance.id}')),
      );
      await tester.pumpAndSettle();
    }

    await openMenu();
    await tester.tap(
      find.byKey(ValueKey('outfit-delete-texture-${appearance.id}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除导入贴图？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.hasTexture(appearance.assetName), isTrue);

    await openMenu();
    await tester.tap(
      find.byKey(ValueKey('outfit-delete-texture-${appearance.id}')),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('删除'));
      for (
        var attempt = 0;
        attempt < 100 && await textureFile.exists();
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
    for (
      var attempt = 0;
      attempt < 10 &&
          find
              .byKey(ValueKey('outfit-texture-menu-${appearance.id}'))
              .evaluate()
              .isNotEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(store.hasTexture(appearance.assetName), isFalse);
    expect(
      find.byKey(ValueKey('outfit-texture-menu-${appearance.id}')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
