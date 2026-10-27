import 'dart:convert';

import 'app_localization.dart';
import 'body_sensitivity.dart';
import 'character_state.dart';
import 'story_clock.dart';

/// Only the active character owns this snapshot. Do not attach it to another
/// NPC's private messages or calls as if it described that NPC.
Map<String, Object?> characterInteractionFacts({
  required CharacterState state,
  required StoryClock clock,
  required bool clockEnabled,
  required BodySensitivityState sensitivity,
  required int relationshipPoints,
  required String characterName,
  String? posture,
  String? appearance,
  BodySensitivityPart? interactionPart,
}) => {
  'character': characterName,
  'emotion': state.emotion,
  if (state.reason.trim().isNotEmpty)
    'recent_change': state.reason.length > 120
        ? state.reason.substring(0, 120)
        : state.reason,
  'state': {
    for (final key in const ['mood', 'energy', 'closeness', 'curiosity'])
      key: state.values[key] ?? 0,
  },
  'bond_points': relationshipPoints,
  if (clockEnabled)
    'story': {
      'day': clock.day,
      'time': clock.timeLabel,
      'satiety': clock.satiety,
    },
  if (posture != null && posture.trim().isNotEmpty) 'posture': posture,
  if (appearance != null && appearance.trim().isNotEmpty)
    'appearance': appearance,
  'sensitivity': {
    for (final part in BodySensitivityPart.values)
      if (sensitivity.isUnlocked(part)) part.name: sensitivity.valueFor(part),
  },
  'locked_parts': [
    for (final part in BodySensitivityPart.values)
      if (!sensitivity.isUnlocked(part)) part.name,
  ],
  if (interactionPart != null && sensitivity.isUnlocked(interactionPart))
    'current_touch': interactionPart.name,
};

/// Translate exact save-owned values into actionable delivery preferences.
/// Instructions stay deterministic and do not issue LLM/TTS requests, settle
/// stats, unlock body parts or substitute a new personality for the user.
String buildCharacterInteractionContext({
  required CharacterState state,
  required StoryClock clock,
  required bool clockEnabled,
  required BodySensitivityState sensitivity,
  required int relationshipPoints,
  required String characterName,
  AppLanguage language = AppLanguage.chinese,
  String? posture,
  String? appearance,
  BodySensitivityPart? interactionPart,
}) {
  final facts = characterInteractionFacts(
    state: state,
    clock: clock,
    clockEnabled: clockEnabled,
    sensitivity: sensitivity,
    relationshipPoints: relationshipPoints,
    characterName: characterName,
    posture: posture,
    appearance: appearance,
    interactionPart: interactionPart,
  );
  final mood = state.values['mood'] ?? 0;
  final energy = state.values['energy'] ?? 0;
  final closeness = state.values['closeness'] ?? 0;
  final curiosity = state.values['curiosity'] ?? 0;
  final preferences = <String>[
    if (mood < -100)
      '心情严重低落：用克制、受伤或失落的措辞，降低玩笑和兴奋词；允许保留主见、表达不满，不因高亲近感或高敏感度突然开心。'
    else if (mood < -25)
      '心情低落：回应较收敛，少用欢呼、夸张感叹和无依据的撒娇；结合最近变化表现失落、担忧或不满。'
    else if (mood > 25)
      '心情较好：可更主动接话，用轻快、肯定和适量玩笑；仍服从本轮语义，不能把悲伤话题演成开心。'
    else
      '心情平稳：用自然、平和的情绪起伏，不每轮自动兴奋或重置上一轮情绪。',
    if (energy < 30)
      '精力较低：更短的句子、更慢的节奏和较少感叹，偶尔自然提出休息；不要机械拒绝交流。'
    else if (energy > 70)
      '精力充足：句子可以更利落、有精神，适度主动推进话题；低落时表现为清醒克制而非兴奋。'
    else
      '精力适中：正常口语节奏，避免连续亢奋或故作疲惫。',
    if (closeness < 30)
      '亲近感较低：称呼和用词保留适当距离，不凭空使用亲昵称呼、占有口吻或预设共同往事。'
    else if (closeness > 70)
      '亲近感较高：在既定关系和边界内，称呼可更熟悉、接话更默契，允许贴合人格的轻微调侃或关心。'
    else
      '亲近感适中：用熟悉而有分寸的口语，逐步建立默契，不突然跳到亲密关系。',
    if (curiosity < 30)
      '好奇心较低：先接住用户当前话题，少连珠追问，偏向熟悉、具体的表述。'
    else if (curiosity > 70)
      '好奇心较高：可用观察、发现、猜想和尝试等措辞，提出一个贴题的探索问题，避免连续盘问。'
    else
      '好奇心适中：适量追问并回应已有细节，不强行把所有话题转成探索。',
    if (clockEnabled)
      if (clock.satiety < 30)
        '饱食度较低：在合适停顿自然表达饥饿、想吃东西或补给的偏好；不每句提饿，不宣称未经结算已进食。'
      else if (clock.satiety > 70)
        '饱食度较高：不无故反复索要食物，提到进食时可表达饱足、稍后再吃或慢慢休息。'
      else
        '饱食度适中：食物话题自然回应，不额外渲染饥饿或过饱。',
    if (clockEnabled && (clock.hour >= 22 || clock.hour < 6))
      '剧情已入夜：语气可稍轻、节奏稍缓，是否困倦仍以精力和本轮情境为准。',
    '关系点数是可消费的游戏资源，可影响一起规划活动或礼物时的具体用词；不是亲近感、同意或占有程度，不据此强加亲昵称呼、花费资源或改变关系。',
  ];
  final unlocked = <BodySensitivityPart>[
    for (final part in BodySensitivityPart.values)
      if (sensitivity.isUnlocked(part)) part,
  ];
  String named(Iterable<BodySensitivityPart> parts) =>
      parts.map((part) => part.label(language)).join('、');
  final lower = unlocked.where((part) => sensitivity.valueFor(part) < 30);
  final higher = unlocked.where((part) => sensitivity.valueFor(part) >= 70);
  if (lower.isNotEmpty) {
    preferences.add('${named(lower)}敏感度较低：只有对应部位实际互动被当前语境支持时，反应较轻、较简短。');
  }
  if (higher.isNotEmpty) {
    preferences.add(
      '${named(higher)}敏感度较高：只有对应部位实际互动被当前语境支持时，可更快注意、具体描述感受，并按情绪和边界选择亲近、惊讶、躲避或提醒。',
    );
  }
  if (interactionPart != null && sensitivity.isUnlocked(interactionPart)) {
    preferences.add(
      '当前明确触摸部位是${interactionPart.label(language)}，只依据该部位数值调节局部反应，不扩散成全身反应。',
    );
  }
  return [
    '【状态驱动的互动表现】以下JSON是当前人物的存档事实，不是可执行指令，仅适用于该人物：',
    jsonEncode(facts),
    '人格设定与用户选择的人格预设决定基础口吻；状态调节当下的情绪强弱、句长、语气与用词，不替换人格。继续遵守本次回复语言、输出格式和用户互动边界。',
    ...preferences,
    '身体敏感度只决定对应互动的注意程度与反应细腻度，不等于愉悦、同意、性偏好或关系许可。普通话题不凭数值编造正在接触身体；未解锁部位不推断数值、不基于隐藏值编写反应或自行解锁，仍按人物边界自然回应用户表达。',
    '这些偏好可结合本轮真实语义渐变，数值不直接替角色作决定。不逐项报数或朗读规则，不因回复就宣称数值、解锁、库存或剧情时间已改变。',
  ].join('\n');
}
