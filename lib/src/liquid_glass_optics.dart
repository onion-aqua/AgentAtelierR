import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Filters the backdrop only. Text, icons and hit testing remain undistorted.
class LiquidGlassOptics extends StatefulWidget {
  const LiquidGlassOptics({
    super.key,
    this.enabled = true,
    required this.borderRadius,
    required this.dark,
    required this.blurSigma,
    required this.filterBackdrop,
    required this.child,
  });

  final bool enabled;
  final BorderRadius borderRadius;
  final bool dark;
  final double blurSigma;
  final bool filterBackdrop;
  final Widget child;

  @override
  State<LiquidGlassOptics> createState() => _LiquidGlassOpticsState();
}

class _LiquidGlassOpticsState extends State<LiquidGlassOptics>
    with SingleTickerProviderStateMixin {
  static ui.FragmentProgram? _sharedProgram;
  static Future<ui.FragmentProgram?>? _loadingProgram;
  static bool _programUnavailable = false;
  ui.FragmentShader? _shader;
  Offset _light = const Offset(.25, .08);
  late final _glint = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );

  static Future<ui.FragmentProgram?> _loadProgram() async {
    try {
      return _sharedProgram = await ui.FragmentProgram.fromAsset(
        'shaders/liquid_glass.frag',
      );
    } on Object {
      // A missing/unsupported shader must never turn a usable page black.
      _programUnavailable = true;
      return null;
    } finally {
      _loadingProgram = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _prepareShader();
  }

  @override
  void didUpdateWidget(LiquidGlassOptics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled &&
        (!oldWidget.enabled ||
            (!oldWidget.filterBackdrop && widget.filterBackdrop))) {
      _prepareShader();
    }
    if (!widget.enabled) _glint.stop();
  }

  Future<void> _prepareShader() async {
    if (!widget.enabled ||
        !widget.filterBackdrop ||
        !ui.ImageFilter.isShaderFilterSupported ||
        _programUnavailable ||
        _shader != null) {
      return;
    }
    final cached = _sharedProgram;
    if (cached != null) {
      // Each surface owns its uniforms; only the compiled program is shared.
      // Warm surfaces can refract from their very first frame.
      _shader = cached.fragmentShader();
      return;
    }
    final program = await (_loadingProgram ??= _loadProgram());
    if (!mounted || program == null || _shader != null) return;
    setState(() => _shader = program.fragmentShader());
  }

  @override
  void dispose() {
    _glint.dispose();
    _shader?.dispose();
    super.dispose();
  }

  void _touch(Offset point, Size size, {bool restart = false}) {
    if (!widget.enabled ||
        size.isEmpty ||
        MediaQuery.disableAnimationsOf(context)) {
      return;
    }
    setState(() {
      _light = Offset(
        (point.dx / size.width).clamp(0, 1),
        (point.dy / size.height).clamp(0, 1),
      );
    });
    if (restart) _glint.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    // Avoid LayoutBuilder: dialogs query intrinsic sizes. Once the shader
    // loads, the existing render box supplies the already-laid-out dimensions.
    final box = context.findRenderObject() as RenderBox?;
    final size = box?.hasSize == true ? box!.size : Size.zero;
    final shortSide = math.min(size.width, size.height);
    final radii = widget.borderRadius;
    final radius = [
      radii.topLeft.x,
      radii.topRight.x,
      radii.bottomLeft.x,
      radii.bottomRight.x,
    ].reduce(math.max);
    final roundness = shortSide.isFinite && shortSide > 0
        ? (radius / shortSide).clamp(0.0, .5)
        : .12;
    return AnimatedBuilder(
      animation: _glint,
      child: widget.child,
      builder: (context, child) {
        final reduceMotion = MediaQuery.disableAnimationsOf(context);
        final phase = reduceMotion || !widget.enabled ? 0.0 : _glint.value;
        final painted = CustomPaint(
          painter: widget.enabled
              ? _GlassGlintPainter(
                  borderRadius: radii,
                  dark: widget.dark,
                  light: _light,
                  phase: phase,
                )
              : null,
          child: child,
        );
        final filterEnabled = widget.enabled && widget.filterBackdrop;
        ui.ImageFilter filter = ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0);
        if (filterEnabled) {
          // Light diffusion, rather than a thick frosted blur.
          final sigma = (widget.blurSigma * .12).clamp(0.0, 1.8);
          filter = ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.clamp,
          );
          final shader = _shader;
          if (shader != null && ui.ImageFilter.isShaderFilterSupported) {
            shader
              ..setFloat(2, roundness)
              ..setFloat(3, reduceMotion ? .65 : 1.0)
              ..setFloat(4, phase)
              ..setFloat(5, _light.dx)
              ..setFloat(6, _light.dy);
            filter = ui.ImageFilter.compose(
              outer: ui.ImageFilter.shader(shader),
              inner: filter,
            );
          }
        }
        // A disabled filter adds no compositing effect, while keeping the
        // editable descendants mounted across changes to glass or blur.
        final result = BackdropFilter(
          enabled: filterEnabled,
          filter: filter,
          child: painted,
        );
        return Listener(
          onPointerDown: !widget.enabled
              ? null
              : (event) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box?.hasSize == true) {
                    _touch(event.localPosition, box!.size, restart: true);
                  }
                },
          onPointerMove: !widget.enabled
              ? null
              : (event) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box?.hasSize == true) {
                    _touch(event.localPosition, box!.size);
                  }
                },
          child: result,
        );
      },
    );
  }
}

class _GlassGlintPainter extends CustomPainter {
  const _GlassGlintPainter({
    required this.borderRadius,
    required this.dark,
    required this.light,
    required this.phase,
  });

  final BorderRadius borderRadius;
  final bool dark;
  final Offset light;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final shape = borderRadius.toRRect(rect).scaleRadii();
    // Full-page rectangles must not acquire a frame or a bright cross-page line.
    if (shape.tlRadiusX + shape.trRadiusX + shape.blRadiusX + shape.brRadiusX ==
        0) {
      return;
    }
    final pulse = math.sin(phase * math.pi);
    final direction = Alignment(light.dx * 2 - 1, light.dy * 2 - 1);
    canvas.save();
    canvas.clipRRect(shape);
    final sheen = RadialGradient(
      center: direction,
      radius: .9,
      colors: [
        Colors.white.withValues(alpha: .035 + pulse * .055),
        Colors.white.withValues(alpha: 0),
      ],
    );
    canvas.drawRRect(shape, Paint()..shader = sheen.createShader(rect));
    final edge = LinearGradient(
      begin: direction,
      end: Alignment(-direction.x, -direction.y),
      colors: [
        Colors.white.withValues(alpha: dark ? .48 : .7),
        Colors.white.withValues(alpha: .03),
        const Color(0xFFA6CFFF).withValues(alpha: .16 + pulse * .08),
        Colors.white.withValues(alpha: .30),
      ],
      stops: const [0, .36, .73, 1],
    );
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0
        ..shader = edge.createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassGlintPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.dark != dark ||
      oldDelegate.light != light ||
      oldDelegate.phase != phase;
}
