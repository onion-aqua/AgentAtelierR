import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/rag_memory_archive.dart';
import 'package:ryza_chat_mvp/src/rag_memory_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory support;
  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('rag-archive-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async => support.path);
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await support.delete(recursive: true);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppController> create({RagMemoryRuntime? runtime}) async {
    final controller = await AppController.load(
      ragRuntime:
          runtime ??
          RagMemoryRuntime(
            embed: (texts) async => texts.map((_) => <double>[1, 0]).toList(),
          ),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  void turn(AppController controller, String user, String assistant) {
    controller.addUserMessage(user);
    controller.addAssistantMessage(assistant);
  }

  test(
    'archive roundtrip retains full text, ownership and withdrawn sources',
    () {
      var archive = RagMemoryArchive(characterId: 'ryza');
      archive = archive.put(
        turnId: 'u1',
        messageId: 'a1',
        user: '紫色围巾',
        assistant: '明天一起带上紫色围巾。',
      );
      archive = archive.put(
        turnId: 'u2',
        messageId: 'a2',
        user: '第二轮',
        assistant: '好的。',
      );
      archive = archive.withoutTurn('u1');
      final restored = RagMemoryArchive.fromJson(
        jsonDecode(jsonEncode(archive.toJson())),
        characterId: 'ryza',
      );
      expect(restored.turns.single.messageId, 'a2');
      expect(restored.withdrawnMessageIds, contains('a1'));
      expect(
        restored.put(
          turnId: 'u1',
          messageId: 'a1',
          user: '紫色围巾',
          assistant: '过期结果',
        ),
        same(restored),
      );
      expect(
        () =>
            RagMemoryArchive.fromJson(archive.toJson(), characterId: 'sophie'),
        throwsFormatException,
      );
    },
  );

  test(
    'only completely empty foreign archive templates can migrate ownership',
    () {
      final empty = RagMemoryArchive(characterId: 'ryza');
      expect(
        RagMemoryArchive.fromJson(
          empty.toJson(),
          characterId: 'sophie',
        ).characterId,
        'sophie',
      );
      final withdrawn = empty.withoutMessages({'old-assistant'});
      expect(
        () => RagMemoryArchive.fromJson(
          withdrawn.toJson(),
          characterId: 'sophie',
        ),
        throwsFormatException,
      );
      final nonEmpty = empty.put(
        turnId: 'u1',
        messageId: 'a1',
        user: '密语',
        assistant: '只告诉莱莎',
      );
      expect(
        () =>
            RagMemoryArchive.fromJson(nonEmpty.toJson(), characterId: 'sophie'),
        throwsFormatException,
      );
    },
  );

  test(
    'more than sixty visible messages keep every completed archived turn',
    () async {
      final controller = await create();
      for (var index = 0; index < 50; index++) {
        turn(controller, '第$index轮，蓝铜矿编号$index', '莱莎：记下编号$index。');
      }
      expect(controller.messages.length, lessThanOrEqualTo(60));
      expect(controller.ragArchiveTurnCount, 50);
      final exported = controller.exportData()['ragMemoryArchive'] as Map;
      expect((exported['turns'] as List).first['user'], contains('第0轮'));
      expect(
        controller.ragMemoryPromptForCurrentConversation('第0轮的蓝铜矿编号'),
        contains('第0轮'),
      );
    },
  );

  test(
    'stream only archives when complete and never archives a failed reply',
    () async {
      final controller = await create();
      controller.addUserMessage('秘密颜色是青碧色');
      controller.beginAssistantStream();
      controller.appendAssistantDelta('莱莎：青碧色');
      expect(controller.ragArchiveTurnCount, 0);
      controller.failAssistantStream('offline');
      controller.finishAssistantStream(recordMemory: true);
      expect(controller.ragArchiveTurnCount, 0);
      controller.addUserMessage('重要日期是四月七号');
      controller.beginAssistantStream();
      controller.appendAssistantDelta('莱莎：我记住四月七号了。');
      controller.finishAssistantStream(recordMemory: true);
      expect(controller.ragArchiveTurnCount, 1);
    },
  );

  test('undo removes raw evidence and source-owned ledger facts', () async {
    final controller = await create();
    turn(controller, '我们约好明天一起去黑曜洞窟', '莱莎：答应你，明天一起去黑曜洞窟。');
    controller.recordDeterministicMemoryForLastTurn();
    expect(
      controller.ragMemoryPromptForCurrentConversation('黑曜洞窟'),
      contains('黑曜洞窟'),
    );
    controller.undoLastUserTurn();
    expect(controller.ragArchiveTurnCount, 0);
    expect(
      controller.ragMemoryPromptForCurrentConversation('黑曜洞窟'),
      isNot(contains('黑曜洞窟')),
    );
    expect(
      controller.memoryPromptForCurrentConversation(currentInput: '黑曜洞窟'),
      isNot(contains('黑曜洞窟')),
    );
  });

  test(
    'older save, new save and portable backup own independent source histories',
    () async {
      final controller = await create();
      turn(controller, '暗号是月银风铃', '莱莎：月银风铃，记住了。');
      await controller.saveToLocalSlot(0);
      final backup = jsonDecode(
        jsonEncode(controller.exportData()),
      ) as Map<String, dynamic>;
      turn(controller, '另一暗号是赤金水晶', '莱莎：赤金水晶。');
      expect(controller.ragArchiveTurnCount, 2);
      await controller.loadFromLocalSlot(0);
      expect(controller.ragArchiveTurnCount, 1);
      expect(
        controller.ragMemoryPromptForCurrentConversation('赤金水晶'),
        isNot(contains('赤金水晶')),
      );
      await controller.createLocalSlot(1);
      await controller.loadFromLocalSlot(1);
      expect(controller.ragArchiveTurnCount, 0);
      final imported = await create();
      await imported.importData(backup);
      expect(imported.ragArchiveTurnCount, 1);
      expect(
        imported.ragMemoryPromptForCurrentConversation('月银风铃'),
        contains('月银风铃'),
      );
    },
  );

  test(
    'characters and NPC private prompts do not share main archive evidence',
    () async {
      final controller = await create();
      turn(controller, '秘密码是翡翠星辰', '莱莎：翡翠星辰。');
      expect(
        controller.buildNpcMessagePrompt('claudia', currentInput: '翡翠星辰'),
        isNot(contains('用户原话：秘密码是翡翠星辰')),
      );
      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      expect(controller.ragArchiveTurnCount, 0);
      expect(controller.ragMemoryPromptForCurrentConversation('翡翠星辰'), isEmpty);
      turn(controller, '只有苏菲知道银月圆舞曲', 'ソフィー：銀月のワルツだね。');
      await controller.setActiveCharacter(CharacterRuntimeIds.ryza);
      expect(controller.ragArchiveTurnCount, 1);
      expect(
        controller.ragMemoryPromptForCurrentConversation('银月圆舞曲'),
        isNot(contains('只有苏菲知道')),
      );
    },
  );

  test(
    'memory switches stop archiving, indexing and prompt injection',
    () async {
      var embeddingCalls = 0;
      final controller = await create(
        runtime: RagMemoryRuntime(
          embed: (texts) async {
            embeddingCalls++;
            return texts.map((_) => <double>[1, 0]).toList();
          },
        ),
      );
      turn(controller, '宝石叫青空之露', '莱莎：青空之露。');
      controller.setRagMemoryEnabled(false);
      turn(controller, '不应保存银红之花', '莱莎：银红之花。');
      await controller.prepareRagMemory('青空之露');
      expect(embeddingCalls, 0);
      expect(controller.ragArchiveTurnCount, 1);
      expect(controller.ragMemoryLastEvidence, isEmpty);
      expect(controller.ragMemoryPromptForCurrentConversation('青空之露'), isEmpty);
      controller.setRagMemoryEnabled(true);
      controller.setLongTermMemoryEnabled(false);
      await controller.prepareRagMemory('青空之露');
      expect(embeddingCalls, 0);
      expect(controller.ragMemoryStatus, '已关闭');
    },
  );

  test(
    'long Chinese tail facts survive tokenizer-sized overlapping chunks',
    () async {
      final observed = <String>[];
      final controller = await create(
        runtime: RagMemoryRuntime(
          embed: (texts) async {
            observed.addAll(texts);
            return texts.map((_) => <double>[1, 0]).toList();
          },
        ),
      );
      turn(controller, '记住这份旅途记录', '${'沿着河岸慢慢向前走，' * 80}最终找到的矿石叫紫雾金晶。');
      await controller.prepareRagMemory(
        '紫雾金晶',
        timeout: const Duration(seconds: 10),
      );
      expect(observed.any((text) => text.contains('紫雾金晶')), isTrue);
      expect(
        observed.skip(1).every((text) => text.runes.length <= 105),
        isTrue,
      );
      expect(controller.ragMemoryLastEvidence, contains('紫雾金晶'));
    },
  );

  test(
    'an in-flight embedding cannot resurrect deleted or withdrawn evidence',
    () async {
      final pending = Completer<List<List<double>>>();
      final controller = await create(
        runtime: RagMemoryRuntime(embed: (_) => pending.future),
      );
      turn(controller, '最后的暗号是琉璃灯塔', '莱莎：琉璃灯塔。');
      final preparing = controller.prepareRagMemory('琉璃灯塔');
      await Future<void>.delayed(Duration.zero);
      controller.undoLastUserTurn();
      pending.complete([
        [1, 0],
      ]);
      await preparing;
      expect(controller.ragMemoryLastEvidence, isEmpty);
      expect(controller.ragArchiveTurnCount, 0);
      expect(controller.ragMemoryPromptForCurrentConversation('琉璃灯塔'), isEmpty);
    },
  );

  test(
    'manual source memory deletion also forgets its original archived evidence',
    () async {
      final controller = await create();
      turn(controller, '我们约好周末一起去翡翠花园', '莱莎：答应你，周末一起去翡翠花园。');
      controller.recordDeterministicMemoryForLastTurn();
      final document =
          jsonDecode(controller.memorySummary) as Map<String, dynamic>;
      document['entries'] = [];
      controller.updateMemorySummary(jsonEncode(document));
      expect(controller.ragArchiveTurnCount, 0);
      expect(controller.ragMemoryPromptForCurrentConversation('翡翠花园'), isEmpty);
    },
  );
}
