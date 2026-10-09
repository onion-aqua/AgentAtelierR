import 'npc_chat_contacts.dart';
import 'chat_segments.dart';

/// The communication methods that can be mentioned in the roleplay without
/// changing the app's fictional world state.
enum NpcContactChannel {
  generic,
  wechat,
  qq,
  sms,
  line,
  discord,
  telegram,
  email,
}

extension NpcContactChannelLabel on NpcContactChannel {
  String get label => switch (this) {
    NpcContactChannel.generic => '联系方式',
    NpcContactChannel.wechat => '微信',
    NpcContactChannel.qq => 'QQ',
    NpcContactChannel.sms => '短信 / SMS',
    NpcContactChannel.line => 'LINE',
    NpcContactChannel.discord => 'Discord',
    NpcContactChannel.telegram => 'Telegram',
    NpcContactChannel.email => '电子邮件',
  };
}

class NpcContactRequest {
  const NpcContactRequest({required this.contactIds, required this.channel});

  final List<String> contactIds;
  final NpcContactChannel channel;

  bool get isUnambiguous => contactIds.length == 1;
}

/// Detects an explicit request to exchange contact details in user text.
///
/// It deliberately requires an adding/exchange phrase. A casual mention of
/// “联系” or a platform name alone must not fill the virtual phone with NPCs.
class NpcContactRequestDetector {
  const NpcContactRequestDetector._();

  static NpcContactRequest? detect(
    String input, {
    required Iterable<NpcChatContact> contacts,
    Iterable<String> fallbackContactIds = const [],
  }) {
    final text = _dialogueText(input);
    final requests = _clauses(text)
        .where((clause) => _requestPattern.hasMatch(clause))
        .where((clause) => !_excludedRequest.hasMatch(clause))
        .toList();
    if (requests.isEmpty) return null;
    final channel = _channelFor(requests.join('\n'));
    final ids = <String>[];
    for (final contact in contacts) {
      if (contact.matchesMention(text)) ids.add(contact.id);
    }
    if (ids.isEmpty) {
      final known = contacts.map((contact) => contact.id).toSet();
      ids.addAll(
        fallbackContactIds
            .where(known.contains)
            .where((id) => !ids.contains(id)),
      );
    }
    if (ids.isEmpty) return null;
    return NpcContactRequest(
      contactIds: List<String>.unmodifiable(ids),
      channel: channel,
    );
  }

  static bool looksLikeRefusal(String reply) {
    return _clauses(_dialogueText(reply)).any((clause) {
      final text = _withoutCues(clause).trim();
      return _shortRefusal.hasMatch(text) || _contactRefusal.hasMatch(text);
    });
  }

  /// Only a direct, completed acceptance can offer an add-contact confirmation.
  /// Silence, a generic continuation, or another character's consent is not
  /// enough. The caller still asks the user before changing their contact list.
  static bool looksLikeAgreement(String reply) {
    final text = _dialogueText(reply);
    if (text.isEmpty || looksLikeRefusal(text)) return false;
    final clauses = _clauses(text).map(_withoutCues).toList();
    if (clauses.any(_hesitation.hasMatch)) return false;
    return clauses.any((clause) {
      final trimmed = clause.trim();
      return !_reportedAgreement.hasMatch(trimmed) &&
          (_directAgreement.hasMatch(trimmed) ||
              _contactAgreement.hasMatch(trimmed));
    });
  }

  static List<String> acceptedContactIds(
    String reply,
    NpcContactRequest request, {
    required String primaryCharacterId,
    Iterable<NpcChatContact> contacts = const [],
  }) {
    final speech = <String, List<String>>{};
    for (final segment in parseAssistantSegments(
      _normalizeContactSpeakers(reply, contacts),
      defaultPrimaryCharacterId: primaryCharacterId,
    )) {
      final id = segment.speaker == ChatSpeaker.character
          ? segment.characterId
          : segment.speaker == ChatSpeaker.ryza
          ? segment.primaryCharacterId
          : null;
      if (id == null || !request.contactIds.contains(id)) continue;
      speech.putIfAbsent(id, () => []).add(segment.text);
    }
    return List<String>.unmodifiable(
      request.contactIds.where(
        (id) => looksLikeAgreement(speech[id]?.join('\n') ?? ''),
      ),
    );
  }

  /// The same speaker resolution is used when a follow-up request says "you"
  /// rather than repeating an NPC's name. Only unambiguous catalog identities
  /// count, never names mentioned inside narration or translation.
  static List<String> speakingContactIds(
    String reply, {
    required Iterable<NpcChatContact> contacts,
    required String primaryCharacterId,
  }) {
    final known = contacts.map((contact) => contact.id).toSet();
    return List<String>.unmodifiable({
      for (final segment in parseAssistantSegments(
        _normalizeContactSpeakers(reply, contacts),
        defaultPrimaryCharacterId: primaryCharacterId,
      ))
        if (segment.speaker == ChatSpeaker.character &&
            known.contains(segment.characterId))
          segment.characterId!,
    });
  }

