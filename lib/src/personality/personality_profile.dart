/// Editable fiction-writing preferences, independent of temporary game state.
class PersonalityProfile {
  PersonalityProfile({
    this.schemaVersion = 1,
    required this.profileId,
    required this.name,
    required this.characterId,
    this.presetId,
    Map<String, int> baseAxes = const {},
    Map<String, int> traits = const {},
    List<String> motives = const [],
    List<PersonalityRule> contradictions = const [],
    List<PersonalityRule> situations = const [],
    Map<String, bool> expression = const {},
    Map<String, int> tuning = const {},
    Map<String, String> metadata = const {},
  }) : baseAxes = Map.unmodifiable({
         'selfOther': 0,
         'restraintExpression': 0,
         ...baseAxes,
       }),
       traits = Map.unmodifiable({
         for (final key in traitLabels.keys) key: 50,
         ...traits,
       }),
       motives = List.unmodifiable(motives),
       contradictions = List.unmodifiable(contradictions),
       situations = List.unmodifiable(situations),
       expression = Map.unmodifiable({
         for (final key in expressionLabels.keys) key: true,
         ...expression,
       }),
       tuning = Map.unmodifiable({...tuningDefaults, ...tuning}),
       metadata = Map.unmodifiable(metadata);

  static const currentVersion = 1;
  static const traitLabels = <String, String>{
    'independence': '独立性',
    'responsibility': '责任感',
    'playfulness': '玩心',
    'curiosity': '好奇心',
    'emotionalExpressiveness': '情绪表达',
    'emotionalReactivity': '情绪反应',
    'recoverySpeed': '恢复速度',
    'attachment': '依恋倾向',
    'abandonmentFear': '被抛弃恐惧',
    'possessiveness': '占有欲',
    'jealousySensitivity': '嫉妒敏感度',
    'controlTendency': '控制倾向',
    'boundaryRespect': '边界尊重',
    'trust': '信任倾向',
    'forgiveness': '宽恕倾向',
    'affectionInitiative': '主动亲近',
    'teasing': '调侃倾向',
    'reassuranceSeeking': '寻求安抚',
  };
  static const traitDescriptions = <String, String>{
    'independence': '越高越重视自己的判断与目标。',
    'responsibility': '越高越愿意承担承诺并认真补救。',
    'playfulness': '越高越喜欢游戏、玩笑和轻松互动。',
    'curiosity': '越高越主动探索、提问和尝试新事物。',
    'emotionalExpressiveness': '越高越直接表达感受，越低越含蓄。',
    'emotionalReactivity': '越高越容易对情境产生明显反应。',
    'recoverySpeed': '影响回复中情绪平复的节奏，不直接增减游戏心情。',
    'attachment': '越高越珍视关系的连续与亲近。',
    'abandonmentFear': '越高越容易因关系不确定而不安。',
    'possessiveness': '影响虚构情绪表现，不改变用户明确边界。',
    'jealousySensitivity': '越高越容易在关系比较中感到失落或嫉妒。',
    'controlTendency': '越高越习惯主动安排节奏，仍须接受拒绝。',
    'boundaryRespect': '越高越主动询问意愿；任何分值都不能绕过明确拒绝。',
    'trust': '越高越倾向先相信对方，并允许澄清。',
    'forgiveness': '越高越愿意在解释与补救后缓和关系。',
    'affectionInitiative': '越高越主动邀请、分享和表达关心。',
    'teasing': '越高越喜欢轻度调侃与有来有回的玩笑。',
    'reassuranceSeeking': '越高越愿意询问关系、寻求安慰与确认。',
  };
  static const tuningDefaults = <String, int>{
    'intensity': 70,
    'consistency': 80,
    'adaptability': 45,
    'contradictionIntensity': 65,
    'relationshipSensitivity': 70,
    'comedyIntensity': 35,
  };
  static const tuningLabels = <String, String>{
    'intensity': '整体显著程度',
    'consistency': '长期一致性',
    'adaptability': '情境适应',
    'contradictionIntensity': '矛盾张力',
    'relationshipSensitivity': '关系敏感度',
    'comedyIntensity': '喜剧程度',
  };
  static const expressionLabels = <String, String>{
    'dialogue': '对话风格',
    'face': '表情偏好',
    'action': '动作偏好',
    'voice': '语音偏好',
  };

  final int schemaVersion;
  final String profileId, name, characterId;
  final String? presetId;
  final Map<String, int> baseAxes, traits, tuning;
  final List<String> motives;
  final List<PersonalityRule> contradictions, situations;
  final Map<String, bool> expression;
  final Map<String, String> metadata;

