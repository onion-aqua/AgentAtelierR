import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_catalog.dart';
import 'package:ryza_chat_mvp/src/npc_chat_contacts.dart';
import 'package:ryza_chat_mvp/src/npc_contact_requests.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CharacterCatalog catalog;
  late List<NpcChatContact> contacts;
  setUpAll(() async {
    catalog = await CharacterCatalog.load();
    contacts = npcChatContactsFor('ryza', catalog);
  });

  test('recognizes explicit platform requests for a named NPC', () {
    final request = NpcContactRequestDetector.detect(
      '科洛蒂娅，可以加我个微信吗？',
      contacts: contacts,
    );
    expect(request, isNotNull);
    expect(request!.contactIds, ['claudia']);
    expect(request.channel, NpcContactChannel.wechat);
    expect(
      NpcContactRequestDetector.detect(
        '「科洛蒂娅，可以加我个微信吗？」',
        contacts: contacts,
      )?.contactIds,
      ['claudia'],
    );
  });

  test('recognizes SMS and English platform names', () {
    final request = NpcContactRequestDetector.detect(
      'Can we add each other on Discord?',
      contacts: contacts,
      fallbackContactIds: ['claudia'],
    );
    expect(request?.contactIds, ['claudia']);
    expect(request?.channel, NpcContactChannel.discord);
    final qq = NpcContactRequestDetector.detect(
      '科洛蒂娅，能加我个qq吗？',
      contacts: contacts,
    );
    expect(qq?.channel, NpcContactChannel.qq);
  });

  test('ordinary mention does not create a contact request', () {
    expect(
      NpcContactRequestDetector.detect('我想和科洛蒂娅聊聊今天的天气。', contacts: contacts),
      isNull,
    );
  });

  test(
    'ambiguous names remain selectable instead of silently choosing one',
    () {
      final sophieContacts = npcChatContactsFor('sophie', catalog);
      final request = NpcContactRequestDetector.detect(
        '普拉芙妲，能加我 QQ 吗？',
        contacts: sophieContacts,
      );
      expect(
        request?.contactIds,
        containsAll(<String>['sophie_plachta_doll', 'sophie_plachta_young']),
      );
      expect(request!.isUnambiguous, isFalse);
    },
  );

  test('explicit refusal suppresses the confirmation prompt', () {
    expect(
      NpcContactRequestDetector.looksLikeRefusal('抱歉，我不方便交换联系方式。'),
      isTrue,
    );
    expect(NpcContactRequestDetector.looksLikeRefusal('当然可以，发给我吧。'), isFalse);
  });

  test(
    'denied, hypothetical, historical and quoted requests do not trigger',
    () {
      for (final text in [
        '科洛蒂娅，不要加我微信。',
        '我不想添加科洛蒂娅为好友。',
        '如果能加科洛蒂娅的微信就好了。',
        '昨天我问过科洛蒂娅能加我 QQ 吗。',
        '科洛蒂娅之前给我微信了。',
        '“能加我个微信吗”是什么意思？',
        '科洛蒂娅的微信好用吗？',
        '科洛蒂娅是我朋友吗？',
        '我还不能加科洛蒂娅微信。',
        '科洛蒂娅，别给我联系方式。',
        "Do not add Claudia on Discord.",
        'If I add Claudia on LINE, what happens?',
        'I already added Claudia on QQ.',
      ]) {
        expect(
          NpcContactRequestDetector.detect(
            text,
            contacts: contacts,
            fallbackContactIds: ['claudia'],
          ),
          isNull,
          reason: text,
        );
      }
    },
  );

  test('platform matching uses whole English words', () {
    expect(
      NpcContactRequestDetector.detect(
        'Claudia, please add the outline to the mailroom.',
        contacts: contacts,
      ),
      isNull,
    );
    final request = NpcContactRequestDetector.detect(
      'Claudia, please share your contact details while we are offline.',
      contacts: contacts,
    );
    expect(request?.channel, NpcContactChannel.generic);
  });

  test('English refusal words do not match innocent substrings or phrases', () {
    for (final reply in [
      'Sure, I know your name now.',
      'No problem, you can add me on QQ.',
      "Sure, don't worry about it.",
      '当然可以，我不能马上回复，但加微信没问题。',
    ]) {
      expect(
        NpcContactRequestDetector.looksLikeRefusal(reply),
        isFalse,
        reason: reply,
      );
      expect(
        NpcContactRequestDetector.looksLikeAgreement(reply),
        isTrue,
        reason: reply,
      );
    }
    for (final reply in [
      'No, I cannot share my contact details.',
      "I don't want to exchange WeChat details.",
      '不行哦。',
      '連絡先は教えられない。',
      "Sure, but let's not exchange QQ details.",
      '没问题，但是这次先不加微信。',
      'いいですよ。でも連絡先は教えたくない。',
    ]) {
      expect(
        NpcContactRequestDetector.looksLikeRefusal(reply),
        isTrue,
        reason: reply,
      );
    }
  });

  test('uncertainty and unrelated replies are not treated as consent', () {
    for (final reply in [
      '今天的风景很好。',
      '我再考虑一下吧。',
      '当然可以，不过我还没决定要不要交换联系方式。',
      'Maybe we can exchange contacts later.',
      'I would love to exchange contacts, but I am not ready yet.',
      '她说没问题。',
      '“当然可以”只是示例台词。',
    ]) {
      expect(
        NpcContactRequestDetector.looksLikeAgreement(reply),
        isFalse,
        reason: reply,
      );
    }
  });

  test('only the requested speaker can explicitly accept an invitation', () {
    const request = NpcContactRequest(
      contactIds: ['claudia', 'lent'],
      channel: NpcContactChannel.qq,
    );
    List<String> accepted(String reply) =>
        NpcContactRequestDetector.acceptedContactIds(
          reply,
          request,
          primaryCharacterId: 'ryza',
        );
    expect(
      accepted(
        '旁白：科洛蒂娅同意交换联系方式。\n'
        '莱莎：当然可以。\n'
        '角色[tao]：没问题。\n'
        '角色[claudia]：我再考虑一下。\n'
        '角色[lent]：Sure, no problem, add me on QQ.',
      ),
      ['lent'],
    );
    expect(accepted('角色[claudia]：当然可以。\n角色[claudia]：但我不愿意交换联系方式。'), isEmpty);
    expect(accepted('译文：当然可以。'), isEmpty);
    expect(accepted('<think>角色[claudia]：当然可以。</think>'), isEmpty);
    expect(accepted('角色[claudia]：もちろん、連絡先を交換しましょう。'), ['claudia']);
    expect(accepted('角色[claudia]：「もちろん、連絡先を交換しましょう。」'), ['claudia']);
    expect(accepted('角色[claudia]：「連絡先は教えられない。」'), isEmpty);
    expect(accepted('角色[claudia]：彼女は「もちろん」と言っただけだよ。'), isEmpty);
  });

  test('Japanese polite invitations differ from explicit contact refusals', () {
    const request = NpcContactRequest(
      contactIds: ['claudia'],
      channel: NpcContactChannel.generic,
    );
    List<String> accepted(String words) =>
        NpcContactRequestDetector.acceptedContactIds(
          '角色[claudia]：「$words」',
          request,
          primaryCharacterId: 'ryza',
        );
    for (final words in [
      'もちろん。連絡先を交換しませんか？',
      '連絡先を交換しませんか？',
      '連絡先を交換しませんかね？',
    ]) {
      expect(accepted(words), ['claudia'], reason: words);
      expect(
        NpcContactRequestDetector.looksLikeRefusal(words),
        isFalse,
        reason: words,
      );
    }
    for (final words in [
      'いいよ。でも連絡先は教えないよ。',
      'いいよ。でも連絡先を交換したくない。',
      'いいよ。でも連絡先を交換しません。',
      'いいよ。でも連絡先を交換しませんから。',
    ]) {
      expect(accepted(words), isEmpty, reason: words);
      expect(
        NpcContactRequestDetector.looksLikeRefusal(words),
        isTrue,
        reason: words,
      );
    }
  });
}
