import 'package:flutter/foundation.dart';

@immutable
class ImageGenerationIntent {
  const ImageGenerationIntent({
    required this.prompt,
    required this.sourceText,
    this.requiresConversationContext = false,
  });

  /// Prompt with the surrounding request wording removed when possible.
  final String prompt;

  /// The original trimmed user message. Keep this for audit and fallback.
  final String sourceText;

  /// A drawing command with no new subject or visual directions. Resolve it
  /// against a snapshot of this conversation rather than drawing the command.
  final bool requiresConversationContext;
}

class ImageGenerationIntentDetector {
  const ImageGenerationIntentDetector();

  static final _contextOnlyRequest = RegExp(
    r'^\s*(?:(?:请|麻烦(?:你)?|拜托(?:你)?|现在|来|能不能|可不可以|可以|帮我|替我|给我)\s*)*'
    r'(?:(?:(?:重新|再来|再)\s*)?'
    r'(?:生图|出图|(?:生成|绘制|画|制作|做|出)\s*'
    r'(?:(?:一|1)?\s*(?:张|幅|个)?\s*(?:图片|图像|插画|图|画)|(?:一|1)\s*(?:张|幅)))|'
    r'(?:再来|来)\s*(?:一|1)\s*(?:张|幅)(?:\s*(?:图片|图像|插画|图))?)'
    r'\s*(?:(?:吧|好吗|可以吗|行吗|谢谢|拜托了)\s*|[，,。.!！?？])*$',
  );

  static final _contextOnlyRetry = RegExp(
    r'^\s*(?:请\s*)?(?:把|将)?\s*'
    r'(?:刚才|上次|之前|这|那)\s*(?:那|这)?\s*(?:一?张)?\s*(?:图片|图像|插画|图)\s*'
    r'(?:重新|再)\s*(?:生成|绘制|画|制作|做|出)\s*'
    r'(?:(?:一|1)\s*(?:张|幅)(?:\s*(?:图片|图像|插画|图))?)?'
    r'\s*(?:(?:吧|好吗|可以吗|行吗|谢谢)\s*|[，,。.!！?？])*$',
  );

  static final _strongRequest = RegExp(
    r'(?:帮我|替我|给我|请|麻烦(?:你)?|拜托(?:你)?|能不能|可不可以|可以(?:帮我|给我)?|来|现在(?:帮我|给我)?|我要|我想要)\s*'
    r'(?:生成|绘制|画|制作|做|出)\s*'
    r'(?:(?:一|1)\s*(?:张|幅|个)?)?',
    caseSensitive: false,
  );

  static final _directQuantifiedRequest = RegExp(
    r'(?:^|[\n，。！？；,:;])\s*'
    r'(?:重新|再)?\s*(?:生成|绘制|画|制作|做|出)\s*'
    r'(?:一|1)\s*(?:张|幅|个)?',
    caseSensitive: false,
  );

  static final _directImageRequest = RegExp(
    r'(?:^|[\n，。！？；,:;])\s*'
    r'(?:重新|再)?\s*(?:生成|绘制|制作)\s*'
    r'(?:图片|图像|插画|壁纸|头像|立绘)',
    caseSensitive: false,
  );

  static final _shortRequest = RegExp(
    r'(?:^|[\n，。！？；,:;])\s*(?:请|帮我|给我|来|重新|再)?\s*'
    r'(?:生图|出图)(?=$|[\s：:，,。.!！?？])',
    caseSensitive: false,
  );

  static final _retryRequest = RegExp(
    r'(?:重新|再)\s*(?:生成|绘制|画|制作|做|出)\s*'
    r'(?:(?:一|1)\s*(?:张|幅|个)?)?',
    caseSensitive: false,
  );

  static final _negative = RegExp(
    r'(?:不要|别|不用|无需|不必|禁止|停止|取消|拒绝|没让你|没有让你|不是让你|暂时不|先不)',
  );

  static final _capabilityQuestion = RegExp(
    r'(?:是否支持|支不支持|会不会|会生成|能否支持|为什么|为何|怎么|如何|怎样|什么是|介绍|说明|教程|接口|功能|价格|费用|多少钱)',
  );

  static final _historicalReference = RegExp(
    r'(?:刚才|之前|上次|以前|历史|已经|曾经|那张|这张|生成过|画过|做过)',
  );

  static final _retrySignal = RegExp(r'(?:重新|再来|再生成|再画|重画|重做)');

  static final _visualEvidence = RegExp(
    r'(?:画|绘制|生图|出图|图片|图像|插画|壁纸|头像|立绘|画面|一\s*张|1\s*张|一\s*幅|1\s*幅)',
  );

