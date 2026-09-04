import 'app_controller.dart';
import 'character_expression.dart';
import 'character_performance.dart';

enum ChatSpeaker { narrator, ryza, translation }

class ChatSegment {
  const ChatSegment({required this.speaker, required this.text});

  final ChatSpeaker speaker;
  final String text;
}

final RegExp _speakerPrefix = RegExp(
  r'^\s*(旁白|莱莎|译文)\s*[：:]\s*',
  multiLine: true,
);
final RegExp _fishCue = RegExp(r'\[[^\[\]\r\n]+\]');
final RegExp _faceCue = RegExp(
  r'\[face\s*:\s*([^\[\]\r\n]+)\]',
  caseSensitive: false,
);
final RegExp _actionCue = RegExp(
  r'\[action\s*:\s*([^\[\]\r\n]+)\]',
  caseSensitive: false,
);
final RegExp _appCue = RegExp(
  r'\[(?:face|action)\s*:\s*[^\[\]\r\n]+\]',
  caseSensitive: false,
);
final RegExp _leadingFishCue = RegExp(
  r'^\s*\[(?!face\s*:)[^\[\]\r\n]+\]',
  caseSensitive: false,
);
final RegExp _emotionStrengthPrefix = RegExp(
  r'^(?:slightly|very|extremely)\s+',
  caseSensitive: false,
);
const _deliveryCues = {
  'in a hurry tone',
  'shouting',
  'screaming',
  'whispering',
  'soft tone',
  'emphasis',
  'laughing',
  'chuckling',
  'sobbing',
  'crying loudly',
  'sighing',
  'groaning',
  'panting',
  'gasping',
  'yawning',
  'snoring',
  'clear throat',
  'audience laughing',
  'background laughter',
  'crowd laughing',
  'break',
  'long-break',
  'pause',
  'short pause',
};
const _fishEmotionCues = {
  'relaxed',
  'happy',
  'curious',
  'excited',
  'confident',
  'surprised',
  'worried',
  'empathetic',
  'calm',
  'angry',
  'anxious',
  'ashamed',
  'bored',
  'compassionate',
  'contemptuous',
  'confused',
  'delighted',
  'depressed',
  'determined',
  'disappointed',
  'disdainful',
  'disgusted',
  'doubtful',
  'embarrassed',
  'encouraging',
  'enthusiastic',
  'envious',
  'friendly',
  'frustrated',
  'grateful',
  'guilty',
  'hopeful',
  'hysterical',
  'indifferent',
  'jealous',
  'lonely',
  'moved',
  'mysterious',
  'nervous',
  'nostalgic',
  'optimistic',
  'pessimistic',
  'proud',
  'regretful',
  'relieved',
  'resigned',
  'sad',
  'sarcastic',
  'satisfied',
  'scared',
  'sympathetic',
  'uncertain',
  'unhappy',
  'upset',
  'urgent',
  'warm and happy',
};
final RegExp _standaloneAction = RegExp(r'^\s*[（(].*[）)]\s*$');

List<ChatSegment> parseAssistantSegments(String response) {
  final segments = <ChatSegment>[];
  ChatSpeaker? activeSpeaker;

  for (final rawLine in response.replaceAll('\r\n', '\n').split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final prefix = _speakerPrefix.firstMatch(line);
    if (prefix != null) {
      activeSpeaker = switch (prefix.group(1)) {
        '旁白' => ChatSpeaker.narrator,
        '译文' => ChatSpeaker.translation,
        _ => ChatSpeaker.ryza,
      };
      final content = line.substring(prefix.end).trim();
      if (content.isNotEmpty) {
        segments.add(ChatSegment(speaker: activeSpeaker, text: content));
      }
      continue;
    }

    final speaker = _standaloneAction.hasMatch(line)
        ? ChatSpeaker.narrator
        : (activeSpeaker ?? ChatSpeaker.ryza);
    segments.add(ChatSegment(speaker: speaker, text: line));
  }

  return segments;
}

List<List<ChatSegment>> groupAssistantSegmentsForDisplay(String response) {
  final segments = parseAssistantSegments(response)
      .where((segment) => displayTextForAssistantSegment(segment).isNotEmpty)
      .toList(growable: false);
  if (segments.isEmpty && response.trim().isNotEmpty) {
    return [
      [ChatSegment(speaker: ChatSpeaker.ryza, text: response.trim())],
    ];
  }
  final runs = <List<ChatSegment>>[];
  for (final segment in segments) {
    final narrator = segment.speaker == ChatSpeaker.narrator;
    if (runs.isEmpty ||
        (runs.last.first.speaker == ChatSpeaker.narrator) != narrator) {
      runs.add(<ChatSegment>[]);
    }
    runs.last.add(segment);
  }
  return runs;
}

