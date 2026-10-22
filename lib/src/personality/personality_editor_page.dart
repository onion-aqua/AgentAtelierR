import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../platform_slider.dart';
import '../settings_detail_page.dart';
import '../settings_form.dart';
import 'personality_profile.dart';
import 'personality_presets.dart';
import 'personality_interpreter.dart';
import 'personality_chart.dart';

/// The editor owns a draft. Previewing and moving sliders never changes chat,
/// character state, or the stored configuration until Save completes.
class PersonalityEditorPage extends StatefulWidget {
  const PersonalityEditorPage({
    super.key,
    required this.controller,
    required this.initialConfiguration,
    required this.onSave,
  });

  final AppController controller;
  final PersonalityConfiguration initialConfiguration;
  final Future<void> Function(PersonalityConfiguration) onSave;

  @override
  State<PersonalityEditorPage> createState() => _PersonalityEditorPageState();
}

class _PersonalityEditorPageState extends State<PersonalityEditorPage> {
  late Map<String, dynamic> _draft;
  late String _savedFingerprint;
  final _scenario = TextEditingController(text: '今天的调合非常顺利，你真的很厉害！');
  String _previewEmotion = 'neutral';
  double _previewCloseness = 40;
  String _preset = 'energetic_adventurer';
  String? _error;
  String _status = '已保存';
  bool _busy = false;
  bool _allowPop = false;
  int _editorVersion = 0;
  Widget? _preview;
  final _formScroll = ScrollController();
  PersonalityChartGroup _chartGroup = PersonalityChartGroup.basic;
  String _selectedParameter = 'independence';

  static const _expressionLabels = {
    'dialogue': '影响对话表达',
    'face': '影响表情偏好',
    'action': '影响动作偏好',
    'voice': '影响语音演出偏好',
  };

  @override
  void initState() {
    super.initState();
    _draft = _clone(widget.initialConfiguration.toJson());
    _savedFingerprint = jsonEncode(_draft);
  }

  Map<String, dynamic> _clone(Object value) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

  List<dynamic> get _profiles => _draft['profiles'] as List<dynamic>;
  Map<String, dynamic> get _profile => _profiles
      .cast<Map<String, dynamic>>()
      .firstWhere((entry) => entry['profileId'] == _draft['activeProfileId']);
  String get _characterId => widget.initialConfiguration.characterId;
  bool get _dirty => jsonEncode(_draft) != _savedFingerprint;
  String get _profileKey => '${_profile['profileId']}:$_editorVersion';

  PersonalityConfiguration _validated() => PersonalityConfiguration.fromJson(
    _draft,
    expectedCharacterId: _characterId,
  );

