import 'package:flutter_test/flutter_test.dart';

import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';

void main() {
  test('registry contains isolated Ryza and Sophie resource namespaces', () {
    final ryza = characterRuntimeProfileById('ryza');
    final sophie = characterRuntimeProfileById('sophie');

    expect(ryza.id, CharacterRuntimeIds.ryza);
    expect(sophie.id, CharacterRuntimeIds.sophie);
    expect(ryza.resourceNamespace, isNot(sophie.resourceNamespace));
    expect(ryza.renderMode, CharacterRenderMode.protectedSpine);
    expect(ryza.hasSpineResources, isTrue);
    expect(ryza.staticPortraitAsset, contains('/character_switch/ryza.png'));
    expect(
      sophie.staticPortraitAsset,
      'assets/images/characters/sophie_portrait.png',
    );
    expect(sophie.hasSpineResources, isFalse);
    expect(sophie.spineAssetNamespace, contains('sophie'));
  });

  test('unknown and malformed IDs normalize to the stable default', () {
    expect(normalizeCharacterRuntimeId(null), CharacterRuntimeIds.ryza);
    expect(
      normalizeCharacterRuntimeId('  SOPHIE '),
      CharacterRuntimeIds.sophie,
    );
    expect(
      normalizeCharacterRuntimeId('not-a-character'),
      CharacterRuntimeIds.ryza,
    );
  });

  test('profile names are locale aware without changing persistence IDs', () {
    final profile = characterRuntimeProfileById('sophie');

    expect(profile.displayNameFor('zh'), '苏菲');
    expect(profile.displayNameFor('en'), 'Sophie');
    expect(profile.displayNameFor('ja'), 'ソフィー');
    expect(profile.id, CharacterRuntimeIds.sophie);
  });
}
