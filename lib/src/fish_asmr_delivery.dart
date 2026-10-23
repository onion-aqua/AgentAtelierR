final _asmrTokens = RegExp(
  r'\[[^\[\]\r\n]+\]|<[\s\S]*?>|[\s\S]',
  unicode: true,
);
const _asmrBaselineAliases = {
  'whisper',
  'whispering',
  'unvoiced whispering',
  'near-whisper',
  'soft',
  'soft tone',
  'soft intimate voice',
  'low volume',
};
final _asmrBaselineWrapper = RegExp(
  r'^<\s*/?\s*(?:whisper|soft)\s*>$',
  caseSensitive: false,
);

/// Keeps the whole ASMR synthesis segment in one explicit whisper delivery.
/// Historical soft/whisper cues and wrappers are replaced by a single baseline;
/// spoken words, punctuation, emotion and other independent cues remain intact.
/// Drama 3's existing compiler converts this cue to one paired whisper wrapper.
///
/// Transport cleanup sets [addWhisperBase] false so text without delivery cues
/// stays untagged when the user has disabled delivery controls.
String scopeFishAsmrDelivery(
  String text, {
  bool drama3 = false,
  bool addWhisperBase = true,
}) {
  final tokens = _asmrTokens
      .allMatches(text)
      .map((match) => match.group(0)!)
      .toList();
  var hasBaseline = false;
  final retained = <String>[];
  for (final token in tokens) {
    final bracket = token.startsWith('[') && token.endsWith(']');
    if ((bracket &&
            _asmrBaselineAliases.contains(
              token.substring(1, token.length - 1).trim().toLowerCase(),
            )) ||
        _asmrBaselineWrapper.hasMatch(token)) {
      hasBaseline = true;
      continue;
    }
    retained.add(token);
  }
  if (!addWhisperBase && !hasBaseline) return text;

  final output = StringBuffer();
  var baselineAdded = false;
  for (final token in retained) {
    if (!baselineAdded &&
        token.trim().isNotEmpty &&
        !token.startsWith('[') &&
        !token.startsWith('<')) {
      output.write('[whispering]');
      baselineAdded = true;
    }
    output.write(token);
  }
  // A control-only input must remain empty of synthesized speech.
  return baselineAdded ? output.toString().trim() : text;
}