  void _change(VoidCallback edit) {
    setState(() {
      edit();
      _status = '有未保存的修改';
      _error = null;
      _preview = null;
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    try {
      final valid = _validated();
      final now = DateTime.now().toUtc().toIso8601String();
      final configuration = valid.copyWith(
        profiles: [
          for (final profile in valid.profiles)
            profile.copyWith(
              metadata: {
                ...profile.metadata,
                'createdAt': profile.metadata['createdAt'] ?? now,
                'updatedAt': now,
              },
            ),
        ],
      );
      setState(() {
        _busy = true;
        _error = null;
      });
      await widget.onSave(configuration);
      if (!mounted) return;
      setState(() {
        _draft = _clone(configuration.toJson());
        _savedFingerprint = jsonEncode(_draft);
        _editorVersion++;
        _status = '已保存，下次对话生效';
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('人格倾向已保存，下次对话生效')));
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _status = '保存失败，草稿已保留';
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败，草稿已保留：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String description) async =>
      await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(description),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _close() async {
    if (_busy) return;
    if (_dirty && !await _confirm('放弃未保存的修改？', '已保存的人格保持原样，本页草稿将被丢弃。')) return;
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _selectProfile(String id) => _change(() {
    _draft['activeProfileId'] = id;
    _editorVersion++;
  });

  void _showChartGroup(PersonalityChartGroup group) {
    setState(() {
      _chartGroup = group;
      if (PersonalityChartGroup.forParameter(_selectedParameter) != group) {
        _selectedParameter = switch (group) {
          PersonalityChartGroup.axes => 'selfOther',
          PersonalityChartGroup.basic => 'independence',
          PersonalityChartGroup.relationships => 'attachment',
          PersonalityChartGroup.tuning => 'intensity',
        };
      }
    });
  }

  void _editChart(Map<String, int> changes) {
    if (_busy) return;
    final edits = <String, int>{};
    for (final entry in changes.entries) {
      final values = _chartValues(entry.key);
      if (!values.containsKey(entry.key)) continue;
      final value = entry.value.clamp(
        PersonalityChartGroup.forParameter(entry.key) ==
                PersonalityChartGroup.axes
            ? -100
            : 0,
        100,
      );
      if (values[entry.key] != value) edits[entry.key] = value;
    }
    if (edits.isEmpty) return;
    _change(() {
      for (final entry in edits.entries) {
        _chartValues(entry.key)[entry.key] = entry.value;
      }
      if (edits.length == 1) _selectedParameter = edits.keys.single;
    });
  }

  Map<String, dynamic> _chartValues(String key) =>
      _profile[switch (PersonalityChartGroup.forParameter(key)) {
            PersonalityChartGroup.axes => 'baseAxes',
            PersonalityChartGroup.tuning => 'tuning',
            _ => 'traits',
          }]
          as Map<String, dynamic>;

  Widget _chart(double height) {
    final identity = _profileKey;
    final group = _chartGroup;
    return PersonalityChartPanel(
      key: const ValueKey('personality-live-chart'),
      editingIdentity: identity,
      baseAxes: Map<String, int>.from(_profile['baseAxes'] as Map),
      traits: Map<String, int>.from(_profile['traits'] as Map),
      tuning: Map<String, int>.from(_profile['tuning'] as Map),
      group: group,
      selectedParameter: _selectedParameter,
      onGroupChanged: _showChartGroup,
      onSelectParameter: (key) => setState(() => _selectedParameter = key),
      onChanged: _busy
          ? null
          : (changes) {
              if (identity == _profileKey && group == _chartGroup) {
                _editChart(changes);
              }
            },
      maxHeight: height,
    );
  }

  String _newId() => 'custom_${DateTime.now().microsecondsSinceEpoch}';

  void _newPreset() {
    if (_profiles.length >= 24) {
      setState(() => _error = '最多保存 24 份人格档案，请先删除不需要的档案。');
      return;
    }
    final profile = PersonalityPresets.create(
      _preset,
      _characterId,
      profileId: _newId(),
    );
    _change(() {
      _profiles.add(_clone(profile.toJson()));
      _draft['activeProfileId'] = profile.profileId;
      _editorVersion++;
    });
  }

  void _copyProfile() {
    if (_profiles.length >= 24) {
      setState(() => _error = '最多保存 24 份人格档案，请先删除不需要的档案。');
      return;
    }
    final clone = _clone(_profile);
    clone['profileId'] = _newId();
    final name = '${clone['name']}';
    clone['name'] = '${name.substring(0, name.length.clamp(0, 54))} · 副本';
    clone['presetId'] = null;
    _change(() {
      _profiles.add(clone);
      _draft['activeProfileId'] = clone['profileId'];
      _editorVersion++;
    });
  }

  Future<void> _restore() async {
    if (!await _confirm('恢复当前人格的默认值？', '只替换当前档案的草稿，其他档案不受影响；点击保存后生效。')) return;
    if (!mounted) return;
    final id = _profile['presetId'] as String?;
    final restored = id != null && PersonalityPresets.ids.contains(id)
        ? PersonalityPresets.create(
            id,
            _characterId,
            profileId: _profile['profileId'] as String,
            name: _profile['name'] as String,
          )
        : PersonalityProfile(
            profileId: _profile['profileId'] as String,
            name: _profile['name'] as String,
            characterId: _characterId,
          );
    _change(() {
      _profiles[_profiles.indexOf(_profile)] = _clone(restored.toJson());
      _editorVersion++;
    });
  }

  Future<void> _deleteProfile() async {
    if (_profiles.length <= 1) return;
    if (!await _confirm('删除当前人格档案？', '保存后删除才生效，其他人格档案和游戏存档不受影响。')) return;
    if (!mounted) return;
    _change(() {
      _profiles.remove(_profile);
      _draft['activeProfileId'] = (_profiles.first as Map)['profileId'];
      _editorVersion++;
    });
  }

  Future<void> _importJson(String source) async {
    try {
      if (source.length > 1024 * 1024) {
        throw const FormatException('人格配置不能超过 1 MB');
      }
      final imported = PersonalityConfiguration.fromJson(
        jsonDecode(source),
        expectedCharacterId: _characterId,
      );
      if (!mounted) return;
      if (!await _confirm('导入这份人格配置？', '将替换本页的人格档案草稿。校验已通过，保存后生效。')) return;
      if (!mounted) return;
      _change(() {
        _draft = _clone(imported.toJson());
        _editorVersion++;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = '导入失败，原草稿已保留：$error');
    }
  }

  Future<void> _pickImport() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (file == null || !mounted) return;
      if (await file.length() > 1024 * 1024) {
        throw const FormatException('人格配置不能超过 1 MB');
      }
      await _importJson(utf8.decode(await file.readAsBytes()));
    } on Object catch (error) {
      if (mounted) setState(() => _error = '读取失败，原草稿已保留：$error');
    }
  }

  Future<void> _pasteImport() async {
    final input = TextEditingController();
    try {
      final value = await showDialog<String>(
        context: context,
        useRootNavigator: false,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('粘贴人格 JSON'),
          content: SizedBox(
            width: 560,
            child: TextField(
              key: const ValueKey('personality-json-input'),
              controller: input,
              maxLines: 12,
              decoration: const InputDecoration(labelText: '完整配置 JSON'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, input.text),
              child: const Text('校验并导入'),
            ),
          ],
        ),
      );
      if (value != null && mounted) await _importJson(value);
    } finally {
      // Dialog route disposal completes after its reverse transition.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      input.dispose();
    }
  }

  Future<void> _export({required bool clipboard}) async {
    try {
      final text = const JsonEncoder.withIndent('  ')
          .convert(_validated().toJson());
      if (clipboard) {
        await Clipboard.setData(ClipboardData(text: text));
      } else {
        final output = await FilePicker.saveFile(
          fileName: 'personality-$_characterId.json',
          bytes: Uint8List.fromList(utf8.encode(text)),
          mimeType: 'application/json',
        );
        if (output == null) return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(clipboard ? '人格 JSON 已复制' : '人格 JSON 已导出')),
        );
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '导出失败：$error');
    }
  }

