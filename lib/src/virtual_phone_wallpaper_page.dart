import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'glass_ui.dart';
import 'virtual_phone_wallpaper_image.dart';
import 'virtual_phone_wallpapers.dart';

/// A picker result kept separate from platform APIs so the page can be tested.
class VirtualPhoneWallpaperImageSelection {
  const VirtualPhoneWallpaperImageSelection({
    required this.bytes,
    this.filename,
  });

  final Uint8List bytes;
  final String? filename;
}

class VirtualPhoneWallpaperPage extends StatefulWidget {
  const VirtualPhoneWallpaperPage({
    super.key,
    required this.store,
    required this.language,
    this.imagePicker,
    this.liquidGlass = false,
  });

  final VirtualPhoneWallpaperStore store;
  final AppLanguage language;
  final bool liquidGlass;
  final Future<VirtualPhoneWallpaperImageSelection?> Function()? imagePicker;

  @override
  State<VirtualPhoneWallpaperPage> createState() =>
      _VirtualPhoneWallpaperPageState();
}

class _VirtualPhoneWallpaperPageState extends State<VirtualPhoneWallpaperPage> {
  bool _ready = false;
  bool _loadFailed = false;
  bool _working = false;
  bool _confirmingDeletion = false;
  bool _deleteMode = false;
  String? _error;
  final Set<String> _toDelete = {};

