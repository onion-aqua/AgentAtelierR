import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_localization.dart';
import 'character_appearance.dart';
import 'glass_ui.dart';
import 'local_skin_store.dart';
import 'protected_character_assets.dart';
import 'skin_import_controls.dart';

class AppearancePickerPage extends StatefulWidget {
  const AppearancePickerPage({
    super.key,
    required this.appearances,
    required this.selectedId,
    required this.language,
    required this.liquidGlass,
    required this.previewBuilder,
    required this.onSelected,
    required this.onTextureChanged,
  });

  final List<CharacterAppearance> appearances;
  final String selectedId;
  final AppLanguage language;
  final bool liquidGlass;
  final Widget Function(CharacterAppearance appearance) previewBuilder;
  final ValueChanged<CharacterAppearance> onSelected;
  final VoidCallback onTextureChanged;

  @override
  State<AppearancePickerPage> createState() => _AppearancePickerPageState();
}

class _AppearancePickerPageState extends State<AppearancePickerPage> {
  late final List<CharacterAppearance> _appearances;
  final Map<String, int> _previewRevisions = {};
  late int _focusedIndex;
  late int _lastFocusedIndex;
  double _dragDistance = 0;

  @override
  void initState() {
    super.initState();
    _appearances = [...widget.appearances];
    _focusedIndex = max(
      0,
      _appearances.indexWhere((item) => item.id == widget.selectedId),
    );
    _lastFocusedIndex = _focusedIndex;
  }

  void _focus(int index) {
    if (index < 0 || index > _appearances.length || index == _focusedIndex) {
      return;
    }
    setState(() {
      _lastFocusedIndex = _focusedIndex;
      _focusedIndex = index;
    });
  }

  bool _isIncomingRightCard(int index) =>
      index == _focusedIndex + 1 && _lastFocusedIndex < _focusedIndex;

  Duration _cardTransitionDuration(int index) {
    if (_isIncomingRightCard(index)) {
      return const Duration(milliseconds: 760);
    }
    if (index == _focusedIndex && _lastFocusedIndex < _focusedIndex) {
      return const Duration(milliseconds: 680);
    }
    return const Duration(milliseconds: 500);
  }

  Curve _cardPositionCurve(int index) =>
      _isIncomingRightCard(index) || (index - _focusedIndex).abs() >= 2
      ? Curves.easeInOutSine
      : Curves.easeOutCubic;

  void _handleImported(CharacterAppearance appearance) {
    setState(() {
      if (!_appearances.any((item) => item.id == appearance.id)) {
        _appearances.add(appearance);
      }
      _lastFocusedIndex = _focusedIndex;
      _focusedIndex = _appearances.indexWhere(
        (item) => item.id == appearance.id,
      );
    });
  }

  void _handleImportedTexture(CharacterAppearance appearance) {
    setState(() {
      _previewRevisions[appearance.id] =
          (_previewRevisions[appearance.id] ?? 0) + 1;
      _lastFocusedIndex = _focusedIndex;
      _focusedIndex = _appearances.indexWhere(
        (item) => item.id == appearance.id,
      );
    });
    if (appearance.id == widget.selectedId) widget.onTextureChanged();
  }

  Future<void> _setTextureEnabled(
    CharacterAppearance appearance,
    bool enabled,
  ) async {
    await LocalSkinStore.instance.setTextureEnabled(
      appearance.assetName,
      enabled,
    );
    ProtectedCharacterAssets.clearCache();
    if (mounted) _handleImportedTexture(appearance);
  }

