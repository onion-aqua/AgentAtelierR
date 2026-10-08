import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/motion_candidate_search.dart';

/// Small semantic catalogue used by the retrieval contract tests.  The real
/// catalogue has the same semantic fields in its generated descriptions, but
/// is too large and too resource-specific for a unit test fixture.
const _catalogue = <String, String>{
  'grp_fg_wave': '双手挥手问候；区域=手部；类别=挥手；occupancy=FG',
  'grp_fg_clap': '双手拍手；区域=手部；类别=拍手；occupancy=FG',
  'grp_c_01': '双脚轻轻晃动；区域=腿部；类别=晃脚；occupancy=C',
  'grp_eh_10': '身体左右轻晃；区域=身体；类别=轻晃；occupancy=E',
};

void main() {
  test('an explicit hand area request stays inside the hand branch', () {
    final result = selectMotionCandidates(_catalogue, '请做一个手部动作', limit: 2);

    expect(result, isNotEmpty);
    expect(result.keys, everyElement(startsWith('grp_fg_')));
    expect(result.keys, isNot(contains('grp_c_01')));
    expect(result.keys, isNot(contains('grp_eh_10')));
  });

  test('an explicit leg area request stays inside the leg branch', () {
    final result = selectMotionCandidates(_catalogue, '来一个腿部动作', limit: 2);

    expect(result, isNotEmpty);
    expect(result.keys, everyElement(equals('grp_c_01')));
    expect(result.keys, isNot(contains('grp_fg_wave')));
    expect(result.keys, isNot(contains('grp_eh_10')));
  });

  test('an explicit body area request stays inside the body branch', () {
    final result = selectMotionCandidates(_catalogue, '让身体轻轻晃动', limit: 2);

    expect(result, isNotEmpty);
    expect(result.keys, everyElement(equals('grp_eh_10')));
    expect(result.keys, isNot(contains('grp_fg_wave')));
    expect(result.keys, isNot(contains('grp_c_01')));
  });

  test('an unsupported drive-away request never falls back to waving', () {
    final result = selectMotionCandidates(
      _catalogue,
      '请做出驱赶的动作，把它赶走',
      limit: 4,
    );

    expect(result.keys, isNot(contains('grp_fg_wave')));
    expect(result.keys, isNot(contains('grp_fg_clap')));
    expect(result.keys, isNot(contains('grp_c_01')));
    expect(result.keys, isNot(contains('grp_eh_10')));
  });

  test('an unspecified hand gesture selects only a hand candidate', () {
    final result = selectMotionCandidates(_catalogue, '随便来一个自然的手部动作', limit: 1);

    expect(result, hasLength(1));
    expect(result.keys.single, startsWith('grp_fg_'));
  });

  test('a multi-region request can retrieve both branches', () {
    final result = selectMotionCandidates(_catalogue, '身体轻晃，同时挥手问候', limit: 4);

    expect(result.keys, contains('grp_eh_10'));
    expect(result.keys, contains('grp_fg_wave'));
    expect(result.keys, isNot(contains('grp_c_01')));
  });
}
