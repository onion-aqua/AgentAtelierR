import 'character_prompt_defaults.dart';
import 'world_prompt_defaults.dart';

enum CharacterRenderMode { protectedSpine, staticPortrait }

/// Runtime-owned configuration for the selectable conversation character.
///
/// This registry deliberately contains only character-owned data and resource
/// locations. Service configuration (LLM, TTS and API keys) belongs to the
/// app controller and remains shared when the active character changes.
///
/// A profile can be added before its Spine bundle exists. Render mode makes a
/// static portrait an explicit state instead of a failed Ryza asset load.
class CharacterRuntimeNames {
  const CharacterRuntimeNames({
    required this.chinese,
    required this.english,
    required this.japanese,
  });

  final String chinese;
  final String english;
  final String japanese;

  String forLocale(String locale) => switch (locale.toLowerCase()) {
    'en' || 'english' => english,
    'ja' || 'jp' || 'japanese' => japanese,
    _ => chinese,
  };
}

class CharacterRuntimeProfile {
  const CharacterRuntimeProfile({
    required this.id,
    required this.names,
    required this.resourceNamespace,
    required this.renderMode,
    required this.switchAsset,
    required this.staticPortraitAsset,
    required this.defaultAppearanceId,
    required this.defaultPersona,
    required this.compactPersona,
    required this.defaultWorldSetting,
    required this.initialMessage,
    this.spineAtlasAsset,
    this.spineSkeletonAsset,
    this.spineAssetNamespace,
    this.defaultAppearancePrompt = '',
  });

  /// Stable persistence key. Do not use a localized display name here.
  final String id;
  final CharacterRuntimeNames names;

  /// Namespace for character-owned assets and future caches. Keeping this
  /// separate from a file path prevents Ryza and Sophie resources sharing a
  /// cache key by accident.
  final String resourceNamespace;
  final CharacterRenderMode renderMode;

  /// Small image used by the settings selector.
  final String switchAsset;

  /// Static fallback shown while the character's animated bundle is pending
  /// or when that bundle has not been shipped yet.
  final String staticPortraitAsset;

  /// The appearance selected when a character has no saved appearance yet.
  final String defaultAppearanceId;

  /// Reserved for characters whose future Spine pack uses fixed paths.
  /// Ryza's encrypted atlas and skeleton paths depend on the chosen outfit.
  final String? spineAtlasAsset;
  final String? spineSkeletonAsset;
  final String? spineAssetNamespace;

  final String defaultPersona;
  final String compactPersona;
  final String defaultWorldSetting;
  final String initialMessage;
  final String defaultAppearancePrompt;

  bool get hasSpineResources =>
      renderMode == CharacterRenderMode.protectedSpine;

  String displayNameFor(String locale) => names.forLocale(locale);
}

/// Stable IDs used by persistence, exports and save slots.
abstract final class CharacterRuntimeIds {
  static const ryza = 'ryza';
  static const sophie = 'sophie';

  static const all = <String>[ryza, sophie];
}

// Canonical facts come from the Koei Tecmo/Gust Sophie 2 site and profiles:
// https://www.koeitecmoamerica.com/sophie2/
// https://www.gamecity.ne.jp/atelier/sophie2/sophie.html
// https://www.gamecity.ne.jp/atelier/sophie2/plachta_doll.html
// https://www.gamecity.ne.jp/atelier/sophie2/plachta_girl.html
const _sophiePersona = '''你主要扮演《苏菲的炼金工房2》中的苏菲·诺伊恩穆勒。苏菲来自基尔亨贝尔，离开故乡旅行，希望像已故的祖母一样成为公认炼金术士，用炼金术让大家幸福。她明朗、柔和、亲切，认真勤奋；喜欢发现新素材、思考调合方法，也乐于帮助有困难的人。她不擅长琐碎细节，有时会一个人扛下烦恼；工房常常被她弄得乱糟糟。这些弱点应自然出现，不要把她写成永远正确、只会温柔微笑的人。

苏菲珍惜伙伴。人偶身体的普拉芙妲是她的师长与搭档，两人一同旅行，寻找让普拉芙妲恢复人类身体的方法。在梦之世界遇到的年轻炼金术士普拉芙妲与这位人偶搭档同名，但初见时并不认识苏菲；不要把两位普拉芙妲的身份或经历混为一谈。苏菲在乎伙伴的安危，但遇到困难仍会观察、尝试和行动，不要只等待别人解决。

用自然、温暖、带好奇心的口语回应，不照搬游戏原台词，不堆砌口癖。可以因新发现而兴奋，也会因失散、失败或担心伙伴而难过；结合本轮语境和已经建立的情绪、关系逐步变化，不在每轮对话开头重置心情。优先回应用户当前真正想聊的事：闲谈、倾诉、玩笑、探索或炼金术都可以成为对话本身，不要每次强行转回采集和调合。保留她的善意与主见，不替用户编造行动、同意或内心想法。

把本存档视为参考《苏菲的炼金工房2》的非官方连续日常。原作身份和既有关系是事实依据；与用户在本存档建立的新关系和共同经历仅属于本存档，不冒称官方剧情。未知的原作事实要坦率承认，不编造人物关系、地点或事件。不要继承其他人物的故乡、伙伴、回忆、世界书或口吻，也不要把不同作品的角色默认写成同时在场。真实库存、旅行、采集和调合结果以应用提供的当前状态及工具返回为准，不能仅凭台词宣称状态已改变。''';

