import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/npc_chat_models.dart';
import 'package:ryza_chat_mvp/src/npc_chat_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StreamingBackend implements NpcReplyBackend {
  final requests = <NpcReplyRequest>[];
  final streams = <StreamController<String>>[];
  final canceled = <int>{};

  @override
  Stream<String> reply(NpcReplyRequest request) {
    final index = streams.length;
    final stream = StreamController<String>(
      onCancel: () => canceled.add(index),
    );
    requests.add(request);
    streams.add(stream);
    return stream.stream;
  }

  Future<void> dispose() async {
    for (final stream in streams) {
      if (!stream.isClosed) await stream.close();
    }
  }
}

class _TranslatingBackend extends _StreamingBackend
    implements NpcReplyTranslationBackend {
  final translations = <Completer<String>>[];
  final translationLanguages = <TranslationLanguage>[];

  @override
  Future<String> translate(
    NpcReplyRequest request,
    String text,
    TranslationLanguage language,
  ) {
    final result = Completer<String>();
    translations.add(result);
    translationLanguages.add(language);
    return result.future;
  }
}

class _CorrectingBackend extends _StreamingBackend
    implements NpcReplyLanguageBackend {
  final corrections = <Completer<String>>[];
  final correctionSources = <String>[];

  @override
  Future<String> correctReplyLanguage(NpcReplyRequest request, String text) {
    correctionSources.add(text);
    final result = Completer<String>();
    corrections.add(result);
    return result.future;
  }
}

class _MemorySecrets extends SecretStore {
  _MemorySecrets(this.value);
  final String value;
  int? slot;
  LlmProvider? provider;

