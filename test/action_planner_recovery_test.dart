import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/auxiliary_llm_tasks.dart';
import 'package:ryza_chat_mvp/src/independent_performance_tools.dart';

CharacterPerformancePromptContext _capabilities({
  bool manualPosture = false,
  Map<String, String>? groups,
}) => CharacterPerformancePromptContext(
  appearanceId: 'recovery-test',
  posture: 'sitting_normal',
  revision: 1,
  resourcesReady: true,
  playableActionDescriptions: const {},
  playableMotionGroupDescriptions:
      groups ?? const {'grp_fg_clap': '双手拍手', 'grp_fg_wave': '挥手问候'},
  availablePostures: const {'sitting_normal': '自然坐姿', 'sitting_agura': '盘腿坐姿'},
  postureManuallySelected: manualPosture,
);

String _response(List<Map<String, dynamic>> rows) =>
    jsonEncode({'segments': rows});

Map<String, dynamic> _row(
  Object? id,
  String action, {
  String match = 'exact',
}) => {
  'id': ?id,
  'action': action,
  'match': match,
  'reason': match == 'none' ? '本段无需动作' : '本段接受并执行对应动作',
};

Future<Map<int, String>> _plan({
  required AuxiliaryCompletion complete,
  List<int> ids = const [1],
  String userInput = '请拍手。',
  String source = '旁白：莱莎露出笑容。\n莱莎：拍手だね？うん、やってみるよ。\n译文：是拍手对吧？嗯，我来试试看。',
  CharacterPerformancePromptContext? capabilities,
}) => ActionPlannerTool().plan(
  userInput: userInput,
  source: source,
  ids: ids,
  capabilities: capabilities ?? _capabilities(),
  recentActions: const [],
  complete: complete,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test(
    'screenshot mixed narration and protagonist IDs preserve the clap',
    () async {
      var calls = 0;
      final result = await _plan(
        complete: (messages) async {
          calls++;
          final input = jsonDecode(messages.last['content']!) as Map;
          expect(input['line_ids'], [1]);
          expect(input['reply'], contains('[id:1]'));
          return _response([
            _row(0, 'none', match: 'none'),
            _row(1, 'grp_fg_clap'),
            _row(2, 'grp_not_in_catalogue'),
          ]);
        },
      );
      expect(result, {1: '[action:grp_fg_clap]'});
      expect(calls, 1);
    },
  );

  test(
    'extra malformed rows do not invalidate a valid protagonist action',
    () async {
      var calls = 0;
      final result = await _plan(
        complete: (_) async {
          calls++;
          return jsonEncode({
            'segments': [
              null,
              'not a row',
              {'id': 50},
              _row(1, 'grp_fg_clap'),
            ],
          });
        },
      );
      expect(result, {1: '[action:grp_fg_clap]'});
      expect(calls, 1);
    },
  );

  test('a numeric string ID is normalized without another request', () async {
    var calls = 0;
    final result = await _plan(
      complete: (_) async {
        calls++;
        return _response([_row('1', 'grp_fg_clap')]);
      },
    );
    expect(result, {1: '[action:grp_fg_clap]'});
    expect(calls, 1);
  });

  test('a single missing ID can identify the only protagonist line', () async {
    var calls = 0;
    final result = await _plan(
      complete: (_) async {
        calls++;
        return _response([_row(null, 'grp_fg_clap')]);
      },
    );
    expect(result, {1: '[action:grp_fg_clap]'});
    expect(calls, 1);
  });

  test(
    'an explicit narration ID is repaired rather than assigned to the actor',
    () async {
      var calls = 0;
      final result = await _plan(
        complete: (_) async {
          calls++;
          return _response([
            _row(
              calls == 1 ? 0 : 1,
              calls == 1 ? 'grp_fg_wave' : 'grp_fg_clap',
            ),
          ]);
        },
      );
      expect(calls, 2);
      expect(result, {1: '[action:grp_fg_clap]'});
    },
  );

  for (final invalidId in <Object>[0, '0', '1.5']) {
    test('unrepaired explicit invalid ID stays none: $invalidId', () async {
      var calls = 0;
      final result = await _plan(
        complete: (_) async {
          calls++;
          return _response([_row(invalidId, 'grp_fg_clap')]);
        },
      );
      expect(calls, 2);
      expect(result, {1: '[action:none]'});
    });
  }

  test('an explicit null ID is not treated as an omitted ID', () async {
    var calls = 0;
    final result = await _plan(
      complete: (_) async {
        calls++;
        return _response([
          {..._row(null, 'grp_fg_clap'), 'id': null},
        ]);
      },
    );
    expect(calls, 2);
    expect(result, {1: '[action:none]'});
  });

  test(
    'partial recovery merges missing rows while retaining a validated action',
    () async {
      var calls = 0;
      final result = await _plan(
        ids: [1, 3],
        source: '旁白：她抬起双手。\n莱莎：我来拍手。\n译文：I will clap.\n莱莎：接着挥手。',
        complete: (_) async {
          calls++;
          return _response([
            calls == 1 ? _row(1, 'grp_fg_clap') : _row(3, 'grp_fg_wave'),
          ]);
        },
      );
      expect(calls, 2);
      expect(result, {1: '[action:grp_fg_clap]', 3: '[action:grp_fg_wave]'});
    },
  );

  test(
    'unrepaired missing rows get none without losing other valid rows',
    () async {
      var calls = 0;
      final result = await _plan(
        ids: [1, 3],
        source: '旁白：她抬起双手。\n莱莎：我来拍手。\n译文：I will clap.\n莱莎：接着说吧。',
        complete: (_) async {
          calls++;
          return _response([_row(1, 'grp_fg_clap')]);
        },
      );
      expect(calls, 2);
      expect(result, {1: '[action:grp_fg_clap]', 3: '[action:none]'});
    },
  );

  test(
    'a failed repair transport retains validated first-response actions',
    () async {
      var calls = 0;
      final result = await _plan(
        ids: [1, 3],
        source: '旁白：她抬起双手。\n莱莎：我来拍手。\n译文：I will clap.\n莱莎：继续吧。',
        complete: (messages) async {
          calls++;
          final input = jsonDecode(messages.last['content']!) as Map;
          if (calls == 1) return _response([_row(1, 'grp_fg_clap')]);
          expect(input['line_ids'], [3]);
          throw TimeoutException('test transport interrupted');
        },
      );
      expect(calls, 2);
      expect(result, {1: '[action:grp_fg_clap]', 3: '[action:none]'});
    },
  );

  test('schema repair and unsupported expansion request only their missing-ID union', () async {
    var calls = 0;
    final result = await _plan(
      ids: [1, 3, 4],
      source: '旁白：她抬起双手。\n莱莎：我来拍手。\n译文：I will clap.\n莱莎：我再想想。\n莱莎：继续吧。',
      capabilities: _capabilities(
        groups: {
          'grp_fg_clap': '双手拍手',
          for (var i = 0; i < 60; i++) 'grp_fg_wait_$i': '安静等候$i',
        },
      ),
      complete: (messages) async {
        calls++;
        final input = jsonDecode(messages.last['content']!) as Map;
        if (calls == 1) {
          expect(input['line_ids'], [1, 3, 4]);
          return _response([
            _row(1, 'grp_fg_clap'),
            {
              'id': 3,
              'action': 'none',
              'match': 'unsupported',
              'reason': '需重新查询资源',
            },
          ]);
        }
        expect(input['line_ids'], [3, 4]);
        expect((input['dialogue_lines'] as List).map((row) => row['id']), [
          3,
          4,
        ]);
        expect(input['can_expand'], isFalse);
        expect((input['candidates'] as Map).length, lessThanOrEqualTo(49));
        return _response([
          _row(3, 'none', match: 'none'),
          _row(4, 'none', match: 'none'),
        ]);
      },
    );
    expect(calls, 2);
    expect(result, {
      1: '[action:grp_fg_clap]',
      3: '[action:none]',
      4: '[action:none]',
    });
  });

  test('replacement candidate windows keep actions validated in an earlier window', () async {
    const refinement =
        'wave upper lower arm wrist finger palm gently alternate rotate greeting farewell left right forward outward slow smooth loop salute';
    var calls = 0;
    String? secondAction;
    final result = await _plan(
      ids: [1, 3],
      source: '旁白：她抬起双手。\n莱莎：我来拍手。\n译文：I will clap.\n莱莎：接着做下一步。',
      capabilities: _capabilities(
        groups: {
          'grp_fg_clap': '双手拍手',
          for (var i = 0; i < 60; i++) 'grp_fg_wave_$i': refinement,
          for (var i = 0; i < 80; i++) 'grp_fg_wait_$i': '安静等候$i',
        },
      ),
      complete: (messages) async {
        calls++;
        final input = jsonDecode(messages.last['content']!) as Map;
        final candidates = input['candidates'] as Map;
        if (calls == 1) {
          expect(candidates.containsKey('grp_fg_clap'), isTrue);
          return jsonEncode({
            'search_query': refinement,
            'segments': [
              _row(1, 'grp_fg_clap'),
              {
                'id': 3,
                'action': 'none',
                'match': 'unsupported',
                'reason': '重新查找下一步',
              },
            ],
          });
        }
        expect(input['line_ids'], [3]);
        expect(candidates.containsKey('grp_fg_clap'), isFalse);
        secondAction = candidates.keys.cast<String>().firstWhere(
          (key) => key.startsWith('grp_fg_wave_'),
        );
        return _response([_row(3, secondAction!)]);
      },
    );
    expect(calls, 2);
    expect(secondAction, isNotNull);
    expect(result, {1: '[action:grp_fg_clap]', 3: '[action:$secondAction]'});
  });

  test('multiple missing IDs are never guessed by row position', () async {
    var calls = 0;
    final result = await _plan(
      ids: [1, 3],
      source: '旁白：她抬起双手。\n莱莎：我来拍手。\n译文：I will clap.\n莱莎：接着挥手。',
      complete: (_) async {
        calls++;
        return _response([
          _row(null, 'grp_fg_clap'),
          _row(null, 'grp_fg_wave'),
        ]);
      },
    );
    expect(calls, 2);
    expect(result, {1: '[action:none]', 3: '[action:none]'});
  });

  test('one malformed document gets one bounded repair attempt', () async {
    var calls = 0;
    final result = await _plan(
      complete: (_) async {
        calls++;
        return calls == 1
            ? '{"segments":'
            : _response([_row(1, 'grp_fg_clap')]);
      },
    );
    expect(calls, 2);
    expect(result, {1: '[action:grp_fg_clap]'});
  });

  test(
    'two empty segment responses end safely without a third request',
    () async {
      var calls = 0;
      final result = await _plan(
        complete: (_) async {
          calls++;
          return '{"segments":[]}';
        },
      );
      expect(calls, 2);
      expect(result, {1: '[action:none]'});
    },
  );

  test(
    'catalogue expansion and schema repair share a two-request budget',
    () async {
      var calls = 0;
      final result = await _plan(
        capabilities: _capabilities(
          groups: {for (var i = 0; i < 60; i++) 'grp_fg_clap_$i': '双手拍手$i'},
        ),
        complete: (_) async {
          calls++;
          return calls == 1 ? '{"request_catalog":true}' : '{"segments":[]}';
        },
      );
      expect(calls, 2);
      expect(result, {1: '[action:none]'});
    },
  );

  test('an explicit catalogue request can replace a valid none row with an exact action', () async {
    var calls = 0;
    final result = await _plan(
      capabilities: _capabilities(
        groups: {
          'grp_fg_clap': '双手拍手',
          for (var i = 0; i < 60; i++) 'grp_fg_wait_$i': '安静等候$i',
        },
      ),
      complete: (messages) async {
        calls++;
        final input = jsonDecode(messages.last['content']!) as Map;
        if (calls == 1) {
          expect(input['can_expand'], isTrue);
          return jsonEncode({
            'request_catalog': true,
            'search_query': '双手拍手',
            'segments': [_row(1, 'none', match: 'none')],
          });
        }
        expect(input['line_ids'], [1]);
        expect(input['can_expand'], isFalse);
        expect((input['candidates'] as Map).containsKey('grp_fg_clap'), isTrue);
        return _response([_row(1, 'grp_fg_clap')]);
      },
    );
    expect(calls, 2);
    expect(result, {1: '[action:grp_fg_clap]'});
  });

  test(
    'a pure schema repair advertises no remaining expansion budget',
    () async {
      var calls = 0;
      final result = await _plan(
        capabilities: _capabilities(
          groups: {
            'grp_fg_clap': '双手拍手',
            for (var i = 0; i < 60; i++) 'grp_fg_wait_$i': '安静等候$i',
          },
        ),
        complete: (messages) async {
          calls++;
          final input = jsonDecode(messages.last['content']!) as Map;
          if (calls == 1) {
            expect(input['can_expand'], isTrue);
            return '{"segments":[]}';
          }
          expect(input['line_ids'], [1]);
          expect(input['can_expand'], isFalse);
          expect((input['candidates'] as Map).length, lessThanOrEqualTo(17));
          return _response([_row(1, 'grp_fg_clap')]);
        },
      );
      expect(calls, 2);
      expect(result, {1: '[action:grp_fg_clap]'});
    },
  );

  test(
    'a catalogue request during schema repair cannot start a third request',
    () async {
      var calls = 0;
      final result = await _plan(
        capabilities: _capabilities(
          groups: {for (var i = 0; i < 60; i++) 'grp_fg_clap_$i': '双手拍手$i'},
        ),
        complete: (_) async {
          calls++;
          return calls == 1 ? '{"segments":[]}' : '{"request_catalog":true}';
        },
      );
      expect(calls, 2);
      expect(result, {1: '[action:none]'});
    },
  );

  test(
    'a missing match assessment never promotes an action to exact',
    () async {
      var calls = 0;
      final result = await _plan(
        complete: (_) async {
          calls++;
          return _response([
            {'id': 1, 'action': 'grp_fg_clap'},
          ]);
        },
      );
      expect(calls, 2);
      expect(result, {1: '[action:none]'});
    },
  );

  test(
    'an action outside the candidates cannot execute during recovery',
    () async {
      var calls = 0;
      final result = await _plan(
        complete: (_) async {
          calls++;
          return _response([_row(1, 'grp_unknown')]);
        },
      );
      expect(calls, 2);
      expect(result, {1: '[action:none]'});
    },
  );

  test(
    'manual posture lock survives schema recovery and suppresses a bad row',
    () async {
      var calls = 0;
      final result = await _plan(
        capabilities: _capabilities(manualPosture: true),
        complete: (_) async {
          calls++;
          return _response([
            {..._row(1, 'grp_fg_clap'), 'posture': 'sitting_agura'},
          ]);
        },
      );
      expect(calls, 2);
      expect(result, {1: '[action:none]'});
      expect(result.values.join(), isNot(contains('[posture:')));
    },
  );

  test(
    'a contradictory none assessment cannot execute a claimed action',
    () async {
      var calls = 0;
      final result = await _plan(
        complete: (_) async {
          calls++;
          return _response([_row(1, 'grp_fg_clap', match: 'none')]);
        },
      );
      expect(calls, 2);
      expect(result, {1: '[action:none]'});
    },
  );

  for (final reply in ['莱莎：今は拍手したくない。', '莱莎：拍手はしないよ。']) {
    test(
      'refusal and negation remain none without forcing motion: $reply',
      () async {
        var calls = 0;
        final result = await _plan(
          ids: [0],
          source: reply,
          complete: (_) async {
            calls++;
            return _response([_row(0, 'none', match: 'none')]);
          },
        );
        expect(calls, 1);
        expect(result, {0: '[action:none]'});
      },
    );
  }

  test(
    'valid unsupported assessment stays none and preserves its warning',
    () async {
      var calls = 0;
      final warnings = <String>[];
      final result = await ActionPlannerTool().plan(
        userInput: '请跳一个后空翻。',
        source: '莱莎：这个动作我做不到。',
        ids: [0],
        capabilities: _capabilities(),
        recentActions: const [],
        onMismatch: warnings.add,
        complete: (_) async {
          calls++;
          return _response([
            {
              'id': 0,
              'action': 'none',
              'match': 'unsupported',
              'reason': '没有后空翻资源',
            },
          ]);
        },
      );
      expect(calls, 1);
      expect(result, {0: '[action:none]'});
      expect(warnings.join(), contains('后空翻'));
    },
  );
}
