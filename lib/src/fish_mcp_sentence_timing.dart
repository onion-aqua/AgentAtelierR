/// A small, cancellable playback gap for separately synthesized MCP clips.
/// Existing ASMR gaps use the larger minimum rather than adding this twice.
const fishMcpClipPause = Duration(milliseconds: 220);

int clampFishMcpSentencePauseMs(num? value) {
  if (value == null || !value.isFinite) return 220;
  return value.round().clamp(0, 800).toInt();
}

final _tokens = RegExp(
  r'\[[^\[\]\r\n]*\]|<[^<>\r\n]*>|https?://[^\s<>\[\]]+|'
  r'[0-9]+(?:[.,][0-9]+)+|(?:[A-Za-z]\.){2,}|'
  r"[A-Za-z]+(?:['’][A-Za-z]+)*|[\s\S]",
  caseSensitive: false,
  unicode: true,
);
final _pause = RegExp(
  r'^\[\s*(?:(?:short|long)[ -]?)?(?:pause|break)\s*\]$',
  caseSensitive: false,
);
final _spoken = RegExp(r'[A-Za-z0-9\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]');
const _closers = '」』”’"\'）)】]〉》';
const _openers = '「『“‘（(【[〈《';
const _abbreviations = {
  'mr',
  'mrs',
  'ms',
  'dr',
  'prof',
  'sr',
  'jr',
  'st',
  'vs',
  'etc',
  'e.g',
  'i.e',
};

bool _control(String token) =>
    token.startsWith('[') && token.endsWith(']') ||
    token.startsWith('<') && token.endsWith('>');

bool _sentenceEnd(String token) => '。！？!?'.contains(token) && token.length == 1;

/// Add modest pauses only between sentences in Fish MCP synthesis payloads.
/// This runs after noise cleanup and before model-specific tag compilation.
/// It preserves the spoken text and existing controls, never requests audible
/// breathing, and never adds leading/trailing silence or comma-level pauses.
/// Limit automatic cues per clip so short fragmented text cannot grow a long
/// sequence of silence. Explicit pauses satisfy the boundary without stacking.
String addFishMcpSentencePauses(String text, {int sentencePauseMs = 220}) {
  final milliseconds = clampFishMcpSentencePauseMs(sentencePauseMs);
  if (milliseconds == 0) return text;
  final cue = milliseconds < 400
      ? '[short pause]'
      : milliseconds < 700
      ? '[pause]'
      : '[long pause]';
  final tokens = _tokens.allMatches(text).map((m) => m.group(0)!).toList();
  final insertions = <int>{};
  var hasSpeech = false;
  var added = tokens.where(_pause.hasMatch).length;
  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    if (_control(token)) continue;
    final newline = token == '\n' || token == '\r';
    var boundary = _sentenceEnd(token) || newline;
    if (token == '.') {
      final previous = index > 0 ? tokens[index - 1].toLowerCase() : '';
      // Decimal numbers, URLs and dotted initialisms are indivisible tokens.
      // A remaining dot needs a separator to avoid splitting a domain/name.
      final next = index + 1 < tokens.length ? tokens[index + 1] : '';
      boundary =
          !_abbreviations.contains(previous) &&
          !RegExp(r'^[a-z]$').hasMatch(previous) &&
          (next.trim().isEmpty || _closers.contains(next) || _control(next));
    }
    if (!boundary || !hasSpeech) {
      if (_spoken.hasMatch(token)) hasSpeech = true;
      continue;
    }

    var end = index;
    var cursor = index + 1;
    var existingPause = false;
    var nextSpeech = false;
    var pastOpener = false;
    while (cursor < tokens.length) {
      final next = tokens[cursor];
      if (_control(next)) {
        existingPause |= _pause.hasMatch(next);
      } else if (next.length == 1 &&
          (_openers.contains(next) ||
              next == '"' && tokens[cursor - 1].trim().isEmpty)) {
        // A quoted next sentence is still speech. Keep the cue before its
        // opening quote rather than inserting it inside the quotation.
        pastOpener = true;
      } else if (next.trim().isEmpty ||
          _sentenceEnd(next) ||
          next == '.' ||
          next.length == 1 && _closers.contains(next)) {
        // Keep the pause outside closing quotes, and retain all original
        // whitespace. Consecutive punctuation/newlines form one boundary.
        if (!pastOpener) end = cursor;
      } else {
        nextSpeech = _spoken.hasMatch(next);
        break;
      }
      cursor++;
    }
    if (nextSpeech && !existingPause && added < 6) {
      insertions.add(end);
      added++;
    }
    hasSpeech = false;
    // Do not treat a punctuation run or its closing quote as another sentence.
    index = cursor - 1;
  }
  if (insertions.isEmpty) return text;
  final output = StringBuffer();
  for (var index = 0; index < tokens.length; index++) {
    output.write(tokens[index]);
    if (insertions.contains(index)) output.write(cue);
  }
  return output.toString();
}