  static final _nonImageOutput = RegExp(
    r'(?:一|1)?\s*(?:段|篇|首|份|个)?\s*'
    r'(?:故事|代码|文本|文章|文案|诗歌?|小说|语音|音频|音乐|歌曲|视频|动画|程序|提示词|总结|报告)',
  );

  static final _explicitDrawingVerb = RegExp(r'(?:画|绘制|生图|出图)');

  static final _discussedRequestPrefix = RegExp(
    r'(?:(?:如果|假如|假设|倘若|要是|当|每当|比如|例如)\s*'
    r'(?:我|用户|有人|别人|他|她|你)\s*(?:说|输入|发送|要求|让|请))|'
    r'(?:(?:我|用户|有人|别人|他|她)\s*(?:说过|输入过|发送过|说的是))|'
    r'(?:(?:解释|说明|讨论|分析|介绍|了解|研究|想知道).*)',
  );

  static final _discussedRequestSuffix = RegExp(
    r'(?:是什么意思|这句话什么意思|这(?:句|个)(?:话|请求|命令)?什么意思|'
    r'要多少钱|需要多少(?:钱|积分|费用)|是否收费|是否需要付费|怎么收费|'
    r'会怎么(?:回答|处理|识别)|会不会(?:触发生图|自动生图|被识别为生图请求))'
    r'[吗呢呀]?[？?]?$',
  );

  static final _leadingCommand = RegExp(
    r'^\s*(?:(?:请|麻烦(?:你)?|拜托(?:你)?|现在|来|能不能|可不可以|可以)?\s*'
    r'(?:帮我|替我|给我)?\s*)?'
    r'(?:重新|再)?\s*(?:生成|绘制|画|制作|做|出|生图|出图)\s*'
    r'(?:(?:一|1)\s*(?:张|幅|个)?\s*)?',
    caseSensitive: false,
  );

  static final _leadingImageNoun = RegExp(
    r'^(?:图片|图像|插画|壁纸|头像|立绘|画面|图)\s*'
    r'(?:内容|主题|描述)?\s*(?:是|为|关于|：|:|，|,)?\s*',
  );

  static final _trailingImageNoun = RegExp(
    r'\s*(?:的)?(?:图片|图像|插画)\s*'
    r'(?:吧|好吗|可以吗|谢谢)?[。.!！?？]*$',
  );

  static final _trailingPoliteness = RegExp(
    r'\s*(?:吧|好吗|可以吗|行吗|谢谢|拜托了)[。.!！?？]*$',
  );

  ImageGenerationIntent? detect(String text) {
    final source = text.trim();
    if (source.isEmpty) return null;

    // These whole-message forms contain no subject. Anchoring keeps quoted,
    // negative and hypothetical discussions out of the paid generation path.
    if (_contextOnlyRequest.hasMatch(source) ||
        _contextOnlyRetry.hasMatch(source)) {
      return ImageGenerationIntent(
        prompt: source,
        sourceText: source,
        requiresConversationContext: true,
      );
    }

    final candidates = <({int start, int end, bool strong})>[];
    for (final match in _strongRequest.allMatches(source)) {
      candidates.add((
        start: _trimmedMatchStart(source, match),
        end: match.end,
        strong: true,
      ));
    }
    for (final match in _directQuantifiedRequest.allMatches(source)) {
      candidates.add((
        start: _trimmedMatchStart(source, match),
        end: match.end,
        strong: false,
      ));
    }
    for (final match in _directImageRequest.allMatches(source)) {
      candidates.add((
        start: _trimmedMatchStart(source, match),
        end: match.end,
        strong: false,
      ));
    }
    for (final match in _shortRequest.allMatches(source)) {
      candidates.add((
        start: _trimmedMatchStart(source, match),
        end: match.end,
        strong: false,
      ));
    }
    for (final match in _retryRequest.allMatches(source)) {
      candidates.add((start: match.start, end: match.end, strong: false));
    }
    candidates.sort((a, b) => a.start.compareTo(b.start));

    for (final candidate in candidates) {
      final clauseStart = _clauseStart(source, candidate.start);
      final clauseEnd = _clauseEnd(source, candidate.end);
      final clause = source.substring(clauseStart, clauseEnd).trim();
      final prefix = source.substring(clauseStart, candidate.start);
      if (_insideQuotation(source, candidate.start) ||
          _discussedRequestPrefix.hasMatch(prefix) ||
          _discussedRequestSuffix.hasMatch(
            source.substring(candidate.end, clauseEnd),
          )) {
        continue;
      }
      if (_negative.hasMatch(prefix)) continue;
      if (_negativeCommandTargetsMatch(clause, candidate.start - clauseStart)) {
        continue;
      }
      if (!_hasVisualEvidence(clause)) continue;
      if (!candidate.strong &&
          _capabilityQuestion.hasMatch(clause) &&
          !_retrySignal.hasMatch(clause)) {
        continue;
      }
      if (!candidate.strong &&
          _historicalReference.hasMatch(clause) &&
          !_retrySignal.hasMatch(clause)) {
        continue;
      }
      if (!_hasRequestPayload(source, candidate.end, clauseEnd) &&
          !_mentionsImageNoun(clause)) {
        continue;
      }
      final prompt = _extractPrompt(clause, source);
      return ImageGenerationIntent(prompt: prompt, sourceText: source);
    }
    return null;
  }

