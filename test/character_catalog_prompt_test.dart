import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_catalog.dart';

void main() {
  test('Klaudia calls Ryza by the short Chinese and Japanese names', () {
    const profile = CharacterProfile(
      id: 'claudia',
      names: CharacterNames(
        chinese: '科洛蒂娅',
        english: 'Claudia',
        japanese: 'クラウディア',
      ),
      avatarFile: 'claudia.png',
      systemPrompt: '【身份与经历】科洛蒂娅。\n【人物关系】莱莎琳·斯托特。',
    );

    expect(profile.encounterPrompt, contains('昵称“莱莎”'));
    expect(profile.encounterPrompt, contains('「ライザ」'));
    expect(profile.encounterPrompt, contains('不得使用“莱莎琳”或「ライザリン」'));
  });

  test('the short-name rule is limited to Klaudia', () {
    const profile = CharacterProfile(
      id: 'patricia',
      names: CharacterNames(
        chinese: '帕特莉夏',
        english: 'Patricia',
        japanese: 'パトリツィア',
      ),
      avatarFile: 'patricia.png',
      systemPrompt: '【身份与经历】帕特莉夏。\n【人物关系】',
    );

    expect(profile.encounterPrompt, isNot(contains('科洛蒂娅称呼规则')));
  });
}
