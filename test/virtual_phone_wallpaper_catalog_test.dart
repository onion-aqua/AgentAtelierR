import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/virtual_phone_wallpaper_catalog.dart';
import 'package:ryza_chat_mvp/src/virtual_phone_wallpapers.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _pngHeader({int width = 1024, int height = 1536}) =>
    Uint8List.fromList([
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      0,
      0,
      0,
      13,
      73,
      72,
      68,
      82,
      width >> 24 & 0xff,
      width >> 16 & 0xff,
      width >> 8 & 0xff,
      width & 0xff,
      height >> 24 & 0xff,
      height >> 16 & 0xff,
      height >> 8 & 0xff,
      height & 0xff,
    ]);

String _catalog(List<Map<String, Object?>> wallpapers) =>
    jsonEncode({'schema_version': 1, 'wallpapers': wallpapers});

Map<String, Object?> _entry({
  String id = 'catalog-purple-sky',
  String path = 'assets/images/virtual_phone/wallpapers/png1.png',
}) => {'id': id, 'name': '紫色夜空', 'asset_path': path};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'valid catalogue keeps only entries whose PNG resource exists',
    () async {
      final result = await loadVirtualPhoneWallpaperCatalog(
        loadString: (_) async => _catalog([
          _entry(),
          _entry(
            id: 'catalog-missing',
            path: 'assets/images/virtual_phone/wallpapers/missing.png',
          ),
        ]),
        loadBytes: (path) async {
          if (path.endsWith('/missing.png')) throw StateError('not found');
          return _pngHeader();
        },
      );

      expect(result, hasLength(1));
      expect(result.single.id, 'catalog-purple-sky');
      expect(result.single.assetPath, endsWith('/png1.png'));
    },
  );

  test('malformed catalogue falls back to no additions', () async {
    final result = await loadVirtualPhoneWallpaperCatalog(
      loadString: (_) async => _catalog([_entry(id: 'builtin-bg1')]),
      loadBytes: (_) async => _pngHeader(),
    );

    expect(result, isEmpty);
  });

  test('parser rejects unsafe paths, duplicate IDs and unknown fields', () {
    expect(
      () => parseVirtualPhoneWallpaperCatalog(
        _catalog([_entry(path: '../png1.png')]),
      ),
      throwsFormatException,
    );
    expect(
      () => parseVirtualPhoneWallpaperCatalog(_catalog([_entry(), _entry()])),
      throwsFormatException,
    );
    expect(
      () => parseVirtualPhoneWallpaperCatalog(
        jsonEncode({
          'schema_version': 1,
          'wallpapers': [_entry()],
          'server': 'https://example.invalid',
        }),
      ),
      throwsFormatException,
    );
  });

  test('oversized PNG dimensions are skipped before UI exposure', () async {
    final result = await loadVirtualPhoneWallpaperCatalog(
      loadString: (_) async => _catalog([_entry()]),
      loadBytes: (_) async => _pngHeader(width: 9000, height: 1),
    );

    expect(result, isEmpty);
  });

  test('catalogue wallpaper deletion persists as a local tombstone', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var directoryRequests = 0;
    Future<List<VirtualPhoneWallpaperCatalogEntry>> provider() async => const [
      VirtualPhoneWallpaperCatalogEntry(
        id: 'catalog-purple-sky',
        name: '紫色夜空',
        assetPath: 'assets/images/virtual_phone/wallpapers/png1.png',
      ),
    ];
    final store = VirtualPhoneWallpaperStore(
      preferences: preferences,
      catalogProvider: provider,
      directoryProvider: () async {
        directoryRequests++;
        throw StateError('Catalog deletion must not access imported files');
      },
    );
    addTearDown(store.dispose);

    await store.load();
    expect(store.wallpapers, hasLength(4));
    final catalogue = store.wallpapers.last;
    expect(catalogue.isBuiltIn, isTrue);
    expect(catalogue.canDelete, isTrue);
    await store.select(catalogue.id);
    await store.deleteImported({catalogue.id});
    expect(store.wallpapers, hasLength(3));
    expect(store.selected.id, 'builtin-bg1');
    expect(directoryRequests, 0);

    final saved = jsonDecode(
      preferences.getString('virtual_phone.wallpapers.v1')!,
    ) as Map<String, dynamic>;
    expect(saved['hidden_catalog_ids'], ['catalog-purple-sky']);
    final reloaded = VirtualPhoneWallpaperStore(
      preferences: preferences,
      catalogProvider: provider,
      directoryProvider: () async => throw StateError('Not needed'),
    );
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.wallpapers, hasLength(3));
    expect(reloaded.selected.id, 'builtin-bg1');
  });
}