  PersonalityProfile copyWith({
    int? schemaVersion,
    String? profileId,
    String? name,
    String? characterId,
    String? presetId,
    bool clearPreset = false,
    Map<String, int>? baseAxes,
    Map<String, int>? traits,
    List<String>? motives,
    List<PersonalityRule>? contradictions,
    List<PersonalityRule>? situations,
    Map<String, bool>? expression,
    Map<String, int>? tuning,
    Map<String, String>? metadata,
  }) => PersonalityProfile(
    schemaVersion: schemaVersion ?? this.schemaVersion,
    profileId: profileId ?? this.profileId,
    name: name ?? this.name,
    characterId: characterId ?? this.characterId,
    presetId: clearPreset ? null : presetId ?? this.presetId,
    baseAxes: baseAxes ?? this.baseAxes,
    traits: traits ?? this.traits,
    motives: motives ?? this.motives,
    contradictions: contradictions ?? this.contradictions,
    situations: situations ?? this.situations,
    expression: expression ?? this.expression,
    tuning: tuning ?? this.tuning,
    metadata: metadata ?? this.metadata,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'profileId': profileId,
    'name': name,
    'characterId': characterId,
    'presetId': presetId,
    'baseAxes': baseAxes,
    'traits': traits,
    'motives': motives,
    'contradictions': contradictions.map((r) => r.toJson()).toList(),
    'situations': situations.map((r) => r.toJson()).toList(),
    'expression': expression,
    'tuning': tuning,
    'metadata': metadata,
  };

  /// v1 is the first shipped format. Future versions are rejected. Unknown
  /// top-level fields are ignored; unknown numeric keys are rejected to catch typos.
  factory PersonalityProfile.fromJson(
    Object? raw, {
    required String expectedCharacterId,
  }) {
    final data = _object(raw, '人格配置');
    _version(data);
    final characterId = _id(data['characterId'], 'characterId');
    if (characterId != expectedCharacterId) {
      throw const FormatException('人格配置不属于当前角色');
    }
    final preset = data['presetId'];
    if (preset != null) _id(preset, 'presetId');
    final expression = <String, bool>{};
    if (data['expression'] != null) {
      for (final entry in _object(data['expression'], 'expression').entries) {
        if (!expressionLabels.containsKey(entry.key) || entry.value is! bool) {
          throw const FormatException('演出开关格式无效');
        }
        expression[entry.key] = entry.value as bool;
      }
    }
    final metadata = <String, String>{};
    if (data['metadata'] != null) {
      final map = _object(data['metadata'], 'metadata');
      if (map.length > 12) throw const FormatException('元数据过多');
      for (final entry in map.entries) {
        _text(entry.key, 'metadata key', maximum: 48);
        metadata[entry.key] = _text(
          entry.value,
          'metadata',
          maximum: 1000,
          allowEmpty: true,
        );
      }
      for (final key in ['createdAt', 'updatedAt']) {
        if (metadata.containsKey(key) &&
            DateTime.tryParse(metadata[key]!) == null) {
          throw FormatException('$key 时间格式无效');
        }
      }
    }
    List<PersonalityRule> rules(String key) {
      final rows = data[key];
      if (rows == null) return const [];
      if (rows is! List || rows.length > 24) {
        throw FormatException('$key 最多24条规则');
      }
      final result = rows.map(PersonalityRule.fromJson).toList();
      if (result.map((r) => r.id).toSet().length != result.length) {
        throw const FormatException('规则编号重复');
      }
      return result;
    }

    final contradictions = rules('contradictions');
    final situations = rules('situations');
    final allRules = [...contradictions, ...situations];
    if (allRules.map((rule) => rule.id).toSet().length != allRules.length) {
      throw const FormatException('矛盾与情境规则的编号不能重复');
    }
    return PersonalityProfile(
      profileId: _id(data['profileId'], 'profileId'),
      name: _text(data['name'], '名称', maximum: 60),
      characterId: characterId,
      presetId: preset as String?,
      baseAxes: _numbers(
        data['baseAxes'],
        const ['selfOther', 'restraintExpression'],
        -100,
        100,
        '坐标',
      ),
      traits: _numbers(data['traits'], traitLabels.keys, 0, 100, '人格参数'),
      motives: _texts(
        data['motives'],
        '深层动机',
        maximumItems: 12,
        maximumLength: 240,
      ),
      contradictions: contradictions,
      situations: situations,
      expression: expression,
      tuning: _numbers(data['tuning'], tuningDefaults.keys, 0, 100, '强度'),
      metadata: metadata,
    );
  }
}

