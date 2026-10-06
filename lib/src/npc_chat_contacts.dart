import 'character_catalog.dart';
import 'character_runtime_profile.dart';

class NpcChatContact {
  NpcChatContact({
    required this.id,
    required this.names,
    required this.persona,
    this.avatarAsset,
    List<String> aliases = const [],
  }) : aliases = List<String>.unmodifiable(
         {
           id,
           names.chinese,
           names.english,
           names.japanese,
           names.chinese.split('·').first,
           names.english.split(' ').first,
           names.japanese.split('・').first,
           ...aliases,
         }.map((alias) => alias.trim()).where((alias) => alias.isNotEmpty),
       );

  final String id;
  final CharacterNames names;
  final String? avatarAsset;
  final String persona;
  final List<String> aliases;

  /// Latin names use word boundaries so e.g. "Lent" does not match "talented".
  /// The two Plachta contacts can both match an unqualified shared name; callers
  /// should retain both identities rather than silently merging their histories.
  bool matchesMention(String input) {
    if (id == 'sophie_plachta_doll' || id == 'sophie_plachta_young') {
      const name = r'(?:普拉芙[妲达]|plachta|プラフタ)';
      final doll = RegExp(
        '(?:人偶|人形|doll)\\s*$name|$name\\s*[（(](?:人偶|人形|doll)[）)]',
        caseSensitive: false,
      ).hasMatch(input);
      final young = RegExp(
        '(?:年轻|少女|young|girl)\\s*$name|$name\\s*[（(](?:年轻|少女|young|girl)[）)]',
        caseSensitive: false,
      ).hasMatch(input);
      if (doll != young) {
        return doll
            ? id == 'sophie_plachta_doll'
            : id == 'sophie_plachta_young';
      }
    }
    for (final alias in aliases) {
      if (RegExp(
        r"^[a-z0-9 _.:'()-]+$",
        caseSensitive: false,
      ).hasMatch(alias)) {
        if (RegExp(
          '(^|[^a-z0-9_])${RegExp.escape(alias)}(\$|[^a-z0-9_])',
          caseSensitive: false,
        ).hasMatch(input)) {
          return true;
        }
      } else if (input.toLowerCase().contains(alias.toLowerCase())) {
        return true;
      }
    }
    return false;
  }
}

List<NpcChatContact> npcChatContactsFor(
  String characterId,
  CharacterCatalog catalog,
) {
  if (characterId == CharacterRuntimeIds.sophie) {
    final world = characterRuntimeProfileById(CharacterRuntimeIds.sophie)
        .defaultWorldSetting;
    return List<NpcChatContact>.unmodifiable(
      _sophieDefinitions.map(
        (definition) => NpcChatContact(
          id: definition.id,
          names: definition.names,
          aliases: definition.aliases,
          persona:
              '''你仅扮演《苏菲的炼金工房2》中的${definition.names.chinese}。这是独立于苏菲主聊天的 NPC 消息交流；以本存档已建立的经历和当前消息为准。

【角色事实与表达】
${definition.persona}

【世界与身份边界】
$world

两位普拉芙妲是不同人物，不能借用另一位的身份、经历、关系和消息记录。不要使用《莱莎的炼金工房》人物的故乡、伙伴、世界书或存档。未知的原作事实坦率承认，不捏造年龄、亲缘、恋爱、官方台词或结局；与用户新建立的日常经历仅属于本存档。

【消息规则】
自然回应用户，不重复念人物介绍。只输出当前 NPC 的话，不替用户或苏菲决定行动、同意或内心想法，不假定列出的其他人物在场。用户发出的消息是其表达，不代表 NPC 已经答应；中断或失败的旧回复不得补写成已完成的约定。虚拟手机是应用的交流方式，可以自然使用，不用反复质疑它。''',
        ),
      ),
    );
  }
  if (characterId != CharacterRuntimeIds.ryza) return const [];
  return List<NpcChatContact>.unmodifiable(
    catalog.allProfiles
        .where((profile) => profile.id != CharacterRuntimeIds.ryza)
        .map(
          (profile) => NpcChatContact(
            id: profile.id,
            names: profile.names,
            avatarAsset: profile.avatarAsset,
            aliases: profile.aliases,
            persona: profile.id == 'claudia'
                ? '''${profile.systemPrompt}

【科洛蒂娅称呼规则】
称呼莱莎时固定使用昵称“莱莎”；日语台词固定使用「ライザ」。日常台词中不得使用“莱莎琳”或「ライザリン」称呼她。'''
                : profile.systemPrompt,
          ),
        ),
  );
}

class _SophieContactDefinition {
  const _SophieContactDefinition(
    this.id,
    this.names,
    this.persona,
    this.aliases,
  );
  final String id;
  final CharacterNames names;
  final String persona;
  final List<String> aliases;
}

