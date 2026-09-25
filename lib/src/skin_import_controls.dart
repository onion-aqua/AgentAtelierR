import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:spine_flutter/spine_flutter.dart' hide Color;

import 'app_localization.dart';
import 'character_appearance.dart';
import 'local_skin_store.dart';
import 'protected_character_assets.dart';
import 'runtime_log.dart';

class SkinImportControls extends StatefulWidget {
  const SkinImportControls({
    super.key,
    required this.appearance,
    required this.language,
    required this.onImported,
    required this.onTextureChanged,
    this.compact = false,
  });
  final CharacterAppearance appearance;
  final AppLanguage language;
  final ValueChanged<CharacterAppearance> onImported;
  final VoidCallback onTextureChanged;
  final bool compact;

  @override
  State<SkinImportControls> createState() => _SkinImportControlsState();
}

class _SkinImportControlsState extends State<SkinImportControls> {
  bool _busy = false;
  String? _error;
  String t(String zh, String en, String ja) => widget.language.text(zh, en, ja);

  Future<Uint8List?> _pick(String extension) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [extension],
    );
    if (result.isEmpty) return null;
    final selected = result.single;
    if (await selected.length() > maxSkinImportBytes) {
      throw const FormatException('Maximum size: 64 MB');
    }
    final bytes = await selected.readAsBytes();
    if (bytes.length > maxSkinImportBytes) {
      throw const FormatException('Maximum size: 64 MB');
    }
    return bytes;
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } on Object catch (error, stack) {
      RuntimeLog.instance.error('SkinImport', error, stack);
      if (mounted) {
        setState(
          () => _error = '${t('导入失败', 'Import failed', '読み込み失敗')}: $error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importZip() async {
    final bytes = await _pick('zip');
    if (bytes == null) return;
    final files = await compute(decodeSkinZip, bytes);
    final base = files.keys
        .firstWhere((name) => name.endsWith('.atlas'))
        .replaceFirst('.atlas', '');
    parseCharacterMotionGroups(utf8.decode(files['${base}_gesture.json']!));
    final bundle = ProtectedCharacterAssetBundle({
      for (final entry in files.entries) 'import/${entry.key}': entry.value,
    });
    final atlas = await Atlas.fromAsset('import/$base.atlas', bundle: bundle);
    try {
      final skeleton = await SkeletonData.fromAsset(
        atlas,
        'import/$base.skel',
        bundle: bundle,
      );
      try {
        if (skeleton.findAnimation('motion_A_001_idle') == null) {
          throw const FormatException('Missing compatible idle animation');
        }
      } finally {
        skeleton.dispose();
      }
    } finally {
      atlas.dispose();
    }
    final record = await LocalSkinStore.instance.importPackage(bytes);
    registerLocalSkinAppearances();
    if (mounted) widget.onImported(characterAppearanceById(record['id']!));
  }

  Future<void> _importTexture() async {
    final bytes = await _pick('png');
    if (bytes == null) return;
    final files = await ProtectedCharacterAssets.originalFilesFor(
      widget.appearance.assetName,
    );
    final pngs = files.entries
        .where((entry) => entry.key.endsWith('.png'))
        .toList();
    if (pngs.length != 1) {
      throw const FormatException('Expected one texture page');
    }
    if (pngSize(bytes) != pngSize(pngs.single.value)) {
      throw FormatException(
        'PNG size ${pngSize(bytes)}; expected ${pngSize(pngs.single.value)}',
      );
    }
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
    await LocalSkinStore.instance.importTexture(
      widget.appearance.assetName,
      bytes,
      pngs.single.value,
    );
    ProtectedCharacterAssets.clearCache();
    if (mounted) widget.onTextureChanged();
  }

  @override
  Widget build(BuildContext context) {
    final store = LocalSkinStore.instance;
    final id = widget.appearance.assetName;
    final importButtons = Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        FilledButton.tonalIcon(
          onPressed: _busy ? null : () => _run(_importZip),
          icon: const Icon(Icons.folder_zip_outlined),
          label: Text(t('导入皮肤 ZIP', 'Import skin ZIP', 'スキン ZIP を追加')),
        ),
        Tooltip(
          message: t(
            'PNG 尺寸及部件位置须与当前服装原图一致，文件上限 64 MB',
            'PNG dimensions and parts must match this outfit. Maximum 64 MB.',
            'PNG のサイズとパーツ配置を合わせてください。上限 64 MB。',
          ),
          child: FilledButton.tonalIcon(
            onPressed: _busy ? null : () => _run(_importTexture),
            icon: const Icon(Icons.texture),
            label: Text(t('导入贴图', 'Import texture', 'テクスチャを追加')),
          ),
        ),
      ],
    );
    final textureChoices = store.hasTexture(id)
        ? Wrap(
            spacing: 8,
            children: [
              for (final enabled in [false, true])
                ChoiceChip(
                  label: Text(
                    enabled
                        ? t('导入贴图', 'Imported texture', '追加テクスチャ')
                        : t('原始贴图', 'Original texture', '元のテクスチャ'),
                  ),
                  selected: store.usesTexture(id) == enabled,
                  onSelected: _busy
                      ? null
                      : (_) => _run(() async {
                          await store.setTextureEnabled(id, enabled);
                          ProtectedCharacterAssets.clearCache();
                          if (mounted) widget.onTextureChanged();
                        }),
                ),
            ],
          )
        : null;
    if (widget.compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          importButtons,
          ?textureChoices,
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(color: Colors.white24),
          Text(
            t('本地皮肤与贴图', 'Local skins and textures', 'ローカルスキンとテクスチャ'),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          importButtons,
          const SizedBox(height: 8),
          Text(
            t(
              'PNG 必须与当前皮肤原图尺寸、部件位置一致。仅替换图集，不改变骨骼；无预览图的皮肤留空。文件上限 64 MB。',
              'PNG dimensions and part layout must match this skin. Skeletons stay unchanged; missing previews stay blank. Maximum 64 MB.',
              'PNG のサイズとパーツ配置は元画像と一致させてください。骨格は変更しません。プレビューがない場合は空欄です。上限 64 MB。',
            ),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          ?textureChoices,
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
        ],
      ),
    );
  }
}