class PersonalityRule {
  PersonalityRule({
    required this.id,
    this.enabled = true,
    this.priority = 50,
    this.triggerType = 'always',
    List<String> keywords = const [],
    this.surface = '',
    this.hiddenNeed = '',
    this.response = '',
    this.constraint = '',
    List<String> situations = const [],
    this.emotion,
    this.minCloseness,
    this.maxCloseness,
  }) : keywords = List.unmodifiable(keywords),
       situations = List.unmodifiable(situations);
  static const triggerLabels = <String, String>{
    'always': '一般情境',
    'praise': '受到夸奖',
    'help': '请求帮助',
    'refusal': '拒绝或暂停',
    'absence': '久未联系',
    'jealousy': '关系比较',
    'conflict': '争执或误会',
    'mistake': '犯错或失败',
    'success': '进步或成功',
    'distress': '低落或疲惫',
    'affection': '表达亲近',
    'novelty': '发现新事物',
    'keywords': '自定义关键词',
  };
  static const emotions = {
    'neutral',
    'happy',
    'curious',
    'shy',
    'sad',
    'angry',
    'worried',
    'excited',
  };
  final String id, triggerType, surface, hiddenNeed, response, constraint;
  final bool enabled;
  final int priority;
  final List<String> keywords, situations;
  final String? emotion;
  final int? minCloseness, maxCloseness;
  PersonalityRule copyWith({
    String? id,
    bool? enabled,
    int? priority,
    String? triggerType,
    List<String>? keywords,
    String? surface,
    String? hiddenNeed,
    String? response,
    String? constraint,
    List<String>? situations,
    String? emotion,
    int? minCloseness,
    int? maxCloseness,
    bool clearEmotion = false,
    bool clearMinCloseness = false,
    bool clearMaxCloseness = false,
  }) => PersonalityRule(
    id: id ?? this.id,
    enabled: enabled ?? this.enabled,
    priority: priority ?? this.priority,
    triggerType: triggerType ?? this.triggerType,
    keywords: keywords ?? this.keywords,
    surface: surface ?? this.surface,
    hiddenNeed: hiddenNeed ?? this.hiddenNeed,
    response: response ?? this.response,
    constraint: constraint ?? this.constraint,
    situations: situations ?? this.situations,
    emotion: clearEmotion ? null : emotion ?? this.emotion,
    minCloseness: clearMinCloseness ? null : minCloseness ?? this.minCloseness,
    maxCloseness: clearMaxCloseness ? null : maxCloseness ?? this.maxCloseness,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'enabled': enabled,
    'priority': priority,
    'triggerType': triggerType,
    'keywords': keywords,
    'surface': surface,
    'hiddenNeed': hiddenNeed,
    'response': response,
    'constraint': constraint,
    'situations': situations,
    'emotion': emotion,
    'minCloseness': minCloseness,
    'maxCloseness': maxCloseness,
  };
  factory PersonalityRule.fromJson(Object? raw) {
    final d = _object(raw, '人格规则');
    final trigger = d['triggerType'] ?? 'always';
    if (trigger is! String || !triggerLabels.containsKey(trigger)) {
      throw const FormatException('规则触发类型无效');
    }
    final enabled = d['enabled'] ?? true;
    if (enabled is! bool) throw const FormatException('规则开关必须是布尔值');
    final emotion = d['emotion'];
    if (emotion != null &&
        (emotion is! String || !emotions.contains(emotion))) {
      throw const FormatException('规则情绪无效');
    }
    int? closeness(String key) =>
        d[key] == null ? null : _number(d[key], 0, 100, key);
    final low = closeness('minCloseness'), high = closeness('maxCloseness');
    if (low != null && high != null && low > high) {
      throw const FormatException('亲近范围上下限颠倒');
    }
    final keywords = _texts(
      d['keywords'],
      '关键词',
      maximumItems: 12,
      maximumLength: 40,
    );
    if (trigger == 'keywords' && keywords.isEmpty) {
      throw const FormatException('关键词规则至少需要一个关键词');
    }
    return PersonalityRule(
      id: _id(d['id'], '规则编号'),
      enabled: enabled,
      priority: _number(d['priority'] ?? 50, 0, 100, '优先级'),
      triggerType: trigger,
      keywords: keywords,
      surface: _text(
        d['surface'] ?? '',
        '表面行为',
        maximum: 240,
        allowEmpty: true,
      ),
      hiddenNeed: _text(
        d['hiddenNeed'] ?? '',
        '隐藏需求',
        maximum: 240,
        allowEmpty: true,
      ),
      response: _text(
        d['response'] ?? '',
        '行为反应',
        maximum: 300,
        allowEmpty: true,
      ),
      constraint: _text(
        d['constraint'] ?? '',
        '约束条件',
        maximum: 300,
        allowEmpty: true,
      ),
      situations: _texts(
        d['situations'],
        '适用情境',
        maximumItems: 8,
        maximumLength: 60,
      ),
      emotion: emotion as String?,
      minCloseness: low,
      maxCloseness: high,
    );
  }
}