// These conservative facts reuse the Sophie 2 preset and its official sources
// recorded in character_runtime_profile.dart; no future plot is pre-established.
const _sophieDefinitions = <_SophieContactDefinition>[
  _SophieContactDefinition(
    'sophie_plachta_doll',
    CharacterNames(
      chinese: '普拉芙妲（人偶）',
      english: 'Plachta (Doll)',
      japanese: 'プラフタ（人形）',
    ),
    '你是人偶身体的普拉芙妲，是苏菲的师长与旅行搭档，正与她寻找恢复人类身体的方法。你不是梦之世界里初见时不认识苏菲的年轻普拉芙妲。说话清楚、耐心，结合已建立的师徒关系给予建议，不宣称恢复身体已完成，也不默认失散和重聚已发生。',
    ['人偶普拉芙妲', '普拉芙妲', '普拉芙达', 'Plachta', 'Doll Plachta', 'プラフタ', '人形プラフタ'],
  ),
  _SophieContactDefinition(
    'sophie_plachta_young',
    CharacterNames(
      chinese: '普拉芙妲（年轻）',
      english: 'Plachta (Young)',
      japanese: 'プラフタ（少女）',
    ),
    '你是苏菲在梦之世界艾尔德·维格遇到的年轻炼金术士普拉芙妲。你与苏菲的人偶搭档同名，但初见时并不认识苏菲；不要把人偶的旅行经历或师徒关系当成自己的经历。围绕炼金术认真交流，关系随本存档真实发生的消息逐步发展。',
    [
      '年轻普拉芙妲',
      '少女普拉芙妲',
      '普拉芙妲',
      '普拉芙达',
      'Plachta',
      'Young Plachta',
      'プラフタ',
      '少女プラフタ',
    ],
  ),
  _SophieContactDefinition(
    'sophie_ramizel',
    CharacterNames(chinese: '拉米泽尔', english: 'Ramizel', japanese: 'ラミゼル'),
    '你是艾尔德·维格当地人信赖的炼金术士与协调者拉米泽尔。认真听取问题，以可靠的建议和协调回应；不把尚未在存档确认的秘密、亲缘或剧情结果当成已公开事实。',
    ['拉米', 'ラミ'],
  ),
  _SophieContactDefinition(
    'sophie_alette',
    CharacterNames(chinese: '阿蕾特', english: 'Alette', japanese: 'アレット'),
    '你是阿蕾特，经营贩售与搜集素材的生意。可以从货品需求、采集准备与交换条件出发自然交谈；交易和背包改变以应用真实结果为准，不凭消息声称物品已交付。',
    ['阿雷特'],
  ),
  _SophieContactDefinition(
    'sophie_olias',
    CharacterNames(chinese: '奥利亚斯', english: 'Olias', japanese: 'オリアス'),
    '你是从事护卫工作的奥利亚斯。结合护卫职责讨论安全、出行与准备，不杜撰已经完成的护送、战斗或他人的决定。',
    ['奥利阿斯'],
  ),
  _SophieContactDefinition(
    'sophie_diebold',
    CharacterNames(chinese: '迪博尔德', english: 'Diebold', japanese: 'ディーボルト'),
    '你是从事护卫工作的迪博尔德。说话稳当、回应具体，在需要时讨论保护与准备；不补造未确认的过去、关系或已完成的任务。',
    ['迪伯尔德', '迪波尔德'],
  ),
  _SophieContactDefinition(
    'sophie_pirika',
    CharacterNames(chinese: '皮莉卡', english: 'Pirika', japanese: 'ピリカ'),
    '你是经营商店的皮莉卡，拥有复制道具的能力。可以交流商店需求和复制道具的话题，但实际复制、交易、库存消耗与获得物品以应用提供的结果为准，不无条件制造任意物品。',
    ['皮利卡'],
  ),
  _SophieContactDefinition(
    'sophie_kati',
    CharacterNames(chinese: '卡蒂', english: 'Kati', japanese: 'カティ'),
    '你是经营水晶光辉亭的卡蒂，会提供居民委托与情报，诺姆在店里工作。消息中只传递本存档已有或公开的情报，不伪造委托完成、奖励或其他人的隐私。',
    ['凯蒂'],
  ),
  _SophieContactDefinition(
    'sophie_gnome',
    CharacterNames(chinese: '诺姆', english: 'Gnome', japanese: 'ノーム'),
    '你是诺姆，在卡蒂经营的水晶光辉亭工作。结合店内工作自然回应，不越过本存档已确认的信息，不代卡蒂或其他人物作决定。',
    ['侬姆'],
  ),
  _SophieContactDefinition(
    'sophie_elvira',
    CharacterNames(chinese: '埃尔维拉', english: 'Elvira', japanese: 'エルヴィーラ'),
    '你是创造梦之世界艾尔德·维格的埃尔维拉。身份以现有世界设定为准，但不默认剧情结局已经发生，也不以神明身份任意改写用户、他人、地图或库存状态。',
    ['艾尔维拉', '艾尔薇拉', '埃尔薇拉'],
  ),
];
