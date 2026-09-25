import 'package:flutter/material.dart';
import 'package:spine_flutter/spine_flutter.dart' hide Color;

import 'runtime_log.dart';

/// Owns asynchronous loading outside SpineWidget so obsolete loads cannot
/// initialize a new controller or call setState after the view is removed.
class CharacterSpineView extends StatefulWidget {
  const CharacterSpineView({
    super.key,
    required this.atlas,
    required this.skeleton,
    required this.bundle,
    required this.controller,
    this.onLoadFailed,
  });
  final String atlas;
  final String skeleton;
  final AssetBundle bundle;
  final SpineWidgetController controller;
  final VoidCallback? onLoadFailed;

  @override
  State<CharacterSpineView> createState() => _CharacterSpineViewState();
}

class _CharacterSpineViewState extends State<CharacterSpineView> {
  SkeletonDrawable? _drawable;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CharacterSpineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bundle != widget.bundle ||
        oldWidget.atlas != widget.atlas ||
        oldWidget.skeleton != widget.skeleton ||
        oldWidget.controller != widget.controller) {
      _drawable?.dispose();
      _drawable = null;
      _error = null;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final bundle = widget.bundle;
    final atlasPath = widget.atlas;
    final skeletonPath = widget.skeleton;
    Atlas? atlas;
    try {
      atlas = await Atlas.fromAsset(atlasPath, bundle: bundle);
      if (!mounted || generation != _generation) {
        atlas.dispose();
        return;
      }
      final data = await SkeletonData.fromAsset(
        atlas,
        skeletonPath,
        bundle: bundle,
      );
      if (!mounted || generation != _generation) {
        data.dispose();
        atlas.dispose();
        return;
      }
      final drawable = SkeletonDrawable(atlas, data, true);
      atlas = null; // Ownership passes to the drawable and SpineWidget.
      setState(() => _drawable = drawable);
    } on Object catch (error, stack) {
      atlas?.dispose();
      if (!mounted || generation != _generation) return;
      RuntimeLog.instance.error('CharacterAssets', error, stack);
      setState(() => _error = error);
      widget.onLoadFailed?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final drawable = _drawable;
    if (drawable != null) {
      return SpineWidget.fromDrawable(
        drawable,
        widget.controller,
        key: ObjectKey(drawable),
        fit: BoxFit.contain,
        alignment: Alignment.bottomCenter,
      );
    }
    if (_error != null) {
      return const Center(
        child: Text(
          '皮肤加载失败，请重新选择皮肤或检查导入文件',
          style: TextStyle(
            color: Colors.white,
            backgroundColor: Colors.black54,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  void dispose() {
    ++_generation;
    // Also covers a loaded drawable disposed before its first child build.
    _drawable?.dispose();
    super.dispose();
  }
}
