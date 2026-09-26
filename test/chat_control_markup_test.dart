import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';

void main() {
  test('private control blocks are removed and answer/code bodies remain', () {
    const response =
        '莱莎：<think>secret</think><answer>你好，<code>print(1)</code></answer>'
        '<tool_call>{"token":"hidden"}</tool_call>'
        '<function_call>run()</function_call>！';

    expect(displayTextForAssistantResponse(response), '莱莎：你好，print(1)！');
    expect(
      ttsTextForAssistantResponse(
        response,
        fallbackMood: CharacterMood.neutral,
      ),
      '[relaxed] 你好，print(1)！',
    );
    expect(
      conversationTextForAssistantResponse(response, showRawOutput: true),
      '莱莎：你好，print(1)！',
    );
  });

  test(
    'streaming fragments never expose partial control tags or hidden text',
    () {
      expect(displayTextForAssistantResponse('莱莎：你好 <thi'), '莱莎：你好');
      expect(displayTextForAssistantResponse('莱莎：你好 <think>hidden'), '莱莎：你好');
      expect(
        displayTextForAssistantResponse('莱莎：你好 <think>hidden</think> 再见'),
        '莱莎：你好  再见',
      );
      expect(
        displayTextForAssistantResponse(r'莱莎：\<answer>好\</answer>'),
        '莱莎：好',
      );
      expect(displayTextForAssistantResponse(r'莱莎：好\<thi'), '莱莎：好');
      expect(filterAssistantControlMarkup('莱莎：a <'), '莱莎：a <');
      expect(filterAssistantControlMarkup('旁白：她看见 <t'), '旁白：她看见 <t');
      expect(filterAssistantControlMarkup('旁白：她看见 <thi>'), '旁白：她看见 <thi>');
      expect(groupAssistantSegmentsForDisplay('<think>private'), isEmpty);
      expect(
        displayTextForAssistantResponse('莱莎：<thinking>保留</thinking>'),
        '莱莎：<thinking>保留</thinking>',
      );
    },
  );

  test('hidden multiline blocks cannot become dialogue segments', () {
    const response = '莱莎：你好。\n<tool_call>\n莱莎：不要显示\n</tool_call>\n莱莎：再见。';
    final segments = parseAssistantSegments(response);
    expect(segments.map((segment) => segment.text), ['你好。', '再见。']);
    expect(displayTextForAssistantResponse(response), '莱莎：你好。\n莱莎：再见。');
  });

  test('an unclosed thinking block yields to the final answer', () {
    const response =
        '<think>draft\n旁白：still private\n'
        '<answer>旁白：书页翻动。\n苏菲：找到配方了。</answer>';
    const expected = '旁白：书页翻动。\n苏菲：找到配方了。';

    expect(displayTextForAssistantResponse(response), expected);
    expect(
      conversationTextForAssistantResponse(response, showRawOutput: true),
      expected,
    );
  });

  test('a final answer marker can close an unfinished tool call', () {
    const response = '<tool_call>{"query":"weather"}<answer>旁白：雨停了。</answer>';
    expect(displayTextForAssistantResponse(response), '旁白：雨停了。');
  });

  test('unclosed thinking does not swallow a new narration paragraph', () {
    const response = '<think>planning text\n\n旁白：她推开工房的门。\n莱莎：欢迎回来。';
    expect(displayTextForAssistantResponse(response), '旁白：她推开工房的门。\n莱莎：欢迎回来。');
    expect(
      conversationTextForAssistantResponse(response, showRawOutput: true),
      '旁白：她推开工房的门。\n莱莎：欢迎回来。',
    );
  });

  test('an unclosed tool call does not swallow a new narration paragraph', () {
    const response = '<tool_call>{"query":"weather"}\n\n旁白：雨停了。';
    expect(displayTextForAssistantResponse(response), '旁白：雨停了。');
  });

  test('a closed private block keeps even speaker-prefixed lines hidden', () {
    const response =
        '<think>planning text\n\n旁白：private draft\n</think>'
        '\n旁白：公开的旁白。';
    expect(displayTextForAssistantResponse(response), '旁白：公开的旁白。');
    expect(
      filterAssistantControlMarkup(
        '<think><answer>private</answer></think>visible',
      ),
      'visible',
    );
  });

  test('a tag cannot consume narration across a newline', () {
    const response = '旁白：旧笔记里有 <think about\n旁白：新的线索。> 就在这里。';
    expect(
      conversationTextForAssistantResponse(response, showRawOutput: true),
      response,
    );
  });
}
