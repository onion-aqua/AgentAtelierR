import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Windows cannot unlink a file retained by a memory-mapped image codec.
/// Decode an independent buffer there so deleting a wallpaper frees its file
/// even when a thumbnail is cached. Android can keep its efficient file decoder.
ImageProvider virtualPhoneWallpaperFileImage(String path) {
  final file = File(path);
  return Platform.isWindows ? _WallpaperBytesFileImage(file) : FileImage(file);
}

class _WallpaperBytesFileImage extends FileImage {
  const _WallpaperBytesFileImage(super.file);

  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _decodeFromBytes(decode),
        scale: key.scale,
        debugLabel: 'Virtual phone wallpaper',
      );

  Future<ui.Codec> _decodeFromBytes(ImageDecoderCallback decode) async {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) throw const FormatException('Empty wallpaper image');
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }
}
