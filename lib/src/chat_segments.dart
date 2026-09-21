import 'app_controller.dart';
import 'character_expression.dart';
import 'character_performance.dart';

enum ChatSpeaker { narrator, ryza, character, translation }

class ChatSegment {
  const ChatSegment({
    required this.speaker,
    required this.text,
    this.characterId,
  });

  final ChatSpeaker speaker;
  final String text;
  final String? characterId;
}

final RegExp _speakerPrefix = RegExp(
  r'^\s*(旁白|莱莎|译文|narrator|ryza|translation|角色\s*\[\s*([^\]\r\n]+?)\s*\])\s*[：:]\s*',
  multiLine: true,
  caseSensitive: false,
);
final RegExp _inlineSpeakerPrefix = RegExp(
  r'(旁白|莱莎|译文|narrator|ryza|translation|角色\s*\[\s*([^\]\r\n]+?)\s*\])\s*[：:]',
  caseSensitive: false,
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
  r'\[(?:face|action|posture)\s*:\s*[^\[\]\r\n]+\]',
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
  'unvoiced whispering',
  'whisper',
  'near-whisper',
  'soft tone',
  'breathy',
  'very breathy voice',
  'extremely breathy voiced speech',
  'low volume',
  'low voice',
  'soft intimate voice',
  'soft breathy voice',
  'airy voice',
  'inhale',
  'exhale',
  'sigh',
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
Set<String> get speechDeliveryTags => Set.unmodifiable(_deliveryCues);
Set<String> get speechEmotionTags => Set.unmodifiable(_fishEmotionCues);
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
final RegExp _standaloneAsteriskNarration = RegExp(r'^\s*\*\s*(.+?)\s*\*\s*$');
final RegExp _standaloneUnderscoreNarration = RegExp(r'^\s*＿\s*(.+?)\s*＿\s*$');
final RegExp _metadataLine = RegExp(
  r'^\s*(?:<\|[^\r\n|]+\|>|```+|(?:###\s*)?(?:assistant|user|system)\s*:?)\s*$',
  caseSensitive: false,
);

/// Preserve multiline user narration independently from spoken dialogue.
({String narration, String speech}) parseUserComposerParts(String text) {
  final narration = <String>[];
  final speech = <String>[];
  var isNarration = false;
  for (final line in text.replaceAll('\r\n', '\n').split('\n')) {
    final prefix = RegExp(r'^\s*(旁白(?:上|下)?|发言)\s*[：:]\s*').firstMatch(line);
    if (prefix != null) isNarration = prefix.group(1) != '发言';
    (isNarration ? narration : speech).add(
      prefix == null ? line : line.substring(prefix.end),
    );
  }
  return (
    narration: narration.join('\n').trim(),
    speech: speech.join('\n').trim(),
  );
}

List<ChatSegment> parseAssistantSegments(String response) {
  final segments = <ChatSegment>[];
  ChatSpeaker? activeSpeaker;
  String? activeCharacterId;

  for (final rawLine in _expandInlineSpeakerLines(response)) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    // Chat templates sometimes leak role markers into the visible stream.
    // They are transport metadata, never dialogue and never narration.
    if (_metadataLine.hasMatch(line)) continue;

    final prefix = _speakerPrefix.firstMatch(line);
    if (prefix != null) {
      final label = prefix.group(1)?.toLowerCase();
      activeSpeaker = switch (label) {
        '旁白' => ChatSpeaker.narrator,
        '译文' => ChatSpeaker.translation,
        '莱莎' => ChatSpeaker.ryza,
        'narrator' => ChatSpeaker.narrator,
        'translation' => ChatSpeaker.translation,
        'ryza' => ChatSpeaker.ryza,
        _ => ChatSpeaker.character,
      };
      activeCharacterId = activeSpeaker == ChatSpeaker.character
          ? prefix.group(2)?.toLowerCase()
          : null;
      final content = line.substring(prefix.end).trim();
      if (content.isNotEmpty) {
        segments.add(
          ChatSegment(
            speaker: activeSpeaker,
            text: content,
            characterId: activeCharacterId,
          ),
        );
      }
      continue;
    }

    final asteriskNarration = _standaloneAsteriskNarration.firstMatch(line);
    final underscoreNarration = _standaloneUnderscoreNarration.firstMatch(line);
    final isWrappedNarration =
        _standaloneAction.hasMatch(line) ||
        asteriskNarration != null ||
        underscoreNarration != null;
    final speaker = isWrappedNarration
        ? ChatSpeaker.narrator
        : (activeSpeaker ?? ChatSpeaker.ryza);
    final content =
        asteriskNarration?.group(1) ?? underscoreNarration?.group(1) ?? line;
    segments.add(
      ChatSegment(
        speaker: speaker,
        text: content,
        characterId: speaker == ChatSpeaker.character
            ? activeCharacterId
            : null,
      ),
    );
    // A wrapped aside is a self-contained narration beat. Do not let the
    // following unprefixed dialogue inherit narrator as its speaker.
    if (isWrappedNarration) {
      activeSpeaker = null;
      activeCharacterId = null;
    }
  }

  return segments;
}

