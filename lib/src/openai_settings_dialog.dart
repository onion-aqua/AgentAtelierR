import 'package:flutter/material.dart';

import 'ai_services.dart';
import 'app_controller.dart';
import 'settings_detail_page.dart';
import 'app_localization.dart';
import 'openai_configuration_slots.dart';

class OpenAiSettingsDialog extends StatefulWidget {
  const OpenAiSettingsDialog({super.key, required this.controller});
  final AppController controller;

  @override
  State<OpenAiSettingsDialog> createState() => _OpenAiSettingsDialogState();
}

class _OpenAiSettingsDialogState extends State<OpenAiSettingsDialog> {
  late final OpenAiConfigurationSlots _slots;
  late final List<TextEditingController> _urls;
  late final List<TextEditingController> _models;
  final _keys = List.generate(3, (_) => TextEditingController());
  final _clearKeys = List.filled(3, false);
  final _edited = List.filled(3, false);
  late bool _enabled;
  bool _saving = false;
  String? _error;

  AppLanguage get _language => widget.controller.interfaceLanguage;

  @override
  void initState() {
    super.initState();
    _slots = widget.controller.openAiConfigurations;
    _urls = List.generate(
      3,
      (i) => TextEditingController(
        text: _slots.entries[i]?['baseUrl'] ?? 'https://api.openai.com/v1',
      ),
    );
    _models = List.generate(
      3,
      (i) => TextEditingController(text: _slots.entries[i]?['model'] ?? ''),
    );
    _enabled =
        widget.controller.aiEnabled &&
        widget.controller.llmProvider == LlmProvider.openAiCompatible;
  }

  @override
  void dispose() {
    for (final controller in [..._urls, ..._models, ..._keys]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final draft = _slots.copy();
    for (var i = 0; i < OpenAiConfigurationSlots.count; i++) {
      if (i != draft.active && draft.entries[i] == null && !_edited[i]) {
        continue;
      }
      final url = _urls[i].text.trim();
      final model = _models[i].text.trim();
      final parsed = Uri.tryParse(url);
      if (parsed == null ||
          !['https', 'http'].contains(parsed.scheme) ||
          parsed.host.isEmpty ||
          model.isEmpty) {
        setState(() {
          _slots.active = i;
          _error = _language.text(
            '请填写有效的 HTTP(S) 地址和模型名称。',
            'Enter a valid HTTP(S) URL and model name.',
            '有効な HTTP(S) URL とモデル名を入力してください。',
          );
        });
        return;
      }
      draft.entries[i] = {'baseUrl': url, 'model': model};
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await const SecretStore().writeOpenAiSlotKeys({
        for (var i = 0; i < OpenAiConfigurationSlots.count; i++)
          if (_keys[i].text.trim().isNotEmpty || _clearKeys[i])
            i: _keys[i].text.trim(),
      });
      widget.controller.saveOpenAiConfigurations(draft, enabled: _enabled);
      if (mounted) {
        setState(() => _saving = false);
        Navigator.pop(context);
      }
    } on Object {
      // Do not log text fields or storage errors that could contain a key.
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _language.text(
            '配置保存失败，请重试。',
            'Could not save the configuration. Please retry.',
            '設定を保存できませんでした。もう一度お試しください。',
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = _language;
    final index = _slots.active;
    return PopScope(
      canPop: !_saving,
      child: SettingsDetailPage(
        controller: widget.controller,
        title: Text(
          language.text('OpenAI 兼容接口', 'OpenAI-compatible API', 'OpenAI互換API'),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (var i = 0; i < OpenAiConfigurationSlots.count; i++)
                    ChoiceChip(
                      key: ValueKey('openai-slot-$i'),
                      selected: index == i,
                      label: Text(
                        language.text(
                          '配置 ${i + 1}',
                          'Slot ${i + 1}',
                          '設定 ${i + 1}',
                        ),
                      ),
                      onSelected: _saving
                          ? null
                          : (_) => setState(() {
                              _slots.active = i;
                              _error = null;
                            }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                language.text(
                  '最多保存 3 个配置。切换保留本次编辑，保存后启用所选配置。',
                  'Keep up to 3 configurations. Switching keeps drafts; Save activates the selected slot.',
                  '最大3つまで保存できます。切替時は下書きを保持し、保存で選択した設定を有効にします。',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              SettingsOptionCard(
                child: SwitchListTile(
                  value: _enabled,
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _enabled = value),
                  title: Text(
                    language.text('启用真实 AI 对话', 'Enable AI chat', 'AI会話を有効にする'),
                  ),
                ),
              ),
              TextField(
                key: ValueKey('openai-url-$index'),
                controller: _urls[index],
                enabled: !_saving,
                keyboardType: TextInputType.url,
                onChanged: (_) => _edited[index] = true,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: ValueKey('openai-model-$index'),
                controller: _models[index],
                enabled: !_saving,
                onChanged: (_) => _edited[index] = true,
                decoration: InputDecoration(
                  labelText: language.text('模型名称', 'Model name', 'モデル名'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: ValueKey('openai-key-$index'),
                controller: _keys[index],
                onChanged: (value) {
                  if (value.trim().isNotEmpty && _clearKeys[index]) {
                    setState(() => _clearKeys[index] = false);
                  }
                },
                enabled: !_saving,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: language.text(
                    '留空保留此槽位的 Key',
                    'Leave blank to keep this slot’s key',
                    '空欄でこの設定のキーを保持',
                  ),
                  helperText: _clearKeys[index]
                      ? language.text(
                          '保存时清除此槽位的 Key',
                          'This slot’s key will be cleared on Save',
                          '保存時にこの設定のキーを削除',
                        )
                      : null,
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                language.text(
                  '接口使用 /chat/completions 与 SSE 流式增量。每个槽位的 Key 独立保存在系统安全存储，不随备份导出。',
                  'Uses /chat/completions with SSE streaming. Keys are stored separately in secure storage and excluded from backups.',
                  '/chat/completions と SSE ストリーミングを使用。各キーは安全なストレージに個別保存し、バックアップには含めません。',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving
                ? null
                : () => setState(() {
                    _keys[index].clear();
                    _clearKeys[index] = true;
                  }),
            child: Text(language.text('清除 Key', 'Clear key', 'キーを削除')),
          ),
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text(language.text('取消', 'Cancel', 'キャンセル')),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(
              _saving
                  ? language.text('保存中...', 'Saving...', '保存中...')
                  : language.text('保存', 'Save', '保存'),
            ),
          ),
        ],
      ),
    );
  }
}