  static String _normalizeContactSpeakers(
    String reply,
    Iterable<NpcChatContact> contacts,
  ) {
    // Filter private model output before looking for speaker names. In
    // particular, a hidden name prefix must not rescue consent from <think>.
    final visible = filterAssistantControlMarkup(reply);
    final catalog = contacts.toList(growable: false);
    var translating = false;
    return visible
        .split('\n')
        .map((line) {
          final canonical = _canonicalSpeaker.firstMatch(line)?.group(1);
          if (canonical != null) {
            translating = RegExp(
              r'^(?:译文|translation)$',
              caseSensitive: false,
            ).hasMatch(canonical);
          }
          // A translation can contain a copied NPC name or speaker marker.
          // Never promote those continuation lines into original speech.
          if (translating) return '';
          final prefix = _namedSpeaker.firstMatch(line);
          if (prefix == null) return line;
          final label = (prefix.group(1) ?? prefix.group(2)!)
              .trim()
              .toLowerCase();
          final matches = catalog
              .where(
                (contact) => contact.aliases.any(
                  (alias) => alias.toLowerCase() == label,
                ),
              )
              .toList(growable: false);
          if (matches.length != 1) return line;
          return '角色[${matches.single.id}]：${line.substring(prefix.end)}';
        })
        .join('\n');
  }

  static final _namedSpeaker = RegExp(
    r'^\s*(?:\*\*|__)?(?:角色\s*\[\s*([^\]\r\n]+?)\s*\]|([^：:\r\n]{1,80}?))(?:\*\*|__)?\s*[：:]\s*(?:\*\*|__)?',
  );
  static final _canonicalSpeaker = RegExp(
    r'^\s*(旁白|莱莎|苏菲|ソフィー|译文|narrator|ryza|sophie|translation|角色\s*\[[^\]\r\n]+\])\s*[：:]',
    caseSensitive: false,
  );

  static const _contactObject =
      r'(?:好友|朋友|联系人|联系方式|联络方式|联络|私信|微信|电报|短信|邮箱|邮件|連絡先|友達|交換|追加|\b(?:friend|contacts?|wechat|weixin|wx|qq|sms|line|discord|telegram|email|mail)\b)';

  static final _requestPattern = RegExp(
    '(?:添加|加上|加入|加个|加我|加你|加为|加一下|互加|加|交换|留下|留个|互留|获取|给我|给你|要个).{0,10}$_contactObject|'
    '$_contactObject.{0,8}(?:交换|添加|加我|加你|给我|给你)|'
    r'\b(?:add|exchange|share|give|contact)\b.{0,20}'
    '$_contactObject|'
    r'(?:連絡先|LINE|QQ).{0,8}(?:交換|教えて|追加)|(?:交換|追加).{0,8}(?:連絡先|LINE|QQ)',
    caseSensitive: false,
  );

  static final _excludedRequest = RegExp(
    r'不要|不用|无需|无须|别(?:再|给我|给你|替我|帮我)?(?:加|添加|交换|留)|别给|不想|不愿|不需要|不打算|(?:我|你|她|他|现在|暂时|仍然|还|先)(?:不可以|不能|不可|不加)|没有(?:问|说|要求)|没(?:问|说|要求)|如果|假如|假设|假定|要是|昨天|之前|以前|曾经|已经|问过|说过|加过|已加|加了|想象|示例|例子|是什么意思|怎么说|\b(?:do\s+not|don[\x27’]t|not\s+(?:add|share|exchange|give)|never|already|yesterday|previously|before|suppose|imagine|example|if)\b',
    caseSensitive: false,
  );

