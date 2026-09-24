/// Reduces long repeated punctuation runs before synthesis. This keeps the
/// visible assistant message untouched while preventing TTS engines from
/// over-extending pauses, sighs, or emphatic sounds.
String compressRepeatedTtsPunctuation(String text) {
  final pattern = RegExp(r'([.!?。！？…~～、，,：:；;])\1+');
  return text.replaceAllMapped(pattern, (match) {
    final run = match.group(0)!;
    final keep = (run.runes.length + 1) ~/ 2;
    final codePoint = run.runes.first;
    return String.fromCharCodes(List<int>.filled(keep, codePoint));
  });
}

/// Fish Audio can misread a small tsu after an ellipsis as a breath sound.
/// Keep normal Japanese gemination, such as 待って, unchanged.
String normalizeFishAudioText(String text) {
  final pattern = RegExp(
    r'(?:…+|\.{2,})(?:[ \t\u3000]*\[[a-z][a-z ]*\])*[ \t\u3000]*っ',
  );
  return text.replaceAllMapped(
    pattern,
    (match) => match.group(0)!.substring(0, match.group(0)!.length - 1),
  );
}
