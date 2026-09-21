import 'package:flutter/material.dart';

class SwipeCollectionSelection extends StatefulWidget {
  const SwipeCollectionSelection({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.child,
    this.selectedLabel = '已选择',
  });
  final bool selected;
  final ValueChanged<bool>? onChanged;
  final Widget child;
  final String selectedLabel;
  @override
  State<SwipeCollectionSelection> createState() => _SwipeSelectionState();
}

class _SwipeSelectionState extends State<SwipeCollectionSelection>
    with SingleTickerProviderStateMixin {
  static const _revealWidth = 64.0;
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  double _direction = 0;
  @override
  void initState() {
    super.initState();
    _slide.value = widget.selected ? 1 : 0;
  }

  void _settle([double velocity = 0]) {
    final open = _direction == 0 ? widget.selected : _direction > 0;
    if (open != widget.selected) widget.onChanged?.call(open);
    _slide.animateTo(open ? 1 : 0, curve: Curves.easeOutCubic);
  }

  @override
  void didUpdateWidget(covariant SwipeCollectionSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onChanged == null || oldWidget.selected != widget.selected) {
      _slide.value = widget.selected && widget.onChanged != null ? 1 : 0;
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onHorizontalDragStart: widget.onChanged == null
        ? null
        : (_) {
            _slide.stop();
            _direction = 0;
          },
    onHorizontalDragUpdate: widget.onChanged == null
        ? null
        : (details) {
            _direction += details.delta.dx;
            _slide.value = (_slide.value + details.delta.dx / _revealWidth)
                .clamp(0, 1);
          },
    onHorizontalDragEnd: widget.onChanged == null
        ? null
        : (details) => _settle(details.primaryVelocity ?? 0),
    onHorizontalDragCancel: widget.onChanged == null ? null : _settle,
    child: ClipRect(
      child: AnimatedBuilder(
        animation: _slide,
        child: widget.child,
        builder: (context, child) => Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: _revealWidth * _slide.value,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: _revealWidth,
                  maxWidth: _revealWidth,
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: .24),
                    child: Center(
                      child: IgnorePointer(
                        ignoring: _slide.value < .95,
                        child: ExcludeSemantics(
                          excluding: _slide.value < .95,
                          child: Padding(
                            padding: const EdgeInsets.all(5),
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final style = const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                );
                                final measure = TextPainter(
                                  text: TextSpan(
                                    text: widget.selectedLabel,
                                    style: style,
                                  ),
                                  textDirection: Directionality.of(context),
                                  textScaler: MediaQuery.textScalerOf(context),
                                )..layout();
                                final vertical =
                                    measure.width > constraints.maxWidth &&
                                    constraints.maxHeight > 70;
                                measure.dispose();
                                return FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    vertical
                                        ? widget.selectedLabel
                                              .split('')
                                              .join('\n')
                                        : widget.selectedLabel,
                                    textAlign: TextAlign.center,
                                    style: style,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Transform.translate(
              offset: Offset(_revealWidth * _slide.value, 0),
              child: Padding(
                // Reserve three full-width characters as soon as the row
                // starts opening, for both assistant and user text.
                padding: EdgeInsets.only(
                  right: _slide.value > 0
                      ? MediaQuery.textScalerOf(context).scale(18) * 3
                      : 0,
                ),
                child: child,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