  static final _shortRefusal = RegExp(
    r'^(?:(?:抱歉|对不起|不好意思|sorry)[\s，,:：]*)?(?:不行|不可以|不能|不方便|不太方便|不愿意|不要|不了|算了|拒绝|无理|無理|嫌だ|できない|できません)(?:[啊呀哦呢吧です]*[。.!！?？]?)$|^(?:no|nope|not\s+now|i\s+(?:cannot|can\s+not|can[\x27’]t|won[\x27’]t))(?:[。.!！?？]?)$',
    caseSensitive: false,
  );
  // Japanese negative polite forms ending in 「ませんか」 are invitations.
  // 「ませんから」 still states a refusal, so exclude only an actual question
  // ending rather than every occurrence of the syllable 「か」.
  static const _japaneseRefusal =
      r'(?:教えられない|教えない|教えたくない|教えません(?!か(?:ね|しら)?(?:$|[\s、]))|渡せない|交換できない|交換しない|交換したくない|交換しません(?!か(?:ね|しら)?(?:$|[\s、]))|追加しない|追加しません(?!か(?:ね|しら)?(?:$|[\s、]))|お断り)';
  static final _contactRefusal = RegExp(
    '(?:不(?:能|可以|方便|愿意|想|加|留|告诉|提供)|拒绝|别加|不要加|无需添加|不给|不交换|不添加|$_japaneseRefusal).{0,20}$_contactObject|'
    '$_contactObject.{0,20}(?:不(?:能|可以|方便|愿意|想|加|留|告诉|提供)|不给|不交换|不添加|拒绝|$_japaneseRefusal)|'
    r'\b(?:cannot|can\s+not|can[\x27’]t|won[\x27’]t|will\s+not|do\s+not|don[\x27’]t|not\s+(?:share|exchange|add|give)|refuse|decline)\b.{0,30}'
    '$_contactObject|'
    '$_contactObject.{0,30}'
    r'\b(?:cannot|can\s+not|can[\x27’]t|won[\x27’]t|will\s+not|refuse|decline)\b',
    caseSensitive: false,
  );
  static final _directAgreement = RegExp(
    r'^(?:(?:うん|ええ)[、,\s]+)?(?:当然可以|当然没问题|当然好|当然|可以的|可以呀|可以啊|可以哦|可以|好呀|好啊|好的|好哦|好|没问题|没有问题|行啊|行呀|乐意|愿意|同意|いいわよ|いいわ|いいよ|いいですよ|いいです|いいとも|いいね|もちろん(?:いいわよ|いいわ|いいよ|いいですよ)?|はい|喜んで|よろこんで|構わない|かまわない|大丈夫|了解です)[呀啊哦啦哟]?(?:$|[\s，,:：。.!！?？~～、]|加|给|交換|追加)|^\b(?:yes|yeah|yep|sure|absolutely|certainly|of\s+course|no\s+problem|okay|ok)\b',
    caseSensitive: false,
  );
  static final _contactAgreement = RegExp(
    '(?:可以|同意|愿意|乐意|没问题|当然|给你|这是我的|这就是我的|加我|加你|加上|加吧|加进|交换吧).{0,20}$_contactObject|'
    '$_contactObject.{0,20}(?:给你|发给你|没问题|可以加|加吧|交換しよう|交換しましょう|教える|教えます|追加して|追加しよう)|'
    '$_contactObject.{0,20}'
    r'交換しませんか(?:ね|しら)?(?=$|[\s、])|'
    r'\b(?:let[\x27’]s|i\s+(?:can|will|would\s+love\s+to)|you\s+can|here\s+is\s+my|here[\x27’]s\s+my)\b.{0,30}'
    '$_contactObject',
    caseSensitive: false,
  );
  static final _hesitation = RegExp(
    r'考虑一下|再考虑|再说|以后再|先等等|还没决定|尚未决定|不确定|也许|可能吧|看情况|不知道|わからない|分からない|考えさせて|また今度|まだ決め|\b(?:maybe|perhaps|not\s+sure|not\s+ready|not\s+comfortable|undecided|later|let\s+me\s+think|need\s+to\s+think)\b',
    caseSensitive: false,
  );
  static final _reportedAgreement = RegExp(
    r'(?:她|他|别人|对方|朋友).{0,4}(?:说|同意|愿意)|听说|据说|\b(?:he|she|they)\s+(?:said|says|agreed|agrees)\b',
    caseSensitive: false,
  );
  static Iterable<String> _clauses(String text) => text
      .split(RegExp(r'[，,。.!！?？;；\n]+'))
      .where((part) => part.trim().isNotEmpty);

  static String _withoutQuotes(String text) => text.replaceAll(
    RegExp(r'“[^”]*”|‘[^’]*’|「[^」]*」|『[^』]*』|"[^"\r\n]*"'),
    '',
  );

  static String _dialogueText(String text) {
    var trimmed = text.trim();
    // A whole NPC line commonly uses Japanese dialogue brackets. Preserve its
    // own words while ignoring quotations embedded in a report or an example.
    for (final (open, close) in const [
      ('「', '」'),
      ('『', '』'),
      ('“', '”'),
      ('‘', '’'),
      ('"', '"'),
      ("'", "'"),
    ]) {
      if (trimmed.length >= 2 &&
          trimmed.startsWith(open) &&
          trimmed.endsWith(close)) {
        trimmed = trimmed.substring(1, trimmed.length - 1).trim();
        break;
      }
    }
    return _withoutQuotes(trimmed).trim();
  }

  static String _withoutCues(String text) =>
      text.replaceAll(RegExp(r'\[[^\]\r\n]*\]'), '').trim();

  static bool _latinWord(String text, String word) =>
      RegExp('\\b(?:$word)\\b', caseSensitive: false).hasMatch(text);

  static NpcContactChannel _channelFor(String text) {
    if (text.contains('微信') || _latinWord(text, 'wechat|weixin|wx')) {
      return NpcContactChannel.wechat;
    }
    if (_latinWord(text, 'qq')) {
      return NpcContactChannel.qq;
    }
    if (text.contains('短信') || _latinWord(text, 'sms')) {
      return NpcContactChannel.sms;
    }
    if (_latinWord(text, 'line')) return NpcContactChannel.line;
    if (_latinWord(text, 'discord')) return NpcContactChannel.discord;
    if (_latinWord(text, 'telegram') || text.contains('电报')) {
      return NpcContactChannel.telegram;
    }
    if (text.contains('邮箱') ||
        text.contains('邮件') ||
        _latinWord(text, 'email|mail')) {
      return NpcContactChannel.email;
    }
    return NpcContactChannel.generic;
  }
}
