import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/image_generation_intent.dart';

void main() {
  group('ImageGenerationIntentDetector', () {
    const detector = ImageGenerationIntentDetector();

    test('recognizes common Chinese image requests and extracts prompts', () {
      final cases = <String, String>{
        '帮我生成一张莱莎在海边的图片': '莱莎在海边',
        '请画一张夕阳下的工坊': '夕阳下的工坊',
        '给我绘制一个动漫风头像': '动漫风头像',
        '做一张蓝紫渐变壁纸吧': '蓝紫渐变壁纸',
        '生成图片：莱莎坐在窗边': '莱莎坐在窗边',
        '生图：水彩风格的库肯岛': '水彩风格的库肯岛',
        '来，帮我画可爱的菲': '可爱的菲',
        '重新生成一张夜景图': '夜景图',
      };

      for (final MapEntry(key: source, value: prompt) in cases.entries) {
        final result = detector.detect(source);
        expect(result, isNotNull, reason: source);
        expect(result!.prompt, prompt, reason: source);
        expect(result.sourceText, source, reason: source);
        expect(result.requiresConversationContext, isFalse, reason: source);
      }
    });

    test('keeps an auditable fallback when a request has no prompt', () {
      expect(detector.detect('生成一张图片')?.prompt, '生成一张图片');
      expect(detector.detect('生图')?.prompt, '生图');
    });

    test('bare polite and retry commands resolve the conversation scene', () {
      const requests = [
        '生图',
        '生图吧',
        '请帮我生图，谢谢',
        '生成一张图片',
        '生成图片',
        '帮我生成一个图片',
        '给我生成张图',
        '请画一幅画',
        '帮我画画',
        '请画一张',
        '画图',
        '重新生成一张图片吧',
        '再来一张',
        '再生图',
        '把刚才那张图重新生成一张',
      ];
      for (final request in requests) {
        expect(
          detector.detect(request)?.requiresConversationContext,
          isTrue,
          reason: request,
        );
      }
    });

    test('explicit styling or a new subject keeps its own prompt', () {
      const requests = ['生图：动漫风', '重新生成一张夜景图片', '帮我画一张莱莎坐在海边的图片', '生成图片：蓝色背景'];
      for (final request in requests) {
        expect(
          detector.detect(request)?.requiresConversationContext,
          isFalse,
          reason: request,
        );
      }
    });

    test('does not trigger on negation or cancellation', () {
      const messages = [
        '不要生成图片',
        '请不要帮我画一张图',
        '别画一张莱莎的图',
        '无需生成一张图片',
        '我没让你帮我生成图片',
        '暂时不生图',
        '取消生成一张图片',
      ];
      for (final message in messages) {
        expect(detector.detect(message), isNull, reason: message);
      }
    });

    test('a negative style constraint does not hide a later request', () {
      final result = detector.detect('不要画得太暗，帮我画一张莱莎在海边的图片');
      expect(result, isNotNull);
      expect(result!.prompt, '莱莎在海边');
    });

    test('does not trigger on history, capability, or feature discussion', () {
      const messages = [
        '刚才生成的图片很好看',
        '之前画的图放在哪里？',
        '你会生成图片吗？',
        '是否支持生成图片？',
        '生成图片要多少钱？',
        '怎么生成图片？',
        '请介绍一下生图功能',
        '我想了解生成图片的接口格式',
        '把刚才生成的图片打开',
      ];
      for (final message in messages) {
        expect(detector.detect(message), isNull, reason: message);
      }
    });

    test('non-image creation requests never call the paid image flow', () {
      const messages = [
        '帮我做一个蛋糕',
        '请制作一瓶精力剂',
        '帮我生成一段故事',
        '帮我生成一段代码',
        '请生成一篇文章',
        '给我制作一首歌曲',
        '帮我生成一个炼金配方',
        '生成一段图像处理代码',
        '帮我生成一个头像提示词',
      ];
      for (final message in messages) {
        expect(detector.detect(message), isNull, reason: message);
      }
    });

    test('quoted commands and hypothetical discussions do not generate', () {
      const messages = [
        '莱莎说“帮我画一张猫”是什么意思？',
        '有人发了「请画一张海边」这句话',
        '解释一下 `帮我生成一张图片` 的意思',
        '如果我说帮我画一张猫，你会怎么回答？',
        '假如用户要求帮我生成一张猫的图片，会发生什么？',
        '当我输入帮我画一张猫的时候会触发生图吗？',
        '帮我画一张猫要多少钱？',
        '能解释一下帮我画一张猫是什么意思吗？',
        '我想知道帮我生成一张图片是否需要付费',
      ];
      for (final message in messages) {
        expect(detector.detect(message), isNull, reason: message);
      }
    });

    test(
      'real drawing requests retain quoted and conditional scene content',
      () {
        const messages = [
          '请画一张她说着“你好”的场景',
          '帮我画一张写着“帮我画一张猫”的海报',
          '请画一张“如果下雨就撑伞”的插画',
          '帮我画一张如果下雨莱莎就撑伞的场景',
          '如果可以，请帮我画一张猫',
          '如果可以帮我画一张猫',
          '莱莎，帮我画一张海边的图片',
          '请画一张写着“生成图片要多少钱”的海报',
          '帮我画一张她担心会不会被发现的插画',
        ];
        for (final message in messages) {
          expect(detector.detect(message), isNotNull, reason: message);
        }
      },
    );

    test('explicit retry of an earlier result remains a request', () {
      expect(detector.detect('把刚才那张图重新生成一张')?.prompt, isNotEmpty);
      expect(detector.detect('刚才画过了，再画一张夜景')?.prompt, '夜景');
    });

    test('requires concrete payload for bare drawing helpers', () {
      expect(detector.detect('帮我画'), isNull);
      expect(detector.detect('帮我画猫'), isNotNull);
      expect(detector.detect('画一张'), isNotNull);
      expect(detector.matches('给我做一张角色立绘'), isTrue);
    });
  });
}
