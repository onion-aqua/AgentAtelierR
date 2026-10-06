import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/virtual_phone_wallpapers.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _preferenceKey = 'virtual_phone.wallpapers.v1';

Future<Uint8List> _png({int width = 3, int height = 5}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff277dda),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences preferences;
  late Directory directory;
  late VirtualPhoneWallpaperStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    directory = await Directory.systemTemp.createTemp('aar_phone_wallpapers_');
    store = VirtualPhoneWallpaperStore(
      preferences: preferences,
      directoryProvider: () async => directory,
    );
  });

  tearDown(() async {
    store.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'empty or bundled-only settings do not request a platform directory',
    () async {
      var calls = 0;
      final bundledStore = VirtualPhoneWallpaperStore(
        preferences: preferences,
        directoryProvider: () async {
          calls++;
          throw StateError('Directory should not be needed.');
        },
      );
      addTearDown(bundledStore.dispose);

      await bundledStore.load();
      expect(bundledStore.wallpapers.map((wallpaper) => wallpaper.id), [
        'builtin-bg1',
        'builtin-bg2',
        'builtin-bg3',
      ]);
      expect(bundledStore.selected.id, 'builtin-bg1');
      await bundledStore.select('builtin-bg2');
      await bundledStore.deleteImported({'builtin-bg1', 'builtin-bg2'});
      await bundledStore.load();
      expect(bundledStore.wallpapers.length, 3);
      expect(bundledStore.selected.id, 'builtin-bg2');
      expect(calls, 0);

      final reloaded = VirtualPhoneWallpaperStore(
        preferences: preferences,
        directoryProvider: () async => throw StateError('Not needed.'),
      );
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.selected.id, 'builtin-bg2');
    },
  );

  test('imports an independent image copy and restores relative metadata', () async {
    final source = File(
      '${directory.parent.path}/phone-source-${directory.uri.pathSegments.where((segment) => segment.isNotEmpty).last}.png',
    );
    await source.writeAsBytes(await _png());
    addTearDown(() async {
      if (await source.exists()) await source.delete();
    });
    final wallpaper = await store.importImage(
      await source.readAsBytes(),
      filename: source.path,
    );
    final imported = File(wallpaper.filePath!);
    expect(wallpaper.isBuiltIn, false);
    expect(store.selected.id, wallpaper.id);
    expect(imported.parent.path, directory.path);
    expect(await imported.exists(), true);
    expect(wallpaper.name, startsWith('phone-source-'));
    final raw = preferences.getString(_preferenceKey)!;
    expect(raw, isNot(contains(directory.path)));
    expect(raw, isNot(contains(source.path)));
    expect(
      (jsonDecode(raw)['imports'] as List).single['filename'],
      '${wallpaper.id}.png',
    );

    await source.delete();
    final reloaded = VirtualPhoneWallpaperStore(
      preferences: preferences,
      directoryProvider: () async => directory,
    );
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.wallpapers.length, 4);
    expect(reloaded.selected.id, wallpaper.id);
    expect(await File(reloaded.selected.filePath!).exists(), true);
  });

  test(
    'batch deletion protects bundled images and persists selected fallback',
    () async {
      final first = await store.importImage(await _png(), filename: 'one.png');
      final second = await store.importImage(await _png(), filename: 'two.png');
      final untouched = File('${directory.path}/user-original.png');
      await untouched.writeAsBytes(await _png());

      await store.deleteImported({
        first.id,
        second.id,
        'builtin-bg1',
        'builtin-bg3',
      });
      expect(store.wallpapers.length, 3);
      expect(store.selected.id, 'builtin-bg1');
      expect(await File(first.filePath!).exists(), false);
      expect(await File(second.filePath!).exists(), false);
      expect(await untouched.exists(), true);

      final reloaded = VirtualPhoneWallpaperStore(
        preferences: preferences,
        directoryProvider: () async => directory,
      );
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.wallpapers.length, 3);
      expect(reloaded.selected.id, 'builtin-bg1');
    },
  );

  test('deleting another wallpaper retains the current selection', () async {
    final first = await store.importImage(await _png());
    final second = await store.importImage(await _png());
    await store.deleteImported({first.id});
    expect(store.selected.id, second.id);
    expect(store.wallpapers.length, 4);
    expect(await File(second.filePath!).exists(), true);
  });

  test(
    'invalid and oversized images leave files and selection unchanged',
    () async {
      await store.select('builtin-bg3');
      final saved = preferences.getString(_preferenceKey);
      await expectLater(
        store.importImage(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      await expectLater(
        store.importImage(Uint8List(24 * 1024 * 1024 + 1)),
        throwsFormatException,
      );
      expect(store.wallpapers.length, 3);
      expect(store.selected.id, 'builtin-bg3');
      expect(preferences.getString(_preferenceKey), saved);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'normalizes large wallpapers before storing or displaying them',
    () async {
      final wallpaper = await store.importImage(
        await _png(width: 3000, height: 60),
        filename: 'wide.png',
      );
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        await File(wallpaper.filePath!).readAsBytes(),
      );
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      expect(descriptor.width, 2560);
      expect(descriptor.height, 51);
      descriptor.dispose();
      buffer.dispose();
    },
  );

  test('serializes mutations, snapshots imported bytes, and recovers after an error', () async {
    final bytes = await _png();
    final first = store.importImage(bytes, filename: 'first.png');
    bytes.fillRange(0, bytes.length, 0);
    final failed = store.importImage(Uint8List.fromList([1, 2, 3]));
    final failureCheck = expectLater(failed, throwsFormatException);
    final second = store.importImage(await _png(), filename: 'second.png');
    final selected = store.select('builtin-bg2');
    final firstWallpaper = await first;
    await failureCheck;
    final secondWallpaper = await second;
    await selected;

    expect(store.wallpapers.map((wallpaper) => wallpaper.id), [
      'builtin-bg1',
      'builtin-bg2',
      'builtin-bg3',
      firstWallpaper.id,
      secondWallpaper.id,
    ]);
    expect(store.selected.id, 'builtin-bg2');
    expect(
      jsonDecode(preferences.getString(_preferenceKey)!)['selected'],
      'builtin-bg2',
    );
  });

  test(
    'load drops missing and corrupt imported files and falls back safely',
    () async {
      final first = await store.importImage(await _png());
      final second = await store.importImage(await _png());
      await File(first.filePath!).delete();
      await File(second.filePath!).writeAsBytes([1, 2, 3]);

      final reloaded = VirtualPhoneWallpaperStore(
        preferences: preferences,
        directoryProvider: () async => directory,
      );
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.wallpapers.length, 3);
      expect(reloaded.selected.id, 'builtin-bg1');
      expect(
        jsonDecode(preferences.getString(_preferenceKey)!)['imports'],
        isEmpty,
      );
    },
  );

  test(
    'rejects paths and imported IDs that could escape managed storage',
    () async {
      final original = File('${directory.path}/original.png');
      await original.writeAsBytes(await _png());
      const id = 'imported-0123456789abcdef0123456789abcdef';
      await preferences.setString(
        _preferenceKey,
        jsonEncode({
          'selected': id,
          'imports': [
            {'id': id, 'name': 'unsafe', 'filename': '../original.png'},
            {
              'id': '../original',
              'name': 'unsafe',
              'filename': '../original.png',
            },
            {
              'id': 'builtin-bg1',
              'name': 'fake builtin',
              'filename': 'original.png',
            },
          ],
        }),
      );
      await store.load();
      await store.deleteImported({id, '../original', 'builtin-bg1'});
      expect(store.wallpapers.length, 3);
      expect(store.selected.id, 'builtin-bg1');
      expect(await original.exists(), true);
    },
  );

  test(
    'startup IO failures retain metadata and allow later recovery',
    () async {
      final wallpaper = await store.importImage(await _png());
      final persisted = preferences.getString(_preferenceKey);
      final unavailable = VirtualPhoneWallpaperStore(
        preferences: preferences,
        directoryProvider: () async =>
            throw const FileSystemException('unavailable'),
      );
      addTearDown(unavailable.dispose);
      await unavailable.load();
      expect(unavailable.selected.id, 'builtin-bg1');
      expect(preferences.getString(_preferenceKey), persisted);

      final recovered = VirtualPhoneWallpaperStore(
        preferences: preferences,
        directoryProvider: () async => directory,
      );
      addTearDown(recovered.dispose);
      await recovered.load();
      expect(recovered.selected.id, wallpaper.id);
    },
  );

  test('malformed preferences recover without a platform directory', () async {
    await preferences.setString(_preferenceKey, '{broken json');
    await store.load();
    expect(store.wallpapers.length, 3);
    expect(store.selected.id, 'builtin-bg1');
    expect(
      jsonDecode(preferences.getString(_preferenceKey)!)['imports'],
      isEmpty,
    );
    await expectLater(store.select('nonexistent'), throwsStateError);
    await store.select('builtin-bg2');
    expect(store.selected.id, 'builtin-bg2');
  });

  test('wrong preference types recover without failing app startup', () async {
    await preferences.setInt(_preferenceKey, 123);
    await store.load();
    expect(store.selected.id, 'builtin-bg1');
    expect(store.wallpapers.length, 3);
    expect(
      jsonDecode(preferences.getString(_preferenceKey)!)['imports'],
      isEmpty,
    );
  });

  test(
    'rejects huge image dimensions before decoding the full image',
    () async {
      await expectLater(
        store.importImage(await _png(width: 8193, height: 1)),
        throwsFormatException,
      );
      expect(store.selected.id, 'builtin-bg1');
      expect(store.wallpapers.length, 3);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'an import storage failure leaves selected state and metadata intact',
    () async {
      await store.select('builtin-bg2');
      final saved = preferences.getString(_preferenceKey);
      final failing = VirtualPhoneWallpaperStore(
        preferences: preferences,
        directoryProvider: () async =>
            throw const FileSystemException('unwritable'),
      );
      addTearDown(failing.dispose);
      await failing.load();
      await expectLater(
        failing.importImage(await _png()),
        throwsA(isA<FileSystemException>()),
      );
      expect(failing.selected.id, 'builtin-bg2');
      expect(failing.wallpapers.length, 3);
      expect(preferences.getString(_preferenceKey), saved);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'finishing an in-flight import after disposal does not notify listeners',
    () async {
      final ready = Completer<Directory>();
      final entered = Completer<void>();
      var notifications = 0;
      final temporaryStore = VirtualPhoneWallpaperStore(
        preferences: preferences,
        directoryProvider: () {
          entered.complete();
          return ready.future;
        },
      );
      temporaryStore.addListener(() => notifications++);
      final pending = temporaryStore.importImage(await _png());
      await entered.future;
      final before = notifications;
      temporaryStore.dispose();
      ready.complete(directory);
      await pending;
      expect(notifications, before);
    },
  );
}