  void _runPreview() {
    try {
      final configuration = _validated();
      final result = PersonalityInterpreter().interpret(
        configuration.activeProfile,
        input: _scenario.text,
        emotion: _previewEmotion,
        closeness: _previewCloseness.round(),
        enabled: true,
      );
      setState(() {
        _error = null;
        _preview = Column(
          key: const ValueKey('personality-preview-result'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsSectionHeading(
              '规则试运行结果',
              description: '本地行为示意，不是模型实测回复；不调用 API，也不修改存档。',
            ),
            Text(result.coreSummary),
            const SizedBox(height: 12),
            Text('使用动机：${result.motives.join('；')}'),
            const SizedBox(height: 12),
            if (result.triggeredRules.isEmpty)
              const Text('没有触发额外矛盾规则，使用基础人格倾向。'),
            for (final rule in result.triggeredRules)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${rule.id} · 优先级 ${rule.priority}'),
                subtitle: Text(
                  '触发：${result.triggerReasons[rule.id] ?? rule.triggerType}\n表面：${rule.surface}\n需求：${rule.hiddenNeed}\n反应：${rule.response}\n约束：${rule.constraint}',
                ),
              ),
            const SettingsSectionHeading('对话示意'),
            Text(result.preview),
            const SettingsSectionHeading('演出偏好'),
            Text(
              result.preferences.entries
                  .map((entry) => '${entry.key}：${entry.value}')
                  .join('\n'),
            ),
            ExpansionTile(
              title: const Text('查看发送给模型的行为约束'),
              children: [SelectableText(result.prompt)],
            ),
          ],
        );
      });
    } on Object catch (error) {
      setState(() => _error = '暂时无法试运行：$error');
    }
  }

  @override
  void dispose() {
    _formScroll.dispose();
    _scenario.dispose();
    super.dispose();
  }

  Widget _textField(
    String field,
    String label, {
    int lines = 1,
    int maxLength = 300,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      key: ValueKey('personality-$_profileKey-$field'),
      initialValue: _profile[field]?.toString() ?? '',
      enabled: !_busy,
      maxLines: lines,
      maxLength: maxLength,
      decoration: InputDecoration(labelText: label, counterText: ''),
      onChanged: (value) => _change(() => _profile[field] = value),
    ),
  );

  Widget _section(
    String title,
    String subtitle,
    List<Widget> children, {
    bool expanded = false,
    Key? key,
  }) => ExpansionTile(
    key: key,
    initiallyExpanded: expanded,
    title: Text(title),
    subtitle: Text(subtitle),
    children: [
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ],
  );

  Widget _overview() {
    final preset = _profile['presetId'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('personality-profile-selector-$_editorVersion'),
          initialValue: _draft['activeProfileId'] as String,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '当前人格档案'),
          items: [
            for (final profile in _profiles)
              DropdownMenuItem(
                value: (profile as Map)['profileId'] as String,
                child: Text(
                  profile['name'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: _busy
              ? null
              : (value) {
                  if (value != null) _selectProfile(value);
                },
        ),
        const SizedBox(height: 12),
        Text('预设：${PersonalityPresets.names[preset] ?? '自定义'}'),
      ],
    );
  }

  Widget _rules() => _section('动机与内在矛盾', '编辑长期需求、矛盾和情境行为规则', [
    TextFormField(
      key: ValueKey('personality-motives-$_profileKey'),
      initialValue: (_profile['motives'] as List).join('\n'),
      enabled: !_busy,
      maxLines: 5,
      decoration: const InputDecoration(
        labelText: '深层动机',
        helperText: '每行一条；每轮最多选择两条相关动机。',
      ),
      onChanged: (text) => _change(
        () => _profile['motives'] = text
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .map((line) => line.trim())
            .toList(),
      ),
    ),
    for (final kind in ['contradictions', 'situations']) ...[
      SettingsSectionHeading(kind == 'contradictions' ? '内在矛盾规则' : '情境行为规则'),
      for (var i = 0; i < (_profile[kind] as List).length; i++)
        _ruleTile(kind, i),
      OutlinedButton.icon(
        key: ValueKey('personality-add-$kind'),
        onPressed: _busy ? null : () => _editRule(kind),
        icon: const Icon(Icons.add),
        label: Text(kind == 'contradictions' ? '添加矛盾规则' : '添加情境规则'),
      ),
    ],
    const SettingsSectionHeading(
      '表达范围',
      description: '演出只提供语义偏好，合法表情和动作仍由原有规划器决定。',
    ),
    for (final entry in _expressionLabels.entries)
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(entry.value),
        value: (_profile['expression'] as Map)[entry.key] == true,
        onChanged: _busy
            ? null
            : (value) => _change(
                () => (_profile['expression'] as Map)[entry.key] = value,
              ),
      ),
  ]);

  Widget _ruleTile(String kind, int index) {
    final rules = _profile[kind] as List;
    final rule = rules[index] as Map<String, dynamic>;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SettingsOptionCard(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${rule['id']} · 优先级 ${rule['priority']}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(rule['response'] as String? ?? ''),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用规则'),
                value: rule['enabled'] == true,
                onChanged: _busy
                    ? null
                    : (value) => _change(() => rule['enabled'] = value),
              ),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _editRule(kind, index: index),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('编辑'),
                  ),
                  IconButton(
                    tooltip: '上移规则',
                    onPressed: index > 0 && !_busy
                        ? () => _change(() {
                            final old = rules.removeAt(index);
                            rules.insert(index - 1, old);
                          })
                        : null,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  IconButton(
                    tooltip: '下移规则',
                    onPressed: index + 1 < rules.length && !_busy
                        ? () => _change(() {
                            final old = rules.removeAt(index);
                            rules.insert(index + 1, old);
                          })
                        : null,
                    icon: const Icon(Icons.arrow_downward),
                  ),
                  IconButton(
                    tooltip: '删除规则',
                    onPressed: _busy
                        ? null
                        : () => _change(() => rules.removeAt(index)),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editRule(String kind, {int? index}) async {
    final rules = _profile[kind] as List;
    final initial = index == null
        ? PersonalityRule(id: 'rule_${DateTime.now().microsecondsSinceEpoch}')
        : PersonalityRule.fromJson(rules[index]);
    final result = await pushSettingsPage<PersonalityRule>(
      context: context,
      controller: widget.controller,
      builder: (_) => _PersonalityRuleEditor(
        controller: widget.controller,
        initial: initial,
      ),
    );
    if (result == null || !mounted) return;
    _change(() {
      if (index == null) {
        rules.add(_clone(result.toJson()));
      } else {
        rules[index] = _clone(result.toJson());
      }
    });
  }

  Widget _testing() => _section('情境测试', '本地预览，不消耗 API，不写入游戏存档', [
    const Text('试运行会临时模拟启用当前草稿，不改变总开关。真正的角色回复效果请保存并启用后在聊天中体验。'),
    const SizedBox(height: 12),
    TextField(
      key: const ValueKey('personality-scenario'),
      controller: _scenario,
      enabled: !_busy,
      maxLines: 4,
      decoration: const InputDecoration(
        labelText: '发生了什么？',
        helperText: '例如：用户说今天不想聊天，希望独处。',
      ),
    ),
    const SizedBox(height: 12),
    DropdownButtonFormField<String>(
      initialValue: _previewEmotion,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '模拟当前情绪'),
      items: [
        for (final emotion in [
          'neutral',
          'happy',
          'curious',
          'shy',
          'sad',
          'angry',
          'worried',
          'excited',
        ])
          DropdownMenuItem(value: emotion, child: Text(emotion)),
      ],
      onChanged: _busy
          ? null
          : (value) => setState(() => _previewEmotion = value ?? 'neutral'),
    ),
    const SizedBox(height: 12),
    Text('模拟亲近感：${_previewCloseness.round()}'),
    PlatformSlider(
      value: _previewCloseness,
      min: 0,
      max: 100,
      divisions: 100,
      onChanged: _busy
          ? null
          : (value) => setState(() => _previewCloseness = value),
    ),
    FilledButton.icon(
      key: const ValueKey('personality-run-preview'),
      onPressed: _busy ? null : _runPreview,
      icon: const Icon(Icons.play_arrow),
      label: const Text('试运行当前草稿'),
    ),
    ?_preview,
  ]);

  Widget _management() => _section('预设与配置', '独立档案、JSON 导入导出与版本', [
    _textField('name', '当前档案名称', maxLength: 60),
    TextFormField(
      key: ValueKey('personality-description-$_profileKey'),
      initialValue:
          (_profile['metadata'] as Map)['description'] as String? ?? '',
      enabled: !_busy,
      maxLines: 3,
      maxLength: 500,
      decoration: const InputDecoration(labelText: '档案说明', counterText: ''),
      onChanged: (value) =>
          _change(() => (_profile['metadata'] as Map)['description'] = value),
    ),
    const SizedBox(height: 12),
    DropdownButtonFormField<String>(
      key: const ValueKey('personality-preset-selector'),
      initialValue: _preset,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '内置预设'),
      items: [
        for (final id in PersonalityPresets.ids)
          DropdownMenuItem(
            value: id,
            child: Text(PersonalityPresets.names[id]!),
          ),
      ],
      onChanged: _busy
          ? null
          : (value) => setState(() => _preset = value ?? _preset),
    ),
    const SizedBox(height: 12),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('personality-new-preset'),
          onPressed: _busy ? null : _newPreset,
          icon: const Icon(Icons.add),
          label: const Text('以预设新建档案'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('personality-copy-profile'),
          onPressed: _busy ? null : _copyProfile,
          icon: const Icon(Icons.copy_outlined),
          label: const Text('复制当前人格'),
        ),
        TextButton(
          onPressed: _busy ? null : _restore,
          child: const Text('恢复当前档案默认值'),
        ),
        TextButton(
          onPressed: _busy || _profiles.length <= 1 ? null : _deleteProfile,
          child: const Text('删除当前档案'),
        ),
      ],
    ),
    const SettingsSectionHeading('配置文件'),
    Text('格式版本：${_draft['schemaVersion']} · 当前角色：$_characterId'),
    const SizedBox(height: 12),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _pickImport,
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('导入 JSON 文件'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _export(clipboard: false),
          icon: const Icon(Icons.save_alt),
          label: const Text('导出 JSON 文件'),
        ),
        TextButton(
          key: const ValueKey('personality-paste-json'),
          onPressed: _busy ? null : _pasteImport,
          child: const Text('粘贴 JSON'),
        ),
        TextButton(
          key: const ValueKey('personality-copy-json'),
          onPressed: _busy ? null : () => _export(clipboard: true),
          child: const Text('复制 JSON'),
        ),
      ],
    ),
    const SizedBox(height: 8),
    const Text('导入配置先校验，保存后才影响对话。预设只提供初始值，不会在加载时覆盖你的修改。'),
  ]);

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && (!_dirty || _allowPop),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _close();
    },
    child: SettingsDetailPage(
      controller: widget.controller,
      title: const Text('人格倾向'),
      scrollable: false,
      contentPadding: EdgeInsets.zero,
      content: LayoutBuilder(
        builder: (context, constraints) => Scrollbar(
          controller: _formScroll,
          child: SingleChildScrollView(
            key: const ValueKey('personality-editor-scroll'),
            controller: _formScroll,
            padding: const EdgeInsets.all(16),
            child: _formContent(
              (constraints.maxHeight * .8).clamp(400.0, 560.0),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : _close, child: const Text('取消')),
        FilledButton.icon(
          key: const ValueKey('personality-save'),
          onPressed: _busy ? null : _save,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(_busy ? '正在保存…' : '保存并使用'),
        ),
      ],
    ),
  );

  Widget _formContent(double chartHeight) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SettingsOptionCard(
        child: SwitchListTile(
          key: const ValueKey('personality-enabled'),
          value: _draft['enabled'] == true,
          onChanged: _busy
              ? null
              : (value) => _change(() => _draft['enabled'] = value),
          title: const Text('启用人格倾向'),
          subtitle: const Text('保存后生效；关闭即可沿用原有角色设定。'),
        ),
      ),
      const SizedBox(height: 12),
      Semantics(
        liveRegion: true,
        child: Text(
          _status,
          key: const ValueKey('personality-save-status'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: SelectableText(
            _error!,
            key: const ValueKey('personality-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      _overview(),
      const SizedBox(height: 16),
      _chart(chartHeight),
      const SizedBox(height: 8),
      Text(switch (_selectedParameter) {
        'selfOther' => '负值偏向独立与个人目标，正值偏向照顾关系与他人。',
        'restraintExpression' => '负值偏向克制与延迟表达，正值偏向外放与主动互动。',
        _ =>
          PersonalityProfile.traitDescriptions[_selectedParameter] ??
              '调整表达的强度与节奏，不直接改变游戏中的心情或关系数值。',
      }, style: Theme.of(context).textTheme.bodySmall),
      _rules(),
      _testing(),
      _management(),
    ],
  );
}

class _PersonalityRuleEditor extends StatefulWidget {
  const _PersonalityRuleEditor({
    required this.controller,
    required this.initial,
  });
  final AppController controller;
  final PersonalityRule initial;
  @override
  State<_PersonalityRuleEditor> createState() => _PersonalityRuleEditorState();
}

class _PersonalityRuleEditorState extends State<_PersonalityRuleEditor> {
  late final Map<String, dynamic> _draft = Map<String, dynamic>.from(
    jsonDecode(jsonEncode(widget.initial.toJson())) as Map,
  );
  String? _error;
  bool _allowPop = false;
  bool _confirming = false;
  bool get _dirty => jsonEncode(_draft) != jsonEncode(widget.initial.toJson());

  Future<void> _close() async {
    if (_confirming) return;
    if (_dirty) {
      _confirming = true;
      final discard = await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('放弃未保存的规则修改？'),
          content: const Text('继续编辑会保留当前规则草稿；放弃后返回人格页面。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃修改'),
            ),
          ],
        ),
      );
      _confirming = false;
      if (discard != true || !mounted) return;
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Widget field(String name, String label, {int lines = 2, bool list = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          key: ValueKey('personality-rule-$name'),
          initialValue: list
              ? (_draft[name] as List? ?? []).join('、')
              : _draft[name]?.toString() ?? '',
          maxLines: lines,
          decoration: InputDecoration(labelText: label),
          onChanged: (value) => setState(
            () => _draft[name] = list
                ? value
                      .split(RegExp(r'[,，、\n]'))
                      .map((v) => v.trim())
                      .where((v) => v.isNotEmpty)
                      .toList()
                : value,
          ),
        ),
      );

  void _save() {
    try {
      final rule = PersonalityRule.fromJson(_draft);
      setState(() => _allowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, rule);
      });
    } on Object catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_dirty || _allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _close();
    },
    child: SettingsDetailPage(
      controller: widget.controller,
      title: const Text('编辑人格规则'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field('id', '稳定规则 ID', lines: 1),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用规则'),
            value: _draft['enabled'] == true,
            onChanged: (value) => setState(() => _draft['enabled'] = value),
          ),
          Text('优先级：${_draft['priority']}（同优先级按列表顺序）'),
          PlatformSlider(
            value: (_draft['priority'] as int).toDouble(),
            min: 0,
            max: 100,
            divisions: 100,
            onChanged: (value) =>
                setState(() => _draft['priority'] = value.round()),
          ),
          DropdownButtonFormField<String>(
            initialValue: _draft['triggerType'] as String,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '触发方式'),
            items: [
              for (final entry in PersonalityRule.triggerLabels.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (value) =>
                setState(() => _draft['triggerType'] = value ?? 'always'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _draft['emotion'] as String? ?? '',
            decoration: const InputDecoration(labelText: '仅在此情绪下触发（可选）'),
            isExpanded: true,
            items: [
              const DropdownMenuItem(value: '', child: Text('不限情绪')),
              for (final emotion in PersonalityRule.emotions)
                DropdownMenuItem(value: emotion, child: Text(emotion)),
            ],
            onChanged: (value) =>
                setState(() => _draft['emotion'] = value == '' ? null : value),
          ),
          const SizedBox(height: 12),
          for (final entry in {
            'minCloseness': '最低亲近感',
            'maxCloseness': '最高亲近感',
          }.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextFormField(
                initialValue: _draft[entry.key]?.toString() ?? '',
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: entry.value,
                  helperText: '0–100；留空表示不限',
                ),
                onChanged: (value) => setState(
                  () => _draft[entry.key] = value.trim().isEmpty
                      ? null
                      : int.tryParse(value) ?? value,
                ),
              ),
            ),
          field('keywords', '触发关键词（顿号、逗号或换行分隔）', list: true),
          field('situations', '适用情境（可留空）', list: true),
          field('surface', '表面行为'),
          field('hiddenNeed', '隐藏需求'),
          field('response', '行为反应'),
          field('constraint', '约束条件'),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: _close, child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存规则草稿')),
      ],
    ),
  );
}
