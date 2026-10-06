import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// An app window expands from its launcher icon inside the phone Navigator.
/// Page contents keep their final layout throughout the transition, so text
/// fields and long lists are scaled/clipped rather than laid out at icon size.
class VirtualPhoneAppRoute extends PageRoute<void> {
  VirtualPhoneAppRoute({
    required super.settings,
    required this.originRect,
    required this.icon,
    required this.iconBackground,
    required this.iconForeground,
    required this.builder,
    this.originRectResolver,
    this.canHandleBackGesture,
    this.reduceMotion = false,
  }) : super(allowSnapshotting: false);

  final Rect originRect;
  final IconData icon;
  final Color iconBackground;
  final Color iconForeground;
  final WidgetBuilder builder;
  final Rect Function()? originRectResolver;
  final bool Function()? canHandleBackGesture;
  final bool reduceMotion;
  bool _gestureActive = false;
  bool _settlingGesture = false;
  NavigatorState? _gestureNavigator;
  AnimationStatusListener? _settleListener;

  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 420);
  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 320);
  @override
  bool get maintainState => true;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;

  bool get canStartBackGesture =>
      !_gestureActive &&
      isCurrent &&
      popGestureEnabled &&
      (canHandleBackGesture?.call() ?? true);

  // A settings category or drawer can consume a back request without popping
  // the app route. Keep edge swipes available there, but leave the app full size.
  bool get canHandleEdgeBackGesture =>
      !_gestureActive &&
      isCurrent &&
      (animation?.isCompleted ?? false) &&
      (secondaryAnimation?.isDismissed ?? true) &&
      (canHandleBackGesture?.call() ?? true);

  void requestBackFromEdge() {
    if (canHandleEdgeBackGesture) navigator?.maybePop();
  }

  // The same curve is used during open, close, cancel and commit. Gesture
  // progress is inverted into this curve so the visible window follows the
  // finger linearly, without switching curves when the user releases it.
  static double _controllerProgress(double visibleProgress) =>
      1 - math.pow(1 - visibleProgress.clamp(0.0, 1.0), 1 / 3).toDouble();

  @override
  void handleStartBackGesture({double progress = 1}) {
    if (!canStartBackGesture) return;
    _gestureActive = true;
    _settlingGesture = false;
    _gestureNavigator = navigator;
    controller!.stop();
    controller!.value = _controllerProgress(progress);
    navigator?.didStartUserGesture();
  }

  @override
  void handleUpdateBackGestureProgress({required double progress}) {
    if (_gestureActive && !_settlingGesture && isCurrent) {
      controller!.value = _controllerProgress(progress);
    }
  }

  @override
  void handleCancelBackGesture() => _finishGesture(commit: false);

  @override
  void handleCommitBackGesture() => _finishGesture(commit: true);

  void _finishGesture({required bool commit}) {
    if (!_gestureActive || _settlingGesture) return;
    _settlingGesture = true;
    final animationController = controller!;
    // Drawer, form or dialog state may change while a gesture is held. Recheck
    // the actual route disposition before committing, rather than skipping it.
    final mayPop =
        isCurrent &&
        !willHandlePopInternally &&
        popDisposition == RoutePopDisposition.pop &&
        (canHandleBackGesture?.call() ?? true);
    if (commit && mayPop) {
      navigator!.pop(); // Reuse normal pop; never restart from a full window.
      if (!reduceMotion && animationController.isAnimating) {
        animationController.animateBack(
          0,
          duration: const Duration(milliseconds: 240),
          curve: Curves.linear,
        );
      }
    } else if (isActive) {
      if (reduceMotion) {
        animationController.value = 1;
      } else {
        animationController.animateTo(
          1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    }
    if (animationController.isAnimating) {
      _settleListener = (status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          _stopGesture();
        }
      };
      animationController.addStatusListener(_settleListener!);
    } else {
      _stopGesture();
    }
  }

  void _stopGesture() {
    final listener = _settleListener;
    if (listener != null) controller?.removeStatusListener(listener);
    _settleListener = null;
    if (_gestureActive && _gestureNavigator?.mounted == true) {
      _gestureNavigator!.didStopUserGesture();
    }
    _gestureNavigator = null;
    _gestureActive = false;
    _settlingGesture = false;
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => RepaintBoundary(child: builder(context));

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _PhoneAppTransition(route: this, animation: animation, child: child);

  @override
  void dispose() {
    _stopGesture();
    super.dispose();
  }
}

class _PhoneAppTransition extends StatefulWidget {
  const _PhoneAppTransition({
    required this.route,
    required this.animation,
    required this.child,
  });
  final VirtualPhoneAppRoute route;
  final Animation<double> animation;
  final Widget child;
  @override
  State<_PhoneAppTransition> createState() => _PhoneAppTransitionState();
}

class _PhoneAppTransitionState extends State<_PhoneAppTransition>
    with WidgetsBindingObserver {
  double? _edgeProgress;
  bool _edgeAnimates = false;
  bool _predictive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent event) {
    if (event.isButtonEvent || !widget.route.canStartBackGesture) return false;
    _predictive = true;
    widget.route.handleStartBackGesture(progress: 1 - event.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent event) {
    if (_predictive) {
      widget.route.handleUpdateBackGestureProgress(
        progress: 1 - event.progress,
      );
    }
  }

  @override
  void handleCancelBackGesture() {
    if (_predictive) widget.route.handleCancelBackGesture();
    _predictive = false;
  }

  @override
  void handleCommitBackGesture() {
    if (_predictive) widget.route.handleCommitBackGesture();
    _predictive = false;
  }

  void _startEdge(DragStartDetails details) {
    if (!widget.route.canHandleEdgeBackGesture) return;
    _edgeProgress = 0;
    _edgeAnimates = widget.route.canStartBackGesture;
    if (_edgeAnimates) widget.route.handleStartBackGesture();
  }

  void _updateEdge(DragUpdateDetails details, bool left, double width) {
    final progress = _edgeProgress;
    if (progress == null) return;
    _edgeProgress = (progress + (left ? 1 : -1) * details.delta.dx / width)
        .clamp(0.0, 1.0);
    if (_edgeAnimates) {
      widget.route.handleUpdateBackGestureProgress(
        progress: 1 - _edgeProgress!,
      );
    }
  }

  void _endEdge(DragEndDetails details, bool left) {
    final progress = _edgeProgress;
    if (progress == null) return;
    _edgeProgress = null;
    final velocity = (details.primaryVelocity ?? 0) * (left ? 1 : -1);
    final commit = velocity > 900 || (velocity >= -900 && progress >= .35);
    if (_edgeAnimates) {
      if (commit) {
        widget.route.handleCommitBackGesture();
      } else {
        widget.route.handleCancelBackGesture();
      }
    } else if (commit) {
      widget.route.requestBackFromEdge();
    }
    _edgeAnimates = false;
  }

  void _cancelEdge() {
    if (_edgeProgress != null && _edgeAnimates) {
      widget.route.handleCancelBackGesture();
    }
    _edgeProgress = null;
    _edgeAnimates = false;
  }

  Rect _origin(Size size) {
    final route = widget.route;
    // The launcher gently scales back up during close. Resolve the actual
    // icon on each closing frame so the final window lands on it precisely.
    final resolved =
        route._gestureActive ||
            widget.animation.status == AnimationStatus.reverse
        ? route.originRectResolver?.call()
        : null;
    final rect = resolved ?? route.originRect;
    if (rect.isFinite && rect.width > 0 && rect.height > 0) return rect;
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: 58,
      height: 58,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => AnimatedBuilder(
      animation: widget.animation,
      builder: (context, _) {
        final size = constraints.biggest;
        final route = widget.route;
        final t = route.reduceMotion
            ? 1.0
            : Curves.easeOutCubic.transform(
                widget.animation.value.clamp(0.0, 1.0),
              );
        final rect = Rect.lerp(_origin(size), Offset.zero & size, t)!;
        final contentOpacity = const Interval(
          .12,
          .55,
          curve: Curves.easeOut,
        ).transform(t);
        final iconOpacity = 1 - const Interval(0, .30).transform(t);
        final enabled = route.canHandleEdgeBackGesture;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fromRect(
              rect: rect,
              child: SizedBox.expand(
                key: const ValueKey('virtual-phone-app-transition'),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16 * (1 - t)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .16 * (1 - t)),
                        blurRadius: 16,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16 * (1 - t)),
                    child: ColoredBox(
                      color: Color.lerp(route.iconBackground, Colors.black, t)!,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          IgnorePointer(
                            ignoring:
                                !widget.animation.isCompleted ||
                                route._gestureActive,
                            child: Opacity(
                              opacity: contentOpacity,
                              child: FittedBox(
                                fit: BoxFit.cover,
                                alignment: Alignment.topCenter,
                                child: SizedBox(
                                  width: size.width,
                                  height: size.height,
                                  child: widget.child,
                                ),
                              ),
                            ),
                          ),
                          if (iconOpacity > 0)
                            IgnorePointer(
                              child: Center(
                                child: Opacity(
                                  opacity: iconOpacity,
                                  child: Icon(
                                    route.icon,
                                    color: route.iconForeground,
                                    size: 29,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            for (final left in [true, false])
              Positioned(
                top: 0,
                bottom: 0,
                left: left ? 0 : null,
                right: left ? null : 0,
                width: 24,
                child: GestureDetector(
                  key: ValueKey(
                    'virtual-phone-back-edge-${left ? 'left' : 'right'}',
                  ),
                  behavior: HitTestBehavior.translucent,
                  dragStartBehavior: DragStartBehavior.down,
                  onHorizontalDragStart: enabled ? _startEdge : null,
                  onHorizontalDragUpdate: enabled || _edgeProgress != null
                      ? (details) => _updateEdge(details, left, size.width)
                      : null,
                  onHorizontalDragEnd: enabled || _edgeProgress != null
                      ? (details) => _endEdge(details, left)
                      : null,
                  onHorizontalDragCancel: enabled || _edgeProgress != null
                      ? _cancelEdge
                      : null,
                ),
              ),
          ],
        );
      },
    ),
  );
}
