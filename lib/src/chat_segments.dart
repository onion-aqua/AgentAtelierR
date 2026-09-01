import 'app_controller.dart';
import 'character_expression.dart';
import 'character_performance.dart';

enum ChatSpeaker { narrator, ryza }

class ChatSegment {
  const ChatSegment({required this.speaker, required this.text});

  final ChatSpeaker speaker;
  final String text;
}

final RegExp _speakerPrefix = RegExp(r'^\s*(旁白|莱莎)\s*[：:]\s*', multiLine: true);
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
final RegExp _standaloneAction = RegExp(r'^\s*[（(].*[）)]\s*$');

List<ChatSegment> parseAssistantSegments(String response) {
  final segments = <ChatSegment>[];
  ChatSpeaker? activeSpeaker;

  for (final rawLine in response.replaceAll('\r\n', '\n').split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final prefix = _speakerPrefix.firstMatch(line);
    if (prefix != null) {
      activeSpeaker = prefix.group(1) == '旁白'
          ? ChatSpeaker.narrator
          : ChatSpeaker.ryza;
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
        final label = segment.speaker == ChatSpeaker.narrator ? '旁白' : '莱莎';
        return '$label：$text';
      })
      .where((line) => line.isNotEmpty)
      .join('\n');
}

String conversationTextForAssistantResponse(
  String response, {
  required bool showRawOutput,
}) {
  return showRawOutput ? response : displayTextForAssistantResponse(response);
}
