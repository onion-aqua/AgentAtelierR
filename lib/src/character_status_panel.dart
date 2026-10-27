import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'character_state.dart';
import 'body_sensitivity.dart';
import 'character_status_body_map.dart';
import 'character_status_silhouette.dart';
import 'glass_ui.dart';
import 'story_clock.dart';

enum _BodyMetric { curiosity, mood, closeness, satiety, energy, posture }

/// A schematic view of the existing save's stats. Body regions are navigation
/// anchors, not additional health/injury values or a second simulation.
class CharacterStatusPanel extends StatefulWidget {
  const CharacterStatusPanel({
    super.key,
    required this.language,
    required this.characterName,
    required this.state,
    required this.clock,
    required this.clockEnabled,
    required this.relationshipPoints,
    required this.postureLabel,
    required this.location,
    required this.sceneTimeLabel,
    required this.memoryEnabled,
    this.outfitLabel,
    this.silhouette,
    this.sensitivity,
    this.onSensitivityChanged,
    this.onSensitivityUnlock,
    this.manualEditingEnabled = false,
    this.touchGrowthEnabled = true,
    this.onTouchGrowthChanged,
  });

  final AppLanguage language;
  final String characterName;
  final CharacterState state;
  final StoryClock clock;
  final bool clockEnabled;
  final int relationshipPoints;
  final String postureLabel;
  final String location;
  final String sceneTimeLabel;
  final bool memoryEnabled;
  final String? outfitLabel;
  final Future<CharacterStatusSilhouette>? silhouette;
  final BodySensitivityState? sensitivity;
  final void Function(BodySensitivityPart, int)? onSensitivityChanged;
  final ValueChanged<BodySensitivityPart>? onSensitivityUnlock;
  final bool manualEditingEnabled;
  final bool touchGrowthEnabled;
  final ValueChanged<bool>? onTouchGrowthChanged;

  @override
  State<CharacterStatusPanel> createState() => _CharacterStatusPanelState();
}

class _CharacterStatusPanelState extends State<CharacterStatusPanel> {
  _BodyMetric _selected = _BodyMetric.mood;
  BodySensitivityPart _selectedPart = BodySensitivityPart.head;
  bool _showSensitivity = false;
  int? _sensitivityDraft;
  bool _draggingSensitivity = false;
  late final BodySensitivityState _defaults = BodySensitivityState();
  BodySensitivityState get sensitivity => widget.sensitivity ?? _defaults;

