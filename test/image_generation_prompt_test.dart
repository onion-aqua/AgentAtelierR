import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/image_generation_intent.dart';
import 'package:ryza_chat_mvp/src/image_generation_prompt.dart';

void main() {
  final bareIntent = detectImageGenerationIntent('生图')!;

  test(
    'uses active identity, background and recent dialogue without a new LLM',
    () {
      final prompt = buildImageGenerationPrompt(
        intent: bareIntent,
        context: ImageGenerationPromptContext(
          characterName: '苏菲',
          characterProfile: '一位喜欢帮助朋友的炼金术士。',
          worldBackground: '艾德维格是梦中的城镇。',
          location: '工坊 / 窗边',
          storyTime: '第3天 17:30',
          weather: '小雨，18°C',
          appearance: '白色短外套，红色领结',
          history: const [
            ImageGenerationPromptMessage(text: '我们用蓝色的花做花环吧。', isUser: true),
            ImageGenerationPromptMessage(
              text: '旁白：苏菲坐在窗边，把蓝色花朵编进花环。\n苏菲：似合うかな？\n译文：适合我吗？',
              isUser: false,
            ),
          ],
        ),
      );

      for (final detail in [
        '苏菲',
        '炼金术士',
        '梦中的城镇',
        '工坊 / 窗边',
        '第3天 17:30',
        '小雨，18°C',
        '白色短外套，红色领结',
        '用户：我们用蓝色的花做花环吧。',
        '旁白：苏菲坐在窗边，把蓝色花朵编进花环。',
        '苏菲：似合うかな？',
      ]) {
        expect(prompt, contains(detail));
      }
      expect(prompt, isNot(contains('适合我吗？')));
      expect(prompt, contains('本张图片的主角固定为莱莎'));
      expect(prompt, contains('当前对话角色和历史中提及的人物仅用于理解场景，不自动替换莱莎'));
      expect(prompt, startsWith('$contextualImagePromptHeader\n'));
      expect(imageGenerationPromptCaption(prompt), '当前对话场景');
    },
  );

  test(
    'unnamed scene defaults to Ryza while preserving the exact user prompt',
    () {
      final intent = detectImageGenerationIntent('帮我画一张夕阳下的海边工坊的图片')!;
      final prompt = buildImageGenerationPrompt(
        intent: intent,
        context: ImageGenerationPromptContext(
          characterName: '苏菲',
          worldBackground: '不应加入的背景',
        ),
      );
      expect(prompt, startsWith('$explicitImagePromptHeader\n'));
      expect(prompt, contains('默认主要人物为莱莎（ライザリン・シュタウト / Ryza）'));
      expect(
        prompt,
        endsWith('$explicitImagePromptContentMarker\n${intent.prompt}'),
      );
      expect(prompt, isNot(contains('不应加入的背景')));
      expect(imageGenerationPromptCaption(prompt), intent.prompt);
      expect(imageGenerationPromptCaption(intent.prompt), intent.prompt);
    },
  );

  test(
    'explicit characters, groups and no-person requirements take priority',
    () {
      const prompts = [
        '苏菲在梦中的工坊调合药剂',
        '菲在花园里，油画风格',
        '苏菲与普拉芙妲的双人合照',
        '海边的无人风景，不画人物',
        '仅有一束蓝色的花，没有人',
        '莱莎走在海边\n衣服保持原样，夕阳逆光。',
      ];
      for (final userPrompt in prompts) {
        final prompt = buildImageGenerationPrompt(
          intent: ImageGenerationIntent(
            prompt: userPrompt,
            sourceText: userPrompt,
          ),
          context: ImageGenerationPromptContext(characterName: '苏菲'),
        );
        expect(prompt, contains('用户本次对画面的明确要求优先'), reason: userPrompt);
        expect(prompt, contains('就按指定人物及人数绘制'), reason: userPrompt);
        expect(prompt, contains('不额外加入莱莎'), reason: userPrompt);
        expect(prompt, endsWith(userPrompt), reason: userPrompt);
        expect(
          imageGenerationPromptCaption(prompt),
          userPrompt,
          reason: userPrompt,
        );
      }
    },
  );

  test('captions preserve older stored prompts and hide new default rules', () {
    const oldExplicitPrompt = '莱莎在海边';
    const oldContextPrompt = '生成一张与当前角色、世界及最近对话相符的场景插画。\n旧版上下文内容';
    expect(imageGenerationPromptCaption(oldExplicitPrompt), oldExplicitPrompt);
    expect(imageGenerationPromptCaption(oldContextPrompt), '当前对话场景');
    final wrapped = buildImageGenerationPrompt(
      intent: const ImageGenerationIntent(
        prompt: oldExplicitPrompt,
        sourceText: '生图',
      ),
      context: ImageGenerationPromptContext(characterName: '莱莎'),
    );
    final caption = imageGenerationPromptCaption(wrapped);
    expect(caption, oldExplicitPrompt);
    expect(caption, isNot(contains('主要人物选择规则')));
  });

  test(
    'excludes generation notices, failures and internal control material',
    () {
      final prompt = buildImageGenerationPrompt(
        intent: bareIntent,
        context: ImageGenerationPromptContext(
          characterName: '莱莎',
          history: const [
            ImageGenerationPromptMessage(text: '用户想在露台喝茶。', isUser: true),
            ImageGenerationPromptMessage(
              text:
                  '<think>这是隐藏推理ZZZ</think><tool_call>私密工具参数ZZZ</tool_call>'
                  '<answer>旁白：[action:grp_recipe_083][face:happy]莱莎捧起茶杯。\n'
                  '莱莎：[whispering]一緒に飲もう。\n译文：一起喝吧。</answer>'
                  '<horae>内部记忆记录ZZZ</horae>',
              isUser: false,
            ),
            ImageGenerationPromptMessage(text: '图片已生成：旧图片主题ZZZ', isUser: false),
            ImageGenerationPromptMessage(text: '图片生成失败：服务报错ZZZ', isUser: false),
            ImageGenerationPromptMessage(
              text: '连接错误ZZZ',
              isUser: false,
              isFailure: true,
            ),
            ImageGenerationPromptMessage(
              text: '自定义的图片记录ZZZ',
              isUser: false,
              isGeneratedImageRecord: true,
            ),
            ImageGenerationPromptMessage(text: '发言：生图', isUser: true),
          ],
        ),
      );

      expect(prompt, contains('用户想在露台喝茶'));
      expect(prompt, contains('莱莎捧起茶杯'));
      expect(prompt, contains('一緒に飲もう'));
      expect(prompt, isNot(contains('ZZZ')));
      expect(prompt, isNot(contains('grp_recipe')));
      expect(prompt, isNot(contains('[face:')));
      expect(prompt, isNot(contains('[whispering]')));
      expect(prompt, isNot(contains('一起喝吧')));
      expect(prompt, isNot(contains('用户：发言：生图')));
    },
  );

  test('long background cannot crowd out the latest meaningful scene', () {
    final history = [
      const ImageGenerationPromptMessage(text: '极旧海盗主题', isUser: true),
      for (var i = 0; i < 30; i++)
        ImageGenerationPromptMessage(
          text: '第$i轮 ${'旧事' * 800}',
          isUser: i.isEven,
        ),
      const ImageGenerationPromptMessage(text: '现在到了星空下的花园。', isUser: true),
      ImageGenerationPromptMessage(
        text: '旁白：最新场景开头 ${'花园中的长篇描述' * 300} 最新场景结尾萤火虫。',
        isUser: false,
      ),
      const ImageGenerationPromptMessage(text: '生图', isUser: true),
    ];
    final prompt = buildImageGenerationPrompt(
      intent: bareIntent,
      context: ImageGenerationPromptContext(
        characterName: '莱莎',
        characterProfile: '角色背景' * 10000,
        worldBackground: '世界背景' * 10000,
        history: history,
      ),
    );

    expect(prompt.length, lessThan(9000));
    expect(prompt, contains('星空下的花园'));
    expect(prompt, contains('最新场景开头'));
    expect(prompt, contains('最新场景结尾萤火虫'));
    expect(prompt, isNot(contains('极旧海盗主题')));
    expect(prompt.indexOf('星空下的花园'), lessThan(prompt.indexOf('最新场景结尾萤火虫')));
  });

  test('no history still creates a useful active-scene prompt', () {
    final prompt = buildImageGenerationPrompt(
      intent: bareIntent,
      context: ImageGenerationPromptContext(
        characterName: '莱莎',
        location: '库肯岛海边',
      ),
    );
    expect(prompt, contains('库肯岛海边'));
    expect(prompt, contains('暂无有效对话'));
    expect(prompt.trim(), isNot('生图'));
  });

  test('snapshot copies history and does not follow later list mutation', () {
    final history = [
      const ImageGenerationPromptMessage(text: '当前存档中的花园', isUser: true),
    ];
    final snapshot = ImageGenerationPromptContext(
      characterName: '莱莎',
      history: history,
    );
    history
      ..clear()
      ..add(const ImageGenerationPromptMessage(text: '另一个存档的森林', isUser: true));
    final prompt = buildImageGenerationPrompt(
      intent: bareIntent,
      context: snapshot,
    );
    expect(prompt, contains('当前存档中的花园'));
    expect(prompt, isNot(contains('另一个存档的森林')));
  });

  test('truncation preserves Unicode characters at boundaries', () {
    final prompt = buildImageGenerationPrompt(
      intent: bareIntent,
      context: ImageGenerationPromptContext(
        characterName: '🌸' * 100,
        worldBackground: '🌷' * 1500,
        history: [
          ImageGenerationPromptMessage(text: '🌿' * 3000, isUser: true),
        ],
      ),
    );
    final decoded = String.fromCharCodes(prompt.runes);
    expect(decoded, prompt);
    expect(prompt, isNot(contains('\uFFFD')));
  });
}
