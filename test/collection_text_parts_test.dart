import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/collection_text_parts.dart';

void main() {
  test('audio replaces original speech in place, keeping narration and translation', () {
    const text = '她笑了。\nこんにちは。\n你好。\nまたね。\n再见。\n她挥挥手。';
    final parts = collectionTextParts(text, [
      {'text': 'こんにちは。', 'audioIndex': 0},
      {'text': 'またね。', 'audioIndex': 1},
    ], 2);
    expect(parts.map((p) => p.text).join(), text);
    expect(parts.where((p) => p.audioIndex != null).map((p) => p.text), [
      'こんにちは。',
      'またね。',
    ]);
  });
  test('whitespace and repeated dialogue preserve original order', () {
    const text = 'Hi there.\n你好\nHi there.';
    final parts = collectionTextParts(text, [
      {'text': 'Hi\nthere.', 'audioIndex': 1},
      {'text': 'Hi there.', 'audioIndex': 0},
    ], 2);
    expect(parts.map((p) => p.text).join(), text);
    expect(parts.where((p) => p.audioIndex != null).map((p) => p.audioIndex), [
      1,
      0,
    ]);
  });
  test('missing or invalid mapping keeps text without duplicate fallback', () {
    final parts = collectionTextParts('Original', [
      {'text': 'Other', 'audioIndex': 0},
      {'text': 'Original', 'audioIndex': 9},
    ], 1);
    expect(parts.single.text, 'Original');
    expect(parts.single.audioIndex, isNull);
  });
}