  @override
  void didUpdateWidget(covariant CharacterStatusPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.manualEditingEnabled ||
        !_draggingSensitivity ||
        oldWidget.characterName != widget.characterName) {
      _sensitivityDraft = null;
      _draggingSensitivity = false;
    }
  }

  AppLanguage get language => widget.language;
  CharacterState get state => widget.state;
  String _text(String zh, String en, String ja) => language.text(zh, en, ja);

  String _label(_BodyMetric metric) => switch (metric) {
    _BodyMetric.curiosity => _text('好奇心', 'Curiosity', '好奇心'),
    _BodyMetric.mood => _text('心情', 'Mood', '気分'),
    _BodyMetric.closeness => _text('亲近感', 'Closeness', '親しみ'),
    _BodyMetric.satiety => _text('饱食度', 'Satiety', '満腹度'),
    _BodyMetric.energy => _text('精力', 'Energy', '元気'),
    _BodyMetric.posture => _text('当前姿态', 'Posture', '現在の姿勢'),
  };

  String _region(_BodyMetric metric) => switch (metric) {
    _BodyMetric.curiosity => _text('头部', 'MIND', '頭部'),
    _BodyMetric.mood => _text('胸口', 'EMOTION', '胸元'),
    _BodyMetric.closeness => _text('心间', 'BOND', '心'),
    _BodyMetric.satiety => _text('腹部', 'ABDOMEN', '腹部'),
    _BodyMetric.energy => _text('四肢', 'LIMBS', '四肢'),
    _BodyMetric.posture => _text('下肢', 'STANCE', '下肢'),
  };

  String _value(_BodyMetric metric) => switch (metric) {
    _BodyMetric.satiety =>
      widget.clockEnabled ? '${widget.clock.satiety}' : '—',
    _BodyMetric.posture => widget.postureLabel,
    _ => '${state.values[metric.name] ?? 0}',
  };

  String _band(_BodyMetric metric) {
    final band = (state.bands[metric.name] ?? 1).clamp(0, 2);
    return switch (metric) {
      _BodyMetric.mood => [
        _text('低落', 'Low', '落ち込み'),
        _text('平静', 'Calm', '平静'),
        _text('愉快', 'Cheerful', '楽しい'),
      ][band],
      _BodyMetric.energy => [
        _text('疲惫', 'Tired', '疲れ'),
        _text('正常', 'Steady', '普通'),
        _text('充沛', 'Energetic', '元気'),
      ][band],
      _BodyMetric.closeness => [
        _text('疏离', 'Distant', '距離感'),
        _text('熟悉', 'Familiar', '馴染み'),
        _text('亲近', 'Close', '親密'),
      ][band],
      _BodyMetric.curiosity => [
        _text('兴致不高', 'Quiet', '関心薄い'),
        _text('关注', 'Attentive', '関心あり'),
        _text('兴致盎然', 'Intrigued', '興味津々'),
      ][band],
      _BodyMetric.satiety =>
        !widget.clockEnabled
            ? _text('时钟已关闭', 'Clock off', '時計オフ')
            : widget.clock.satiety < 30
            ? _text('饥饿', 'Hungry', '空腹')
            : widget.clock.satiety < 70
            ? _text('适中', 'Satisfied', '適度')
            : _text('饱足', 'Well fed', '満腹'),
      _BodyMetric.posture => _text('演出姿态', 'Current pose', '演出の姿勢'),
    };
  }

  Color _color(BuildContext context, _BodyMetric metric) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final warning = metric == _BodyMetric.mood
        ? (state.values['mood'] ?? 0) < -25
        : metric == _BodyMetric.energy
        ? (state.values['energy'] ?? 0) < 30
        : metric == _BodyMetric.satiety &&
              widget.clockEnabled &&
              widget.clock.satiety < 30;
    if (warning) {
      return dark ? const Color(0xFFFFBB91) : const Color(0xFFA34C25);
    }
    if (metric == _BodyMetric.satiety && !widget.clockEnabled) {
      return Theme.of(context).colorScheme.onSurfaceVariant;
    }
    return Theme.of(context).colorScheme.primary;
  }

  String _explanation(_BodyMetric metric) => switch (metric) {
    _BodyMetric.curiosity => _text(
      '对新事物的兴趣与关注程度，随对话中的实际经历变化。',
      'Interest in new things, updated by experiences in the conversation.',
      '新しい物事への関心。会話の中で実際に経験したことに応じて変化します。',
    ),
    _BodyMetric.mood => _text(
      '当前的情绪状态。对话、休息和物品都可能影响心情。',
      'Current mood, influenced by conversations, rest and items.',
      '現在の気分。会話、休憩、アイテムなどで変化します。',
    ),
    _BodyMetric.closeness => _text(
      '与你相处积累的亲近感，与可用于购物的关系点数分别记录。',
      'Closeness built through time together, tracked separately from spendable bond points.',
      '一緒に過ごして深まる親しみ。買い物に使う関係ポイントとは別の値です。',
    ),
    _BodyMetric.satiety => _text(
      widget.clockEnabled ? '随剧情时间消耗，进食后恢复。' : '开启剧情时钟后显示饱食度，当前未参与状态显示。',
      widget.clockEnabled
          ? 'Decreases with story time and recovers after eating.'
          : 'Enable the story clock to display satiety.',
      widget.clockEnabled ? '物語の時間とともに減り、食事で回復します。' : '物語の時計を有効にすると満腹度を表示します。',
    ),
    _BodyMetric.energy => _text(
      '反映日常活动后的整体体力，休息或睡眠有助于恢复。',
      'Overall energy after daily activities. Rest and sleep help restore it.',
      '日常の活動による全身の元気。休憩や睡眠で回復します。',
    ),
    _BodyMetric.posture => _text(
      '角色当前的身体姿态。',
      'The character’s current body posture.',
      'キャラクターの現在の身体の姿勢。',
    ),
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 760;
      return SingleChildScrollView(
        key: const ValueKey('character-status-scroll'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _overview(context),
                const SizedBox(height: 20),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 6, child: _bodyCard(context)),
                      const SizedBox(width: 20),
                      Expanded(flex: 4, child: _contextCards(context)),
                    ],
                  )
                else ...[
                  _bodyCard(context),
                  const SizedBox(height: 20),
                  _contextCards(context),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _overview(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final emotion = switch (state.emotion) {
      'happy' => _text('开心', 'Happy', '嬉しい'),
      'curious' => _text('好奇', 'Curious', '興味津々'),
      'shy' => _text('害羞', 'Shy', '照れ'),
      'sad' => _text('难过', 'Sad', '悲しい'),
      'angry' => _text('生气', 'Angry', '怒り'),
      'worried' => _text('担心', 'Worried', '心配'),
      'excited' => _text('兴奋', 'Excited', 'わくわく'),
      _ => _text('平静', 'Calm', '平静'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CHARACTER / STATUS',
          style: TextStyle(
            color: colors.primary,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.2,
          ),
        ),
        const SizedBox(height: 9),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 6,
          children: [
            Text(
              widget.characterName,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: .09),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                emotion,
                style: TextStyle(color: colors.primary, fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 18,
          runSpacing: 8,
          children: [
            _inlineInfo(
              context,
              Icons.favorite_border_rounded,
              '${_text('关系点数', 'Bond points', '関係ポイント')}  ${widget.relationshipPoints}',
            ),
            _inlineInfo(
              context,
              Icons.schedule_rounded,
              widget.clockEnabled
                  ? '${_text('第 ${widget.clock.day} 天', 'Day ${widget.clock.day}', '${widget.clock.day} 日目')} · ${widget.clock.timeLabel}'
                  : _text('剧情时钟已关闭', 'Story clock off', '物語の時計はオフ'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _inlineInfo(BuildContext context, IconData icon, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        icon,
        size: 14,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 6),
      Flexible(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
    ],
  );

  Widget _bodyCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final sensitivityLabel = _text('敏感度', 'Sensitivity', '敏感度');
    return GlassContentCard(
      liquidGlass: GlassStyleScope.resolve(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  key: const ValueKey('body-map-overview-tab'),
                  label: Text(_text('综合状态', 'Overview', '総合状態')),
                  selected: !_showSensitivity,
                  onSelected: (_) => setState(() => _showSensitivity = false),
                ),
                ChoiceChip(
                  key: const ValueKey('body-map-sensitivity-tab'),
                  label: Text(_text('部位敏感度', 'Body sensitivity', '部位の敏感度')),
                  selected: _showSensitivity,
                  onSelected: (_) => setState(() => _showSensitivity = true),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _text('点击标记查看详情', 'Tap a marker for details', 'マークをタップして詳細を表示'),
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
            ),
            const SizedBox(height: 8),
            CharacterStatusBodyMap(
              silhouette: widget.silhouette,
              selectedId: _showSensitivity
                  ? _selectedPart.name
                  : _selected.name,
              keyPrefix: _showSensitivity ? 'body-sensitivity' : 'body-status',
              onSelected: (id) => setState(() {
                if (_showSensitivity) {
                  _selectedPart = BodySensitivityPart.values.byName(id);
                  _sensitivityDraft = null;
                  _draggingSensitivity = false;
                } else {
                  _selected = _BodyMetric.values.byName(id);
                }
              }),
              markers: _showSensitivity
                  ? [
                      for (final part in _sensitivityOrder)
                        BodyMapMarker(
                          id: part.name,
                          region: part.label(language),
                          title: sensitivityLabel,
                          value: sensitivity.isUnlocked(part)
                              ? '${part == _selectedPart && _sensitivityDraft != null ? _sensitivityDraft : sensitivity.valueFor(part)}'
                              : _text('未解锁', 'Locked', '未解放'),
                          valueFontSize: sensitivity.isUnlocked(part) ? 21 : 13,
                          note: sensitivity.isUnlocked(part)
                              ? '/ 100'
                              : _text(
                                  '尚未主动触发',
                                  'Not activated yet',
                                  'まだ触れていません',
                                ),
                          anchor: _partAnchor(part),
                          color: sensitivity.isUnlocked(part)
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                    ]
                  : [
                      for (final metric in _BodyMetric.values)
                        BodyMapMarker(
                          id: metric.name,
                          region: _region(metric),
                          title: _label(metric),
                          value: _value(metric),
                          note:
                              '${_band(metric)}${(state.delta[metric.name] ?? 0) == 0 ? '' : '  ${(state.delta[metric.name] ?? 0) > 0 ? '+' : ''}${state.delta[metric.name]}'}',
                          anchor: switch (metric) {
                            _BodyMetric.curiosity => 'head',
                            _BodyMetric.mood => 'chest',
                            _BodyMetric.closeness => 'breast',
                            _BodyMetric.satiety => 'abdomen',
                            _BodyMetric.energy => 'arm_l',
                            _BodyMetric.posture => 'legs',
                          },
                          color: _color(context, metric),
                          valueFontSize: metric == _BodyMetric.posture
                              ? 13
                              : 21,
                        ),
                    ],
            ),
            if (_showSensitivity)
              _sensitivityDetail(context)
            else
              _detail(context),
          ],
        ),
      ),
    );
  }

  // Side order follows the front-facing silhouette, rather than enum order.
  static const _sensitivityOrder = [
    BodySensitivityPart.head,
    BodySensitivityPart.chest,
    BodySensitivityPart.rightArm,
    BodySensitivityPart.leftArm,
    BodySensitivityPart.abdomen,
    BodySensitivityPart.waist,
    BodySensitivityPart.hands,
    BodySensitivityPart.legs,
    BodySensitivityPart.intimate,
  ];

  String _partAnchor(BodySensitivityPart part) => switch (part) {
    BodySensitivityPart.head => 'head',
    BodySensitivityPart.chest => 'chest',
    BodySensitivityPart.abdomen => 'abdomen',
    BodySensitivityPart.leftArm => 'arm_l',
    BodySensitivityPart.rightArm => 'arm_r',
    BodySensitivityPart.hands => 'hands',
    BodySensitivityPart.legs => 'legs',
    BodySensitivityPart.waist => 'waist',
    BodySensitivityPart.intimate => 'intimate',
  };

  Widget _sensitivityDetail(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final value = _sensitivityDraft ?? sensitivity.valueFor(_selectedPart);
    final unlocked = sensitivity.isUnlocked(_selectedPart);
    return Container(
      key: const ValueKey('body-sensitivity-detail'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${_selectedPart.label(language)} · ${_text('敏感度', 'Sensitivity', '敏感度')}  ${unlocked ? '$value / 100' : _text('未解锁', 'Locked', '未解放')}',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: colors.primary,
            ),
          ),
          if (!unlocked) ...[
            const SizedBox(height: 10),
            Text(
              _text(
                widget.manualEditingEnabled
                    ? '尚未主动触发。点击人物对应部位，或主动解锁后再查看数值。'
                    : '尚未主动触发。点击人物对应部位后解锁。',
                widget.manualEditingEnabled
                    ? 'Not activated yet. Tap the matching part on the character or unlock it here to view its value.'
                    : 'Not activated yet. Tap the matching part on the character to unlock it.',
                widget.manualEditingEnabled
                    ? 'まだ触れていません。該当部位をタップするか、ここで解放すると値を確認できます。'
                    : 'まだ触れていません。キャラクターの該当部位をタップすると解放されます。',
              ),
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: colors.onSurfaceVariant,
              ),
            ),
            if (widget.manualEditingEnabled &&
                widget.onSensitivityUnlock != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('body-sensitivity-unlock'),
                  onPressed: () {
                    if (widget.manualEditingEnabled) {
                      widget.onSensitivityUnlock!(_selectedPart);
                    }
                  },
                  icon: const Icon(Icons.lock_open_rounded, size: 17),
                  label: Text(_text('主动解锁', 'Unlock', '解放する')),
                ),
              ),
          ],
          if (widget.manualEditingEnabled &&
              unlocked &&
              widget.onSensitivityChanged != null)
            Slider(
              key: const ValueKey('body-sensitivity-slider'),
              value: value.toDouble(),
              min: 0,
              max: 100,
              divisions: 100,
              label: '$value',
              semanticFormatterCallback: (value) => '${value.round()} / 100',
              onChangeStart: (_) => setState(() => _draggingSensitivity = true),
              onChanged: (value) {
                if (widget.manualEditingEnabled) {
                  setState(() => _sensitivityDraft = value.round());
                }
              },
              onChangeEnd: (value) {
                if (!widget.manualEditingEnabled) return;
                widget.onSensitivityChanged!(_selectedPart, value.round());
                setState(() {
                  _sensitivityDraft = null;
                  _draggingSensitivity = false;
                });
              },
            ),
          if (widget.manualEditingEnabled) ...[
            const SizedBox(height: 6),
            Text(
              _text(
                '数值编辑已开启 · 仅本次页面有效',
                'Editing enabled for this visit',
                '今回のみ数値編集が有効です',
              ),
              key: const ValueKey('status-numeric-edit-enabled'),
              style: TextStyle(fontSize: 11, color: colors.primary),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            _text(
              '各部位随人物和存档保存。数值越高，相关互动时的反应越明显。',
              'Saved per character and save. Higher values make reactions to related interactions more noticeable.',
              'キャラクターとセーブごとに保存します。値が高いほど、その部位に関するやり取りへの反応が表れやすくなります。',
            ),
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: colors.onSurfaceVariant,
            ),
          ),
          if (widget.onTouchGrowthChanged != null) ...[
            const SizedBox(height: 8),
            Material(
              type: MaterialType.transparency,
              child: SwitchListTile.adaptive(
                key: const ValueKey('body-sensitivity-touch-growth'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  _text('随触摸变化', 'Grow with touch', 'タッチで変化'),
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  _text(
                    '同一部位每 10 秒最多增加 1 点。',
                    'Up to +1 per body part every 10 seconds.',
                    '同じ部位は10秒に1ポイントまで増加します。',
                  ),
                  style: const TextStyle(fontSize: 11),
                ),
                value: widget.touchGrowthEnabled,
                onChanged: widget.onTouchGrowthChanged,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detail(BuildContext context) {
    final color = _color(context, _selected);
    final value = _selected == _BodyMetric.satiety
        ? widget.clock.satiety
        : state.values[_selected.name] ?? 0;
    final hasMeter =
        _selected != _BodyMetric.posture &&
        !(_selected == _BodyMetric.satiety && !widget.clockEnabled);
    return Container(
      key: const ValueKey('body-status-detail'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${_region(_selected)} · ${_label(_selected)}',
                style: TextStyle(fontWeight: FontWeight.w600, color: color),
              ),
              Text(
                '${_value(_selected)} · ${_band(_selected)}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          if (hasMeter) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: _selected == _BodyMetric.mood
                    ? ((value + 100) / 200).clamp(0.0, 1.0)
                    : (value / 100).clamp(0.0, 1.0),
                minHeight: 3,
                color: color,
                backgroundColor: color.withValues(alpha: .12),
              ),
            ),
          ],
          const SizedBox(height: 9),
          Text(
            _explanation(_selected),
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _contextCards(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (state.reason.trim().isNotEmpty) ...[
        _infoCard(
          context,
          Icons.history_rounded,
          _text('最近变化', 'Recent change', '最近の変化'),
          state.reason,
          footnote: state.updatedAt?.toLocal().toString().split('.').first,
        ),
        const SizedBox(height: 12),
      ],
      _infoCard(
        context,
        Icons.location_on_outlined,
        _text('此刻所在', 'Here and now', '今いる場所'),
        widget.location,
        footnote: widget.sceneTimeLabel,
      ),
      const SizedBox(height: 12),
      _infoCard(
        context,
        Icons.checkroom_outlined,
        _text('角色档案', 'Character details', 'キャラクター情報'),
        [
          if (widget.outfitLabel != null) widget.outfitLabel!,
          widget.postureLabel,
        ].join(' · '),
        footnote:
            '${_text('长期记忆', 'Long-term memory', '長期記憶')} · '
            '${widget.memoryEnabled ? _text('已启用', 'Enabled', '有効') : _text('已关闭', 'Disabled', '無効')}',
      ),
    ],
  );

  Widget _infoCard(
    BuildContext context,
    IconData icon,
    String title,
    String body, {
    String? footnote,
  }) {
    final colors = Theme.of(context).colorScheme;
    return GlassContentCard(
      liquidGlass: GlassStyleScope.resolve(context),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(body, style: const TextStyle(height: 1.5)),
            if (footnote != null && footnote.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                footnote,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