/// Some chat-template/Tavern backends emit two speaker-prefixed beats on one
/// physical line. Split those boundaries before the stateful line parser so a
/// narrator beat cannot be swallowed into the preceding Ryza bubble.
Iterable<String> _expandInlineSpeakerLines(String response) sync* {
  for (final rawLine in response.replaceAll('\r\n', '\n').split('\n')) {
    final matches = _inlineSpeakerPrefix.allMatches(rawLine).toList();
    if (matches.length <= 1) {
      yield rawLine;
      continue;
    }
    var cursor = 0;
    for (final match in matches) {
      if (match.start > cursor) yield rawLine.substring(cursor, match.start);
      cursor = match.start;
    }
    yield rawLine.substring(cursor);
  }
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
    final previous = runs.isEmpty ? null : runs.last.first;
    final continuesDialogueTranslation =
        segment.speaker == ChatSpeaker.translation &&
        previous != null &&
        (previous.speaker == ChatSpeaker.ryza ||
            previous.speaker == ChatSpeaker.character ||
            previous.speaker == ChatSpeaker.translation);
    final sameSpeaker =
        previous != null &&
        previous.speaker == segment.speaker &&
        previous.characterId == segment.characterId;
    if (runs.isEmpty || (!sameSpeaker && !continuesDialogueTranslation)) {
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

String? _primaryFishEmotion(String cue) {
  final body = cue.substring(1, cue.length - 1).trim();
  // Delivery cues such as "very breathy voice" are not emotion modifiers.
  if (_deliveryCues.contains(body.toLowerCase())) return null;
  final emotion = body.replaceFirst(_emotionStrengthPrefix, '').trim();
  return _fishEmotionCues.contains(emotion.toLowerCase()) ? emotion : null;
}

String applyFishEmotionIntensity(
  String text,
  TtsEmotionIntensity intensity, {
  bool asmr = false,
}) {
  final ensured = text.trim();
  final match = _leadingFishCue.firstMatch(ensured);
  if (match == null) return ensured;
  final cue = match.group(0)!.trim();
  final baseEmotion = _primaryFishEmotion(cue);
  if (baseEmotion == null) return ensured;

  final replacement = switch (intensity) {
    TtsEmotionIntensity.off => '',
    TtsEmotionIntensity.natural => '[$baseEmotion]',
    _ => '[${_fishPerformanceDirection(baseEmotion, intensity, asmr: asmr)}]',
  };
  return '$replacement${ensured.substring(match.end)}'.trim();
}

/// Applies strength and cue density independently to Fish Audio text.
String applyFishEmotionIntensityPerSentence(
  String text,
  TtsEmotionIntensity intensity, {
  TtsCueDensity density = TtsCueDensity.normal,
  bool asmr = false,
}) {
  final input = text.trim();
  if (input.isEmpty) return input;
  final sentences = input
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
  // Preserve delivery-only or free-form preview cues without inventing a mood.
  String? emotion = _leadingFishCue.hasMatch(input) ? null : 'relaxed';
  var spokenSentenceIndex = 0;
  var totalDeliveryCues = 0;
  final output = <String>[];
  // Density off also disables ASMR-specific performance directions.
  final quietDelivery = asmr && density != TtsCueDensity.off;
  for (final sentence in sentences) {
    var body = sentence;
    String? explicitEmotion;
    final leadingDelivery = StringBuffer();
    while (true) {
      final leading = _leadingFishCue.firstMatch(body);
      if (leading == null) break;
      final cue = leading.group(0)!.trim();
      final primary = _primaryFishEmotion(cue);
      if (primary == null) {
        leadingDelivery.write('$cue ');
      } else {
        explicitEmotion = primary;
      }
      body = body.substring(leading.end).trimLeft();
    }
    if (explicitEmotion != null) emotion = explicitEmotion;
    final sentenceEmotion = emotion;
    body = '$leadingDelivery$body';
    final hasSpeech = body.replaceAll(_fishCue, '').trim().isNotEmpty;
    var sentenceDeliveryCues = 0;
    body = body
        .replaceAllMapped(_fishCue, (match) {
          final cue = match.group(0)!;
          final primary = _primaryFishEmotion(cue);
          if (primary != null) {
            // Respect a deliberate inline transition and inherit it afterwards.
            emotion = primary;
            return applyFishEmotionIntensity(
              cue,
              intensity,
              asmr: quietDelivery,
            );
          }
          final name = cue.substring(1, cue.length - 1).trim().toLowerCase();
          if (!_deliveryCues.contains(name)) return cue;
          final retained = density == TtsCueDensity.sparse
              ? totalDeliveryCues
              : sentenceDeliveryCues;
          if (retained >= inlineCueLimit) return '';
          totalDeliveryCues += 1;
          sentenceDeliveryCues += 1;
          return cue;
        })
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
    if (hasSpeech) {
      // An explicit emotion replaces the inherited one, never stacks with it.
      if (sentenceEmotion != null &&
          (explicitEmotion != null ||
              spokenSentenceIndex % emotionInterval == 0)) {
        body = applyFishEmotionIntensity(
          '[$sentenceEmotion] $body',
          intensity,
          asmr: quietDelivery,
        );
      }
      spokenSentenceIndex += 1;
    }
    // A trailing [pause] is not another sentence to retag.
    if (body.isNotEmpty) output.add(body);
  }
  return output.join(' ');
}

String _fishPerformanceDirection(
  String emotion,
  TtsEmotionIntensity intensity, {
  bool asmr = false,
}) {
  if (asmr) {
    final strength = switch (intensity) {
      TtsEmotionIntensity.restrained => 'slightly',
      TtsEmotionIntensity.vivid => 'clearly',
      TtsEmotionIntensity.dramatic => 'intensely',
      _ => '',
    };
    return '$strength $emotion, expressed through very quiet whispering, '
        'with emotional phrasing and breath timing while keeping the voice hushed';
  }
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
    'sad' ||
    'depressed' ||
    'unhappy' ||
    'lonely' ||
    'disappointed' ||
    'regretful' ||
    'guilty' ||
    'ashamed' => _FishEmotionFamily.melancholy,
    'empathetic' ||
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
    'warm and happy' => _FishEmotionFamily.happy,
    'encouraging' ||
    'grateful' ||
    'hopeful' ||
    'optimistic' ||
    'relieved' ||
    'satisfied' ||
    'friendly' => _FishEmotionFamily.gentlePositive,
    'relaxed' || 'calm' => _FishEmotionFamily.calm,
    _ => _FishEmotionFamily.other,
  };

  return switch ((family, intensity)) {
    (_, TtsEmotionIntensity.restrained) =>
      'slightly $emotion, with subtle and restrained expression',
    (_FishEmotionFamily.happy, TtsEmotionIntensity.vivid) =>
      'clearly $emotion, bright and lively, with expressive phrasing and flowing rhythm',
    (_FishEmotionFamily.happy, TtsEmotionIntensity.dramatic) =>
      'intensely $emotion, with rich joyful expression and continuous rhythmic phrasing',
    (_FishEmotionFamily.gentlePositive, TtsEmotionIntensity.vivid) =>
      'clearly $emotion, with measured warmth and a gradual lift in phrasing',
    (_FishEmotionFamily.gentlePositive, TtsEmotionIntensity.dramatic) =>
      'deeply $emotion, with heartfelt emphasis and a gradual emotional transition',
    (_FishEmotionFamily.curious, TtsEmotionIntensity.vivid) =>
      'clearly $emotion and engaged, with lively questioning intonation',
    (_FishEmotionFamily.curious, TtsEmotionIntensity.dramatic) =>
      'intensely $emotion, with sustained questioning intonation and eager emphasis',
    (_FishEmotionFamily.excited, TtsEmotionIntensity.vivid) =>
      'very $emotion, energetic and animated, with flowing pitch and rhythm',
    (_FishEmotionFamily.excited, TtsEmotionIntensity.dramatic) =>
      'intensely $emotion, with sustained expressive phrasing and energetic rhythm',
    (_FishEmotionFamily.confident, TtsEmotionIntensity.vivid) =>
      'clearly $emotion, with firm emphasis and steady pacing',
    (_FishEmotionFamily.confident, TtsEmotionIntensity.dramatic) =>
      'intensely $emotion, with assured emphasis and deliberate rhythm',
    (_FishEmotionFamily.surprised, TtsEmotionIntensity.vivid) =>
      'clearly $emotion, with a responsive pitch rise and animated reaction',
    (_FishEmotionFamily.surprised, TtsEmotionIntensity.dramatic) =>
      'intensely $emotion, with a marked pitch rise and strong reactive emphasis',
    (_FishEmotionFamily.worried, TtsEmotionIntensity.vivid) =>
      'clearly $emotion, with hesitant phrasing and sustained tension',
    (_FishEmotionFamily.worried, TtsEmotionIntensity.dramatic) =>
      'deeply $emotion, with pronounced tension and weighted hesitant phrasing',
    (_FishEmotionFamily.melancholy, TtsEmotionIntensity.vivid) =>
      'clearly $emotion, with subdued phrasing, weighted words and lingering pauses',
    (_FishEmotionFamily.melancholy, TtsEmotionIntensity.dramatic) =>
      'deeply $emotion, with sustained emotional weight and deliberate subdued phrasing',
    (_FishEmotionFamily.empathetic, TtsEmotionIntensity.vivid) =>
      'clearly $emotion, with attentive phrasing and considered emphasis',
    (_FishEmotionFamily.empathetic, TtsEmotionIntensity.dramatic) =>
      'deeply $emotion, with sustained feeling and heartfelt emphasis',
    (_FishEmotionFamily.angry, TtsEmotionIntensity.vivid) =>
      'clearly $emotion, sharp and direct, with firm emphasis and clipped rhythm',
    (_FishEmotionFamily.angry, TtsEmotionIntensity.dramatic) =>
      'intensely $emotion, with sustained tension, deliberate emphasis and clipped phrasing',
    (_FishEmotionFamily.cold, TtsEmotionIntensity.vivid) =>
      'clearly $emotion, emotionally distant, with flat pitch and clipped phrasing',
    (_FishEmotionFamily.cold, TtsEmotionIntensity.dramatic) =>
      'deeply $emotion, with very flat pitch, terse phrasing and deliberate pauses',
    (_FishEmotionFamily.sarcastic, TtsEmotionIntensity.vivid) =>
      'clearly $emotion, with dry delivery and clipped ironic emphasis',
    (_FishEmotionFamily.sarcastic, TtsEmotionIntensity.dramatic) =>
      'intensely $emotion, with deliberate ironic emphasis and a pointed finish',
    (_FishEmotionFamily.calm, TtsEmotionIntensity.vivid) =>
      'clearly $emotion, with gentle pitch movement and deliberate phrasing',
    (_FishEmotionFamily.calm, TtsEmotionIntensity.dramatic) =>
      'deeply $emotion and immersive, with pronounced gentle prosody, warm emphasis and deliberate pauses',
    (_, TtsEmotionIntensity.vivid) =>
      'clearly $emotion, with expressive phrasing and continuous emotional tone',
    (_, TtsEmotionIntensity.dramatic) =>
      'intensely $emotion, with sustained emotional expression and deliberate emphasis',
    _ => emotion,
  };
}

enum _FishEmotionFamily {
  happy,
  gentlePositive,
  curious,
  excited,
  confident,
  surprised,
  worried,
  melancholy,
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
    this.expressionIntensity = 'normal',
    this.expression,
    this.action,
    this.actions = const [],
    this.motionGroupIds = const [],
    this.actionCueCount = 0,
  });

  final CharacterExpression? expression;
  final String expressionIntensity;
  final CharacterAction? action;
  final List<CharacterAction> actions;
  final List<String> motionGroupIds;
  final int actionCueCount;

  bool get isEmpty =>
      expression == null && action == null && motionGroupIds.isEmpty;
}