  AppLanguage get _language => widget.language;
  bool get _liquidGlass =>
      GlassStyleScope.resolve(context, fallback: widget.liquidGlass);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(VirtualPhoneWallpaperPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      _ready = false;
      _loadFailed = false;
      _deleteMode = false;
      _toDelete.clear();
      _load();
    }
  }

  Future<void> _load() async {
    final store = widget.store;
    try {
      await store.load();
      if (!mounted || store != widget.store) return;
      setState(() {
        _ready = true;
        _loadFailed = false;
      });
    } catch (_) {
      if (!mounted || store != widget.store) return;
      setState(() => _loadFailed = true);
    }
  }

  void _toggleDeleteMode() {
    if (_working) return;
    setState(() {
      _deleteMode = !_deleteMode;
      _toDelete.clear();
      _error = null;
    });
  }

  Future<void> _choose(VirtualPhoneWallpaper wallpaper) async {
    if (_working) return;
    if (_deleteMode) {
      if (wallpaper.isBuiltIn) return;
      setState(() {
        if (!_toDelete.add(wallpaper.id)) _toDelete.remove(wallpaper.id);
      });
      return;
    }
    if (widget.store.selected.id == wallpaper.id) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.store.select(wallpaper.id);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = _language.text(
            '壁纸切换失败，请重试。',
            'Could not change the wallpaper. Please try again.',
            '壁紙を変更できませんでした。もう一度お試しください。',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<VirtualPhoneWallpaperImageSelection?> _pickImage() async {
    if (widget.imagePicker != null) return widget.imagePicker!();
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null) return null;
    if (await file.length() > 24 * 1024 * 1024) {
      throw const FormatException('The image exceeds 24 MB');
    }
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (buffer.length + chunk.length > 24 * 1024 * 1024) {
        throw const FormatException('The image exceeds 24 MB');
      }
      buffer.add(chunk);
    }
    final bytes = buffer.takeBytes();
    if (bytes.isEmpty) {
      throw const FormatException('No image data');
    }
    return VirtualPhoneWallpaperImageSelection(
      bytes: bytes,
      filename: file.name,
    );
  }

  Future<void> _import() async {
    if (_working || _deleteMode) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final image = await _pickImage();
      if (!mounted || image == null) return;
      await widget.store.importImage(image.bytes, filename: image.filename);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = _language.text(
            '图片导入失败，请选择不超过 24 MB 的有效图片后重试。',
            'Could not import the image. Choose a valid image up to 24 MB and try again.',
            '画像を追加できませんでした。24 MB 以下の有効な画像を選んでお試しください。',
          );
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _deleteSelected() async {
    if (_working || _toDelete.isEmpty) return;
    final ids = Set<String>.from(_toDelete);
    // Mark busy before opening the dialog, including the confirmation period.
    setState(() {
      _working = true;
      _confirmingDeletion = true;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        useSafeArea: false,
        builder: (dialogContext) => AlertDialog(
          key: const ValueKey('wallpaper-delete-confirmation'),
          backgroundColor: Theme.of(dialogContext).colorScheme.surface
              .withValues(
                alpha:
                    GlassStyleScope.resolve(
                      dialogContext,
                      fallback: widget.liquidGlass,
                    )
                    ? .76
                    : .94,
              ),
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          title: Text(
            _language.text(
              '删除所选壁纸？',
              'Delete selected wallpapers?',
              '選んだ壁紙を削除しますか？',
            ),
          ),
          content: Text(
            _language.text(
              '将删除 ${ids.length} 张导入壁纸。正在使用的壁纸被删除后会恢复第一张默认壁纸。',
              '${ids.length} imported wallpaper(s) will be deleted. Deleting the current wallpaper restores the first default wallpaper.',
              '追加した壁紙 ${ids.length} 枚を削除します。使用中の壁紙を削除すると、最初の標準壁紙に戻ります。',
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('wallpaper-delete-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(_language.text('取消', 'Cancel', 'キャンセル')),
            ),
            FilledButton(
              key: const ValueKey('wallpaper-delete-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(_language.text('删除', 'Delete', '削除')),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      setState(() => _confirmingDeletion = false);
      await widget.store.deleteImported(ids);
      if (mounted) {
        setState(() {
          _toDelete.clear();
          _deleteMode = false;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = _language.text(
            '壁纸删除失败，请重试。',
            'Could not delete the wallpapers. Please try again.',
            '壁紙を削除できませんでした。もう一度お試しください。',
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _confirmingDeletion = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_deleteMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _deleteMode) _toggleDeleteMode();
      },
      child: AnimatedBuilder(
        animation: widget.store,
        builder: (context, _) => GlassPageSurface(
          liquidGlass: _liquidGlass,
          child: Scaffold(
            key: const ValueKey('virtual-phone-wallpaper-page'),
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              toolbarHeight: 56,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              foregroundColor: colors.onSurface,
              flexibleSpace: GlassSurface(
                liquidGlass: _liquidGlass,
                backdropBlur: false,
                borderRadius: BorderRadius.zero,
                tone: Theme.of(context).brightness == Brightness.dark
                    ? GlassTone.dark
                    : GlassTone.light,
                fallbackColor: glassPageHeaderColor(context),
                child: const SizedBox.expand(),
              ),
              automaticallyImplyLeading: false,
              // The virtual phone's persistent back button occupies the first 50dp.
              leadingWidth: 104,
              leading: Padding(
                padding: const EdgeInsets.only(left: 56),
                child: IconButton(
                  key: const ValueKey('wallpaper-delete-mode'),
                  tooltip: _deleteMode
                      ? _language.text('完成选择', 'Finish selection', '選択を終了')
                      : _language.text(
                          '选择删除的壁纸',
                          'Select wallpapers to delete',
                          '削除する壁紙を選択',
                        ),
                  onPressed: !_ready || _working ? null : _toggleDeleteMode,
                  icon: Icon(
                    _deleteMode
                        ? Icons.check_rounded
                        : Icons.delete_outline_rounded,
                  ),
                ),
              ),
              titleSpacing: 0,
              title: Text(
                _deleteMode
                    ? _language.text(
                        '已选 ${_toDelete.length}',
                        '${_toDelete.length} selected',
                        '${_toDelete.length} 枚選択',
                      )
                    : _language.text('手机壁纸', 'Wallpaper', '壁紙'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 18),
              ),
              actions: [
                if (_deleteMode)
                  IconButton(
                    key: const ValueKey('wallpaper-delete-selected'),
                    tooltip: _language.text(
                      '删除所选壁纸',
                      'Delete selected wallpapers',
                      '選んだ壁紙を削除',
                    ),
                    onPressed: _working || _toDelete.isEmpty
                        ? null
                        : _deleteSelected,
                    icon: const Icon(Icons.delete_rounded),
                  ),
                const SizedBox(width: 6),
              ],
            ),
            body: !_ready
                ? _loading()
                : Column(
                    children: [
                      if (_working && !_confirmingDeletion)
                        const LinearProgressIndicator(
                          key: ValueKey('wallpaper-operation-progress'),
                          minHeight: 2,
                        ),
                      if (_deleteMode)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
                          child: Text(
                            _language.text(
                              '选择要删除的导入壁纸，默认三张壁纸无法删除。',
                              'Select imported wallpapers to delete. The three default wallpapers are protected.',
                              '追加した壁紙を選んで削除できます。標準の3枚は削除できません。',
                            ),
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      if (_error != null) _errorBanner(),
                      Expanded(child: _grid()),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _loading() {
    if (!_loadFailed) {
      return const Center(
        child: CircularProgressIndicator(key: ValueKey('wallpaper-loading')),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _language.text(
                '无法读取壁纸，请重试。',
                'Could not load wallpapers. Please try again.',
                '壁紙を読み込めませんでした。もう一度お試しください。',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('wallpaper-load-retry'),
              onPressed: () {
                setState(() => _loadFailed = false);
                _load();
              },
              child: Text(_language.text('重试', 'Retry', '再試行')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBanner() => Padding(
    key: const ValueKey('wallpaper-error'),
    padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
    child: GlassSurface(
      liquidGlass: _liquidGlass,
      backdropBlur: false,
      fallbackColor: Theme.of(context).colorScheme.errorContainer
          .withValues(alpha: .85),
      borderRadius: BorderRadius.circular(12),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(
            Icons.error_outline_rounded,
            color: Theme.of(context).colorScheme.onErrorContainer,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          IconButton(
            tooltip: _language.text('关闭提示', 'Dismiss', '閉じる'),
            onPressed: () => setState(() => _error = null),
            icon: Icon(
              Icons.close_rounded,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _grid() {
    final wallpapers = widget.store.wallpapers;
    return GridView.builder(
      key: const ValueKey('wallpaper-grid'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: .56,
      ),
      itemCount: wallpapers.length + 1,
      itemBuilder: (context, index) => index == wallpapers.length
          ? _addCard()
          : _wallpaperCard(wallpapers[index]),
    );
  }

  Widget _addCard() => Semantics(
    label: _language.text('导入壁纸', 'Import wallpaper', '壁紙を追加'),
    button: true,
    enabled: !_working && !_deleteMode,
    child: GlassContentCard(
      liquidGlass: _liquidGlass,
      borderRadius: BorderRadius.circular(14),
      child: Material(
        key: const ValueKey('wallpaper-add-card'),
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant
                .withValues(alpha: .6),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _working || _deleteMode ? null : _import,
          child: Icon(
            Icons.add_rounded,
            size: 48,
            color: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: _deleteMode ? .25 : .8),
          ),
        ),
      ),
    ),
  );

  Widget _wallpaperCard(VirtualPhoneWallpaper wallpaper) {
    final selected = _deleteMode
        ? _toDelete.contains(wallpaper.id)
        : widget.store.selected.id == wallpaper.id;
    final protected = _deleteMode && wallpaper.isBuiltIn;
    return Semantics(
      label: wallpaper.name,
      selected: selected,
      button: true,
      enabled: !_working && !protected,
      child: Material(
        key: ValueKey('wallpaper-card-${wallpaper.id}'),
        color: Theme.of(context).colorScheme.surfaceContainerLow
            .withValues(alpha: .8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? const Color(0xFF9ECCFF) : Colors.white24,
            width: selected ? 3 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _working || protected ? null : () => _choose(wallpaper),
          child: Stack(
            fit: StackFit.expand,
            children: [
              LayoutBuilder(
                builder: (context, constraints) => _thumbnail(
                  wallpaper,
                  (constraints.maxWidth *
                          MediaQuery.devicePixelRatioOf(context))
                      .ceil()
                      .clamp(96, 600),
                ),
              ),
              if (protected) const ColoredBox(color: Color(0x77000000)),
              if (selected || _deleteMode)
                Positioned(
                  top: 7,
                  right: 7,
                  child: DecoratedBox(
                    key: selected
                        ? ValueKey('wallpaper-selected-${wallpaper.id}')
                        : null,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF9ECCFF)
                          : Colors.black45,
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        protected
                            ? Icons.lock_outline_rounded
                            : selected
                            ? Icons.check_rounded
                            : Icons.circle_outlined,
                        size: 18,
                        color: selected
                            ? const Color(0xFF12263D)
                            : Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumbnail(VirtualPhoneWallpaper wallpaper, int cacheWidth) {
    Widget error(BuildContext context, Object _, StackTrace? _) =>
        const Center(child: Icon(Icons.broken_image_outlined, size: 30));
    if (wallpaper.assetPath != null) {
      return Image.asset(
        wallpaper.assetPath!,
        fit: BoxFit.cover,
        cacheWidth: cacheWidth,
        errorBuilder: error,
        excludeFromSemantics: true,
      );
    }
    if (wallpaper.filePath != null) {
      return Image(
        image: ResizeImage(
          virtualPhoneWallpaperFileImage(wallpaper.filePath!),
          width: cacheWidth,
        ),
        fit: BoxFit.cover,
        errorBuilder: error,
        excludeFromSemantics: true,
      );
    }
    return error(context, const FormatException('Missing image'), null);
  }
}
