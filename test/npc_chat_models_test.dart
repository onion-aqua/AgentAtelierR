import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/npc_chat_models.dart';

final _start = DateTime.utc(2026, 10, 5);

NpcChatMessage _message(
  String id,
  String text, {
  NpcChatRole role = NpcChatRole.user,
  NpcChatStatus status = NpcChatStatus.completed,
  int minute = 0,
  String? translatedText,
}) => NpcChatMessage(
  id: id,
  role: role,
  text: text,
  createdAt: _start.add(Duration(minutes: minute)),
  status: status,
  translatedText: translatedText,
);

NpcChatThread _longThread(String npcId) => NpcChatThread(
  npcId: npcId,
  messages: [
    _message('old-user', '我叫白露，约定明天一起去山谷寻找苹果。'),
    _message('old-reply', '好，我答应陪你去山谷找苹果。', role: NpcChatRole.assistant),
    for (var index = 0; index < 150; index++) ...[
      _message('user-$index', '聊聊今天的普通天气，第$index轮。', minute: index + 1),
      _message(
        'reply-$index',
        '今天很适合散步。',
        role: NpcChatRole.assistant,
        minute: index + 1,
      ),
    ],
  ],
);

void main() {
  test('save roundtrip keeps all messages, statuses, translations and NPC isolation', () {
    final original = NpcChatState(
      threads: {
        'claudia': _longThread('claudia').appendMessage(
          _message(
            'partial',
            'まだ話している',
            role: NpcChatRole.assistant,
            status: NpcChatStatus.interrupted,
            translatedText: '还没有说完',
          ),
        ),
        'lent': NpcChatThread(
          npcId: 'lent',
          messages: [
            _message('lent-user', '只告诉兰托的消息'),
            _message(
              'lent-failed',
              '网络错误',
              role: NpcChatRole.assistant,
              status: NpcChatStatus.failed,
            ),
          ],
        ),
      },
    );
    final restored = NpcChatState.fromJson(
      jsonDecode(jsonEncode(original.toJson())),
      allowedNpcIds: {'claudia', 'lent'},
    );
    expect(restored.toJson(), original.toJson());
    expect(restored.threadFor('claudia').messages.length, 303);
    expect(restored.threadFor('claudia').messages.last.translatedText, '还没有说完');
    expect(
      restored.threadFor('lent').messages.last.status,
      NpcChatStatus.failed,
    );
    expect(restored.threadFor('missing').messages, isEmpty);
  });

  test('immutable snapshots do not share mutable map or list containers', () {
    final messages = [_message('one', '原始消息')];
    final thread = NpcChatThread(npcId: 'claudia', messages: messages);
    final threads = {'claudia': thread};
    final state = NpcChatState(threads: threads);
    messages.clear();
    threads.clear();
    expect(state.threadFor('claudia').messages.single.text, '原始消息');
    expect(() => state.threads.clear(), throwsUnsupportedError);
    expect(() => thread.messages.clear(), throwsUnsupportedError);
    final updated = thread.upsertMessage(
      thread.messages.single.copyWith(text: '更新'),
    );
    expect(updated.messages.length, 1);
    expect(thread.messages.single.text, '原始消息');
    expect(
      state.withThread(updated).threadFor('claudia').messages.single.text,
      '更新',
    );
    expect(state.withoutThread('claudia').threads, isEmpty);
  });

  test('explicit contacts round trip separately from message threads', () {
    final state = NpcChatState(
      contactIds: const ['claudia', 'lent'],
      threads: {'claudia': NpcChatThread(npcId: 'claudia')},
    );
    final restored = NpcChatState.fromJson(
      jsonDecode(jsonEncode(state.toJson())),
      allowedNpcIds: {'claudia', 'lent'},
    );
    expect(restored.contactIds, {'claudia', 'lent'});
    expect(restored.effectiveContactIds, {'claudia', 'lent'});
    expect(restored.withoutContact('lent').contactIds, {'claudia'});
    expect(restored.withContact('tao').contactIds, {'claudia', 'lent', 'tao'});
  });

  test(
    'legacy history preserves contacts but empty placeholders grant none',
    () {
      final state = NpcChatState.fromJson({
        'version': 1,
        'threads': {
          'claudia': NpcChatThread(npcId: 'claudia').toJson(),
          'lent': NpcChatThread(
            npcId: 'lent',
            messages: [_message('legacy-user', '旧的私信')],
          ).toJson(),
        },
      });
      expect(state.effectiveContactIds, {'lent'});
      expect(state.withContact('claudia').effectiveContactIds, {
        'claudia',
        'lent',
      });
      expect(state.contactIds, isEmpty);
    },
  );

  test(
    'streaming placeholders update the same ID and can clear translation',
    () {
      final partial = _message(
        'stable-id',
        '',
        role: NpcChatRole.assistant,
        status: NpcChatStatus.interrupted,
      );
      final original = NpcChatThread(npcId: 'claudia').upsertMessage(partial);
      final completed = original.upsertMessage(
        partial.copyWith(
          text: '完成的回复',
          status: NpcChatStatus.completed,
          translatedText: 'Completed reply',
        ),
      );
      expect(original.messages.single.status, NpcChatStatus.interrupted);
      expect(completed.messages.single.status, NpcChatStatus.completed);
      expect(
        completed.messages.single
            .copyWith(clearTranslation: true)
            .translatedText,
        isNull,
      );
    },
  );

  test(
    'imports reject duplicate IDs, mismatched ownership and another character',
    () {
      final one = _message('one', '你好').toJson();
      expect(
        () => NpcChatThread.fromJson({
          'npc_id': 'claudia',
          'messages': [one, one],
        }),
        throwsFormatException,
      );
      expect(
        () => NpcChatState.fromJson({
          'version': 1,
          'threads': {
            'lent': {
              'npc_id': 'claudia',
              'messages': [one],
            },
          },
        }),
        throwsFormatException,
      );
      expect(
        () => NpcChatState.fromJson(
          {
            'version': 1,
            'threads': {
              'sophie_plachta_doll': {
                'npc_id': 'sophie_plachta_doll',
                'messages': [one],
              },
            },
          },
          allowedNpcIds: {'claudia'},
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'imports reject malformed fields instead of silently dropping history',
    () {
      final valid = _message('valid', '你好').toJson();
      for (final override in <Map<String, dynamic>>[
        {'id': 'bad id'},
        {'role': 'system'},
        {'status': 'pending'},
        {'text': 42},
        {'text': '  '},
        {
          'translated_text': ['bad'],
        },
        {'created_at': '2026-10-05'},
        {'created_at': '2026-02-30T12:00:00Z'},
        {'created_at': '2026-10-05T25:00:00Z'},
        {'created_at': '2026-10-05T12:00:00+08:99'},
        {'Authorization': 'must not be accepted'},
      ]) {
        expect(
          () => NpcChatMessage.fromJson({...valid, ...override}),
          throwsFormatException,
          reason: '$override',
        );
      }
      for (final value in <Object?>[
        [],
        {'version': 2, 'threads': {}},
        {'version': 1.0, 'threads': {}},
        {'version': 1, 'threads': []},
        {'version': 1},
      ]) {
        expect(() => NpcChatState.fromJson(value), throwsFormatException);
      }
      expect(NpcChatState.fromJson(null).threads, isEmpty);
    },
  );

  test('timezone dates normalize without changing their instant', () {
    final json = _message('one', '你好').toJson()
      ..['created_at'] = '2026-10-05T08:00:00+08:00';
    expect(NpcChatMessage.fromJson(json).createdAt, _start);
  });

  test(
    'old keyword memories survive a short prompt with unrelated recent turns',
    () {
      final thread = _longThread('claudia');
      final memory = thread.memoryContext(
        '还记得我们要去哪儿找苹果吗？',
        maxChars: 1000,
        recentMessages: 6,
      );
      expect(memory, contains('山谷'));
      expect(memory, contains('苹果'));
      expect(memory, contains('今天很适合散步'));
      expect(memory.length, lessThanOrEqualTo(1000));
      expect(thread.messages.length, 302);
    },
  );

  test('broad recall retains early identity and promises without exact query nouns', () {
    final memory = _longThread('claudia')
        .memoryContext('我们之前约定了什么？', maxChars: 900);
    expect(memory, contains('白露'));
    expect(memory, contains('山谷'));
    expect(memory, contains('苹果'));
  });

  test('failed or interrupted replies never become accepted facts', () {
    final thread = NpcChatThread(
      npcId: 'claudia',
      messages: [
        _message('u-one', '你答应今晚去见面了吗？'),
        _message(
          'a-one',
          '我保证今晚一定见面。',
          role: NpcChatRole.assistant,
          status: NpcChatStatus.interrupted,
        ),
        _message('u-two', '可以给我这件道具吗？'),
        _message(
          'a-two',
          '我已经送给你了。',
          role: NpcChatRole.assistant,
          status: NpcChatStatus.failed,
        ),
      ],
    );
    final memory = thread.memoryContext('之前约定');
    expect(memory, contains('已发送，尚无已完成回复'));
    expect(memory, contains('今晚去见面了吗'));
    expect(memory, isNot(contains('我保证')));
    expect(memory, isNot(contains('我已经送给你')));
  });

  test('translated text participates in old-message search', () {
    final thread = NpcChatThread(
      npcId: 'claudia',
      messages: [
        _message(
          'old',
          'リンゴを探しましょう。',
          role: NpcChatRole.assistant,
          translatedText: '一起寻找苹果吧',
        ),
        for (var i = 0; i < 20; i++) _message('recent-$i', '普通闲聊'),
      ],
    );
    expect(thread.memoryContext('苹果', recentMessages: 2), contains('リンゴ'));
  });

  test(
    'per-NPC and main-chat selection cannot leak another NPC transcript',
    () {
      final state = NpcChatState(
        threads: {
          'claudia': _longThread('claudia'),
          'lent': NpcChatThread(
            npcId: 'lent',
            messages: [_message('secret', '兰托专属的炼金配方暗号')],
          ),
        },
      );
      expect(state.memoryContextFor('claudia', '苹果'), isNot(contains('暗号')));
      final selected = state.memoryContextForMainChat(
        '苹果',
        npcIds: ['claudia'],
        maxChars: 1000,
      );
      expect(selected, contains('NPC claudia'));
      expect(selected, contains('不表示主角亲历'));
      expect(selected, isNot(contains('暗号')));
      expect(selected.length, lessThanOrEqualTo(1000));
    },
  );

  test('prompt limits remain hard bounds with large text and emoji', () {
    final thread = NpcChatThread(
      npcId: 'claudia',
      messages: [
        _message('one', List.filled(1000, '苹果🍎').join()),
        _message(
          'two',
          List.filled(1000, '了解🙂').join(),
          role: NpcChatRole.assistant,
        ),
      ],
    );
    for (final limit in [0, 40, 80, 120, 400]) {
      final memory = thread.memoryContext('苹果', maxChars: limit);
      expect(memory.length, lessThanOrEqualTo(limit));
      expect(
        memory.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff),
        isFalse,
      );
    }
  });
}
