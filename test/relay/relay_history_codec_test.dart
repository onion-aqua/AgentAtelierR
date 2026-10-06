import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/relay/relay_history_codec.dart';
import 'package:ryza_chat_mvp/src/relay/relay_protocol.dart';

const _created = '2026-10-05T04:20:00.000Z';
const _updated = '2026-10-05T04:20:01Z';

RelayHistoryAssembler _assembler() => RelayHistoryAssembler(
  pcId: 'pc-1',
  sessionId: 'session-1',
  workspaceId: 'workspace-1',
);

Json _fragment({
  String id = 'message-1',
  int ordinal = 1,
  String role = 'assistant',
  String status = 'completed',
  String body = 'こんにちは',
  int partIndex = 0,
  int partCount = 1,
}) => {
  'message_id': id,
  'role': role,
  'body': body,
  'created_at': _created,
  'updated_at': _updated,
  'ordinal': ordinal,
  'status': status,
  'part_index': partIndex,
  'part_count': partCount,
};

Json _page(
  List<Json> fragments, {
  int revision = 3,
  String? cursor,
  bool more = false,
  String connectionState = 'online',
  String syncState = 'ready',
  int snapshotSeq = 0,
}) => {
  'pc_id': 'pc-1',
  'session_id': 'session-1',
  'workspace_id': 'workspace-1',
  'connection_state': connectionState,
  'snapshot_seq': snapshotSeq,
  'history_revision': revision,
  'sync_state': syncState,
  'messages': fragments,
  'next_cursor': cursor,
  'has_more': more,
};

