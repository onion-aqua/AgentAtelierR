import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/conversation_collection_store.dart';

void main() {
  late Directory root;
  late ConversationCollectionStore store;
  late File audio;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('klaudia-voice-test-');
    store = ConversationCollectionStore(Directory('${root.path}/collections'));
    audio = await File('${root.path}/sample.wav').writeAsBytes([1, 2, 3, 4]);
  });
  tearDown(() async => root.delete(recursive: true));

  test('mixed voice cache keeps speaker identity and order', () async {
    await store.cacheVoice(
      'mixed',
      [audio.path, audio.path],
      texts: ['莱莎台词', '科洛蒂娅台词'],
      speakers: [ChatSpeaker.ryza, ChatSpeaker.character],
    );

    final segments = await store.voiceSegments('mixed');
    expect(segments.map((segment) => segment.text), ['莱莎台词', '科洛蒂娅台词']);
    expect(segments.map((segment) => segment.speaker), [
      ChatSpeaker.ryza,
      ChatSpeaker.character,
    ]);
  });

  test('old cache without speaker metadata remains playable as Ryza', () async {
    await store.directory.create(recursive: true);
    await File('${store.directory.path}/voice_cache.json').writeAsString(
      jsonEncode([
        {
          'key': 'old',
          'audio': ['cache_123/0.wav'],
          'texts': ['旧语音'],
        },
      ]),
    );

    final segments = await store.voiceSegments('old');
    expect(segments, hasLength(1));
    expect(segments.single.text, '旧语音');
    expect(segments.single.speaker, ChatSpeaker.ryza);
  });
}