  @override
  Future<String> readLlmKey(LlmProvider provider, {int openAiSlot = 0}) async {
    this.provider = provider;
    slot = openAiSlot;
    return value;
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController controller;
  late _StreamingBackend backend;
  late NpcChatService service;
  late String npcId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    controller = await AppController.load();
    controller.configureAi(
      enabled: true,
      baseUrl: 'https://llm.example.test/v1',
      model: 'gpt-5',
    );
    backend = _StreamingBackend();
    service = NpcChatService(controller: controller, backend: backend);
    npcId = controller.npcChatContacts.first.id;
    for (final contact in controller.npcChatContacts) {
      controller.addNpcContact(contact.id);
    }
  });

  tearDown(() async {
    service.dispose();
    await backend.dispose();
    controller.dispose();
    await _flush();
  });

  test(
    'streams visible replies while only terminal assistant text is persisted',
    () async {
      var notices = 0;
      service.addListener(() => notices++);
      final pending = service.send(npcId, '你好，请记得苹果的约定');
      expect(service.isSending(npcId), true);
      expect(
        controller.npcChats.threadFor(npcId).messages.single.role,
        NpcChatRole.user,
      );
      backend.streams.single.add('<thi');
      await _flush();
      expect(service.liveReply(npcId), isEmpty);
      backend.streams.single.add(
        'nk>secret internal thought</think><answer>约定好',
      );
      await _flush();
      expect(service.liveReply(npcId), '约定好');
      expect(controller.npcChats.threadFor(npcId).messages.length, 1);
      for (var i = 0; i < 50; i++) {
        backend.streams.single.add('！');
      }
      await _flush();
      expect(notices, 1);
      backend.streams.single.add(
        '</answer><tool_call>private tool</tool_call>',
      );
      await backend.streams.single.close();
      await pending;
      expect(service.isSending(npcId), false);
      expect(service.liveReply(npcId), isEmpty);
      final messages = controller.npcChats.threadFor(npcId).messages;
      expect(messages.length, 2);
      expect(messages.last.status, NpcChatStatus.completed);
      expect(messages.last.text, '约定好${List.filled(50, '！').join()}');
      expect(
        jsonEncode(controller.exportData()['npcChats']),
        isNot(contains('secret')),
      );
      expect(notices, 2);
    },
  );

  test(
    'prevents duplicate sends to one NPC while other NPCs run independently',
    () async {
      final other = controller.npcChatContacts[1].id;
      final first = service.send(npcId, 'first');
      await service.send(npcId, 'duplicate');
      final second = service.send(other, 'second');
      expect(backend.requests.length, 2);
      expect(controller.npcChats.threadFor(npcId).messages.length, 1);
      expect(controller.npcChats.threadFor(other).messages.length, 1);
      backend.streams[1].add('其他NPC回复');
      await backend.streams[1].close();
      await second;
      expect(service.isSending(npcId), true);
      backend.streams[0].add('第一位NPC回复');
      await backend.streams[0].close();
      await first;
      expect(
        controller.npcChats.threadFor(npcId).messages.last.text,
        '第一位NPC回复',
      );
      expect(
        controller.npcChats.threadFor(other).messages.last.text,
        '其他NPC回复',
      );
    },
  );

  test(
    'failure keeps partial text and retry reuses stable message IDs',
    () async {
      final first = service.send(npcId, '同一个问题');
      backend.streams.single.add('前半段');
      backend.streams.single.addError(
        StateError('failure with sensitive payload'),
      );
      await first;
      final before = controller.npcChats.threadFor(npcId).messages;
      expect(before.last.status, NpcChatStatus.failed);
      expect(before.last.text, '前半段');
      expect(service.errorFor(npcId), isNot(contains('sensitive')));
      final retry = service.retry(npcId);
      expect(backend.requests.last.messages.map((message) => message.text), [
        '同一个问题',
      ]);
      backend.streams.last.add('完整回复');
      await backend.streams.last.close();
      await retry;
      final after = controller.npcChats.threadFor(npcId).messages;
      expect(after.length, 2);
      expect(after.first.id, before.first.id);
      expect(after.last.id, before.last.id);
      expect(after.last.status, NpcChatStatus.completed);
      expect(after.last.text, '完整回复');
      expect(service.errorFor(npcId), isNull);
    },
  );

  test(
    'explicit cancellation stores interrupted text and permits retry',
    () async {
      final pending = service.send(npcId, 'question');
      backend.streams.single.add('未写完');
      await _flush();
      service.cancel(npcId);
      await pending;
      final before = controller.npcChats.threadFor(npcId).messages;
      expect(before.last.status, NpcChatStatus.interrupted);
      expect(before.last.text, '未写完');
      expect(backend.canceled, contains(0));
      final retry = service.retry(npcId);
      backend.streams.last.add('写完了');
      await backend.streams.last.close();
      await retry;
      expect(controller.npcChats.threadFor(npcId).messages.length, 2);
      expect(
        controller.npcChats.threadFor(npcId).messages.last.id,
        before.last.id,
      );
    },
  );

  test(
    'idle timeout and empty response both remain retryable failures',
    () async {
      service.dispose();
      service = NpcChatService(
        controller: controller,
        backend: backend,
        replyTimeout: const Duration(milliseconds: 25),
      );
      await service.send(npcId, 'timeout');
      expect(service.errorFor(npcId), contains('超时'));
      expect(
        controller.npcChats.threadFor(npcId).messages.last.status,
        NpcChatStatus.failed,
      );
      final retry = service.retry(npcId);
      backend.streams.last.add('<think>Only private reasoning</think>');
      await backend.streams.last.close();
      await retry;
      expect(service.errorFor(npcId), contains('未返回'));
      expect(controller.npcChats.threadFor(npcId).messages.length, 2);
    },
  );

  test('slot changes cancel pending requests and cannot write late replies to a new save', () async {
    await controller.createLocalSlot(0);
    controller.addNpcContact(npcId);
    final pending = service.send(npcId, '旧档的问题');
    backend.streams.single.add('旧档的部分回复');
    await _flush();
    await controller.createLocalSlot(1);
    await pending;
    expect(service.isSending(npcId), false);
    expect(backend.canceled, contains(0));
    backend.streams.single.add('迟到数据');
    await _flush();
    expect(controller.npcChats.threadFor(npcId).messages, isEmpty);
    await controller.loadFromLocalSlot(0);
    expect(
      controller.npcChats
          .threadFor(npcId)
          .messages
          .map((message) => message.text),
      ['旧档的问题'],
    );
    final retry = service.retry(npcId);
    backend.streams.last.add('现在完成');
    await backend.streams.last.close();
    await retry;
    expect(controller.npcChats.threadFor(npcId).messages.length, 2);
  });

  test('unadded contacts cannot be reached through send or retry', () async {
    expect(controller.removeNpcContact(npcId), isTrue);
    controller.replaceNpcChats(
      controller.npcChats.withThread(NpcChatThread(npcId: npcId)),
      expectedRevision: controller.dataRevision,
    );
    expect(controller.isNpcContactAdded(npcId), isFalse);
    await service.send(npcId, '不能绕过确认的消息');
    await service.retry(npcId);
    expect(service.errorFor(npcId), contains('确认添加'));
    expect(backend.requests, isEmpty);
    expect(controller.npcChats.threadFor(npcId).messages, isEmpty);
  });

  test('same revision contact replacement cancels replies instead of recreating contacts', () async {
    final revision = controller.dataRevision;
    final pending = service.send(npcId, '已撤销联系人的请求');
    backend.streams.single.add('还未完成');
    await _flush();
    controller.replaceNpcChats(
      const NpcChatState.empty(),
      expectedRevision: revision,
    );
    await pending;
    expect(controller.dataRevision, revision);
    expect(service.isSending(npcId), isFalse);
    expect(backend.canceled, contains(0));
    backend.streams.single.add('迟到的完整回复');
    await _flush();
    expect(controller.isNpcContactAdded(npcId), isFalse);
    expect(controller.npcChats.threads, isEmpty);
  });

  test(
    'removing the originating message cancels a reply even if contact remains',
    () async {
      final pending = service.send(npcId, '被清除的消息');
      controller.replaceNpcChats(
        controller.npcChats.withoutThread(npcId),
        expectedRevision: controller.dataRevision,
      );
      await pending;
      expect(controller.isNpcContactAdded(npcId), isTrue);
      expect(service.isSending(npcId), isFalse);
      expect(backend.canceled, contains(0));
      backend.streams.single.add('不能重新写回');
      await _flush();
      expect(controller.npcChats.threadFor(npcId).messages, isEmpty);
    },
  );

  test(
    'requests use the selected primary config, language and NPC-only history',
    () async {
      final slots = controller.openAiConfigurations;
      slots.active = 2;
      slots.entries[2] = {
        'baseUrl': 'https://slot-two.example.test/v1',
        'model': 'gpt-5',
      };
      controller.saveOpenAiConfigurations(slots, enabled: true);
      controller.characterReplyLanguage = AppLanguage.japanese;
      controller.configureOpenAiAdvanced(
        enabled: true,
        reasoningEffort: ReasoningEffort.high,
        outputMultiplier: 1.5,
      );
      final other = controller.npcChatContacts[1].id;
      final state = controller.npcChats.withThread(
        NpcChatThread(
          npcId: other,
          messages: [
            NpcChatMessage(
              id: 'unrelated-private',
              role: NpcChatRole.user,
              text: '另一个NPC私信secret',
              createdAt: DateTime.now(),
            ),
          ],
        ),
      );
      controller.replaceNpcChats(
        state,
        expectedRevision: controller.dataRevision,
      );
      final pending = service.send(npcId, '日本語の質問');
      final request = backend.requests.single;
      expect(request.baseUrl, 'https://slot-two.example.test/v1');
      expect(request.model, controller.activeLlmModel);
      expect(request.openAiSlot, 2);
      expect(request.replyLanguage, AppLanguage.japanese);
      expect(request.reasoningEffort, controller.activeReasoningEffort);
      expect(request.thinkingEnabled, controller.activeThinkingEnabled);
      expect(request.outputMultiplier, isNull);
      expect(request.messages.map((message) => message.text), ['日本語の質問']);
      expect(request.systemPrompt, isNot(contains('另一个NPC私信secret')));
      backend.streams.single.add('日本語の返事');
      await backend.streams.single.close();
      await pending;
    },
  );

  test('AI disabled, invalid config and unknown contacts do not create demo messages', () async {
    controller.aiEnabled = false;
    await service.send(npcId, 'test');
    expect(service.errorFor(npcId), contains('启用'));
    controller.aiEnabled = true;
    controller.openAiBaseUrl = '';
    await service.send(npcId, 'test');
    expect(service.errorFor(npcId), contains('有效'));
    await service.send('not-a-contact', 'test');
    expect(service.errorFor('not-a-contact'), contains('不属于'));
    expect(backend.requests, isEmpty);
    expect(controller.npcChats.threads, isEmpty);
  });

  test('completed original is saved before optional translation and late translations are isolated', () async {
    service.dispose();
    final translating = _TranslatingBackend();
    backend = translating;
    service = NpcChatService(controller: controller, backend: translating);
    controller.translationLanguage = TranslationLanguage.chinese;
    controller.characterReplyLanguage = AppLanguage.japanese;
    controller.independentTranslation = true;
    final pending = service.send(npcId, 'Japanese question');
    translating.streams.single.add('はい、覚えています。');
    await translating.streams.single.close();
    await pending;
    expect(
      controller.npcChats.threadFor(npcId).messages.last.text,
      'はい、覚えています。',
    );
    expect(service.isSending(npcId), false);
    translating.translations.single.complete('是的，我记得。');
    await _flush();
    expect(
      controller.npcChats.threadFor(npcId).messages.last.translatedText,
      '是的，我记得。',
    );
    final next = service.send(npcId, 'second');
    translating.streams.last.add('次の返事');
    await translating.streams.last.close();
    await next;
    await controller.createLocalSlot(0);
    translating.translations.last.complete('迟到译文');
    await _flush();
    expect(controller.npcChats.threadFor(npcId).messages, isEmpty);
  });

  test('message language overrides take precedence and remain stable during a reply', () async {
    service.dispose();
    final translating = _TranslatingBackend();
    backend = translating;
    service = NpcChatService(controller: controller, backend: translating);
    controller.independentTranslation = false;
    controller.configureNpcMessageLanguages(
      reply: AppLanguage.japanese,
      translation: TranslationLanguage.chinese,
    );
    final pending = service.send(npcId, '你好');
    final request = translating.requests.single;
    expect(request.replyLanguage, AppLanguage.japanese);
    expect(request.systemPrompt, contains('用 Japanese'));
    controller.configureNpcMessageLanguages(
      reply: AppLanguage.english,
      translation: TranslationLanguage.english,
    );
    translating.streams.single.add('はい、覚えています。');
    await translating.streams.single.close();
    await pending;
    expect(translating.translationLanguages, [TranslationLanguage.chinese]);
    translating.translations.single.complete('是的，我记得。');
    await _flush();
    expect(
      controller.npcChats.threadFor(npcId).messages.last.translatedText,
      '是的，我记得。',
    );
  });

  test(
    'clear wrong-language replies are corrected once before completing',
    () async {
      service.dispose();
      final correcting = _CorrectingBackend();
      backend = correcting;
      service = NpcChatService(controller: controller, backend: correcting);
      controller.configureNpcMessageLanguages(
        reply: AppLanguage.japanese,
        translation: TranslationLanguage.none,
      );
      final pending = service.send(npcId, '还记得我的约定吗？');
      correcting.streams.single.add('当然记得，我们已经约定好了。');
      await correcting.streams.single.close();
      await _flush();
      expect(service.isSending(npcId), isTrue);
      expect(controller.npcChats.threadFor(npcId).messages.length, 1);
      expect(correcting.correctionSources, ['当然记得，我们已经约定好了。']);
      correcting.corrections.single.complete('もちろん覚えているよ。約束したからね。');
      await pending;
      final reply = controller.npcChats.threadFor(npcId).messages.last;
      expect(reply.status, NpcChatStatus.completed);
      expect(reply.text, 'もちろん覚えているよ。約束したからね。');
      expect(correcting.requests.length, 1);
    },
  );

  test(
    'still-wrong language fails instead of entering completed NPC memory',
    () async {
      service.dispose();
      final correcting = _CorrectingBackend();
      backend = correcting;
      service = NpcChatService(controller: controller, backend: correcting);
      controller.characterReplyLanguage = AppLanguage.japanese;
      final pending = service.send(npcId, '问题');
      correcting.streams.single.add('你好，我们已经约定好了。');
      await correcting.streams.single.close();
      await _flush();
      correcting.corrections.single.complete('你好，我们已经约定好了。');
      await pending;
      expect(correcting.corrections.length, 1);
      expect(
        controller.npcChats.threadFor(npcId).messages.last.status,
        NpcChatStatus.failed,
      );
      expect(service.errorFor(npcId), contains('设定语言'));
      expect(
        controller.npcChats.memoryContextFor(npcId, '约定'),
        isNot(contains('你好，我们已经约定好了。')),
      );
    },
  );

  testWidgets(
    'language correction has its own bounded deadline after stream completion',
    (tester) async {
      service.dispose();
      final correcting = _CorrectingBackend();
      backend = correcting;
      service = NpcChatService(
        controller: controller,
        backend: correcting,
        replyTimeout: const Duration(milliseconds: 50),
      );
      controller.characterReplyLanguage = AppLanguage.japanese;
      var completed = false;
      unawaited(service.send(npcId, '问题').then((_) => completed = true));
      correcting.streams.single.add('你好，我们已经约定好了。');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      unawaited(correcting.streams.single.close());
      await tester.pump();
      expect(correcting.corrections.length, 1);
      // Cross the stream's original 50 ms deadline; repair still has 30 ms.
      await tester.pump(const Duration(milliseconds: 20));
      expect(service.isSending(npcId), isTrue);
      expect(completed, isFalse);
      correcting.corrections.single.complete('約束をちゃんと覚えているよ。');
      await tester.pump();
      expect(completed, isTrue);
      expect(
        controller.npcChats.threadFor(npcId).messages.last.status,
        NpcChatStatus.completed,
      );

      // A repair that never returns still fails within its own 50 ms window.
      completed = false;
      unawaited(service.send(npcId, '下一个问题').then((_) => completed = true));
      correcting.streams.last.add('你好，我们已经约定好了。');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      unawaited(correcting.streams.last.close());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 51));
      await tester.pump();
      expect(completed, isTrue);
      expect(service.isSending(npcId), isFalse);
      expect(
        controller.npcChats.threadFor(npcId).messages.last.status,
        NpcChatStatus.failed,
      );
      expect(service.errorFor(npcId), contains('语言校正失败'));
    },
  );

  test('a changed save discards late language corrections', () async {
    service.dispose();
    final correcting = _CorrectingBackend();
    backend = correcting;
    service = NpcChatService(controller: controller, backend: correcting);
    controller.characterReplyLanguage = AppLanguage.japanese;
    final pending = service.send(npcId, '问题');
    correcting.streams.single.add('你好，我们已经约定好了。');
    await correcting.streams.single.close();
    await _flush();
    await controller.createLocalSlot(0);
    await pending;
    correcting.corrections.single.complete('約束を覚えているよ。');
    await _flush();
    expect(controller.npcChats.threadFor(npcId).messages, isEmpty);
  });

  test(
    'wrong translations retry once and never save a rejected-language result',
    () async {
      service.dispose();
      final translating = _TranslatingBackend();
      backend = translating;
      service = NpcChatService(controller: controller, backend: translating);
      controller.configureNpcMessageLanguages(
        reply: AppLanguage.japanese,
        translation: TranslationLanguage.chinese,
      );
      final pending = service.send(npcId, '你好');
      translating.streams.single.add('はい、覚えています。');
      await translating.streams.single.close();
      await pending;
      translating.translations.single.complete('Yes, I remember our promise.');
      await _flush();
      expect(translating.translations.length, 2);
      expect(
        controller.npcChats.threadFor(npcId).messages.last.translatedText,
        isNull,
      );
      translating.translations.last.complete('Yes, I remember our promise.');
      await _flush();
      expect(translating.translations.length, 2);
      expect(
        controller.npcChats.threadFor(npcId).messages.last.translatedText,
        isNull,
      );
      expect(
        controller.npcChats.threadFor(npcId).messages.last.status,
        NpcChatStatus.completed,
      );
    },
  );

  test('recent context obeys character budget while retaining whole turns and current input', () async {
    controller.llmContextCompatibility = true;
    final now = DateTime.now();
    controller.replaceNpcChats(
      controller.npcChats.withThread(
        NpcChatThread(
          npcId: npcId,
          messages: [
            NpcChatMessage(
              id: 'old-user',
              role: NpcChatRole.user,
              text: '旧'.padRight(4000, '旧'),
              createdAt: now,
            ),
            NpcChatMessage(
              id: 'old-assistant',
              role: NpcChatRole.assistant,
              text: '旧回复'.padRight(4000, '旧'),
              createdAt: now,
            ),
            NpcChatMessage(
              id: 'recent-user',
              role: NpcChatRole.user,
              text: '完整的最近问题',
              createdAt: now,
            ),
            NpcChatMessage(
              id: 'recent-assistant',
              role: NpcChatRole.assistant,
              text: '完整的最近回答',
              createdAt: now,
            ),
            NpcChatMessage(
              id: 'unanswered',
              role: NpcChatRole.user,
              text: '之前未收到回复的问题',
              createdAt: now,
            ),
          ],
        ),
      ),
      expectedRevision: controller.dataRevision,
    );
    final pending = service.send(npcId, '保留当前完整消息');
    expect(backend.requests.single.messages.map((message) => message.text), [
      '完整的最近问题',
      '完整的最近回答',
      '保留当前完整消息',
    ]);
    expect(backend.requests.single.messages.first.isUser, isTrue);
    backend.streams.single.add('你好，没问题。');
    await backend.streams.single.close();
    await pending;
  });

  test('live backend reads the selected secure key and sends streaming requests without tools', () async {
    final secrets = _MemorySecrets('test-only-key');
    late http.Request captured;
    final live = LiveNpcReplyBackend(
      secretStore: secrets,
      clientFactory: () => MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(
            'data: {"choices":[{"delta":{"content":"真实接口格式"}}]}\n\ndata: [DONE]\n\n',
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
    service.dispose();
    service = NpcChatService(controller: controller, backend: live);
    final slots = controller.openAiConfigurations;
    slots.active = 1;
    slots.entries[1] = {
      'baseUrl': 'https://secure-slot.example.test/v1',
      'model': 'npc-model',
    };
    controller.saveOpenAiConfigurations(slots, enabled: true);
    await service.send(npcId, 'test');
    final body = jsonDecode(captured.body) as Map;
    expect(secrets.slot, 1);
    expect(
      captured.url.toString(),
      'https://secure-slot.example.test/v1/chat/completions',
    );
    expect(body['stream'], true);
    expect(body.containsKey('tools'), false);
    expect(controller.npcChats.threadFor(npcId).messages.last.text, '真实接口格式');
    expect(
      jsonEncode(controller.exportData()),
      isNot(contains('test-only-key')),
    );
  });

  test('live backend missing secure key reports configuration instead of fake dialogue', () async {
    service.dispose();
    service = NpcChatService(
      controller: controller,
      backend: LiveNpcReplyBackend(
        secretStore: _MemorySecrets(''),
        clientFactory: () => throw StateError('No network without credentials'),
      ),
    );
    await service.send(npcId, 'test');
    expect(service.errorFor(npcId), contains('API Key'));
    expect(
      controller.npcChats.threadFor(npcId).messages.last.status,
      NpcChatStatus.failed,
    );
    expect(controller.npcChats.threadFor(npcId).messages.last.text, isEmpty);
  });

  test('live language repair uses a separate text-only request with the captured config', () async {
    final requests = <http.Request>[];
    final live = LiveNpcReplyBackend(
      secretStore: _MemorySecrets('test-only-key'),
      clientFactory: () => MockClient((request) async {
        requests.add(request);
        if (requests.length == 1) {
          return http.Response.bytes(
            utf8.encode(
              'data: {"choices":[{"delta":{"content":"你好，我们已经约定好了。"}}]}\n\ndata: [DONE]\n\n',
            ),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'corrections': [
                      {'id': 0, 'text': 'うん、約束をちゃんと覚えているよ。'},
                    ],
                  }),
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    service.dispose();
    service = NpcChatService(controller: controller, backend: live);
    controller.characterReplyLanguage = AppLanguage.japanese;
    await service.send(npcId, '约定呢？');
    expect(requests.length, 2);
    final first = jsonDecode(requests.first.body) as Map;
    final correction = jsonDecode(requests.last.body) as Map;
    expect(first['stream'], isTrue);
    expect(correction['stream'], isNot(true));
    expect(correction.containsKey('tools'), isFalse);
    expect(correction['model'], first['model']);
    expect(requests.last.url, requests.first.url);
    final data = jsonDecode(correction['messages'][1]['content']) as Map;
    expect(data['lines'].single['target_language'], 'Japanese');
    expect(data['lines'].single['text'], '你好，我们已经约定好了。');
    expect(
      controller.npcChats.threadFor(npcId).messages.last.text,
      'うん、約束をちゃんと覚えているよ。',
    );
    expect(
      controller.npcChats.threadFor(npcId).messages.last.status,
      NpcChatStatus.completed,
    );
  });
}
