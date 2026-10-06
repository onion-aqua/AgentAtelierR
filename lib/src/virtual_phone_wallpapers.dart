import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class VirtualPhoneWallpaper {
  const VirtualPhoneWallpaper({
    required this.id,
    required this.name,
    this.assetPath,
    this.filePath,
  }) : assert((assetPath == null) != (filePath == null));

  final String id;
  final String name;
  final String? assetPath;
  final String? filePath;

  bool get isBuiltIn => assetPath != null;
}

/// Owns independent copies of imported wallpapers; never stores source paths.
class VirtualPhoneWallpaperStore extends ChangeNotifier {
  VirtualPhoneWallpaperStore({
    required SharedPreferences preferences,
    Future<Directory> Function()? directoryProvider,
    // Preserve the public named argument and private storage field.
    // ignore: prefer_initializing_formals
  }) : _preferences = preferences,
       _directoryProvider = directoryProvider ?? _defaultDirectory;

  static const _preferenceKey = 'virtual_phone.wallpapers.v1';
  static const _maxInputBytes = 24 * 1024 * 1024;
  static const _maxSourceEdge = 8192;
  static const _maxSourcePixels = 32000000;
  static const _maxStoredEdge = 2560;
  static final _importId = RegExp(r'^imported-[0-9a-f]{32}$');
  static final _random = math.Random.secure();
  static const _builtIns = <VirtualPhoneWallpaper>[
    VirtualPhoneWallpaper(
      id: 'builtin-bg1',
      name: '海边工坊',
      assetPath: 'assets/images/virtual_phone/bg1.png',
    ),
    VirtualPhoneWallpaper(
      id: 'builtin-bg2',
      name: '林间遗迹',
      assetPath: 'assets/images/virtual_phone/bg2.png',
    ),
    VirtualPhoneWallpaper(
      id: 'builtin-bg3',
      name: '落日海岸',
      assetPath: 'assets/images/virtual_phone/bg3.png',
    ),
  ];

  final SharedPreferences _preferences;
  final Future<Directory> Function() _directoryProvider;
  List<VirtualPhoneWallpaper> _wallpapers = [..._builtIns];
  String _selectedId = _builtIns.first.id;
  Future<void> _operations = Future<void>.value();
  Directory? _directory;
  bool _loaded = false;
  bool _disposed = false;

  List<VirtualPhoneWallpaper> get wallpapers => List.unmodifiable(_wallpapers);

  VirtualPhoneWallpaper get selected => _wallpapers.firstWhere(
    (wallpaper) => wallpaper.id == _selectedId,
    orElse: () => _builtIns.first,
  );

  Future<void> load() => _enqueue(_load);

  Future<void> select(String id) => _enqueue(() async {
    await _load();
    final matches = _wallpapers.where((wallpaper) => wallpaper.id == id);
    if (matches.isEmpty) throw StateError('壁纸不存在，请重新选择。');
    final wallpaper = matches.first;
    if (!wallpaper.isBuiltIn &&
        !await _isManagedFile(await _managedDirectory(), '$id.png')) {
      throw StateError('壁纸文件已丢失，请重新导入。');
    }
    if (_selectedId == id) return;
    await _persist(_wallpapers, id);
    _selectedId = id;
    _notify();
  });

  Future<VirtualPhoneWallpaper> importImage(
    Uint8List bytes, {
    String? filename,
  }) {
    // Keep a stable snapshot while an earlier operation is still in flight.
    if (bytes.isEmpty || bytes.length > _maxInputBytes) {
      return Future.error(const FormatException('请选择小于 24 MB 的有效图片。'));
    }
    final input = Uint8List.fromList(bytes);
    return _enqueue(() async {
      await _load();
      final normalized = await _normalizeImage(input);
      final directory = await _managedDirectory();
      final id = _newId();
      final file = _file(directory, '$id.png');
      final temporary = _file(directory, '$id.pending');
      final wallpaper = VirtualPhoneWallpaper(
        id: id,
        name: _displayName(filename),
        filePath: file.path,
      );
      try {
        await temporary.writeAsBytes(normalized, flush: true);
        await temporary.rename(file.path);
        final next = [..._wallpapers, wallpaper];
        await _persist(next, id);
        _wallpapers = next;
        _selectedId = id;
        _notify();
        return wallpaper;
      } catch (_) {
        await _removeOwnedFile(directory, '$id.pending');
        await _removeOwnedFile(directory, '$id.png');
        rethrow;
      }
    });
  }