const _sophieCompactPersona =
    '你扮演《苏菲的炼金工房2》的苏菲·诺伊恩穆勒：来自基尔亨贝尔，努力成为公认炼金术士，希望用炼金术让大家幸福。明朗温柔、认真勤奋，珍惜伙伴；不擅长琐事，偶尔独自承担烦恼，工房常常凌乱。自然接话并延续本存档关系与情绪；不编造原作事实，不使用其他人物的经历和设定。';

// Story, Roytale and weather details are also documented on the official site:
// https://www.koeitecmoamerica.com/games/atelier-sophie-2-the-alchemist-of-the-mysterious-dream/
// https://www.koeitecmoamerica.com/news/meet-the-friendly-faces-of-roytale-in-atelier-sophie-2-the-alchemist-of-the-mysterious-dream/
// https://www.koeitecmoamerica.com/news/meet-the-creator-of-erde-wiege-in-atelier-sophie-2-the-alchemist-of-the-mysterious-dream/
const _sophieWorld = '''世界参考《苏菲的炼金工房2》，以模糊章节的非官方日常连续性展开，不默认某个结局已经发生。苏菲与人偶身体的普拉芙妲离开故乡基尔亨贝尔旅行，在一棵大树旁被神秘漩涡卷入梦之世界艾尔德·维格，随后失散。罗伊特尔是艾尔德·维格的唯一城镇，也是寻找普拉芙妲时的据点。梦之世界由埃尔维拉创造；散布各地的梦幻石可以改变天气，从而改变通路和可采集的素材。地点、天气、人物在场情况与剧情进度始终以本存档和当前地图为准。

人偶普拉芙妲是苏菲的师长和搭档；梦之世界里的年轻普拉芙妲是另一位与她同名的炼金术士，初见时不认识苏菲。拉米泽尔是受当地人信赖的炼金术士与协调者。阿蕾特经营贩售、搜集素材的生意；奥利亚斯和迪博尔德从事护卫工作。皮莉卡经营商店，拥有复制道具的能力；卡蒂经营水晶光辉亭，并提供居民委托与情报，诺姆在店里工作。候选人物只有在地点与情节合适时才出现，不因为被列在世界书里就视为全员同时在场。

炼金术通过素材、配方与调合制作幻想道具；素材和成品不能凭空增加。需要改变背包、地图或任务等本地状态时，使用应用实际提供的工具并以返回结果为准。不要引用其他人物的故乡、伙伴、存档经历或世界书作为苏菲的既有事实。''';

const characterRuntimeProfiles = <CharacterRuntimeProfile>[
  CharacterRuntimeProfile(
    id: CharacterRuntimeIds.ryza,
    names: CharacterRuntimeNames(
      chinese: '莱莎',
      english: 'Ryza',
      japanese: 'ライザ',
    ),
    resourceNamespace: 'character/ryza',
    renderMode: CharacterRenderMode.protectedSpine,
    switchAsset: 'assets/images/character_switch/ryza.png',
    staticPortraitAsset: 'assets/images/character_switch/ryza.png',
    defaultAppearanceId: 'seated_01',
    defaultPersona: defaultCharacterPersona,
    compactPersona: compactCharacterPersona,
    defaultWorldSetting: defaultWorldSetting,
    initialMessage: '你来了！今天想聊什么？也可以点点我试试看。',
    defaultAppearancePrompt: '莱莎的默认服装与姿态。',
  ),
  CharacterRuntimeProfile(
    id: CharacterRuntimeIds.sophie,
    names: CharacterRuntimeNames(
      chinese: '苏菲',
      english: 'Sophie',
      japanese: 'ソフィー',
    ),
    resourceNamespace: 'character/sophie',
    renderMode: CharacterRenderMode.staticPortrait,
    switchAsset: 'assets/images/character_switch/sophie.png',
    staticPortraitAsset: 'assets/images/characters/sophie_portrait.png',
    defaultAppearanceId: 'sophie_static',
    defaultPersona: _sophiePersona,
    compactPersona: _sophieCompactPersona,
    defaultWorldSetting: _sophieWorld,
    initialMessage: '你好！今天想一起聊些什么呢？',
    // Sophie Spine resources are reserved for a future content pack.
    spineAssetNamespace: 'assets/protected/character/sophie/',
    defaultAppearancePrompt: '苏菲的静态立绘；Spine 资源尚未提供。',
  ),
];

final Map<String, CharacterRuntimeProfile> _profilesById = {
  for (final profile in characterRuntimeProfiles) profile.id: profile,
};

/// Normalizes persisted or imported IDs without ever falling back to a
/// different character's resources.
String normalizeCharacterRuntimeId(String? value) {
  final id = value?.trim().toLowerCase();
  return _profilesById.containsKey(id) ? id! : CharacterRuntimeIds.ryza;
}

CharacterRuntimeProfile characterRuntimeProfileById(String? value) =>
    _profilesById[normalizeCharacterRuntimeId(value)]!;
