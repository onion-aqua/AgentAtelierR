import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_posture.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';

void main() {
  test('manual posture wins until released and incompatible changes fail', () {
    final state = CharacterPostureState();
    expect(state.select('sitting_agura', supported: false), isFalse);
    expect(state.sittingId, 'sitting_normal');
    expect(
      state.select('sitting_agura', supported: true, byUser: true),
      isTrue,
    );
    expect(state.select('sitting_normal', supported: true), isFalse);
    expect(state.sittingId, 'sitting_agura');
    state.manual = false;
    expect(state.select('sitting_normal', supported: true), isTrue);
    expect(state.select('invented', supported: true), isFalse);
    state.reset();
    expect(state.manual, isFalse);
  });

  test('normal manual selection locks even when posture does not change', () {
    final state = CharacterPostureState();
    state.select('sitting_normal', supported: true, byUser: true);
    expect(state.manual, isTrue);
    expect(state.select('sitting_agura', supported: true), isFalse);
  });

  test('only Ryza controls posture and posture never reaches TTS', () {
    const text =
        '旁白：[posture:sitting_normal]她坐了下来。\n'
        '莱莎：[happy][face:happy][action:none][posture:sitting_agura]休息一下吧。\n'
        '角色[lent]：[posture:sitting_normal]好。';
    expect(postureCueForAssistantResponse(text), 'sitting_agura');
    final segments = performanceSegmentsForAssistantResponse(
      text,
      fallbackMood: CharacterMood.neutral,
    );
    expect(segments.single.posture, 'sitting_agura');
    expect(segments.single.speechText, isNot(contains('posture')));
    expect(segments.single.speechText, contains('休息一下吧'));
    expect(postureCueForAssistantResponse('莱莎：[posture:invented]好'), isNull);
    expect(postureCueForAssistantResponse('莱莎：[posture:sitting_'), isNull);
  });

  test('posture capability requires actual clip, pose and seated rig', () {
    final group = CharacterMotionGroup.fromJson({
      'GroupId': 'grp_c_test',
      'Label': 'Cross-legged',
      'OccupancyLetters': 'C',
      'AnimName_1': 'leg_clip',
      'Alpha1': '1',
      'ApplicableSittingIDs': 'sitting_agura',
      'ApplicablePoseIds': 'idle',
    });
    CharacterMotionGroup? resolve({
      bool standing = false,
      String pose = 'idle',
      bool exists = true,
    }) => crossLeggedPostureGroup(
      [group],
      standing: standing,
      pose: pose,
      hasAnimation: (_) => exists,
    );
    expect(resolve(), same(group));
    expect(resolve(standing: true), isNull);
    expect(resolve(pose: 'other'), isNull);
    expect(resolve(exists: false), isNull);
  });
}