  Future<void> _deleteImportedTexture(CharacterAppearance appearance) async {
    final language = widget.language;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          language.text(
            '删除导入贴图？',
            'Delete imported texture?',
            '追加テクスチャを削除しますか？',
          ),
        ),
        content: Text(
          language.text(
            '这套服装将恢复原始贴图。',
            'This outfit will return to its original texture.',
            'この衣装は元のテクスチャに戻ります。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(language.text('取消', 'Cancel', 'キャンセル')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(language.text('删除', 'Delete', '削除')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final deleted = await LocalSkinStore.instance.deleteTexture(
        appearance.assetName,
      );
      if (!deleted) return;
      ProtectedCharacterAssets.clearCache();
      if (mounted) _handleImportedTexture(appearance);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              language.text(
                '删除贴图失败',
                'Could not delete texture',
                'テクスチャを削除できませんでした',
              ),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = widget.language;
    final focused = _focusedIndex < _appearances.length
        ? _appearances[_focusedIndex]
        : null;
    final palette = Theme.of(context).colorScheme;
    final foreground = palette.onSurface;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GlassPageSurface(
            liquidGlass: widget.liquidGlass,
            child: const SizedBox.expand(),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
                  child: Row(
                    children: [
                      Icon(Icons.checkroom_outlined, color: foreground),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          language.text('服装切换', 'Outfits', '衣装切り替え'),
                          style: TextStyle(
                            color: foreground,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        '${_focusedIndex + 1} / ${_appearances.length + 1}',
                        style: TextStyle(
                          color: foreground.withValues(alpha: .7),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        tooltip: language.text('关闭', 'Close', '閉じる'),
                        icon: const Icon(Icons.close_rounded),
                        color: foreground,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Focus(
                    autofocus: true,
                    onKeyEvent: (_, event) {
                      if (event is! KeyDownEvent) return KeyEventResult.ignored;
                      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                        _focus(_focusedIndex - 1);
                        return KeyEventResult.handled;
                      }
                      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                        _focus(_focusedIndex + 1);
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: LayoutBuilder(
                      builder: (context, constraints) =>
                          _buildDeck(constraints),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                    width: 164,
                    height: 44,
                    child: FilledButton(
                      key: const ValueKey('outfit-equip-button'),
                      onPressed:
                          focused == null || focused.id == widget.selectedId
                          ? null
                          : () => widget.onSelected(focused),
                      child: Text(
                        focused?.id == widget.selectedId
                            ? language.text('已装备', 'Equipped', '着用中')
                            : language.text('切换', 'Equip', '着替える'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeck(BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final cardWidth = min(440.0, width * 0.66);
    final cardHeight = min(660.0, height * 0.92);
    int paintOrder(int index) => switch (index - _focusedIndex) {
      3 => 0,
      -3 => 1,
      2 => 2,
      -2 => 3,
      -1 => 4,
      0 => 5,
      1 => 6,
      _ => -1,
    };
    final visible = <int>[
      for (var i = 0; i <= _appearances.length; i++)
        if ((i - _focusedIndex).abs() <= 3) i,
    ]..sort((a, b) => paintOrder(a).compareTo(paintOrder(b)));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _dragDistance = 0,
      onHorizontalDragUpdate: (details) =>
          _dragDistance += details.primaryDelta ?? 0,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (_dragDistance < -48 || velocity < -450) {
          _focus(_focusedIndex + 1);
        } else if (_dragDistance > 48 || velocity > 450) {
          _focus(_focusedIndex - 1);
        }
        _dragDistance = 0;
      },
      child: ClipRect(
        child: Stack(
          children: [
            for (final index in visible)
              Positioned(
                key: ValueKey(
                  index == _appearances.length
                      ? 'outfit-import-card'
                      : _appearances[index].id,
                ),
                left: (width - cardWidth) / 2,
                top: (height - cardHeight) / 2,
                width: cardWidth,
                height: cardHeight,
                child: AnimatedSlide(
                  offset: Offset(switch (index - _focusedIndex) {
                    <= -3 => -(width + cardWidth) / (2 * cardWidth),
                    < 0 => -(0.22 + 0.08 * (_focusedIndex - index - 1)),
                    >= 3 => (width + cardWidth) / (2 * cardWidth) + 0.28,
                    2 => (width + cardWidth) / (2 * cardWidth),
                    1 => 0.88,
                    _ => 0,
                  }, 0),
                  duration: _cardTransitionDuration(index),
                  curve: _cardPositionCurve(index),
                  child: AnimatedScale(
                    scale: index == _focusedIndex ? 1 : 0.97,
                    duration: _cardTransitionDuration(index),
                    curve: Curves.easeOutCubic,
                    child: index == _appearances.length
                        ? _ImportOutfitCard(
                            liquidGlass: widget.liquidGlass,
                            focused: index == _focusedIndex,
                            onTap: () => _focus(index),
                            child: SkinImportControls(
                              appearances: _appearances,
                              language: widget.language,
                              onImported: _handleImported,
                              onTextureChanged: _handleImportedTexture,
                            ),
                          )
                        : _OutfitCard(
                            appearance: _appearances[index],
                            language: widget.language,
                            liquidGlass: widget.liquidGlass,
                            preview: KeyedSubtree(
                              key: ValueKey(
                                'outfit-preview-${_appearances[index].id}-${_previewRevisions[_appearances[index].id] ?? 0}',
                              ),
                              child: widget.previewBuilder(_appearances[index]),
                            ),
                            focused: index == _focusedIndex,
                            equipped:
                                _appearances[index].id == widget.selectedId,
                            compact: cardHeight < 300,
                            onTap: () => _focus(index),
                            hasImportedTexture: LocalSkinStore.instance
                                .hasTexture(_appearances[index].assetName),
                            usesImportedTexture: LocalSkinStore.instance
                                .usesTexture(_appearances[index].assetName),
                            onTextureSelected: (enabled) => _setTextureEnabled(
                              _appearances[index],
                              enabled,
                            ),
                            onTextureDelete: () =>
                                _deleteImportedTexture(_appearances[index]),
                          ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ImportOutfitCard extends StatelessWidget {
  const _ImportOutfitCard({
    required this.liquidGlass,
    required this.focused,
    required this.onTap,
    required this.child,
  });

  final bool liquidGlass;
  final bool focused;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: focused ? null : onTap,
    child: GlassSurface(
      key: const ValueKey('outfit-import-surface'),
      liquidGlass: liquidGlass,
      backdropBlur: false,
      fillOpacity: .65,
      fallbackColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xB820292D)
          : const Color(0xD9EFF3F1),
      tone: Theme.of(context).brightness == Brightness.dark
          ? GlassTone.dark
          : GlassTone.light,
      borderRadius: BorderRadius.circular(18),
      child: focused ? child : IgnorePointer(child: child),
    ),
  );
}

class _OutfitCard extends StatelessWidget {
  const _OutfitCard({
    required this.appearance,
    required this.language,
    required this.liquidGlass,
    required this.preview,
    required this.focused,
    required this.equipped,
    required this.compact,
    required this.onTap,
    required this.hasImportedTexture,
    required this.usesImportedTexture,
    required this.onTextureSelected,
    required this.onTextureDelete,
  });

  final CharacterAppearance appearance;
  final AppLanguage language;
  final bool liquidGlass;
  final Widget preview;
  final bool focused;
  final bool equipped;
  final bool compact;
  final VoidCallback onTap;
  final bool hasImportedTexture;
  final bool usesImportedTexture;
  final ValueChanged<bool> onTextureSelected;
  final VoidCallback onTextureDelete;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: appearance.label,
      selected: focused,
      child: GestureDetector(
        onTap: focused ? null : onTap,
        child: GlassSurface(
          key: ValueKey('outfit-surface-${appearance.id}'),
          liquidGlass: liquidGlass,
          backdropBlur: false,
          fillOpacity: .65,
          fallbackColor: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xB820292D)
              : const Color(0xD9EFF3F1),
          tone: Theme.of(context).brightness == Brightness.dark
              ? GlassTone.dark
              : GlassTone.light,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Colors.black38,
              blurRadius: 28,
              offset: Offset(0, 14),
            ),
          ],
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  compact ? 12 : 44,
                  12,
                  compact ? 48 : 76,
                ),
                child: preview,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xC0000000)],
                    stops: [0.70, 1],
                  ),
                ),
              ),
              if (equipped)
                Positioned(
                  top: 12,
                  right: 12,
                  child: const Icon(Icons.check_circle, color: Colors.white),
                ),
              if (focused && hasImportedTexture)
                Positioned(
                  top: 4,
                  left: 4,
                  child: PopupMenuButton<bool>(
                    key: ValueKey('outfit-texture-menu-${appearance.id}'),
                    tooltip: language.text(
                      '选择贴图',
                      'Choose texture',
                      'テクスチャを選択',
                    ),
                    icon: const Icon(
                      Icons.layers_outlined,
                      color: Colors.white,
                    ),
                    onSelected: onTextureSelected,
                    itemBuilder: (menuContext) => [
                      CheckedPopupMenuItem<bool>(
                        value: false,
                        checked: !usesImportedTexture,
                        child: Text(
                          language.text('原始贴图', 'Original texture', '元のテクスチャ'),
                        ),
                      ),
                      PopupMenuItem<bool>(
                        value: true,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 24,
                              child: usesImportedTexture
                                  ? const Icon(Icons.check, size: 20)
                                  : null,
                            ),
                            Expanded(
                              child: Text(
                                language.text(
                                  '导入贴图',
                                  'Imported texture',
                                  '追加テクスチャ',
                                ),
                              ),
                            ),
                            IconButton(
                              key: ValueKey(
                                'outfit-delete-texture-${appearance.id}',
                              ),
                              tooltip: language.text(
                                '删除导入贴图',
                                'Delete imported texture',
                                '追加テクスチャを削除',
                              ),
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () {
                                Navigator.of(menuContext).pop();
                                onTextureDelete();
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              Positioned(
                left: 16,
                right: 12,
                bottom: 14,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appearance.label,
                      maxLines: compact ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? 16 : 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 3),
                      Text(
                        appearance.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