class RyzaPerformanceSegment {
  const RyzaPerformanceSegment({
    this.expressionIntensity = 'normal',
    required this.speechText,
    this.expression,
    this.action,
    this.actions = const [],
    this.motionGroupIds = const [],
    this.posture,
  });

  final String speechText;
  final String expressionIntensity;
  final String? posture;
  final CharacterExpression? expression;
  final CharacterAction? action;
  final List<CharacterAction> actions;
  final List<String> motionGroupIds;
}

List<RyzaPerformanceSegment> performanceSegmentsForAssistantResponse(
  String response, {
  required CharacterMood fallbackMood,
}) {
  final result = <RyzaPerformanceSegment>[];
  for (final segment in parseAssistantSegments(response)) {
    if (segment.speaker != ChatSpeaker.ryza) continue;
    CharacterExpression? expression;
    var expressionIntensity = 'normal';
    CharacterAction? action;
    final actions = <CharacterAction>[];
    final motionGroupIds = <String>[];
    final faceMatches = _faceCue.allMatches(segment.text);
    for (final match in faceMatches) {
      expression = characterExpressionFromTag(match.group(1) ?? '');
      expressionIntensity = characterExpressionIntensityFromTag(
        match.group(1) ?? '',
      );
    }
    final actionMatches = _actionCue.allMatches(segment.text);
    for (final match in actionMatches) {
      final raw = match.group(1) ?? '';
      final motionGroupId = characterMotionGroupIdFromTag(raw);
      if (motionGroupId != null) {
        motionGroupIds.add(motionGroupId);
        continue;
      }
      action = characterActionFromTag(raw);
      if (action != CharacterAction.none) actions.add(action);
    }
    final speechText = ensureFishEmotionCue(segment.text, fallbackMood);
    if (speechText.isEmpty) continue;
    result.add(
      RyzaPerformanceSegment(
        speechText: speechText,
        posture: postureCueForAssistantResponse('莱莎：${segment.text}'),
        expression: expression,
        expressionIntensity: expressionIntensity,
        action: action,
        actions: actions,
        motionGroupIds: motionGroupIds,
      ),
    );
  }
  return result;
}

