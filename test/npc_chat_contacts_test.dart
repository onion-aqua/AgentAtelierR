import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_catalog.dart';
import 'package:ryza_chat_mvp/src/npc_chat_contacts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CharacterCatalog catalog;
  setUpAll(() async => catalog = await CharacterCatalog.load());

  test(
    'Ryza includes every catalog NPC and retains complete persona and aliases',
    () {
      final contacts = npcChatContactsFor('ryza', catalog);
      expect(contacts.length, catalog.allProfiles.length - 1);
      expect(
        contacts.map((contact) => contact.id).toSet().length,
        contacts.length,
      );
      expect(contacts.any((contact) => contact.id == 'ryza'), isFalse);
      final klaudia = contacts.singleWhere(
        (contact) => contact.id == 'claudia',
      );
      expect(klaudia.persona, contains('【人物关系】'));
      expect(
        klaudia.persona,
        contains(catalog.profile('claudia')!.systemPrompt),
      );
      expect(klaudia.persona, contains('日语台词固定使用「ライザ」'));
      expect(klaudia.matchesMention('科洛蒂亚刚才告诉我一件事'), isTrue);
      expect(klaudia.matchesMention('科洛蒂娅说过的话'), isTrue);
      expect(klaudia.matchesMention('KLAUDIA promised to help'), isTrue);
      expect(klaudia.matchesMention('问问クラウディア'), isTrue);
      expect(() => contacts.clear(), throwsUnsupportedError);
      expect(() => catalog.allProfiles.clear(), throwsUnsupportedError);
      expect(
        () => catalog.profile('claudia')!.aliases.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test('Latin aliases only match complete names rather than substrings', () {
    final lent = npcChatContactsFor(
      'ryza',
      catalog,
    ).singleWhere((contact) => contact.id == 'lent');
    expect(lent.matchesMention('What did Lent say?'), isTrue);
    expect(lent.matchesMention('They are talented adventurers'), isFalse);
  });

  test(
    'Sophie contacts use independent identities and no Ryza avatar resources',
    () {
      final contacts = npcChatContactsFor('sophie', catalog);
      expect(contacts.length, 10);
      expect(
        contacts.every((contact) => contact.id.startsWith('sophie_')),
        isTrue,
      );
      expect(contacts.every((contact) => contact.avatarAsset == null), isTrue);
      expect(contacts.any((contact) => contact.id == 'claudia'), isFalse);
      expect(npcChatContactsFor('unknown', catalog), isEmpty);
      expect(npcChatContactsFor('sophie', CharacterCatalog.empty()).length, 10);
    },
  );

  test('two Plachta contacts keep their canonical roles and qualified mentions separate', () {
    final contacts = npcChatContactsFor('sophie', catalog);
    final doll = contacts.singleWhere(
      (contact) => contact.id == 'sophie_plachta_doll',
    );
    final young = contacts.singleWhere(
      (contact) => contact.id == 'sophie_plachta_young',
    );
    expect(doll.names.chinese, isNot(young.names.chinese));
    expect(doll.persona, contains('师长与旅行搭档'));
    expect(young.persona, contains('初见时并不认识苏菲'));
    expect(doll.matchesMention('人偶普拉芙妲告诉我的'), isTrue);
    expect(young.matchesMention('人偶普拉芙妲告诉我的'), isFalse);
    expect(young.matchesMention('Plachta (Young) said this'), isTrue);
    expect(doll.matchesMention('Plachta (Young) said this'), isFalse);
    expect(doll.matchesMention('普拉芙妲说过什么？'), isTrue);
    expect(young.matchesMention('普拉芙妲说过什么？'), isTrue);
  });
}