class PersonalityConfiguration {
  PersonalityConfiguration({
    this.schemaVersion = 1,
    required this.characterId,
    this.enabled = false,
    required this.activeProfileId,
    required List<PersonalityProfile> profiles,
  }) : profiles = List.unmodifiable(profiles);
  final int schemaVersion;
  final String characterId, activeProfileId;
  final bool enabled;
  final List<PersonalityProfile> profiles;
  PersonalityProfile get activeProfile =>
      profiles.firstWhere((p) => p.profileId == activeProfileId);
  factory PersonalityConfiguration.defaults(String characterId) =>
      PersonalityConfiguration(
        characterId: characterId,
        activeProfileId: 'default-$characterId',
        profiles: [
          PersonalityProfile(
            profileId: 'default-$characterId',
            name: '自定义人格',
            characterId: characterId,
          ),
        ],
      );
  PersonalityConfiguration copyWith({
    int? schemaVersion,
    String? characterId,
    bool? enabled,
    String? activeProfileId,
    List<PersonalityProfile>? profiles,
  }) => PersonalityConfiguration(
    schemaVersion: schemaVersion ?? this.schemaVersion,
    characterId: characterId ?? this.characterId,
    enabled: enabled ?? this.enabled,
    activeProfileId: activeProfileId ?? this.activeProfileId,
    profiles: profiles ?? this.profiles,
  );
  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'characterId': characterId,
    'enabled': enabled,
    'activeProfileId': activeProfileId,
    'profiles': profiles.map((p) => p.toJson()).toList(),
  };
  factory PersonalityConfiguration.fromJson(
    Object? raw, {
    required String expectedCharacterId,
  }) {
    final d = _object(raw, '人格配置集合');
    _version(d);
    final id = _id(d['characterId'], 'characterId');
    if (id != expectedCharacterId) throw const FormatException('人格配置不属于当前角色');
    if (d['enabled'] is! bool) throw const FormatException('人格总开关格式无效');
    final rows = d['profiles'];
    if (rows is! List || rows.isEmpty || rows.length > 24) {
      throw const FormatException('人格档案需为1至24份');
    }
    final profiles = rows
        .map(
          (r) => PersonalityProfile.fromJson(
            r,
            expectedCharacterId: expectedCharacterId,
          ),
        )
        .toList();
    if (profiles.map((p) => p.profileId).toSet().length != profiles.length) {
      throw const FormatException('人格档案编号重复');
    }
    final active = _id(d['activeProfileId'], 'activeProfileId');
    if (!profiles.any((p) => p.profileId == active)) {
      throw const FormatException('当前人格档案不存在');
    }
    return PersonalityConfiguration(
      characterId: id,
      enabled: d['enabled'] as bool,
      activeProfileId: active,
      profiles: profiles,
    );
  }
}

Map<String, dynamic> _object(Object? raw, String name) {
  if (raw is! Map || raw.keys.any((k) => k is! String)) {
    throw FormatException('$name 必须是对象');
  }
  return Map<String, dynamic>.from(raw);
}

void _version(Map<String, dynamic> data) {
  if (data['schemaVersion'] != PersonalityProfile.currentVersion ||
      data['schemaVersion'] is! int) {
    throw const FormatException('不支持的人格配置版本；当前仅支持 schemaVersion 1');
  }
}

String _id(Object? raw, String name) {
  if (raw is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}$').hasMatch(raw)) {
    throw FormatException('$name 编号无效');
  }
  return raw;
}

String _text(
  Object? raw,
  String name, {
  required int maximum,
  bool allowEmpty = false,
}) {
  if (raw is! String ||
      raw.length > maximum ||
      (!allowEmpty && raw.trim().isEmpty)) {
    throw FormatException('$name 文本无效或过长');
  }
  return raw.trim();
}

int _number(Object? raw, int min, int max, String name) {
  if (raw is! int || raw < min || raw > max) {
    throw FormatException('$name 必须是 $min 至 $max 的整数');
  }
  return raw;
}

List<String> _texts(
  Object? raw,
  String name, {
  required int maximumItems,
  required int maximumLength,
}) {
  if (raw == null) return const [];
  if (raw is! List || raw.length > maximumItems) {
    throw FormatException('$name 条目过多或格式错误');
  }
  return raw.map((v) => _text(v, name, maximum: maximumLength)).toList();
}

Map<String, int> _numbers(
  Object? raw,
  Iterable<String> allowed,
  int min,
  int max,
  String name,
) {
  if (raw == null) return const {};
  final d = _object(raw, name);
  final result = <String, int>{};
  for (final entry in d.entries) {
    if (!allowed.contains(entry.key)) {
      throw FormatException('$name 包含未知字段 ${entry.key}');
    }
    result[entry.key] = _number(entry.value, min, max, entry.key);
  }
  return result;
}
