import 'package:flutter/material.dart';

/// Edits a voice identifier without exposing the saved or built-in value.
///
/// The public controller remains the effective draft used by save and preview.
/// The separate, initially empty editor is only a replacement input: clearing
/// that input restores the preceding draft, while reset is always explicit.
class HiddenVoiceIdField extends StatefulWidget {
  const HiddenVoiceIdField({
    super.key,
    this.fieldKey,
    required this.controller,
    required this.labelText,
    this.helperText,
    this.emptyValueDescription = '使用内置音色',
    this.resetValue = '',
    this.enabled = true,
    this.onChanged,
  });

  final Key? fieldKey;
  final TextEditingController controller;
  final String labelText;
  final String? helperText;
  final String emptyValueDescription;
  final String resetValue;
  final bool enabled;
  final ValueChanged<String>? onChanged;

  @override
  State<HiddenVoiceIdField> createState() => _HiddenVoiceIdFieldState();
}

class _HiddenVoiceIdFieldState extends State<HiddenVoiceIdField> {
  final _replacement = TextEditingController();
  late String _retainedValue;
  bool _updatingDraft = false;

  @override
  void initState() {
    super.initState();
    _retainedValue = widget.controller.text;
    widget.controller.addListener(_draftChanged);
  }

  @override
  void didUpdateWidget(HiddenVoiceIdField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_draftChanged);
      _retainedValue = widget.controller.text;
      _replacement.clear();
      widget.controller.addListener(_draftChanged);
    }
  }

  void _draftChanged() {
    if (_updatingDraft) return;
    // Voice cloning and preset selection can replace the draft externally.
    // Never copy those identifiers into the visible editor.
    setState(() {
      _retainedValue = widget.controller.text;
      _replacement.clear();
    });
  }

  void _replace(String value) {
    final trimmed = value.trim();
    _updatingDraft = true;
    widget.controller.text = trimmed.isEmpty ? _retainedValue : trimmed;
    _updatingDraft = false;
    widget.onChanged?.call(widget.controller.text);
    setState(() {});
  }

  void _reset() {
    widget.controller.text = widget.resetValue;
    widget.onChanged?.call(widget.controller.text);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_draftChanged);
    _replacement.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: widget.fieldKey,
    controller: _replacement,
    enabled: widget.enabled,
    obscureText: true,
    enableSuggestions: false,
    autocorrect: false,
    onChanged: _replace,
    decoration: InputDecoration(
      labelText: widget.labelText,
      hintText: widget.controller.text.trim().isEmpty
          ? '${widget.emptyValueDescription}；输入自定义 ID 可替换'
          : '已配置音色；输入自定义 ID 可替换',
      helperText: widget.helperText ?? '留空保留当前音色，保存后生效。',
      helperMaxLines: 3,
      suffixIcon: IconButton(
        tooltip: '恢复默认音色',
        onPressed: widget.enabled ? _reset : null,
        icon: const Icon(Icons.restart_alt),
      ),
      border: const OutlineInputBorder(),
    ),
  );
}
