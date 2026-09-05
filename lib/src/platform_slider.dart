import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Avoids Material Slider's orphan OverlayPortal semantics on Windows.
/// See flutter/flutter#190357. Keep the normal Material control elsewhere.
class PlatformSlider extends StatelessWidget {
  const PlatformSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final int? divisions;
  final String? label;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return Semantics(
        container: true,
        explicitChildNodes: true,
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: CupertinoSlider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            activeColor: Theme.of(context).colorScheme.primary,
            onChanged: onChanged,
          ),
        ),
      );
    }
    return Slider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      onChanged: onChanged,
    );
  }
}
