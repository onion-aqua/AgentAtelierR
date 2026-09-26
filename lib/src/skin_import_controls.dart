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
    required this.appearances,
    required this.language,
    required this.onImported,
    required this.onTextureChanged,
  });

  final List<CharacterAppearance> appearances;
  final AppLanguage language;
  final ValueChanged<CharacterAppearance> onImported;
  final ValueChanged<CharacterAppearance> onTextureChanged;

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

  Future<CharacterAppearance?> _chooseTextureTarget() async {
    return showDialog<CharacterAppearance>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t('选择贴图对应的服装', 'Choose outfit for texture', 'テクスチャの衣装を選択')),
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        content: SizedBox(
          width: 360,
          height: (MediaQuery.sizeOf(dialogContext).height * .5).clamp(
            160.0,
            400.0,
          ),
          child: ListView.builder(
            itemCount: widget.appearances.length,
            itemBuilder: (context, index) {
              final appearance = widget.appearances[index];
              return ListTile(
                key: ValueKey('texture-target-${appearance.id}'),
                leading: const Icon(Icons.checkroom_outlined),
                title: Text(appearance.label, maxLines: 2),
                onTap: () => Navigator.of(dialogContext).pop(appearance),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t('取消', 'Cancel', 'キャンセル')),
          ),
        ],
      ),
    );
  }

  Future<void> _importTexture() async {
    final bytes = await _pick('png');
    if (bytes == null || !mounted) return;
    final appearance = await _chooseTextureTarget();
    if (appearance == null || !mounted) return;
    final files = await ProtectedCharacterAssets.originalFilesFor(
      appearance.assetName,
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
      appearance.assetName,
      bytes,
      pngs.single.value,
    );
    ProtectedCharacterAssets.clearCache();
    if (mounted) widget.onTextureChanged(appearance);
  }

  Widget _action({
    required Key key,
    required String label,
    required VoidCallback onTap,
  }) {
    final color = Theme.of(context).colorScheme.onSurface;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        key: key,
        onTap: _busy ? null : onTap,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded, size: 64, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Column(
        children: [
          Expanded(
            child: _action(
              key: const ValueKey('import-outfit-zip'),
              label: t('导入 ZIP', 'Import ZIP', 'ZIP を読み込む'),
              onTap: () => _run(_importZip),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _action(
              key: const ValueKey('import-outfit-texture'),
              label: t('导入贴图', 'Import texture', 'テクスチャを読み込む'),
              onTap: () => _run(_importTexture),
            ),
          ),
        ],
      ),
      if (_busy) const Center(child: CircularProgressIndicator()),
      if (_error != null)
        Positioned(
          left: 12,
          right: 12,
          bottom: 6,
          child: Text(
            _error!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
          ),
        ),
    ],
  );
}
