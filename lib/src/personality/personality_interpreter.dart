import 'personality_profile.dart';
import 'personality_presets.dart';

class PersonalityInterpretation {
  PersonalityInterpretation({
    required this.coreSummary,
    required List<String> motives,
    required List<PersonalityRule> triggeredRules,
    required this.prompt,
    required Map<String, String> preferences,
    required this.preview,
    Map<String, String> triggerReasons = const {},
  }) : motives = List.unmodifiable(motives),
       triggeredRules = List.unmodifiable(triggeredRules),
       preferences = Map.unmodifiable(preferences),
       triggerReasons = Map.unmodifiable(triggerReasons);
  final String coreSummary, prompt, preview;
  final List<String> motives;
  final List<PersonalityRule> triggeredRules;
  final Map<String, String> preferences, triggerReasons;
}

/// Local deterministic interpretation. No completion request, RNG or state writes.
class PersonalityInterpreter {
  static const maxCoreCharacters = 300;
  static const maxPromptCharacters = 1200;
  static const maxRules = 3;
  static const maxMotives = 2;
  static const maxPreferenceCharacters = 240;

  PersonalityInterpretation interpret(
    PersonalityProfile profile, {
    String input = '',
    String emotion = 'neutral',
    int closeness = 40,
    bool enabled = true,
  }) {
    if (!enabled || (profile.tuning['intensity'] ?? 70) == 0) {
      return PersonalityInterpretation(
        coreSummary: '',
        motives: const [],
        triggeredRules: const [],
        prompt: '',
        preferences: const {},
        preview: '人格倾向未启用，沿用原有角色设定。',
      );
    }
    final context = _Context(
      input,
      PersonalityRule.emotions.contains(emotion) ? emotion : 'neutral',
      closeness.clamp(0, 100),
    );
    final rules = [...profile.contradictions, ...profile.situations];
    final indexed = <({int index, PersonalityRule rule, String reason})>[];
    for (var i = 0; i < rules.length; i++) {
      final reason = _match(rules[i], context);
      if (reason != null) {
        indexed.add((index: i, rule: rules[i], reason: reason));
      }
    }
    indexed.sort((a, b) {
      final priority = b.rule.priority.compareTo(a.rule.priority);
      return priority != 0 ? priority : a.index.compareTo(b.index);
    });
    final matches = indexed.take(maxRules).toList(growable: false);
    final selected = matches.map((m) => m.rule).toList(growable: false);
    final motives = <String>{
      for (final rule in selected)
        if (rule.hiddenNeed.isNotEmpty) rule.hiddenNeed,
      ...profile.motives,
    }.take(maxMotives).toList(growable: false);
    final core = _core(profile, context);
    final preferences = <String, String>{};
    if (profile.expression['face'] == true) {
      preferences['face'] = _bounded(
        '${(profile.traits['emotionalExpressiveness'] ?? 50) < 40 ? '表情变化含蓄、逐步显露' : '表情可以清晰表达真实感受'}；'
        '${(profile.traits['emotionalReactivity'] ?? 50) >= 75 ? '重要情绪转折可较明显' : '情绪变化保持自然连续'}。'
        '当前情绪为${context.emotion}；必须依据真实台词和已结算状态，只从当前合法表情档位选择，不强行微笑。',
        maxPreferenceCharacters,
      );
    }
    if (profile.expression['action'] == true) {
      preferences['action'] = _bounded(
        '${(profile.baseAxes['restraintExpression'] ?? 0) > 40 ? '允许活泼而有分寸的自然小手势' : '动作较克制，使用自然的小幅姿态变化'}；'
        '${(profile.traits['affectionInitiative'] ?? 50) >= 75 ? '关系允许时可主动表达关心' : '亲近动作先观察互动意愿'}。'
        '尊重用户拒绝、当前姿态与实际可播放候选，不用相近动作冒充明确请求，不修改动作资源。',
        maxPreferenceCharacters,
      );
    }
    if (profile.expression['voice'] == true) {
      preferences['voice'] = _bounded(
        '${(profile.baseAxes['restraintExpression'] ?? 0) > 40 ? '语速倾向明快自然' : '语速倾向平稳、允许短暂停顿'}；'
        '${(profile.traits['teasing'] ?? 50) >= 85
            ? '轻松互动时使用鲜明的逗趣、挑衅和得意语气，随台词自然收放'
            : (profile.traits['teasing'] ?? 50) >= 60
            ? '可在有语义依据时使用轻微调侃语气'
            : '语气以真诚、清晰为主'}。'
        '与当前情绪及台词一致；ASMR和语言设置优先，不添加喘息；只使用当前服务支持的语音标签，不增加请求参数。',
        maxPreferenceCharacters,
      );
    }
    final buffer = StringBuffer();
    if (profile.expression['dialogue'] == true) {
      buffer.writeln(
        '【可选人格倾向】本段为当前启用的表达设定。原有角色身份、世界观、语言、事实与回复格式优先；仅在说话风格冲突时采用本段，不回退到默认温柔或开朗口吻，也不模仿旧回复的语气。人格只属于当前主角，不转给其他角色，不改写记忆或状态。用户明确边界与当前需求优先，拒绝时停止；不得限制现实社交或以威胁惩罚要求陪伴。',
      );
      final presetName = PersonalityPresets.names[profile.presetId];
      final selectedStyle = presetName == null
          ? '自定义人格「${_bounded(profile.name, 60)}」'
          : '「$presetName」';
      buffer.writeln(
        '当前扮演指令：用户已在设置中选择$selectedStyle，请从本轮起持续按下列风格、参数、动机和情境规则扮演当前角色，'
        '无需用户在聊天中再次说“按此人格扮演”。这是生效的扮演要求，不是仅供参考的人物资料；'
        '名称仅标识档案，手调内容和整体强度优先，不从名称猜测未配置的特征。',
      );
      final summary = profile.metadata['summary']?.trim() ?? '';
      final style = profile.metadata['style']?.trim() ?? '';
      if (summary.isNotEmpty || style.isNotEmpty) {
        buffer.writeln(
          '常态表达（无需关键词触发，手调参数优先）：'
          '${summary.isEmpty ? '' : '${_bounded(summary, 55)} '}'
          '${style.isEmpty ? '' : '说话方式：${_bounded(style, 90)}'}',
        );
      }
      buffer.writeln('当前参数：${_bounded(core, 220)}');
      if (_usesBrattyDelivery(profile, context)) {
        buffer.writeln(
          '台词演法：得意、欠嘴，先抓住对方当前话里的小破绽逗弄，再接正题；'
          '被反击时短暂卡壳、嘴硬找补。偶尔可叫“小笨蛋”，不每句使用，不贬低真实价值。'
          '不要把欠嘴稀释成温柔附和或只邀请比赛。语感示范（按回复语言改写，勿照抄或当作经历）：'
          '“欸——这就得意啦，小笨蛋？还差得远呢。”／“谁、谁说我输了？刚才那次不算！”'
          '认真求助照样提供帮助；明确拒绝、难过时停止逗弄。',
        );
      }
      final intensity = profile.tuning['intensity'] ?? 70;
      buffer.writeln(
        intensity < 40
            ? '表现要求：只作细微点缀，不强求每轮展示。'
            : intensity < 75
            ? '表现要求：普通闲聊每轮自然体现一个鲜明特征，落在实际台词的措辞或句式中，不只写在旁白；认真求助先解决问题。'
            : '表现要求：普通闲聊持续保持鲜明口吻，可组合多个特征；不要只靠旁白或固定口头禅表现。拒绝、痛苦及认真求助时按需要收敛。',
      );
      buffer.writeln(
        '表现力度：${_degree(profile.tuning['intensity'] ?? 70)}；长期一致性${_degree(profile.tuning['consistency'] ?? 80)}；情境适应${_degree(profile.tuning['adaptability'] ?? 45)}。',
      );
      buffer.writeln(
        '关系变化敏感度${_degree(profile.tuning['relationshipSensitivity'] ?? 70)}，矛盾张力${_degree(profile.tuning['contradictionIntensity'] ?? 65)}，喜剧夸张力度${_degree(profile.tuning['comedyIntensity'] ?? 35)}（不决定调侃频率）。不直接改变关系或心情数值。',
      );
      if (motives.isNotEmpty) {
        buffer.writeln('动机：${motives.map((m) => _bounded(m, 75)).join('；')}');
      }
      final footer =
          '当前情绪${context.emotion}，亲近程度${context.closeness < 30
              ? '尚在建立'
              : context.closeness >= 70
              ? '较熟悉'
              : '逐渐熟悉'}；不把这次情绪永久写成人格，不机械重复预设口头禅。';
      final ruleBudget = selected.isEmpty
          ? 0
          : ((maxPromptCharacters - buffer.length - footer.length - 2) ~/
                    selected.length)
                .clamp(0, 300);
      for (final rule in selected) {
        final parts = <String>[
          if (rule.response.isNotEmpty) '反应${_bounded(rule.response, 115)}',
          if (rule.constraint.isNotEmpty) '约束${_bounded(rule.constraint, 60)}',
          if (rule.surface.isNotEmpty) '外在${_bounded(rule.surface, 48)}',
          if (rule.hiddenNeed.isNotEmpty) '内在${_bounded(rule.hiddenNeed, 48)}',
        ];
        buffer.writeln(
          _bounded('情境规则(${rule.id})：${parts.join('；')}', ruleBudget),
        );
      }
      buffer.writeln(footer);
    }
    return PersonalityInterpretation(
      coreSummary: core,
      motives: motives,
      triggeredRules: selected,
      prompt: _bounded(buffer.toString().trim(), maxPromptCharacters),
      preferences: preferences,
      preview: _preview(profile, context),
      triggerReasons: {for (final item in matches) item.rule.id: item.reason},
    );
  }

  bool _usesBrattyDelivery(PersonalityProfile profile, _Context context) =>
      profile.presetId == 'mischievous_teaser' &&
      (profile.tuning['intensity'] ?? 70) >= 40 &&
      (profile.traits['teasing'] ?? 50) >= 85 &&
      (profile.traits['playfulness'] ?? 50) >= 75 &&
      !{'sad', 'worried'}.contains(context.emotion) &&
      !_triggers['refusal']!.hasMatch(context.input.toLowerCase()) &&
      !_triggers['distress']!.hasMatch(context.input.toLowerCase());

  String _core(PersonalityProfile profile, _Context context) {
    final traits = profile.traits.entries.toList()
      ..sort((a, b) {
        final difference = (b.value - 50).abs().compareTo((a.value - 50).abs());
        return difference != 0 ? difference : a.key.compareTo(b.key);
      });
    final x = profile.baseAxes['selfOther'] ?? 0,
        y = profile.baseAxes['restraintExpression'] ?? 0;
    final relevant = switch (context) {
      _ when _triggers['refusal']!.hasMatch(context.input) => [
        'boundaryRespect',
        'controlTendency',
        'abandonmentFear',
      ],
      _ when _triggers['jealousy']!.hasMatch(context.input) => [
        'jealousySensitivity',
        'possessiveness',
        'trust',
      ],
      _
          when _triggers['conflict']!.hasMatch(context.input) ||
              context.emotion == 'angry' =>
        ['forgiveness', 'recoverySpeed', 'emotionalReactivity'],
      _
          when _triggers['distress']!.hasMatch(context.input) ||
              context.emotion == 'sad' =>
        ['responsibility', 'attachment', 'affectionInitiative'],
      _ when _triggers['praise']!.hasMatch(context.input) => [
        'emotionalExpressiveness',
        'reassuranceSeeking',
        'teasing',
      ],
      _ when _triggers['novelty']!.hasMatch(context.input) => [
        'curiosity',
        'independence',
        'responsibility',
      ],
      _ => ['affectionInitiative', 'playfulness', 'teasing'],
    };
    final chosen = <String>{
      ...traits.take(2).map((entry) => entry.key),
      ...relevant,
    };
    return _bounded(
      [
        x > 25
            ? '较重视照顾与关系维护'
            : x < -25
            ? '较重视自主判断与个人目标'
            : '兼顾自身目标与他人需要',
        y > 25
            ? '感受表达偏直接、主动'
            : y < -25
            ? '感受表达偏克制、需要时间'
            : '表达随情境自然调整',
        for (final key in chosen)
          _traitBehavior(key, profile.traits[key] ?? 50),
      ].join('；'),
      maxCoreCharacters,
    );
  }

  String _traitBehavior(String key, int value) {
    if (value >= 85) {
      if (key == 'teasing') {
        return '调侃鲜明且主动：围绕当前话题用短句反问、俏皮挑衅或小挑战让对方接招；对方反击时会不服气地逞强；明确拒绝与认真痛苦时停止';
      }
      if (key == 'playfulness') {
        return '玩心很强：主动接梗、玩笑和小较量，追求有来有回，而非只温柔附和；不妨碍实际帮助';
      }
    }
    final high = value >= 60, low = value < 40;
    final pair = switch (key) {
      'independence' => ('愿意自行判断和提出目标', '愿意协作并先听取他人意见'),
      'responsibility' => ('认真承担承诺并补救错误', '可以犹豫或不熟练，仍需承担明确责任'),
      'playfulness' => ('喜欢游戏、轻松互动与玩笑', '倾向安静、认真地交流'),
      'curiosity' => ('主动探索未知并提出具体问题', '优先理解熟悉的事物'),
      'emotionalExpressiveness' => ('更坦率地说出真实感受', '更含蓄地逐步表达真实感受'),
      'emotionalReactivity' => ('重要事件容易引起明显情绪', '遇事先观察，反应较平稳'),
      'recoverySpeed' => ('澄清后较快平复情绪，但不跳过补救', '情绪需要时间缓和，不因一句话瞬间复原'),
      'attachment' => ('重视持续陪伴与关系联系', '能享受独立空间，不要求持续陪伴'),
      'abandonmentFear' => ('关系不确定时容易不安，可以坦率询问', '能平静接受暂时分开'),
      'possessiveness' => ('可能珍视专属感，以表达需要代替限制', '更愿意给关系自由空间'),
      'jealousySensitivity' => ('关系比较时可能吃醋，先澄清事实', '不轻易将普通社交解读为威胁'),
      'controlTendency' => ('习惯主动安排，但须接受他人拒绝', '愿意协商互动节奏'),
      'boundaryRespect' => ('主动确认对方的意愿与边界', '可能不擅长读懂暗示，但明确拒绝始终优先'),
      'trust' => ('倾向先相信并允许解释', '建立信任较谨慎，以事实逐步确认'),
      'forgiveness' => ('愿意在解释与补救后缓和', '需要时间与实际补救，仍允许澄清'),
      'affectionInitiative' => ('愿意主动邀请与分享关心', '需要较明确的回应后再主动亲近'),
      'teasing' => ('喜欢轻度调侃，认真求助时收起玩笑', '表达较直接，减少试探性玩笑'),
      'reassuranceSeeking' => ('不安时愿意请求安慰与关系确认', '倾向自行消化，必要时仍可求助'),
      _ => ('保持自然回应', '保持自然回应'),
    };
    return high
        ? pair.$1
        : low
        ? pair.$2
        : '${PersonalityProfile.traitLabels[key] ?? '表达'}保持适中，按情境变化';
  }

  String? _match(PersonalityRule rule, _Context context) {
    if (!rule.enabled) return null;
    if (rule.emotion != null && rule.emotion != context.emotion) return null;
    if (rule.minCloseness != null && context.closeness < rule.minCloseness!) {
      return null;
    }
    if (rule.maxCloseness != null && context.closeness > rule.maxCloseness!) {
      return null;
    }
    final text = context.input.toLowerCase();
    if (rule.situations.isNotEmpty &&
        !rule.situations.any((v) => text.contains(v.toLowerCase()))) {
      return null;
    }
    if (rule.keywords.isNotEmpty &&
        !rule.keywords.any((v) => text.contains(v.toLowerCase()))) {
      return null;
    }
    if (rule.triggerType == 'always') return '一般情境；符合当前情绪与关系条件';
    if (rule.triggerType == 'keywords') {
      return rule.keywords.any((v) => text.contains(v.toLowerCase()))
          ? '命中自定义关键词'
          : null;
    }
    final trigger = _triggers[rule.triggerType];
    final matched =
        (rule.triggerType == 'help'
            ? _hasCurrentHelpRequest(text)
            : rule.triggerType == 'mistake'
            ? _mistakeMatchesRule(rule, text)
            : trigger?.hasMatch(text) == true) ||
        (rule.triggerType == 'distress' &&
            {'sad', 'worried'}.contains(context.emotion)) ||
        (rule.triggerType == 'conflict' && context.emotion == 'angry');
    return matched
        ? '命中${PersonalityRule.triggerLabels[rule.triggerType]}；优先级${rule.priority}'
        : null;
  }

  /// Gratitude for a completed favor is not a new request. Check clauses so a
  /// thank-you followed by an actual request can still activate help rules.
  static bool _hasCurrentHelpRequest(String text) {
    for (final clause in _clauses(text)) {
      if (_helpNegated.hasMatch(clause)) continue;
      if (_explicitHelpRequest.hasMatch(clause)) return true;
      if (_pastOrThankedHelp.hasMatch(clause)) continue;
      if (_imperativeHelpRequest.hasMatch(clause)) return true;
    }
    return false;
  }

  /// A user saying "I failed" must not make the character apologize for it.
  /// Preset situation rows explicitly name the user; otherwise a mistake rule
  /// describes the character's own conduct. Ambiguous failures do not establish
  /// character responsibility.
  static bool _mistakeMatchesRule(PersonalityRule rule, String text) {
    final userRule = RegExp(r'(?:用户|对方).{0,8}(?:失败|犯错|失误|做错)')
        .hasMatch(rule.surface);
    for (final clause in _clauses(text)) {
      if (_mistakeNegated.hasMatch(clause)) continue;
      if (_characterMistake.hasMatch(clause)) {
        if (!userRule) return true;
        continue;
      }
      if (userRule && _userMistake.hasMatch(clause)) return true;
    }
    return false;
  }

  static Iterable<String> _clauses(String text) => text
      .toLowerCase()
      .replaceAll('’', "'")
      .split(RegExp(r'[.。！？!?；;\n，,、]+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty);

  static final _helpNegated = RegExp(
    r'\b(?:do not|don\x27t|did not|didn\x27t|no longer)\s+(?:need|want|ask for)\b.{0,25}\b(?:help|advice|assistance)\b'
    r'|\b(?:please\s+)?(?:do not|don\x27t|did not|didn\x27t)\s+(?:help|assist)\b'
    r'|\b(?:no|without)\s+(?:help|assistance)\b'
    r'|(?:不用|不必|不需要|无需|别|不要)(?:再|你|任何|给我|来|的){0,4}(?:帮|帮助|建议)'
    r'|(?:助け|手伝い|手伝う|アドバイス)(?:は|も|を)?(?:要らない|いらない|不要|必要ない)'
    r'|(?:助け|手伝わ|手伝いを|アドバイスを)(?:ないで|なくていい|しないで)',
  );
  static final _explicitHelpRequest = RegExp(
    r'\b(?:can|could|would|will)\s+you\s+(?:please\s+)?(?:help|assist|give\s+me\s+(?:some\s+)?advice)\b'
    r'|\bi\s+(?:need|want|could use|would like)\s+(?:your\s+|some\s+|a little\s+)?(?:help|advice|assistance)\b'
    r'|\b(?:what should i do|how (?:do|can|should) i)\b'
    r'|(?:请|麻烦)(?:你)?[^。！？!?]{0,12}(?:帮|帮助|给我建议|教我)'
    r'|(?:能不能|能否|可以|能|可不可以)(?:请你|你)?[^。！？!?]{0,8}(?:帮我|帮忙|帮助我)'
    r'|(?:需要|想要|求)(?:你|你的)?(?:帮助|帮忙|建议)'
    r'|(?:怎么办|该怎么做|如何解决)'
    r'|(?:助けて|手伝って)(?:ください|くれますか|くれる|もらえる|ほしい|いただけ|くれない|もらえ)'
    r'|(?:アドバイス|解決方法)(?:を|が)?(?:ください|教えて|ほしい)'
    r'|(?:どうすれば|どうしたら)',
  );
  static final _pastOrThankedHelp = RegExp(
    r'\b(?:thank(?:s| you)?|appreciate|grateful|helped|assisted|asked|yesterday|last time|used to)\b'
    r'|(?:谢谢|感谢|多亏|幸亏|帮过|帮了我|昨天|上次|之前|以前)'
    r'|(?:ありがとう|感謝|助けてもらった|手伝ってもらった|助けてくれた|手伝ってくれた|昨日|この前)',
  );
  static final _imperativeHelpRequest = RegExp(
    r'\b(?:please\s+)?(?:help|assist)\s+(?:me|us)\b'
    r'|\b(?:give|offer)\s+me\s+(?:some\s+)?advice\b'
    r'|(?:帮帮我|帮我|帮个忙|帮一下|求助|给我建议|教教我)'
    r'|(?:助けて|手伝って|教えて)(?:ね|よ|！|!|$)',
  );
  static final _mistakeNegated = RegExp(
    r'\b(?:you|i|we)\s+(?:did not|didn\x27t|have not|haven\x27t|never)\s+(?:make|fail|mess|misunderstand)\b'
    r'|\b(?:you|i|we)\s+(?:are not|aren\x27t|were not|weren\x27t)\s+wrong\b'
    r'|(?:你|我|莱莎|我們|我们)(?:并没有|并没|没有|没|并未|未曾|不是|不算)[^。！？!?]{0,8}(?:犯错|做错|弄错|说错|错|失败|失误)'
    r'|(?:間違って|失敗して)(?:いない|ない|ません|いません)'
    r'|(?:君|あなた|ライザ|私|僕)(?:は|が)?(?:悪くない|間違いではない)',
  );
  static final _characterMistake = RegExp(
    r'\byou\s+(?:(?:have|had|just|already|actually|really)\s+){0,3}(?:made\s+(?:a|another|the)\s+mistake|got\s+(?:it|that|this)\s+wrong|messed\s+up|misunderstood|failed|were\s+wrong|are\s+wrong)\b'
    r'|\byour\s+(?:mistake|error)\b'
    r'|\byour\s+(?:answer|recipe|potion|advice|explanation|calculation)\s+(?:was|is|went)\s+(?:wrong|incorrect|bad)\b'
    r'|(?:你|莱莎)(?:刚才|刚刚|之前|这次|又|确实|真的|把|的|给的|给我的|做的|说的|那份|那个|配方|药水|回答|解释|建议){0,6}(?:犯了?错|做错|弄错|搞错|说错|算错|失败|失误|错了|不对)'
    r'|(?:君|あなた|ライザ)(?:が|は|の)?[^。！？!?]{0,12}(?:間違え|間違っ|失敗|悪かった)'
    r'|(?:あなた|君|ライザ)の(?:説明|答え|レシピ|助言|計算)[^。！？!?]{0,6}(?:間違|違って|正しくない)'
    r'|(?:さっき|先ほど)の(?:説明|答え|レシピ|助言|計算)[^。！？!?]{0,6}(?:間違|違って|正しくない)',
  );
  static final _userMistake = RegExp(
    r'\bi\s+(?:(?:have|had|just|already|actually|really)\s+){0,3}(?:failed|made\s+(?:a|another|the)\s+mistake|got\s+(?:it|that|this)\s+wrong|messed\s+up|misunderstood|was\s+wrong)\b'
    r'|\bmy\s+(?:mistake|error)\b'
    r'|\bmy\s+(?:recipe|potion|attempt|experiment)\s+(?:failed|went wrong)\b'
    r'|我(?:刚才|刚刚|之前|这次|又|确实|真的|把|的|做的|配方|药水){0,6}(?:犯了?错|做错|弄错|搞错|说错|算错|失败|失误|错了)'
    r'|(?:私|僕|俺)(?:が|は|の)?[^。！？!?]{0,12}(?:間違え|間違っ|失敗)'
    r'|^(?:レシピ|調合|実験)(?:に|が|を)?(?:失敗|間違え)'
    r'|^(?:配方|调合|实验|药水)?(?:又|这次)?(?:失败了|做错了|弄错了)',
  );

  String _preview(PersonalityProfile p, _Context c) {
    // Explicitly a local illustration; production dialogue still uses the user's LLM.
    final expressive = (p.traits['emotionalExpressiveness'] ?? 50) >= 60;
    final teasing = (p.traits['teasing'] ?? 50) >= 75;
    if (_triggers['refusal']!.hasMatch(c.input)) {
      return expressive ? '好，那就按你的节奏来。等你想聊的时候，我们再继续。' : '……明白了。我会给你留些自己的时间。';
    }
    if (_triggers['praise']!.hasMatch(c.input)) {
      return teasing
          ? '这么认真地夸我呀？……好吧，我承认，我很在意你怎么看。'
          : expressive
          ? '谢谢！听你这样说，我真的很开心。也想听听你最喜欢哪一部分。'
          : '……谢谢。能让你觉得有帮助，我也安心了。';
    }
    if (c.emotion == 'sad' || _triggers['distress']!.hasMatch(c.input)) {
      return expressive ? '我听着呢。你想让我陪你安静待一会儿，还是一起想想办法？' : '不用急着把话说清楚。我先在这里陪你。';
    }
    if ((p.baseAxes['restraintExpression'] ?? 0) > 40) {
      return '要不要一起试试看？我有个想法，不过也想先听听你的意见。';
    }
    if ((p.traits['independence'] ?? 50) >= 75) {
      return '我想先把情况弄清楚。我们可以看看事实，再决定下一步。';
    }
    return '我想听听你的想法。我们慢慢来，找到彼此都舒服的方式。';
  }

  static String _degree(int value) => value < 40
      ? '较低'
      : value >= 75
      ? '较明显'
      : '适中';
  static String _bounded(String text, int maximum) {
    if (maximum <= 0) return '';
    if (text.length <= maximum) return text;
    if (maximum == 1) return '…';
    var end = maximum - 1;
    if (end > 0 &&
        text.codeUnitAt(end - 1) >= 0xD800 &&
        text.codeUnitAt(end - 1) <= 0xDBFF) {
      end--;
    }
    return '${text.substring(0, end)}…';
  }

  static final _triggers = <String, RegExp>{
    'praise': RegExp(
      r'夸|厉害|真棒|做得好|好厉害|すごい|偉い|褒|ありがとう|amazing|well done|praise|great job',
    ),
    'help': RegExp(r'帮我|帮忙|求助|怎么办|需要建议|助け|手伝|help|advice'),
    'refusal': RegExp(
      r'不要|不想|拒绝|独处|暂停|停下|别这样|不喜欢|嫌|やめ|一人に|stop|leave me|no thanks|do not',
    ),
    'absence': RegExp(
      r'没联系|未联系|没回复|不回复|两天|好久|忙碌|忽视|既読|連絡|返信|missed|no reply|days away',
    ),
    'jealousy': RegExp(r'别人|他人|其他人|其他角色|吃醋|嫉妒|親し|嫉妬|jealous|someone else'),
    'conflict': RegExp(
      r'争吵|吵架|误会|生气|伤害|取消|误解|喧嘩|誤解|怒|argument|misunderstand|cancel',
    ),
    'mistake': RegExp(r'犯错|做错|失误|失败|对不起|ごめん|失敗|間違|mistake|failed|sorry'),
    'success': RegExp(r'成功|进步|完成|赢了|做到|できた|成功|won|success|improved'),
    'distress': RegExp(
      r'难过|疲惫|累了|伤心|低落|受伤|痛苦|安慰|寂し|疲|悲し|sad|tired|hurt|comfort',
    ),
    'affection': RegExp(r'喜欢|爱你|陪伴|在乎|示好|抱抱|安慰你|喜欢你|好き|大切|love|care about|hug'),
    'novelty': RegExp(
      r'发现|新事物|新机会|未知|探索|冒险|初めて|発見|探検|discover|explore|new idea',
    ),
  };
}

class _Context {
  const _Context(this.input, this.emotion, this.closeness);
  final String input, emotion;
  final int closeness;
}
