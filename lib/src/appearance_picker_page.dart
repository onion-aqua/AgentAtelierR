import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_localization.dart';
import 'character_appearance.dart';
import 'glass_ui.dart';
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
  late int _focusedIndex;
  late int _lastFocusedIndex;
  double _dragDistance = 0;

  @override
  void initState() {
    super.initState();
    _focusedIndex = max(
      0,
      widget.appearances.indexWhere((item) => item.id == widget.selectedId),
    );
    _lastFocusedIndex = _focusedIndex;
  }

  void _focus(int index) {
    if (index < 0 ||
        index >= widget.appearances.length ||
        index == _focusedIndex) {
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

  void _handleTextureChanged() {
    setState(() {});
    if (widget.appearances[_focusedIndex].id == widget.selectedId) {
      widget.onTextureChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = widget.language;
    final focused = widget.appearances[_focusedIndex];
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
                        '${_focusedIndex + 1} / ${widget.appearances.length}',
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
                      if (event is! KeyDownEvent) {
                        return KeyEventResult.ignored;
                      }
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
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: Theme(
                            data: Theme.of(context).copyWith(
                              colorScheme: palette.copyWith(
                                surface: const Color(0xFF344148),
                                onSurface: foreground,
                              ),
                            ),
                            child: SkinImportControls(
                              key: ValueKey(focused.id),
                              appearance: focused,
                              language: language,
                              compact: true,
                              onImported: widget.onSelected,
                              onTextureChanged: _handleTextureChanged,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        onPressed: _focusedIndex > 0
                            ? () => _focus(_focusedIndex - 1)
                            : null,
                        tooltip: language.text(
                          '上一套',
                          'Previous outfit',
                          '前の衣装',
                        ),
                        icon: const Icon(Icons.chevron_left_rounded),
                        color: foreground,
                      ),
                      IconButton(
                        onPressed: _focusedIndex < widget.appearances.length - 1
                            ? () => _focus(_focusedIndex + 1)
                            : null,
                        tooltip: language.text('下一套', 'Next outfit', '次の衣装'),
                        icon: const Icon(Icons.chevron_right_rounded),
                        color: foreground,
                      ),
                    ],
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
      for (var i = 0; i < widget.appearances.length; i++)
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
                key: ValueKey(widget.appearances[index].id),
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
                    child: _OutfitCard(
                      appearance: widget.appearances[index],
                      language: widget.language,
                      liquidGlass: widget.liquidGlass,
                      preview: widget.previewBuilder(widget.appearances[index]),
                      focused: index == _focusedIndex,
                      equipped:
                          widget.appearances[index].id == widget.selectedId,
                      compact: cardHeight < 300,
                      onTap: () => _focus(index),
                      onEquip: () =>
                          widget.onSelected(widget.appearances[index]),
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
    required this.onEquip,
  });

  final CharacterAppearance appearance;
  final AppLanguage language;
  final bool liquidGlass;
  final Widget preview;
  final bool focused;
  final bool equipped;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback onEquip;

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
          transparentFill: true,
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
                child: appearance.hasPreview
                    ? preview
                    : const Center(
                        child: Icon(
                          Icons.checkroom_outlined,
                          size: 72,
                          color: Colors.white54,
                        ),
                      ),
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
                    if (focused) ...[
                      const SizedBox(height: 8),
                      FilledButton(
                        key: ValueKey('outfit-equip-${appearance.id}'),
                        onPressed: equipped ? null : onEquip,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(64, 36),
                        ),
                        child: Text(
                          equipped
                              ? language.text('已装备', 'Equipped', '着用中')
                              : language.text('切换', 'Equip', '着替える'),
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
