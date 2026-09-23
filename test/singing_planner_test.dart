import 'package:flutter_test/flutter_test.dart';

import 'package:ryza_chat_mvp/src/independent_performance_tools.dart';

void main() {
  test('singing plan keeps tags out of the rendered dialogue text', () async {
    final plan = await SingingPlannerTool().plan(
      userInput: '请唱一首轻柔的歌给我听',
      source: '莱莎：[face:happy][action:none]啦啦啦♪',
      complete: (messages) async =>
          '{"segments":[{"id":0,"tags":["singing","soft singing"]}]}',
    );

    final performance = plan.apply(
      '莱莎：[face:happy][action:none]啦啦啦♪',
    );
    expect(performance, contains('[singing][soft singing]'));
    expect(performance, contains('啦啦啦♪'));
  });

  test('invalid singing tags are ignored rather than sent to Fish Audio', () async {
    final plan = await SingingPlannerTool().plan(
      userInput: '请唱歌',
      source: '莱莎：试试看',
      complete: (messages) async =>
          '{"segments":[{"id":0,"tags":["singing","unknown-provider-tag"]}]}',
    );

    expect(plan.tagsBySegment[0], ['singing']);
  });
}