String fishEmotionForMood(CharacterMood mood) => switch (mood) {
  CharacterMood.neutral => '[relaxed]',
  CharacterMood.happy => '[happy]',
  CharacterMood.concerned => '[empathetic]',
  CharacterMood.excited => '[excited]',
};

String ensureFishEmotionCue(String text, CharacterMood fallbackMood) {
  final trimmed = text.replaceAll(_appCue, '').trim();
  if (trimmed.isEmpty || _leadingFishCue.hasMatch(trimmed)) return trimmed;
  return '${fishEmotionForMood(fallbackMood)} $trimmed';
}

String applyFishEmotionIntensity(String text, TtsEmotionIntensity intensity) {
  final ensured = text.trim();
  final match = _leadingFishCue.firstMatch(ensured);
  if (match == null) return ensured;
  final cue = match.group(0)!.trim();
  final cueBody = cue.substring(1, cue.length - 1).trim();
  final baseEmotion = cueBody.replaceFirst(_emotionStrengthPrefix, '').trim();
  if (_deliveryCues.contains(baseEmotion.toLowerCase())) return ensured;
  if (!_fishEmotionCues.contains(baseEmotion.toLowerCase())) return ensured;

  final replacement = switch (intensity) {
    TtsEmotionIntensity.off => '',
    TtsEmotionIntensity.natural => '[$baseEmotion]',
    _ => '[${_fishPerformanceDirection(baseEmotion, intensity)}]',
  };
  return '$replacement${ensured.substring(match.end)}'.trim();
}

