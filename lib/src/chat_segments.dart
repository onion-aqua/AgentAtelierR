import 'app_controller.dart';
import 'character_expression.dart';

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
  final trimmed = text.replaceAll(_faceCue, '').trim();
  if (trimmed.isEmpty || _leadingFishCue.hasMatch(trimmed)) return trimmed;
  return '${fishEmotionForMood(fallbackMood)} $trimmed';
}

CharacterExpression expressionForAssistantResponse(String response) {
  var expression = CharacterExpression.neutral;
  for (final segment in parseAssistantSegments(response)) {
    if (segment.speaker != ChatSpeaker.ryza) continue;
    for (final match in _faceCue.allMatches(segment.text)) {
      expression = characterExpressionFromTag(match.group(1) ?? '');
    }
  }
  return expression;
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