void main() {
  test(
    'joins cross-page fragments and sorts normalized messages by ordinal',
    () {
      final assembler = _assembler();
      expect(assembler.revision, isNull);
      expect(assembler.messages, throwsFormatException);
      assembler.addPage(
        _page(
          [_fragment(body: 'ただいま。', partCount: 2)],
          cursor: 'opaque-next-page',
          more: true,
          snapshotSeq: 120,
        ),
      );
      expect(assembler.revision, 3);
      expect(assembler.hasMore, isTrue);
      expect(assembler.nextCursor, 'opaque-next-page');
      expect(assembler.messages, throwsFormatException);
      assembler.addPage(
        _page([
          _fragment(body: 'お帰りなさい！', partIndex: 1, partCount: 2),
          _fragment(id: 'user-message', ordinal: 0, role: 'user', body: '帰ったよ'),
        ], snapshotSeq: 125),
      );
      expect(assembler.hasMore, isFalse);
      expect(assembler.nextCursor, isNull);
      expect(assembler.connectionState, 'online');
      expect(assembler.messages(), [
        {
          'message_id': 'user-message',
          'session_id': 'session-1',
          'seq': 0,
          'role': 'user',
          'content': '帰ったよ',
          'created_at': _created,
          'updated_at': _updated,
          'state': 'completed',
          'revision': 3,
        },
        {
          'message_id': 'message-1',
          'session_id': 'session-1',
          'seq': 1,
          'role': 'assistant',
          'content': 'ただいま。お帰りなさい！',
          'created_at': _created,
          'updated_at': _updated,
          'state': 'completed',
          'revision': 3,
        },
      ]);
      // History watermarks are not normalized message seq values or ACKs.
      expect(
        assembler.messages().any((message) => message['seq'] == 125),
        isFalse,
      );
    },
  );

  test(
    'an empty final snapshot is complete, including offline syncing cache',
    () {
      final assembler = _assembler();
      assembler.addPage(
        _page([], connectionState: 'offline', syncState: 'syncing'),
      );
      expect(assembler.messages(), isEmpty);
      expect(assembler.hasMore, isFalse);
      expect(assembler.connectionState, 'offline');
    },
  );

  test(
    'identical duplicate fragments and retried pages do not add messages',
    () {
      final assembler = _assembler();
      final first = _fragment(body: '前半', partCount: 2);
      final firstPage = _page([first, first], cursor: 'next', more: true);
      assembler.addPage(firstPage);
      assembler.addPage(firstPage);
      assembler.addPage(
        _page([first, _fragment(body: '後半', partIndex: 1, partCount: 2)]),
      );
      assembler.addPage(firstPage);
      expect(assembler.messages(), hasLength(1));
      expect(assembler.messages().single['content'], '前半後半');
      expect(assembler.hasMore, isFalse);
      expect(assembler.nextCursor, isNull);
      final copy = assembler.messages();
      copy.single['content'] = 'edited externally';
      expect(assembler.messages().single['content'], '前半後半');
    },
  );

  test(
    'all fragments still require the final page before becoming visible',
    () {
      final assembler = _assembler();
      assembler.addPage(_page([_fragment()], cursor: 'last', more: true));
      expect(assembler.messages, throwsFormatException);
      assembler.addPage(_page([]));
      expect(assembler.messages().single['content'], 'こんにちは');
    },
  );

  test('a final page cannot publish a missing fragment', () {
    final assembler = _assembler();
    assembler.addPage(
      _page([_fragment(partCount: 3)], cursor: 'next', more: true),
    );
    expect(
      () => assembler.addPage(_page([_fragment(partIndex: 2, partCount: 3)])),
      throwsFormatException,
    );
    expect(assembler.messages, throwsFormatException);
  });

  test(
    'history revision changes require a fresh read and invalidate staging',
    () {
      final assembler = _assembler();
      assembler.addPage(
        _page([_fragment()], revision: 3, cursor: 'next', more: true),
      );
      final changed = isA<RelayFailure>()
          .having((failure) => failure.code, 'code', 'HISTORY_CHANGED')
          .having((failure) => failure.retryable, 'retryable', isTrue);
      expect(
        () => assembler.addPage(_page([_fragment()], revision: 4)),
        throwsA(changed),
      );
      expect(assembler.messages, throwsA(changed));
    },
  );

  test('pc, session and workspace must match the requested scope', () {
    for (final key in ['pc_id', 'session_id', 'workspace_id']) {
      final assembler = _assembler();
      expect(
        () => assembler.addPage(_page([])..[key] = 'other-scope'),
        throwsFormatException,
      );
      expect(assembler.messages, throwsFormatException);
    }
  });

  test('page metadata strictly validates revision, cursors and watermarks', () {
    final malformed = <(String, Object?)>[
      ('history_revision', 0),
      ('history_revision', -1),
      ('history_revision', 3.0),
      ('history_revision', '3'),
      ('snapshot_seq', -1),
      ('snapshot_seq', 0.0),
      ('snapshot_seq', '0'),
      ('sync_state', 'unavailable'),
      ('connection_state', 'connected'),
      ('next_cursor', 42),
      ('next_cursor', 'cursor-without-more'),
      ('has_more', 'false'),
      ('messages', null),
    ];
    for (final (key, value) in malformed) {
      expect(
        () => _assembler().addPage(_page([])..[key] = value),
        throwsFormatException,
        reason: key,
      );
    }
    for (final cursor in [null, '']) {
      expect(
        () => _assembler().addPage(_page([], cursor: cursor, more: true)),
        throwsFormatException,
      );
    }
    final missingCursor = _page([])..remove('next_cursor');
    expect(() => _assembler().addPage(missingCursor), throwsFormatException);
  });

  test('fragments of one message must share all stable metadata', () {
    final conflicts = <(String, Object?)>[
      ('role', 'user'),
      ('created_at', '2026-10-05T04:19:00Z'),
      ('updated_at', '2026-10-05T04:20:02Z'),
      ('ordinal', 2),
      ('status', 'streaming'),
      ('part_count', 3),
      ('provisional', true),
      ('replaces_message_id', 'temporary-message'),
    ];
    for (final (key, value) in conflicts) {
      final assembler = _assembler();
      assembler.addPage(
        _page([_fragment(partCount: 2)], cursor: 'next', more: true),
      );
      expect(
        () => assembler.addPage(
          _page([_fragment(partIndex: 1, partCount: 2)..[key] = value]),
        ),
        throwsFormatException,
        reason: key,
      );
    }
  });

  test('duplicate text conflicts do not leak their text in errors', () {
    const secretBody = 'DO_NOT_ECHO_THIS_REAL_MESSAGE';
    final assembler = _assembler();
    assembler.addPage(
      _page([_fragment(body: secretBody)], cursor: 'next', more: true),
    );
    Object? error;
    try {
      assembler.addPage(_page([_fragment(body: '$secretBody changed')]));
    } on Object catch (caught) {
      error = caught;
    }
    expect(error, isA<FormatException>());
    expect(error.toString(), isNot(contains(secretBody)));
    expect(assembler.messages, throwsFormatException);
  });

  test('an ordinal cannot be shared by different stable message ids', () {
    expect(
      () => _assembler().addPage(
        _page([_fragment(), _fragment(id: 'different-message')]),
      ),
      throwsFormatException,
    );
  });

  test('Japanese and paired emoji survive the UTF16 fragment boundary', () {
    final first = '${List.filled(8190, 'あ').join()}🎐';
    expect(first.length, 8192);
    final assembler = _assembler();
    assembler.addPage(
      _page([_fragment(body: first, partCount: 2)], cursor: 'next', more: true),
    );
    assembler.addPage(
      _page([_fragment(body: 'お帰り😊', partIndex: 1, partCount: 2)]),
    );
    expect(assembler.messages().single['content'], '$firstお帰り😊');
    expect(
      () => _assembler().addPage(_page([_fragment(body: '$firstあ')])),
      throwsFormatException,
    );
  });

  test(
    'a fragment cannot split a surrogate pair or contain an unpaired one',
    () {
      final invalidBodies = [
        String.fromCharCodes([0xd83d]),
        String.fromCharCodes([0xde0a]),
        String.fromCharCodes([0xd83d, 0x3042]),
        String.fromCharCodes([0xd83d, 0xd83d, 0xde0a]),
      ];
      for (final body in invalidBodies) {
        expect(
          () => _assembler().addPage(_page([_fragment(body: body)])),
          throwsFormatException,
        );
      }
      final assembler = _assembler();
      expect(
        () => assembler.addPage(
          _page(
            [
              _fragment(body: String.fromCharCodes([0xd83d]), partCount: 2),
            ],
            cursor: 'next',
            more: true,
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test('fragment values and UTC timestamps must match the contract', () {
    final malformed = <(String, Object?)>[
      ('message_id', ''),
      ('message_id', '  '),
      ('message_id', 7),
      ('role', 'system'),
      ('role', 'tool'),
      ('status', 'succeeded'),
      ('body', 123),
      ('ordinal', 1.0),
      ('part_index', -1),
      ('part_index', 1),
      ('part_count', 0),
      ('part_count', 1.0),
      ('created_at', '2026-10-05T04:20:00'),
      ('created_at', '2026-10-05T04:20:00+08:00'),
      ('created_at', '2026-13-05T04:20:00Z'),
      ('updated_at', '2026-10-05T24:20:00Z'),
      ('updated_at', 'not-a-timestamp'),
      ('provisional', 'true'),
      ('provisional', null),
      ('replaces_message_id', ''),
      ('replaces_message_id', null),
      ('replaces_message_id', 'message-1'),
    ];
    for (final (key, value) in malformed) {
      expect(
        () => _assembler().addPage(_page([_fragment()..[key] = value])),
        throwsFormatException,
        reason: key,
      );
    }
    for (final key in _fragment().keys) {
      expect(
        () => _assembler().addPage(_page([_fragment()..remove(key)])),
        throwsFormatException,
        reason: key,
      );
    }
  });

  test('all real message statuses and UTC offset zero are accepted', () {
    final assembler = _assembler();
    final fragments = [
      for (final (index, status) in [
        'queued',
        'streaming',
        'completed',
        'cancelled',
        'failed',
      ].indexed)
        _fragment(
          id: 'message-$index',
          ordinal: index,
          status: status,
          role: status == 'queued' ? 'user' : 'assistant',
          body: status == 'queued' ? '' : '可见正文',
        )..['created_at'] = '2026-10-05T04:20:00+00:00',
    ];
    assembler.addPage(_page(fragments));
    expect(assembler.messages().map((message) => message['state']), [
      'queued',
      'streaming',
      'completed',
      'cancelled',
      'failed',
    ]);
  });

  test(
    'provisional streaming fields are preserved and consistent across parts',
    () {
      final assembler = _assembler();
      assembler.addPage(
        _page(
          [
            _fragment(status: 'streaming', body: '生成中', partCount: 2)
              ..['provisional'] = true,
          ],
          cursor: 'next',
          more: true,
        ),
      );
      assembler.addPage(
        _page([
          _fragment(
            status: 'streaming',
            body: 'の本文',
            partIndex: 1,
            partCount: 2,
          )..['provisional'] = true,
        ]),
      );
      expect(assembler.messages().single['provisional'], isTrue);
      expect(assembler.messages().single['content'], '生成中の本文');

      final completed = _assembler();
      completed.addPage(
        _page([_fragment()..['replaces_message_id'] = 'temporary-stream-id']),
      );
      expect(
        completed.messages().single['replaces_message_id'],
        'temporary-stream-id',
      );
      expect(
        () =>
            _assembler().addPage(_page([_fragment()..['provisional'] = true])),
        throwsFormatException,
      );
    },
  );

  test(
    'page size is limited to 100 fragments and response maps are copied',
    () {
      expect(
        () => _assembler().addPage(
          _page([
            for (var index = 0; index < 101; index++)
              _fragment(id: 'message-$index', ordinal: index),
          ]),
        ),
        throwsFormatException,
      );
      final response = _page([_fragment()]);
      final assembler = _assembler()..addPage(response);
      (response['messages'] as List).single['body'] = 'changed after import';
      expect(assembler.messages().single['content'], 'こんにちは');
    },
  );
}
