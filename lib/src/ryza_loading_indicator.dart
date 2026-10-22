import 'package:flutter/material.dart';

import 'app_localization.dart';

/// Character loading panel, outside the character camera.
class RyzaLoadingPanel extends StatelessWidget {
  const RyzaLoadingPanel({super.key, required this.language});

  final AppLanguage language;

  @override
  Widget build(BuildContext context) {
    final label = language.text('加载中...', 'Loading...', '読み込み中...');
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Container(
          width: 216,
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          decoration: BoxDecoration(
            color: const Color(0xB3000000),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: .14),
              width: 0,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ClipRRect(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                child: RyzaLoadingIndicator(size: 176),
              ),
              const SizedBox(height: 14),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RyzaLoadingIndicator extends StatefulWidget {
  const RyzaLoadingIndicator({
    super.key,
    this.size = 112,
    this.frameDuration = const Duration(milliseconds: 150),
    this.semanticsLabel = 'Loading',
  });

  static const frameAssets = <String>[
    'assets/branding/loading/frame_00.png',
    'assets/branding/loading/frame_01.png',
    'assets/branding/loading/frame_02.png',
    'assets/branding/loading/frame_03.png',
    'assets/branding/loading/frame_04.png',
    'assets/branding/loading/frame_05.png',
  ];

  final double size;
  final Duration frameDuration;
  final String semanticsLabel;

  @override
  State<RyzaLoadingIndicator> createState() => _RyzaLoadingIndicatorState();
}

class _RyzaLoadingIndicatorState extends State<RyzaLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  var _framesPrecached = false;

  Duration get _loopDuration => Duration(
    microseconds:
        widget.frameDuration.inMicroseconds *
        RyzaLoadingIndicator.frameAssets.length,
  );

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _loopDuration);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_framesPrecached) {
      _framesPrecached = true;
      for (final asset in RyzaLoadingIndicator.frameAssets) {
        precacheImage(AssetImage(asset), context);
      }
    }
    _syncMotionPreference();
  }

  @override
  void didUpdateWidget(covariant RyzaLoadingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frameDuration != widget.frameDuration) {
      _controller.duration = _loopDuration;
      _syncMotionPreference();
    }
  }

  void _syncMotionPreference() {
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (disableAnimations) {
      _controller.stop();
      _controller.value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticsLabel,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final frame =
                  (_controller.value * RyzaLoadingIndicator.frameAssets.length)
                      .floor() %
                  RyzaLoadingIndicator.frameAssets.length;
              return Image.asset(
                RyzaLoadingIndicator.frameAssets[frame],
                key: ValueKey('ryza-loading-frame-$frame'),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                excludeFromSemantics: true,
              );
            },
          ),
        ),
      ),
    );
  }
}
