import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/personality/personality_profile.dart';
import 'package:ryza_chat_mvp/src/personality/personality_presets.dart';
import 'package:ryza_chat_mvp/src/personality/personality_interpreter.dart';

void main() {
  final interpreter = PersonalityInterpreter();
  PersonalityProfile profile([String preset = 'tsundere']) =>
      PersonalityPresets.create(preset, 'ryza', profileId: 'trial');
  Map<String, dynamic> jsonProfile() =>
      jsonDecode(jsonEncode(profile().toJson())) as Map<String, dynamic>;

  test(
    'all eleven presets preserve named traits, coordinates and source rule IDs',
    () {
      expect(PersonalityPresets.ids.length, 11);
      expect(
        PersonalityPresets.names.keys.toSet(),
        PersonalityPresets.ids.toSet(),
      );
      for (final id in PersonalityPresets.ids) {
        final original = profile(id);
        final restored = PersonalityProfile.fromJson(
          jsonDecode(jsonEncode(original.toJson())),
          expectedCharacterId: 'ryza',
        );
        expect(restored.toJson(), original.toJson(), reason: id);
        expect(
          restored.traits.keys.toSet(),
          PersonalityProfile.traitLabels.keys.toSet(),
        );
        expect(restored.contradictions.length, inInclusiveRange(3, 4));
        expect(restored.motives, isNotEmpty);
        expect(
          restored.traits.values.every((value) => value >= 0 && value <= 100),
          isTrue,
        );
      }
      expect(profile('energetic_adventurer').baseAxes, {
        'selfOther': 35,
        'restraintExpression': 82,
      });
      expect(profile('tsundere').traits['emotionalExpressiveness'], 36);
      expect(profile('mischievous_teaser').traits['teasing'], 100);
      expect(profile('expressive_yandere').traits['attachment'], 98);
      expect(profile('calm_rational').traits['independence'], 88);
      expect(profile('earnest_clumsy').contradictions.first.id, 'EC-01');
    },
  );

  test('neutral defaults are stable, separate and disabled', () {
    final a = PersonalityConfiguration.defaults('ryza'),
        b = PersonalityConfiguration.defaults('ryza');
    expect(a.toJson(), b.toJson());
    expect(a.enabled, isFalse);
    expect(a.activeProfile.traits.values.every((v) => v == 50), isTrue);
    expect(a.activeProfile.characterId, 'ryza');
    expect(
      PersonalityConfiguration.defaults('sophie').activeProfile.characterId,
      'sophie',
    );
  });

  test(
    'optional absent sections fill neutral defaults without preset overwrite',
    () {
      final raw = {
        'schemaVersion': 1,
        'profileId': 'custom',
        'name': '我的人格',
        'characterId': 'ryza',
        'presetId': 'tsundere',
        'traits': {'teasing': 13},
      };
      final parsed = PersonalityProfile.fromJson(
        raw,
        expectedCharacterId: 'ryza',
      );
      expect(parsed.traits['teasing'], 13);
      expect(parsed.traits['curiosity'], 50);
      expect(parsed.tuning, PersonalityProfile.tuningDefaults);
      expect(parsed.baseAxes, {'selfOther': 0, 'restraintExpression': 0});
      expect(parsed.expression.values.every((value) => value), isTrue);
    },
  );

  test('external versions and character identities are strict', () {
    for (final version in [0, 2, 1.0, '1', null]) {
      final raw = jsonProfile()..['schemaVersion'] = version;
      expect(
        () => PersonalityProfile.fromJson(raw, expectedCharacterId: 'ryza'),
        throwsFormatException,
      );
    }
    expect(
      () => PersonalityProfile.fromJson(
        jsonProfile(),
        expectedCharacterId: 'sophie',
      ),
      throwsFormatException,
    );
    expect(
      () => PersonalityProfile.fromJson(
        jsonProfile()..['profileId'] = '../other',
        expectedCharacterId: 'ryza',
      ),
      throwsFormatException,
    );
  });

  test('number types and ranges reject malformed imports', () {
    for (final value in [-1, 101, 3.5, '60', true]) {
      final raw = jsonProfile();
      (raw['traits'] as Map)['trust'] = value;
      expect(
        () => PersonalityProfile.fromJson(raw, expectedCharacterId: 'ryza'),
        throwsFormatException,
      );
    }
    for (final value in [-101, 101]) {
      final raw = jsonProfile();
      (raw['baseAxes'] as Map)['selfOther'] = value;
      expect(
        () => PersonalityProfile.fromJson(raw, expectedCharacterId: 'ryza'),
        throwsFormatException,
      );
    }
    final raw = jsonProfile();
    (raw['traits'] as Map)['truust'] = 40;
    expect(
      () => PersonalityProfile.fromJson(raw, expectedCharacterId: 'ryza'),
      throwsFormatException,
    );
    expect(
      PersonalityProfile.fromJson(
        jsonProfile()..['futureNote'] = 'ignored',
        expectedCharacterId: 'ryza',
      ).toJson().containsKey('futureNote'),
      isFalse,
    );
  });

  test('invalid switches, collections and timestamps are rejected', () {
    for (final entry in <String, Object>{
      'motives': 'not a list',
      'expression': {'voice': 'yes'},
      'contradictions': [false],
      'metadata': {'createdAt': 'yesterday'},
      'name': '',
      'tuning': {'intensity': -1},
    }.entries) {
      final raw = jsonProfile()..[entry.key] = entry.value;
      expect(
        () => PersonalityProfile.fromJson(raw, expectedCharacterId: 'ryza'),
        throwsFormatException,
        reason: entry.key,
      );
    }
  });

  test('rules validate enums, bounds, keywords and duplicate identities', () {
    final base = PersonalityRule(id: 'test', response: '先听对方说完').toJson();
    for (final fields in <Map<String, dynamic>>[
      {'triggerType': 'unknown'},
      {'triggerType': 'keywords'},
      {'minCloseness': 70, 'maxCloseness': 40},
      {'minCloseness': -1},
      {'priority': 101},
      {'emotion': 'relaxed'},
      {'enabled': 1},
    ]) {
      expect(
        () => PersonalityRule.fromJson({...base, ...fields}),
        throwsFormatException,
      );
    }
    final raw = jsonProfile()..['contradictions'] = [base, base];
    expect(
      () => PersonalityProfile.fromJson(raw, expectedCharacterId: 'ryza'),
      throwsFormatException,
    );
    final acrossSections = jsonProfile()
      ..['contradictions'] = [base]
      ..['situations'] = [base];
    expect(
      () => PersonalityProfile.fromJson(
        acrossSections,
        expectedCharacterId: 'ryza',
      ),
      throwsFormatException,
    );
  });

  test('configuration checks profile counts, identity, active selection and toggles', () {
    final configuration = PersonalityConfiguration.defaults('ryza');
    expect(
      PersonalityConfiguration.fromJson(
        configuration.toJson(),
        expectedCharacterId: 'ryza',
      ).toJson(),
      configuration.toJson(),
    );
    for (final fields in <Map<String, dynamic>>[
      {'profiles': []},
      {
        'profiles': [profile().toJson(), profile().toJson()],
      },
      {'activeProfileId': 'missing'},
      {'enabled': 1},
      {'characterId': 'sophie'},
    ]) {
      expect(
        () => PersonalityConfiguration.fromJson({
          ...configuration.toJson(),
          ...fields,
        }, expectedCharacterId: 'ryza'),
        throwsFormatException,
      );
    }
  });

  test(
    'profile and configuration copies cannot mutate original collections',
    () {
      final traits = {'trust': 18};
      final p = PersonalityProfile(
        profileId: 'immutable',
        name: '草稿',
        characterId: 'ryza',
        traits: traits,
      );
      traits['trust'] = 99;
      expect(p.traits['trust'], 18);
      expect(() => p.traits['trust'] = 0, throwsUnsupportedError);
      final copy = p.copyWith(name: '改名', traits: {...p.traits, 'trust': 19});
      expect(copy.name, '改名');
      expect(p.name, '草稿');
      expect(p.traits['trust'], 18);
      final config = PersonalityConfiguration(
        characterId: 'ryza',
        activeProfileId: p.profileId,
        profiles: [p],
      );
      expect(() => config.profiles.add(copy), throwsUnsupportedError);
      expect(config.copyWith(enabled: true).enabled, isTrue);
      expect(config.enabled, isFalse);
    },
  );

  test('trigger matching honors priority, stable order and disabled rules', () {
    final p = profile().copyWith(
      contradictions: [
        PersonalityRule(id: 'disabled', enabled: false, priority: 100),
        PersonalityRule(id: 'tie-first', priority: 90, response: '先'),
        PersonalityRule(id: 'lower', priority: 20),
        PersonalityRule(id: 'top', priority: 100),
        PersonalityRule(id: 'tie-second', priority: 90, response: '后'),
      ],
      situations: [],
    );
    final result = interpreter.interpret(p);
    expect(result.triggeredRules.map((r) => r.id), [
      'top',
      'tie-first',
      'tie-second',
    ]);
    expect(result.triggerReasons['top'], contains('一般情境'));
    expect(result.motives.length, lessThanOrEqualTo(2));
  });

  test('structured trigger conditions require all filters', () {
    final rule = PersonalityRule(
      id: 'condition',
      triggerType: 'keywords',
      keywords: ['约定'],
      situations: ['晚上'],
      emotion: 'sad',
      minCloseness: 30,
      maxCloseness: 80,
    );
    final p = profile().copyWith(contradictions: [rule], situations: []);
    expect(
      interpreter
          .interpret(p, input: '晚上想起约定', emotion: 'sad', closeness: 50)
          .triggeredRules
          .single
          .id,
      'condition',
    );
    for (final result in [
      interpreter.interpret(p, input: '白天的约定', emotion: 'sad'),
      interpreter.interpret(p, input: '晚上想起约定', emotion: 'happy'),
      interpreter.interpret(p, input: '晚上想起约定', emotion: 'sad', closeness: 10),
    ]) {
      expect(result.triggeredRules, isEmpty);
    }
  });

  test(
    'deterministic presets differ in the same scenario without raw trait dump',
    () {
      const input = '今天有人夸我了，我也觉得你很厉害';
      final a = interpreter.interpret(profile('tsundere'), input: input);
      final b = interpreter.interpret(profile('gentle_guardian'), input: input);
      expect(a.prompt, isNot(b.prompt));
      expect(a.coreSummary, isNot(b.coreSummary));
      expect(
        a.prompt,
        interpreter.interpret(profile('tsundere'), input: input).prompt,
      );
      expect(a.prompt, contains('受到真诚夸奖'));
      expect(a.prompt, contains('原有角色身份'));
      for (final key in PersonalityProfile.traitLabels.keys) {
        expect(a.prompt, isNot(contains('"$key"')));
      }
    },
  );

  test('interpreter bounds output including imported long rules', () {
    final p = profile().copyWith(
      motives: List.generate(12, (i) => '$i${'动机' * 100}'),
      contradictions: List.generate(
        24,
        (i) => PersonalityRule(
          id: 'rule-$i',
          priority: 100 - i,
          surface: '外在' * 100,
          hiddenNeed: '内在' * 100,
          response: '表达' * 150,
          constraint: '限制' * 150,
        ),
      ),
      situations: [],
    );
    final result = interpreter.interpret(p, input: '帮帮我');
    expect(
      result.prompt.length,
      lessThanOrEqualTo(PersonalityInterpreter.maxPromptCharacters),
    );
    expect(
      result.coreSummary.length,
      lessThanOrEqualTo(PersonalityInterpreter.maxCoreCharacters),
    );
    expect(result.triggeredRules.length, 3);
    expect(result.motives.length, 2);
    expect(result.preferences.values.every((s) => s.length <= 240), isTrue);
    expect(result.prompt, contains('当前情绪neutral'));
  });

  test(
    'saved teaser preset keeps its everyday style without a rule trigger',
    () {
      final saved = PersonalityProfile.fromJson(
        profile('mischievous_teaser').toJson(),
        expectedCharacterId: 'ryza',
      );
      final result = interpreter.interpret(saved, input: '今天有什么安排？');
      expect(result.triggeredRules, isEmpty);
      expect(result.prompt, contains(saved.metadata['style']!));
      expect(result.prompt, contains(saved.metadata['summary']!));
      expect(result.prompt, contains('短句、反问、挑战'));
      expect(result.prompt, contains('实际台词的措辞或句式'));
      expect(result.prompt, contains('仅在说话风格冲突时采用本段'));
      expect(result.prompt, contains('当前主角，不转给其他角色'));
      expect(result.prompt, isNot(contains('玩笑程度较低')));
      expect(result.coreSummary, contains('调侃鲜明且主动'));
    },
  );

  for (final id in PersonalityPresets.ids) {
    test('$id keeps its distinct baseline in ordinary conversation', () {
      final p = profile(id);
      final result = interpreter.interpret(p, input: '今天有什么安排？');
      expect(result.prompt, contains(p.metadata['style']!));
      expect(
        result.prompt,
        contains('用户已在设置中选择「${PersonalityPresets.names[id]}」'),
      );
      expect(result.prompt, contains('无需用户在聊天中再次说'));
      expect(result.prompt.length, lessThanOrEqualTo(1200));
      expect(result.prompt, contains('不机械重复预设口头禅'));
    });
  }

  test('saved teaser gets explicit delivery without user roleplay request', () {
    final saved = PersonalityProfile.fromJson(
      profile('mischievous_teaser').toJson(),
      expectedCharacterId: 'ryza',
    );
    final ordinary = interpreter.interpret(saved, input: '今天有什么安排？');
    expect(ordinary.triggeredRules, isEmpty);
    expect(ordinary.prompt, contains('台词演法：得意、欠嘴'));
    expect(ordinary.prompt, contains('被反击时短暂卡壳、嘴硬找补'));
    expect(ordinary.prompt, contains('按回复语言改写，勿照抄或当作经历'));
    expect(ordinary.prompt, contains('小笨蛋'));
    final withRules = interpreter.interpret(saved, input: '你真棒，能帮我吗？');
    expect(withRules.triggeredRules.length, 3);
    for (final rule in withRules.triggeredRules) {
      expect(withRules.prompt, contains(rule.response));
    }
    expect(withRules.prompt.length, lessThanOrEqualTo(1200));
    expect(withRules.prompt, contains('不机械重复预设口头禅'));
  });

  test('bratty examples respect edits, context and preset isolation', () {
    final original = profile('mischievous_teaser');
    for (final edited in [
      original.copyWith(traits: {...original.traits, 'teasing': 60}),
      original.copyWith(traits: {...original.traits, 'playfulness': 20}),
      original.copyWith(tuning: {...original.tuning, 'intensity': 20}),
      original.copyWith(clearPreset: true),
      profile('scheming_tease'),
    ]) {
      expect(interpreter.interpret(edited).prompt, isNot(contains('台词演法')));
    }
    for (final input in [
      '别这样，我不想开玩笑了',
      '今天很难过',
      'Please STOP teasing',
      'やめて',
    ]) {
      expect(
        interpreter.interpret(original, input: input).prompt,
        isNot(contains('台词演法')),
      );
    }
    for (final emotion in ['sad', 'worried']) {
      expect(
        interpreter.interpret(original, emotion: emotion).prompt,
        isNot(contains('台词演法')),
      );
    }
    expect(
      interpreter.interpret(original.copyWith(clearPreset: true)).prompt,
      contains('选择自定义人格'),
    );
  });

  test(
    'custom personality directs roleplay from saved content without a preset',
    () {
      final custom = PersonalityProfile(
        profileId: 'custom-observer',
        name: '安静的观察者',
        characterId: 'ryza',
        baseAxes: {'selfOther': -60, 'restraintExpression': -75},
        traits: {'teasing': 10, 'curiosity': 90},
        metadata: {
          'summary': '沉静、好奇，习惯先观察再开口。',
          'style': '短句、具体观察，少感叹，留出思考停顿。',
        },
        motives: ['希望弄清事情的原因。'],
        situations: [
          PersonalityRule(id: 'observe-first', response: '先提出一个具体观察，再给出自己的判断。'),
        ],
      );
      final saved = PersonalityProfile.fromJson(
        custom.toJson(),
        expectedCharacterId: 'ryza',
      );
      final result = interpreter.interpret(saved, input: '今天有什么安排？');
      expect(result.prompt, contains('选择自定义人格「安静的观察者」'));
      expect(result.prompt, contains('从本轮起持续按下列风格、参数、动机和情境规则'));
      expect(result.prompt, contains(custom.metadata['style']!));
      expect(result.prompt, contains(custom.motives.first));
      expect(result.prompt, contains(custom.situations.first.response));
      expect(result.prompt, contains('感受表达偏克制'));
      expect(result.prompt, isNot(contains('台词演法：得意、欠嘴')));
      expect(result.prompt.length, lessThanOrEqualTo(1200));

      final numericOnly = saved.copyWith(
        metadata: {},
        motives: [],
        situations: [],
      );
      final numericPrompt = interpreter.interpret(numericOnly).prompt;
      expect(numericPrompt, contains('当前扮演指令'));
      expect(numericPrompt, contains('感受表达偏克制'));
      expect(numericPrompt, isNot(contains('常态表达')));
      for (final p in [saved, numericOnly]) {
        expect(interpreter.interpret(p, enabled: false).prompt, isEmpty);
        expect(
          interpreter.interpret(p.copyWith(tuning: {'intensity': 0})).prompt,
          isEmpty,
        );
        expect(
          interpreter
              .interpret(p.copyWith(expression: {'dialogue': false}))
              .prompt,
          isEmpty,
        );
      }
    },
  );

  test(
    'extreme teasing differs from moderate and respects edited parameters',
    () {
      final p = profile('mischievous_teaser');
      final high = interpreter.interpret(p);
      final medium = interpreter.interpret(
        p.copyWith(traits: {...p.traits, 'teasing': 60, 'playfulness': 60}),
      );
      final low = interpreter.interpret(
        p.copyWith(traits: {...p.traits, 'teasing': 0, 'playfulness': 20}),
      );
      expect(high.coreSummary, contains('调侃鲜明且主动'));
      expect(medium.coreSummary, contains('喜欢轻度调侃'));
      expect(low.coreSummary, contains('减少试探性玩笑'));
      expect(low.coreSummary, isNot(contains('调侃鲜明且主动')));
      expect(low.prompt, contains('手调参数优先'));
      expect(high.preferences['voice'], contains('鲜明的逗趣'));
      expect(low.preferences['voice'], isNot(contains('鲜明的逗趣')));
      expect(interpreter.interpret(p, enabled: false).prompt, isEmpty);
      expect(
        interpreter.interpret(p.copyWith(tuning: {'intensity': 0})).prompt,
        isEmpty,
      );
      expect(
        interpreter
            .interpret(p.copyWith(expression: {'dialogue': false}))
            .prompt,
        isEmpty,
      );
    },
  );

  test('long baseline text cannot remove the final state separation', () {
    final p = profile('mischievous_teaser').copyWith(
      metadata: {'summary': '特征' * 300, 'style': '说话方式' * 150},
      motives: ['需要' * 100, '动机' * 100],
    );
    final result = interpreter.interpret(p, input: '你真棒，能帮我吗？');
    expect(result.prompt.length, lessThanOrEqualTo(1200));
    expect(result.prompt, contains('当前情绪neutral'));
    expect(result.prompt, contains('不机械重复预设口头禅'));
  });

  test(
    'situational middle traits affect behavior behind the strongest extremes',
    () {
      final original = profile('expressive_yandere');
      final a = original.copyWith(traits: {...original.traits, 'trust': 39});
      final b = original.copyWith(traits: {...original.traits, 'trust': 60});
      expect(
        interpreter.interpret(a, input: '用户正在和其他人亲近').coreSummary,
        contains('建立信任较谨慎'),
      );
      expect(
        interpreter.interpret(b, input: '用户正在和其他人亲近').coreSummary,
        contains('倾向先相信'),
      );
    },
  );

  test('real emulator praise thanks past help without requesting it again', () {
    final result = interpreter.interpret(
      profile(),
      input:
          'For this chat test only my favorite tea is jasmine. '
          'You did a great job on the potion today and I really appreciate your help.',
    );
    final ids = result.triggeredRules.map((rule) => rule.id).toSet();
    expect(ids, contains('TS-02'));
    expect(ids, isNot(contains('TS-01')));
    expect(result.prompt, isNot(contains('反应嘴上可以别扭，但实际帮助必须真实有效')));
  });

  test(
    'real emulator user failure asks for help without character taking blame',
    () {
      final result = interpreter.interpret(
        profile(),
        input:
            'I failed the recipe. Can you help me fix it? '
            'Please give me one practical first step.',
      );
      final ids = result.triggeredRules.map((rule) => rule.id).toSet();
      expect(ids, contains('TS-01'));
      expect(ids, contains('tsundere_S3'));
      expect(ids, isNot(contains('TS-04')));
      expect(result.prompt, isNot(contains('先辩解、后道歉')));
    },
  );

  for (final input in [
    '谢谢你帮我调好药水，你真棒。',
    '上次你帮我解决了问题，我很感谢。',
    '多亏你的帮助，我已经解决了。',
    'I appreciate your help.',
    'Thank you for helping me yesterday.',
    'You helped me fix my mistake. Thanks!',
    'The help page mentions advice, but I am just reading it.',
    '昨日は手伝ってくれてありがとう。すごいね。',
    '助けてくれてありがとう。',
    'この前助けてもらったことに感謝しています。',
  ]) {
    test('gratitude or a past favor is not a current request: $input', () {
      final result = interpreter.interpret(profile(), input: input);
      expect(
        result.triggeredRules.map((rule) => rule.id),
        isNot(contains('TS-01')),
      );
    });
  }

  for (final input in [
    '能帮我修好药水吗？',
    '请你帮我看看第一步该怎么做。',
    '帮帮我。',
    '谢谢你昨天帮我，现在能不能再帮我看看这个配方？',
    'Can you help me fix it?',
    'Could you please help me?',
    'I need your help.',
    'Give me some advice on this recipe.',
    'Thanks for your help yesterday. Can you help me again today?',
    'THANKS FOR YOUR HELP YESTERDAY. CAN YOU HELP ME AGAIN TODAY?',
    "I don't need help with my recipe. Could you help me find a book instead?",
    'レシピを直すのを手伝ってください。',
    '助けてほしい。',
    'どうすればいいですか？',
    '昨日はありがとう。今の調合も手伝ってもらえる？',
  ]) {
    test('current requests remain available across languages: $input', () {
      final result = interpreter.interpret(profile(), input: input);
      expect(result.triggeredRules.map((rule) => rule.id), contains('TS-01'));
    });
  }

  for (final input in [
    '不需要你的帮助。',
    '不要帮我，我想自己做。',
    "I don't need help.",
    "Please don't help me.",
    "You didn't help me.",
    '手伝いはいらない。',
    '助けないで。',
  ]) {
    test('declining help does not activate a new help rule: $input', () {
      expect(
        interpreter
            .interpret(profile(), input: input)
            .triggeredRules
            .map((rule) => rule.id),
        isNot(contains('TS-01')),
      );
    });
  }

  for (final input in [
    '我把配方做错了，能帮我吗？',
    '我又失败了，请给我建议。',
    '配方失败了，帮帮我。',
    'I failed the recipe. Can you help me?',
    'I made a mistake in the potion.',
    "I'm sorry, I got it wrong.",
    '私が調合に失敗した。手伝ってください。',
    '僕が間違えた。',
    'レシピに失敗した。',
  ]) {
    test('user mistakes never assign character responsibility: $input', () {
      expect(
        interpreter
            .interpret(profile(), input: input)
            .triggeredRules
            .map((rule) => rule.id),
        isNot(contains('TS-04')),
      );
      final adventurer = interpreter.interpret(
        profile('energetic_adventurer'),
        input: input,
      );
      expect(
        adventurer.triggeredRules.map((rule) => rule.id),
        contains('energetic_adventurer_S3'),
      );
      expect(
        adventurer.triggeredRules.map((rule) => rule.id),
        isNot(contains('energetic_adventurer_S5')),
      );
    });
  }

  for (final input in [
    '你刚才做错了，请承担责任。',
    '莱莎说错了。',
    '你给我的配方错了。',
    'You made a mistake in that recipe.',
    'Your answer was incorrect.',
    'You got it wrong.',
    'ライザが間違えたよ。',
    'あなたの説明は間違っている。',
    'さっきの説明が間違っているよ。',
  ]) {
    test(
      'pointing out a character mistake still asks it to take responsibility: $input',
      () {
        expect(
          interpreter
              .interpret(profile(), input: input)
              .triggeredRules
              .map((rule) => rule.id),
          contains('TS-04'),
        );
        final adventurer = interpreter.interpret(
          profile('energetic_adventurer'),
          input: input,
        );
        expect(
          adventurer.triggeredRules.map((rule) => rule.id),
          contains('energetic_adventurer_S5'),
        );
        expect(
          adventurer.triggeredRules.map((rule) => rule.id),
          isNot(contains('energetic_adventurer_S3')),
        );
      },
    );
  }

  for (final input in [
    '你没有做错，不用道歉。',
    "You didn't make a mistake.",
    "You weren't wrong.",
    'ライザは間違っていないよ。',
    '君は悪くない。',
  ]) {
    test('negated fault cannot force a character apology: $input', () {
      expect(
        interpreter
            .interpret(profile(), input: input)
            .triggeredRules
            .map((rule) => rule.id),
        isNot(contains('TS-04')),
      );
    });
  }

  test('disabled channels do not leak preferences or dialogue constraints', () {
    final p = profile().copyWith(
      expression: {
        'dialogue': false,
        'face': false,
        'action': true,
        'voice': false,
      },
    );
    final result = interpreter.interpret(p, input: '帮帮我');
    expect(result.prompt, isEmpty);
    expect(result.preferences.keys, ['action']);
    final off = interpreter.interpret(p, enabled: false);
    expect(off.prompt, isEmpty);
    expect(off.preferences, isEmpty);
    expect(off.triggeredRules, isEmpty);
    final zero = interpreter.interpret(p.copyWith(tuning: {'intensity': 0}));
    expect(zero.prompt, isEmpty);
    expect(zero.preferences, isEmpty);
  });

  test(
    'scenario preview never changes profile, emotion or relationship baseline',
    () {
      final p = profile();
      final before = jsonEncode(p.toJson());
      final result = interpreter.interpret(
        p,
        input: '我不想再聊了，请停下',
        emotion: 'sad',
        closeness: 3,
      );
      expect(result.preview, contains('时间'));
      expect(jsonEncode(p.toJson()), before);
      expect(result.preferences['action'], isNot(contains('grp_')));
    },
  );
}
