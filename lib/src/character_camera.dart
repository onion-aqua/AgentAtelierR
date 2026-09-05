import 'dart:async';

import 'package:flutter/material.dart';

const characterCameraGestureKey = ValueKey('character-stage-gesture');
const characterCameraTransformKey = ValueKey('character-camera-transform');
const characterCameraOffsetKey = ValueKey('character-camera-offset');

class CharacterCamera extends StatefulWidget {
  const CharacterCamera({
    super.key,
    required this.child,
    required this.onTap,
    this.onGazeChanged,
    this.onGazeEnd,
    this.minScale = 0.8,
    this.maxScale = 2.2,
    this.initialScale = 1.25,
    this.initialVerticalOffsetFraction = 0.2,
  });

  final Widget child;
  final ValueChanged<Offset> onTap;
  final ValueChanged<Offset>? onGazeChanged;
  final VoidCallback? onGazeEnd;
  final double minScale;
  final double maxScale;
  final double initialScale;
  final double initialVerticalOffsetFraction;

  @override
  State<CharacterCamera> createState() => _CharacterCameraState();
}

class _CharacterCameraState extends State<CharacterCamera>
    with WidgetsBindingObserver {
  late double _scale;
  double _scaleAtGestureStart = 1;
  double? _verticalOffset;
  bool _pinchDetected = false;
  bool _suppressTap = false;
  Timer? _tapSuppressionTimer;
  final Set<int> _pointers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scale = widget.initialScale.clamp(widget.minScale, widget.maxScale);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tapSuppressionTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _pointers.clear();
      _pinchDetected = false;
      widget.onGazeEnd?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final verticalOffset =
            _verticalOffset ??
            constraints.maxHeight * widget.initialVerticalOffsetFraction;
        return Semantics(
          button: true,
          label: '莱莎，点击触发互动',
          child: Listener(
            onPointerDown: (event) {
              _pointers.add(event.pointer);
              if (_pointers.length == 1) {
                widget.onGazeChanged?.call(
                  _unscalePosition(
                    event.localPosition,
                    constraints.biggest,
                    verticalOffset,
                  ),
                );
              } else {
                widget.onGazeEnd?.call();
              }
            },
            onPointerMove: (event) {
              if (_pointers.length == 1 && !_pinchDetected && !_suppressTap) {
                widget.onGazeChanged?.call(
                  _unscalePosition(
                    event.localPosition,
                    constraints.biggest,
                    verticalOffset,
                  ),
                );
              }
            },
            onPointerUp: (event) {
              _pointers.remove(event.pointer);
              widget.onGazeEnd?.call();
            },
            onPointerCancel: (event) {
              _pointers.remove(event.pointer);
              widget.onGazeEnd?.call();
            },
            child: GestureDetector(
              key: characterCameraGestureKey,
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) {
                if (_pinchDetected || _suppressTap) return;
                widget.onTap(
                  _unscalePosition(
                    details.localPosition,
                    constraints.biggest,
                    verticalOffset,
                  ),
                );
              },
              onScaleStart: (details) {
                _scaleAtGestureStart = _scale;
                _verticalOffset ??= verticalOffset;
                _pinchDetected = details.pointerCount > 1;
              },
              onScaleUpdate: (details) {
                if (details.pointerCount == 1) {
                  return;
                }
                if (details.pointerCount < 2) return;
                _pinchDetected = true;
                _suppressTap = true;
                final nextScale = (_scaleAtGestureStart * details.scale).clamp(
                  widget.minScale,
                  widget.maxScale,
                );
                final maxDown = constraints.maxHeight * 0.55;
                final maxUp = constraints.maxHeight * 0.35;
                final currentOffset = _verticalOffset ?? verticalOffset;
                final nextOffset = (currentOffset + details.focalPointDelta.dy)
                    .clamp(-maxUp, maxDown);
                if ((nextScale - _scale).abs() < 0.001 &&
                    (nextOffset - currentOffset).abs() < 0.1) {
                  return;
                }
                setState(() {
                  _scale = nextScale;
                  _verticalOffset = nextOffset;
                });
              },
              onScaleEnd: (_) {
                if (_pinchDetected) {
                  _tapSuppressionTimer?.cancel();
                  _tapSuppressionTimer = Timer(
                    const Duration(milliseconds: 280),
                    () => _suppressTap = false,
                  );
                }
                _pinchDetected = false;
              },
              child: Transform.translate(
                key: characterCameraOffsetKey,
                offset: Offset(0, verticalOffset),
                child: Transform.scale(
                  key: characterCameraTransformKey,
                  scale: _scale,
                  alignment: Alignment.bottomCenter,
                  child: widget.child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Offset _unscalePosition(
    Offset position,
    Size stageSize,
    double verticalOffset,
  ) {
    final translated = position - Offset(0, verticalOffset);
    if ((_scale - 1).abs() < 0.001) return translated;
    final origin = Offset(stageSize.width / 2, stageSize.height);
    return origin + (translated - origin) / _scale;
  }
}
