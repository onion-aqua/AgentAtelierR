import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/conversation_collection_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ConversationCollectionStore store;
  late File audio;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('collection-test-');
    store = ConversationCollectionStore(Directory('${root.path}/collections'));
    audio = await File('${root.path}/source.wav').writeAsBytes([1, 2, 3, 4]);
  });
  tearDown(() async => root.delete(recursive: true));
  test(
    'speech mappings survive collection, export and cache eviction',
    () async {
      await store.cacheVoice(
        'mapped',
        [audio.path, audio.path],
        texts: ['第一段', '第二段'],
      );
      final mapped = await store.voiceSegments('mapped');
      expect(mapped.map((s) => s.text), ['第一段', '第二段']);
      await store.collect([
        {
          'key': 'mapped',
          'text': '第一段\n第二段',
          'isUser': false,
          'saveText': true,
          'saveVoice': true,
        },
      ]);
      final card = (await store.cards()).single;
      expect((card['items'] as List).single['speech'], [
        {'text': '第一段', 'audioIndex': 0},
        {'text': '第二段', 'audioIndex': 1},
      ]);
      final archive = ZipDecoder().decodeBytes(
        await store.export(card['id'] as String),
      );
      final exported = jsonDecode(
        utf8.decode(archive.findFile('collection.json')!.content),
      );
      expect(exported['items'][0]['speech'][1]['audioIndex'], 1);
      await store.cacheVoice('legacy', [audio.path]);
      expect(await store.voiceSegments('legacy'), isEmpty);
    },
  );

  Map<String, dynamic> selection(
    String key, {
    bool text = true,
    bool voice = true,
  }) => {
    'key': key,
    'text': '收藏文本',
    'isUser': false,
    'saveText': text,
    'saveVoice': voice,
  };

  test(
    '50-reply cache eviction cannot delete collected audio; export is portable',
    () async {
      await store.cacheVoice('first', [audio.path, audio.path]);
      await store.collect([selection('first')]);
      for (var i = 0; i < 50; i++) {
        await store.cacheVoice('reply-$i', [audio.path]);
      }
      expect(await store.availableVoiceKeys(), hasLength(50));
      expect(await store.availableVoiceKeys(), isNot(contains('first')));
      final card = (await store.cards()).single;
      for (final relative in card['audio'] as List) {
        expect(await File(store.path(relative as String)).readAsBytes(), [
          1,
          2,
          3,
          4,
        ]);
      }
      await store.rename(card['id'] as String, ' 新收藏 ');
      store = ConversationCollectionStore(store.directory);
      expect((await store.cards()).single['name'], '新收藏');
      final zip = ZipDecoder().decodeBytes(
        await store.export(card['id'] as String),
      );
      expect(utf8.decode(zip.findFile('conversation.txt')!.content), '收藏文本');
      expect(zip.files.where((f) => f.name.endsWith('.wav')), hasLength(2));
      final data = jsonDecode(
        utf8.decode(zip.findFile('collection.json')!.content),
      );
      expect(data['items'][0]['audioIndexes'], [0, 1]);
      await store.delete(card['id'] as String);
      expect(await store.cards(), isEmpty);
      expect(
        await File(store.path((card['audio'] as List).first as String))
            .exists(),
        isFalse,
      );
      expect(await store.availableVoiceKeys(), hasLength(50));
    },
  );

  test(
    'text-only and voice-only selection, errors do not partially save',
    () async {
      await store.cacheVoice('voice', [audio.path]);
      await store.collect([
        selection('none', voice: false),
        selection('voice', text: false),
      ]);
      final items = (await store.cards()).single['items'] as List;
      expect(items[0]['audioIndexes'], isEmpty);
      expect(items[1]['text'], '');
      expect(items[1]['audioIndexes'], [0]);
      await expectLater(
        store.collect([selection('expired')]),
        throwsStateError,
      );
      expect(await store.cards(), hasLength(1));
      await store.collect([]);
      expect(await store.cards(), hasLength(1));
      expect(() => store.path('../escape.wav'), throwsFormatException);
    },
  );

  test('message identity survives translation, serialization and saves; collections stay independent', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.addAssistantMessage('你好');
    final message = controller.messages.last;
    expect(message.id, isNotEmpty);
    expect(
      message.copyWith(translatedText: 'Hello').collectionKey,
      message.collectionKey,
    );
    expect(
      ChatMessage.fromJson(message.toJson()).collectionKey,
      message.collectionKey,
    );
    await controller.saveToLocalSlot(0);
    await store.collect([selection('text', voice: false)]);
    final before = await store.cards();
    controller.clearChatHistory();
    await controller.loadFromLocalSlot(0);
    expect(controller.messages.last.collectionKey, message.collectionKey);
    expect(await store.cards(), before);
    expect(
      jsonEncode(controller.exportLocalSlot(0)),
      isNot(contains('favorite_')),
    );
    controller.dispose();
  });
}