/// Applies strength and cue density independently to Fish Audio text.
String applyFishEmotionIntensityPerSentence(
  String text,
  TtsEmotionIntensity intensity, {
  TtsCueDensity density = TtsCueDensity.normal,
}) {
  final input = text.trim();
  if (input.isEmpty) return input;
  final leading = _leadingFishCue.firstMatch(input);
  final emotion = leading == null
      ? 'relaxed'
      : leading.group(0)!.substring(1, leading.group(0)!.length - 1).trim();
  final body = leading == null
      ? input
      : input.substring(leading.end).trimLeft();
  if (body.isEmpty) return input;
  final sentences = body
      .split(RegExp(r'(?<=[。！？!?；;])\s*|(?<=[.!?])\s+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  final emotionInterval = switch (density) {
    TtsCueDensity.off || TtsCueDensity.sparse => sentences.length + 1,
    TtsCueDensity.normal => 3,
    TtsCueDensity.frequent => 2,
    TtsCueDensity.everySentence => 1,
  };
  final inlineCueLimit = switch (density) {
    TtsCueDensity.off => 0,
    TtsCueDensity.sparse => 1,
    TtsCueDensity.normal => 1,
    TtsCueDensity.frequent => 2,
    TtsCueDensity.everySentence => 999,
  };
  return [
    for (var index = 0; index < sentences.length; index++)
      if (index % emotionInterval == 0)
        applyFishEmotionIntensity(
          '[$emotion] ${_limitInlineDeliveryCues(sentences[index], inlineCueLimit)}',
          intensity,
        )
      else
        _limitInlineDeliveryCues(sentences[index], inlineCueLimit),
  ].join(' ');
}

String _limitInlineDeliveryCues(String text, int limit) {
  var retained = 0;
  return text
      .replaceAllMapped(_fishCue, (match) {
        final cue = match.group(0)!;
        final name = cue.substring(1, cue.length - 1).trim().toLowerCase();
        if (!_deliveryCues.contains(name)) return cue;
        if (retained >= limit) return '';
        retained += 1;
        return cue;
      })
      .replaceAll(RegExp(r' {2,}'), ' ')
      .trim();
}

String _fishPerformanceDirection(
  String emotion,
  TtsEmotionIntensity intensity,
) {
  final normalized = emotion.toLowerCase();
  final family = switch (normalized) {
    'happy' => _FishEmotionFamily.happy,
    'curious' => _FishEmotionFamily.curious,
    'excited' => _FishEmotionFamily.excited,
    'confident' => _FishEmotionFamily.confident,
    'surprised' => _FishEmotionFamily.surprised,
    'worried' ||
    'scared' ||
    'anxious' ||
    'nervous' ||
    'uncertain' => _FishEmotionFamily.worried,
    'empathetic' ||
    'sad' ||
    'compassionate' ||
    'sympathetic' ||
    'moved' => _FishEmotionFamily.empathetic,
    'angry' ||
    'frustrated' ||
    'upset' ||
    'disgusted' ||
    'contemptuous' => _FishEmotionFamily.angry,
    'indifferent' ||
    'resigned' ||
    'bored' ||
    'disdainful' => _FishEmotionFamily.cold,
    'sarcastic' => _FishEmotionFamily.sarcastic,
    'delighted' ||
    'enthusiastic' ||
    'encouraging' ||
    'grateful' ||
    'hopeful' ||
    'friendly' ||
    'warm and happy' => _FishEmotionFamily.happy,
    'relaxed' || 'calm' => _FishEmotionFamily.calm,
    _ => _FishEmotionFamily.other,
  };

  return switch ((family, intensity)) {
    (_, TtsEmotionIntensity.restrained) =>
      'slightly $emotion, with subtle and restrained expression',
    (_FishEmotionFamily.happy, TtsEmotionIntensity.vivid) => 'clearly happy, bright and lively, with noticeable pitch and rhythm changes',
    (_FishEmotionFamily.happy, TtsEmotionIntensity.dramatic) => 'delighted and highly animated, with strong joyful pitch changes and emphatic rhythm',
    (_FishEmotionFamily.curious, TtsEmotionIntensity.vivid) =>
      'genuinely curious and engaged, with lively questioning intonation',
    (_FishEmotionFamily.curious, TtsEmotionIntensity.dramatic) => 'fascinated and intensely curious, with large questioning pitch changes and eager emphasis',
    (_FishEmotionFamily.excited, TtsEmotionIntensity.vivid) => 'very excited, energetic and animated, with quick pitch and rhythm changes',
    (_FishEmotionFamily.excited, TtsEmotionIntensity.dramatic) => 'ecstatic and highly animated, with strong pitch changes, emphatic stress and energetic rhythm',
    (_FishEmotionFamily.confident, TtsEmotionIntensity.vivid) =>
      'clearly confident and spirited, with firm emphasis and lively pacing',
    (_FishEmotionFamily.confident, TtsEmotionIntensity.dramatic) => 'boldly confident and commanding, with powerful emphasis and pronounced rhythmic changes',
    (_FishEmotionFamily.surprised, TtsEmotionIntensity.vivid) =>
      'visibly surprised, with a sharp pitch rise and animated reaction',
    (_FishEmotionFamily.surprised, TtsEmotionIntensity.dramatic) => 'astonished and highly reactive, with a dramatic pitch rise, gasp-like energy and strong emphasis',
    (_FishEmotionFamily.worried, TtsEmotionIntensity.vivid) =>
      'clearly worried and tense, with unsteady pitch and urgent pacing',
    (_FishEmotionFamily.worried, TtsEmotionIntensity.dramatic) => 'deeply anxious and emotionally shaken, with pronounced tension, trembling pitch and urgent emphasis',
    (_FishEmotionFamily.empathetic, TtsEmotionIntensity.vivid) => 'deeply empathetic and tender, with warm expressive phrasing and gentle emphasis',
    (_FishEmotionFamily.empathetic, TtsEmotionIntensity.dramatic) => 'profoundly moved and compassionate, with rich emotional pitch changes and heartfelt emphasis',
    (_FishEmotionFamily.angry, TtsEmotionIntensity.vivid) =>
      'firmly angry, sharp and direct, with hard emphasis and clipped rhythm',
    (_FishEmotionFamily.angry, TtsEmotionIntensity.dramatic) => 'intensely angry and forceful, with sharp attack, strong emphasis and no gentle breathiness',
    (_FishEmotionFamily.cold, TtsEmotionIntensity.vivid) => 'cold, restrained and emotionally distant, with flat pitch and clipped phrasing',
    (_FishEmotionFamily.cold, TtsEmotionIntensity.dramatic) => 'ice-cold and contemptuous, with very flat pitch, terse phrasing and deliberate pauses',
    (_FishEmotionFamily.sarcastic, TtsEmotionIntensity.vivid) =>
      'dryly sarcastic, pointed and dismissive, with clipped ironic emphasis',
    (_FishEmotionFamily.sarcastic, TtsEmotionIntensity.dramatic) => 'sharply sarcastic and cutting, with deliberate ironic emphasis and a hard finish',
    (_FishEmotionFamily.calm, TtsEmotionIntensity.vivid) =>
      'warmly $emotion, with clear gentle pitch movement and deliberate phrasing',
    (_FishEmotionFamily.calm, TtsEmotionIntensity.dramatic) =>
      'deeply $emotion and immersive, with pronounced gentle prosody, warm emphasis and deliberate pauses',
    (_, TtsEmotionIntensity.vivid) =>
      'clearly $emotion, expressive and animated, with noticeable pitch and rhythm changes',
    (_, TtsEmotionIntensity.dramatic) =>
      'intensely $emotion and highly animated, with strong pitch changes, emphatic stress and dynamic rhythm',
    _ => emotion,
  };
}

enum _FishEmotionFamily {
  happy,
  curious,
  excited,
  confident,
  surprised,
  worried,
  empathetic,
  angry,
  cold,
  sarcastic,
  calm,
  other,
}

String stripLeadingTtsCues(String text) {
  var result = text.trim();
  while (true) {
    final match = _leadingFishCue.firstMatch(result);
    if (match == null) return result;
    result = result.substring(match.end).trimLeft();
  }
}

String ttsEmotionInstruction(TtsEmotionIntensity intensity) =>
    intensity.voiceInstruction;

String mergeTtsInstructions(String base, TtsEmotionIntensity intensity) {
  final parts = <String>[
    if (base.trim().isNotEmpty) base.trim(),
    ttsEmotionInstruction(intensity),
  ];
  return parts.join('\n');
}

class CharacterPerformanceCue {
  const CharacterPerformanceCue({
    this.expression,
    this.action,
    this.actionCueCount = 0,
  });

  final CharacterExpression? expression;
  final CharacterAction? action;
  final int actionCueCount;

  bool get isEmpty => expression == null && action == null;
}

class RyzaPerformanceSegment {
  const RyzaPerformanceSegment({
    required this.speechText,
    this.expression,
    this.action,
  });

  final String speechText;
  final CharacterExpression? expression;
  final CharacterAction? action;
}

List<RyzaPerformanceSegment> performanceSegmentsForAssistantResponse(
  String response, {
  required CharacterMood fallbackMood,
}) {
  final result = <RyzaPerformanceSegment>[];
  for (final segment in parseAssistantSegments(response)) {
    if (segment.speaker != ChatSpeaker.ryza) continue;
    CharacterExpression? expression;
    CharacterAction? action;
    final faceMatches = _faceCue.allMatches(segment.text);
    for (final match in faceMatches) {
      expression = characterExpressionFromTag(match.group(1) ?? '');
    }
    final actionMatches = _actionCue.allMatches(segment.text);
    for (final match in actionMatches) {
      final parsed = characterActionFromTag(match.group(1) ?? '');
      if (parsed != CharacterAction.none) action = parsed;
    }
    final speechText = ensureFishEmotionCue(segment.text, fallbackMood);
    if (speechText.isEmpty) continue;
    result.add(
      RyzaPerformanceSegment(
        speechText: speechText,
        expression: expression,
        action: action,
      ),
    );
  }
  return result;
}

CharacterPerformanceCue performanceCueForAssistantResponse(String response) {
  CharacterExpression? expression;
  CharacterAction? action;
  var actionCueCount = 0;
  for (final segment in parseAssistantSegments(response)) {
    if (segment.speaker != ChatSpeaker.ryza) continue;
    for (final match in _faceCue.allMatches(segment.text)) {
      expression = characterExpressionFromTag(match.group(1) ?? '');
    }
    for (final match in _actionCue.allMatches(segment.text)) {
      actionCueCount += 1;
      final parsed = characterActionFromTag(match.group(1) ?? '');
      if (parsed != CharacterAction.none) action = parsed;
    }
  }
  return CharacterPerformanceCue(
    expression: expression,
    action: action,
    actionCueCount: actionCueCount,
  );
}

CharacterExpression expressionForAssistantResponse(String response) {
  return performanceCueForAssistantResponse(response).expression ??
      CharacterExpression.neutral;
}

String ttsTextForAssistantResponse(
  String response, {
  required CharacterMood fallbackMood,
}) {
  return parseAssistantSegments(response)
      .where((segment) => segment.speaker == ChatSpeaker.ryza)
      .map((segment) => ensureFishEmotionCue(segment.text, fallbackMood))
      .where((text) => text.isNotEmpty)
      .join('\n');
}

String displayTextForAssistantResponse(String response) {
  final segments = parseAssistantSegments(response);
  if (segments.isEmpty) return response.trim();
  final hasExplicitSpeaker = _speakerPrefix.hasMatch(response);

  return segments
      .map((segment) {
        final text = segment.text.replaceAll(_fishCue, '').trim();
        if (!hasExplicitSpeaker && segment.speaker == ChatSpeaker.ryza) {
          return text;
        }
        final label = switch (segment.speaker) {
          ChatSpeaker.narrator => '旁白',
          ChatSpeaker.ryza => '莱莎',
          ChatSpeaker.translation => '译文',
        };
        return '$label：$text';
      })
      .where((line) => line.isNotEmpty)
      .join('\n');
}

String displayTextForAssistantSegment(ChatSegment segment) =>
    segment.text.replaceAll(_fishCue, '').trim();

String conversationTextForAssistantResponse(
  String response, {
  required bool showRawOutput,
}) {
  return showRawOutput ? response : displayTextForAssistantResponse(response);
}