String? postureCueForAssistantResponse(String response) {
  String? posture;
  final cue = RegExp(
    r'\[posture\s*:\s*(sitting_normal|sitting_agura)\s*\]',
    caseSensitive: false,
  );
  for (final segment in parseAssistantSegments(response)) {
    if (segment.speaker != ChatSpeaker.ryza) continue;
    for (final match in cue.allMatches(segment.text)) {
      posture = match.group(1)!.toLowerCase();
    }
  }
  return posture;
}

CharacterPerformanceCue performanceCueForAssistantResponse(String response) {
  CharacterExpression? expression;
  var expressionIntensity = 'normal';
  CharacterAction? action;
  final actions = <CharacterAction>[];
  final motionGroupIds = <String>[];
  var actionCueCount = 0;
  for (final segment in parseAssistantSegments(response)) {
    if (segment.speaker != ChatSpeaker.ryza) continue;
    for (final match in _faceCue.allMatches(segment.text)) {
      expression = characterExpressionFromTag(match.group(1) ?? '');
      expressionIntensity = characterExpressionIntensityFromTag(
        match.group(1) ?? '',
      );
    }
    for (final match in _actionCue.allMatches(segment.text)) {
      actionCueCount += 1;
      // Explicit none must supersede the previous line's action; otherwise its
      // increased cue count replays that old action while streaming.
      final raw = match.group(1) ?? '';
      final motionGroupId = characterMotionGroupIdFromTag(raw);
      if (motionGroupId != null) {
        motionGroupIds.add(motionGroupId);
        continue;
      }
      action = characterActionFromTag(raw);
      if (action != CharacterAction.none) actions.add(action);
    }
  }
  return CharacterPerformanceCue(
    expression: expression,
    expressionIntensity: expressionIntensity,
    action: action,
    actions: actions,
    motionGroupIds: motionGroupIds,
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
          ChatSpeaker.character => '角色[${segment.characterId ?? 'unknown'}]',
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

/// Display indices only: never remove original segments from storage or speech.
List<int> dialogueDisplayIndices(
  List<ChatSegment> segments,
  bool translationOnly,
) => [
  for (var i = 0; i < segments.length; i++)
    if (!translationOnly ||
        !segments.any(
          (segment) => segment.speaker == ChatSpeaker.translation,
        ) ||
        segments[i].speaker == ChatSpeaker.translation)
      i,
];
