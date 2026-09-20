import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/character_state.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final proposal = {
    'state_delta': {
      'mood': 999,
      'energy': -999,
      'closeness': 99,
      'curiosity': 5,
    },
    'emotion': 'curious',
    'reason': '发现新材料',
  };
  test('changes are bounded and each turn settles once', () {
    final next = CharacterState().apply('turn1', proposal);
    expect(next.values, {
      'mood': 5,
      'energy': 60,
      'closeness': 42,
      'curiosity': 55,
    });
    expect(identical(next.apply('turn1', proposal), next), isTrue);
    expect(
      identical(
        next.apply('turn2', {
          'state_delta': {'mood': 'bad'},
          'reason': 'x',
        }),
        next,
      ),
      isTrue,
    );
  });
  test('labels use a deadband instead of oscillating at threshold', () {
    var state = CharacterState(
      values: {'mood': 25, 'energy': 65, 'closeness': 40, 'curiosity': 50},
    );
    state = state.apply('a', {
      'state_delta': {'mood': 5},
      'reason': 'a',
    });
    expect(state.bands['mood'], 1);
    state = state.apply('b', {
      'state_delta': {'mood': 1},
      'reason': 'b',
    });
    expect(state.bands['mood'], 2);
    state = state.apply('c', {
      'state_delta': {'mood': -2},
      'reason': 'c',
    });
    expect(state.bands['mood'], 2);
  });
  test('values, explanation and idempotency survive persistence', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    expect(
      controller.settleCharacterState('t', proposal, controller.dataRevision),
      isTrue,
    );
    expect(controller.exportData()['characterState'], isNotNull);
    expect(
      controller.buildCharacterPrompt(independentPerformance: true),
      contains('发现新材料'),
    );
    await Future<void>.delayed(Duration.zero);
    final restored = await AppController.load();
    expect(restored.characterState.values['closeness'], 42);
    expect(
      restored.settleCharacterState('t', proposal, restored.dataRevision),
      isFalse,
    );
    expect(
      restored.settleCharacterState('new', proposal, restored.dataRevision + 1),
      isFalse,
    );
    controller.dispose();
    restored.dispose();
  });
}
