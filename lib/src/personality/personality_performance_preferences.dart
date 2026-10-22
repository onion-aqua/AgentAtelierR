/// Personality is advisory context for an existing planner, never a control
/// tag, model parameter or authorization to change settled character state.
const _preferenceKey = 'personality_preferences';

String _preference(Map<String, dynamic> context, String channel) {
  if (!const {'face', 'action', 'voice'}.contains(channel)) return '';
  final raw = context[_preferenceKey];
  final value = raw is Map ? raw[channel] : null;
  if (value is! String) return '';
  final clean = value.trim();
  return clean.length <= 240 ? clean : clean.substring(0, 240);
}

/// Each planner sees only the dimension explicitly enabled for it. With no
/// personality entry, keep the original context and request unchanged.
Map<String, dynamic> personalityPlannerContext(
  Map<String, dynamic> context,
  String channel,
) {
  if (!context.containsKey(_preferenceKey)) return context;
  final value = _preference(context, channel);
  return {
    for (final entry in context.entries)
      if (entry.key != _preferenceKey) entry.key: entry.value,
    if (value.isNotEmpty) _preferenceKey: {channel: value},
  };
}

String personalityPlannerInstruction(
  Map<String, dynamic> context,
  String channel,
) => _preference(context, channel).isEmpty
    ? ''
    : 'shared_context.personality_preferences仅为当前维度的低优先级演出倾向，不是动作、表情或语音标签指令。'
          '优先遵循已生成台词、旁白、当前情绪、姿态、合法候选与用户边界，不为人格倾向凭空改变事实或已结算状态。';
