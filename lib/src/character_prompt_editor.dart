import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'settings_detail_page.dart';
import 'app_localization.dart';
import 'character_prompt_defaults.dart';
import 'glass_ui.dart';
import 'world_prompt_defaults.dart';
import 'settings_slots.dart';
import 'settings_slot_selector.dart';

class CharacterPromptEditor extends StatefulWidget {
  const CharacterPromptEditor({
    super.key,
    required this.controller,
    this.world = false,
  });
  final AppController controller;
  final bool world;
  @override
  State<CharacterPromptEditor> createState() => _CharacterPromptEditorState();
}

class _CharacterPromptEditorState extends State<CharacterPromptEditor> {
  SettingsSlotKind get _kind =>
      widget.world ? SettingsSlotKind.world : SettingsSlotKind.character;
  late final _slots = widget.controller.settingsSlots(_kind);
  late final _text = TextEditingController(
    text: widget.world
        ? widget.controller.editableWorldSetting
        : widget.controller.editableCharacterPersona,
  );

  @override
  void initState() {
    super.initState();
    _text.addListener(_refreshStats);
  }

  void _refreshStats() => setState(() {});

  Future<void> _expandEditor() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final language = widget.controller.interfaceLanguage;
    await pushSettingsPage<void>(
      context: context,
      controller: widget.controller,
      builder: (context) => SettingsDetailPage(
        controller: widget.controller,
        title: Text(
          widget.world
              ? language.text('世界书', 'World book', 'ワールドブック')
              : language.text('人物设定', 'Character profile', 'キャラクター設定'),
        ),
        scrollable: false,
        content: TextField(
          key: const ValueKey('fullscreen-prompt-input'),
          controller: _text,
          expands: true,
          minLines: null,
          maxLines: null,
          textAlignVertical: TextAlignVertical.top,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.fullscreen_exit),
            label: Text(language.text('收起', 'Collapse', '縮小')),
          ),
        ],
      ),
    );
    if (mounted) FocusManager.instance.primaryFocus?.unfocus();
  }

  void _stashSlot() {
    final defaultText = widget.world
        ? defaultWorldSetting
        : defaultCharacterPersona;
    _slots.entries[_slots.active] = {
      'text': _text.text.trim() == defaultText.trim() ? '' : _text.text,
    };
  }

  void _selectSlot(int index) {
    if (index == _slots.active) return;
    _stashSlot();
    setState(() {
      _slots.active = index;
      final value = _slots.entries[index]?['text'] ?? '';
      _text.text = value.isEmpty
          ? (widget.world ? defaultWorldSetting : defaultCharacterPersona)
          : value;
    });
  }

  @override
  void dispose() {
    _text.removeListener(_refreshStats);
    _text.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final language = widget.controller.interfaceLanguage;
    final restore = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          widget.world
              ? language.text(
                  '恢复默认世界设定？',
                  'Restore the default world setting?',
                  '世界設定をデフォルトに戻しますか？',
                )
              : language.text(
                  '恢复默认人物设定？',
                  'Restore the default character profile?',
                  'キャラクター設定をデフォルトに戻しますか？',
                ),
        ),
        content: Text(
          language.text(
            '将替换编辑框里的内容，点击保存后生效。',
            'This replaces the editor content. Save to apply it.',
            '編集内容を置き換えます。保存すると反映されます。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(language.text('取消', 'Cancel', 'キャンセル')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(language.text('恢复默认', 'Restore defaults', 'デフォルトに戻す')),
          ),
        ],
      ),
    );
    if (restore == true && mounted) {
      _text.text = widget.world ? defaultWorldSetting : defaultCharacterPersona;
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = widget.controller.interfaceLanguage;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final defaultText = widget.world
        ? defaultWorldSetting
        : defaultCharacterPersona;
    final isDefault = _text.text.trim() == defaultText.trim();
    final estimatedTokens = (_text.text.runes.length / 2.5).ceil();
    return SettingsDetailPage(
      controller: widget.controller,
      scrollable: false,
      contentPadding: EdgeInsets.zero,
      title: Text(
        widget.world
            ? language.text('世界书', 'World book', 'ワールドブック')
            : language.text('人物设定', 'Character profile', 'キャラクター設定'),
      ),
      content: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: SizedBox(
                height: constraints.maxHeight.clamp(
                  700 * MediaQuery.textScalerOf(context).scale(1),
                  double.infinity,
                ),
                child: Column(
                  children: [
                    SettingsSlotSelector(
                      slots: _slots,
                      language: language,
                      onSelected: _selectSlot,
                    ),
                    GlassSurface(
                      liquidGlass: widget.controller.liquidGlassChatUi,
                      tone: dark ? GlassTone.dark : GlassTone.light,
                      fallbackColor: dark
                          ? const Color(0xD92A2B2D)
                          : const Color(0xD9EEF2F0),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 54,
                              height: 54,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Icon(
                                widget.world
                                    ? Icons.menu_book_rounded
                                    : Icons.person_rounded,
                                color: theme.colorScheme.onPrimaryContainer,
                                size: 30,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.world
                                        ? language.text(
                                            'AgentAtelierR 世界书',
                                            'AgentAtelierR World Book',
                                            'AgentAtelierR ワールドブック',
                                          )
                                        : language.text(
                                            '莱莎人物卡',
                                            'Ryza Character Card',
                                            'ライザ キャラクターカード',
                                          ),
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      _TavernMetaChip(
                                        icon: widget.world
                                            ? Icons.public_rounded
                                            : Icons.badge_rounded,
                                        label: isDefault
                                            ? language.text(
                                                '默认',
                                                'Default',
                                                'デフォルト',
                                              )
                                            : language.text(
                                                '自定义',
                                                'Custom',
                                                'カスタム',
                                              ),
                                      ),
                                      _TavernMetaChip(
                                        icon: Icons.vertical_align_top_rounded,
                                        label: language.text(
                                          '系统提示词',
                                          'System prompt',
                                          'システムプロンプト',
                                        ),
                                      ),
                                      _TavernMetaChip(
                                        icon: Icons.lock_outline_rounded,
                                        label: language.text(
                                          '底层规则受保护',
                                          'Core rules protected',
                                          '基本ルール保護',
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: GlassSurface(
                        liquidGlass: widget.controller.liquidGlassChatUi,
                        tone: dark ? GlassTone.dark : GlassTone.light,
                        fallbackColor: dark
                            ? const Color(0xD92A2B2D)
                            : const Color(0xD9EEF2F0),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  Text(
                                    widget.world
                                        ? language.text(
                                            '世界书内容',
                                            'World book content',
                                            'ワールドブック内容',
                                          )
                                        : language.text(
                                            '角色描述与扮演资料',
                                            'Description and roleplay data',
                                            'キャラクター説明とロールプレイ情報',
                                          ),
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    '${_text.text.runes.length} · ≈ $estimatedTokens tokens',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                widget.world
                                    ? language.text(
                                        '在每次启用世界书的请求中注入。用于时代、地点、社会背景和世界规则。',
                                        'Injected when the world book is enabled. Use it for era, locations, society, and world rules.',
                                        'ワールドブック有効時に注入されます。時代、場所、社会背景、世界ルールを記述します。',
                                      )
                                    : language.text(
                                        '在每次启用人物设定的请求中注入。用于身份、性格、背景和互动方式。',
                                        'Injected when the character profile is enabled. Use it for identity, personality, background, and interaction style.',
                                        'キャラクター設定有効時に注入されます。身元、性格、背景、交流方法を記述します。',
                                      ),
                                style: theme.textTheme.bodySmall,
                              ),
                              const SizedBox(height: 10),
                              Align(
                                alignment: Alignment.centerRight,
                                child: IconButton(
                                  key: const ValueKey('expand-prompt-input'),
                                  tooltip: language.text(
                                    '全屏编辑',
                                    'Edit fullscreen',
                                    '全画面で編集',
                                  ),
                                  icon: const Icon(Icons.fullscreen),
                                  onPressed: _expandEditor,
                                ),
                              ),
                              Expanded(
                                child: TextField(
                                  controller: _text,
                                  expands: true,
                                  maxLines: null,
                                  minLines: null,
                                  textAlignVertical: TextAlignVertical.top,
                                  decoration: InputDecoration(
                                    filled: true,
                                    fillColor: dark
                                        ? Colors.black.withValues(alpha: 0.18)
                                        : Colors.white.withValues(alpha: 0.48),
                                    border: const OutlineInputBorder(),
                                    hintText: widget.world
                                        ? language.text(
                                            '输入世界书内容',
                                            'Enter world book content',
                                            'ワールドブック内容を入力',
                                          )
                                        : language.text(
                                            '输入人物设定',
                                            'Enter character profile',
                                            'キャラクター設定を入力',
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _restore,
                            icon: const Icon(Icons.restore_rounded),
                            label: Text(
                              language.text(
                                '恢复默认',
                                'Restore defaults',
                                'デフォルトに戻す',
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _save(context),
                            icon: const Icon(Icons.save_outlined),
                            label: Text(
                              language.text('保存并使用', 'Save & use', '保存して使用'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _save(BuildContext context) {
    final language = widget.controller.interfaceLanguage;
    if (_text.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            language.text(
              '请填写设定，或使用恢复默认。',
              'Enter a setting or restore the default.',
              '設定を入力するか、デフォルトに戻してください。',
            ),
          ),
        ),
      );
      return;
    }
    _stashSlot();
    widget.controller.saveSettingsSlots(_kind, _slots);
    Navigator.pop(context);
  }
}

class _TavernMetaChip extends StatelessWidget {
  const _TavernMetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: Theme.of(context).dividerColor),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14),
        const SizedBox(width: 5),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    ),
  );
}
