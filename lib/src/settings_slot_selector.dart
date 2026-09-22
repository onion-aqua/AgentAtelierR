import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'settings_slots.dart';

class SettingsSlotSelector extends StatelessWidget {
  const SettingsSlotSelector({
    super.key,
    required this.slots,
    required this.language,
    required this.onSelected,
  });

  final SettingsSlots slots;
  final AppLanguage language;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (var i = 0; i < SettingsSlots.count; i++)
            ChoiceChip(
              key: ValueKey('settings-slot-$i'),
              selected: slots.active == i,
              label: Text(
                language.text('槽位 ${i + 1}', 'Slot ${i + 1}', '${i + 1}枠'),
              ),
              avatar: slots.entries[i] == null
                  ? const Icon(Icons.add_rounded, size: 16)
                  : null,
              onSelected: (_) => onSelected(i),
            ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        language.text(
          '切换时保留本次编辑；保存后使用所选槽位。取消不保存。',
          'Switching keeps drafts. Save to use the selected slot; Cancel discards edits.',
          '切替時は下書きを保持。保存で選択枠を使用し、キャンセルで編集を破棄します。',
        ),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
    ],
  );
}