  static bool _insideQuotation(String source, int offset) {
    const pairs = <String, String>{
      '“': '”',
      '‘': '’',
      '「': '」',
      '『': '』',
      '"': '"',
      "'": "'",
      '`': '`',
    };
    final closing = <String>[];
    for (var index = 0; index < offset; index++) {
      final character = source[index];
      if (character == r'\' && index + 1 < offset) {
        index++;
        continue;
      }
      if (character == "'" &&
          index > 0 &&
          index + 1 < source.length &&
          RegExp(r'[A-Za-z0-9]').hasMatch(source[index - 1]) &&
          RegExp(r'[A-Za-z0-9]').hasMatch(source[index + 1])) {
        continue;
      }
      if (closing.isNotEmpty && closing.last == character) {
        closing.removeLast();
      } else if (pairs[character] case final end?) {
        closing.add(end);
      }
    }
    return closing.isNotEmpty;
  }

  bool matches(String text) => detect(text) != null;

  static bool _negativeCommandTargetsMatch(String clause, int matchOffset) {
    final before = clause.substring(0, matchOffset.clamp(0, clause.length));
    final negative = _negative.allMatches(before).lastOrNull;
    if (negative == null) return false;
    // A comma or sentence boundary starts a new instruction, so
    // "不要画得太暗，帮我画一张" remains a valid request.
    final between = before.substring(negative.end);
    return !RegExp(r'[，。！？；,:;\n]').hasMatch(between);
  }

  static bool _hasRequestPayload(String source, int end, int clauseEnd) {
    final tail = source.substring(end.clamp(0, source.length), clauseEnd);
    return tail.replaceAll(RegExp(r'[\s：:，,。.!！?？]'), '').isNotEmpty;
  }

  static bool _mentionsImageNoun(String clause) =>
      RegExp(r'(?:图片|图像|插画|壁纸|头像|立绘|画面|一张|一幅|生图|出图)').hasMatch(clause);

  static bool _hasVisualEvidence(String clause) {
    if (!_visualEvidence.hasMatch(clause)) return false;
    if (_nonImageOutput.hasMatch(clause) &&
        !_explicitDrawingVerb.hasMatch(clause)) {
      return false;
    }
    return true;
  }

  static int _trimmedMatchStart(String source, RegExpMatch match) {
    var start = match.start;
    while (start < match.end &&
        RegExp(r'[\s\n，。！？；,:;]').hasMatch(source[start])) {
      start++;
    }
    return start;
  }

  static int _clauseStart(String source, int index) {
    const boundaries = '\n，。！？；,:;';
    var start = index;
    while (start > 0 && !boundaries.contains(source[start - 1])) {
      start--;
    }
    return start;
  }

  static int _clauseEnd(String source, int index) {
    const boundaries = '\n。！？；;';
    var end = index;
    while (end < source.length && !boundaries.contains(source[end])) {
      end++;
    }
    return end;
  }

  static String _extractPrompt(String clause, String fallback) {
    var prompt = clause.trim();
    prompt = prompt.replaceFirst(_leadingCommand, '');
    prompt = prompt.replaceFirst(RegExp(r'^[\s：:，,]+'), '');
    prompt = prompt.replaceFirst(_leadingImageNoun, '');
    prompt = prompt.replaceFirst(RegExp(r'^[\s：:，,]+'), '');
    prompt = prompt.replaceFirst(_trailingImageNoun, '');
    prompt = prompt.replaceFirst(_trailingPoliteness, '');
    prompt = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (prompt.isEmpty) return fallback.trim();
    return prompt;
  }
}

const imageGenerationIntentDetector = ImageGenerationIntentDetector();

ImageGenerationIntent? detectImageGenerationIntent(String text) =>
    imageGenerationIntentDetector.detect(text);
