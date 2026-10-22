import 'package:flutter/material.dart';

/// Each part owns its scroll position; typing never scrolls another part away.
class NarrationComposerFields extends StatefulWidget {
  const NarrationComposerFields({
    super.key,
    required this.controllers,
    required this.hints,
    required this.expanded,
    required this.onToggleExpanded,
    required this.expandLabel,
    required this.readOnly,
    this.foregroundColor = Colors.white,
  });
  final List<TextEditingController> controllers;
  final List<String> hints;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final String expandLabel;
  final bool readOnly;
  final Color foregroundColor;

  @override
  State<NarrationComposerFields> createState() =>
      _NarrationComposerFieldsState();
}

class _NarrationComposerFieldsState extends State<NarrationComposerFields> {
  final _scroll = List.generate(3, (_) => ScrollController());
  @override
  void dispose() {
    for (final controller in _scroll) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SizedBox(
        height: 26,
        child: Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 26),
            tooltip: widget.expandLabel,
            iconSize: 18,
            color: widget.foregroundColor.withValues(alpha: .7),
            icon: Icon(
              widget.expanded
                  ? Icons.close_fullscreen_rounded
                  : Icons.open_in_full_rounded,
            ),
            onPressed: widget.onToggleExpanded,
          ),
        ),
      ),
      for (var index = 0; index < 3; index++) ...[
        if (index > 0)
          Divider(
            height: 1,
            color: widget.foregroundColor.withValues(alpha: .24),
          ),
        Expanded(
          child: Scrollbar(
            controller: _scroll[index],
            thumbVisibility: true,
            child: TextField(
              key: ValueKey('narration-input-$index'),
              controller: widget.controllers[index],
              scrollController: _scroll[index],
              readOnly: widget.readOnly,
              expands: true,
              minLines: null,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              textAlignVertical: TextAlignVertical.top,
              style: TextStyle(
                color: index == 1
                    ? widget.foregroundColor
                    : widget.foregroundColor.withValues(alpha: .7),
                fontSize: 14,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.fromLTRB(0, 4, 10, 4),
                hintText: widget.hints[index],
                hintStyle: TextStyle(
                  color: widget.foregroundColor.withValues(alpha: .6),
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ),
      ],
    ],
  );
}