  Future<void> deleteImported(Set<String> ids) {
    final requested = Set<String>.of(ids);
    return _enqueue(() async {
      await _load();
      final removed = _wallpapers
          .where(
            (wallpaper) =>
                !wallpaper.isBuiltIn && requested.contains(wallpaper.id),
          )
          .toList();
      if (removed.isEmpty) return;
      final removedIds = removed.map((wallpaper) => wallpaper.id).toSet();
      final next = _wallpapers
          .where((wallpaper) => !removedIds.contains(wallpaper.id))
          .toList();
      final nextSelection = removedIds.contains(_selectedId)
          ? _builtIns.first.id
          : _selectedId;
      // Persist first: a failed write must not erase a selected image.
      await _persist(next, nextSelection);
      _wallpapers = next;
      _selectedId = nextSelection;
      _notify();
      final directory = await _managedDirectory();
      for (final wallpaper in removed) {
        await _removeOwnedFile(directory, '${wallpaper.id}.png');
      }
    });
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    if (_disposed) return Future.error(StateError('壁纸管理已关闭。'));
    final result = _operations.then((_) async {
      if (_disposed) throw StateError('壁纸管理已关闭。');
      return operation();
    });
    // One failed import must not prevent later selections or imports.
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _load() async {
    if (_loaded) return;
    final storedValue = _preferences.get(_preferenceKey);
    final raw = storedValue is String ? storedValue : null;
    var selectedId = _builtIns.first.id;
    final imports = <VirtualPhoneWallpaper>[];
    var canRewrite = true;
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final selected = decoded['selected'];
          if (selected is String) selectedId = selected;
          final items = decoded['imports'];
          if (items is List && items.isNotEmpty) {
            Directory? directory;
            final seen = <String>{};
            for (final item in items) {
              if (item is! Map<String, dynamic>) continue;
              final id = item['id'];
              final filename = item['filename'];
              final name = item['name'];
              if (id is! String ||
                  !_importId.hasMatch(id) ||
                  filename != '$id.png' ||
                  name is! String ||
                  !seen.add(id)) {
                continue;
              }
              directory ??= await _managedDirectory();
              if (!await _isManagedFile(directory, filename as String)) {
                continue;
              }
              imports.add(
                VirtualPhoneWallpaper(
                  id: id,
                  name: _displayName(name, stripExtension: false),
                  filePath: _file(directory, filename).path,
                ),
              );
            }
          }
        }
      } on FormatException {
        // Corrupt metadata cannot hide the three bundled wallpapers.
      } on FileSystemException {
        imports.clear();
        canRewrite = false;
      } on PlatformException {
        imports.clear();
        canRewrite = false;
      } on MissingPluginException {
        imports.clear();
        canRewrite = false;
      } catch (_) {
        imports.clear();
        canRewrite = false;
      }
    }
    final next = [..._builtIns, ...imports];
    if (!next.any((wallpaper) => wallpaper.id == selectedId)) {
      selectedId = _builtIns.first.id;
    }
    if (canRewrite && storedValue != null && raw != _encode(next, selectedId)) {
      try {
        await _persist(next, selectedId);
      } catch (_) {
        // A local settings write must not prevent the app from starting.
      }
    }
    _wallpapers = next;
    _selectedId = selectedId;
    _loaded = true;
    _notify();
  }

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(
      '${support.path}${Platform.pathSeparator}virtual_phone_wallpapers',
    );
  }

  Future<Directory> _managedDirectory() async {
    if (_directory case final directory?) return directory;
    final directory = (await _directoryProvider()).absolute;
    await directory.create(recursive: true);
    final resolved = Directory(await directory.resolveSymbolicLinks());
    _directory = resolved;
    return resolved;
  }

  static File _file(Directory directory, String filename) =>
      File('${directory.path}${Platform.pathSeparator}$filename');

  static Future<bool> _isManagedFile(
    Directory directory,
    String filename,
  ) async {
    final file = _file(directory, filename);
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      if (await file.resolveSymbolicLinks() != file.absolute.path) return false;
      final length = await file.length();
      if (length <= 0 || length > _maxInputBytes) return false;
      return await _isStoredImage(await file.readAsBytes());
    } on FileSystemException {
      return false;
    }
  }

  static Future<bool> _isStoredImage(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 ||
          descriptor.height <= 0 ||
          descriptor.width > _maxStoredEdge ||
          descriptor.height > _maxStoredEdge) {
        return false;
      }
      codec = await descriptor.instantiateCodec(
        targetWidth: 1,
        targetHeight: 1,
      );
      image = (await codec.getNextFrame()).image;
      return true;
    } catch (_) {
      return false;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static Future<void> _removeOwnedFile(
    Directory directory,
    String filename,
  ) async {
    final attempts = Platform.isWindows ? 4 : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        // Revalidate after every wait; never follow a substituted symlink.
        final file = _file(directory, filename);
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          return;
        }
        if (await file.resolveSymbolicLinks() != file.absolute.path) return;
        await file.delete();
        return;
      } on FileSystemException {
        if (attempt + 1 >= attempts) return;
        // A preview can briefly be reading this file when deletion is tapped.
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
  }

  static Future<Uint8List> _normalizeImage(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 ||
          height <= 0 ||
          width > _maxSourceEdge ||
          height > _maxSourceEdge ||
          width * height > _maxSourcePixels) {
        throw const FormatException('图片尺寸过大，请先缩小图片。');
      }
      final scale = math.min(1.0, _maxStoredEdge / math.max(width, height));
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (width * scale).round()),
        targetHeight: math.max(1, (height * scale).round()),
      );
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || data.lengthInBytes > _maxInputBytes) {
        throw const FormatException('图片无法保存，请尝试其他图片。');
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('无法读取图片，请选择有效的图片文件。');
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static String _newId() =>
      'imported-${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  static String _displayName(String? filename, {bool stripExtension = true}) {
    var name = (filename ?? '').split(RegExp(r'[/\\]')).last.trim();
    if (stripExtension) name = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    if (name.isEmpty) return '自定义壁纸';
    return name.runes.take(80).map(String.fromCharCode).join();
  }

  String _encode(List<VirtualPhoneWallpaper> wallpapers, String selectedId) =>
      jsonEncode({
        'selected': selectedId,
        'imports': [
          for (final wallpaper in wallpapers)
            if (!wallpaper.isBuiltIn)
              {
                'id': wallpaper.id,
                'name': wallpaper.name,
                'filename': '${wallpaper.id}.png',
              },
        ],
      });

  Future<void> _persist(
    List<VirtualPhoneWallpaper> wallpapers,
    String selectedId,
  ) async {
    if (!await _preferences.setString(
      _preferenceKey,
      _encode(wallpapers, selectedId),
    )) {
      throw StateError('壁纸设置保存失败，请重试。');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
