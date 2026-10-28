/// Removes standalone tsu breath artifacts after an ellipsis, while preserving
/// Japanese words and quotations such as 待って, …って言った and …つづく.
/// Apply to the accumulated source, never to individual transport deltas: a
/// trailing …っ is hidden until a later て can establish a real word boundary.
/// The original response remains available for diagnostics and export.
String filterJapaneseDialogueArtifacts(String text, {bool streaming = false}) {
  if (!text.contains(RegExp(r'[っつッツ]'))) return text;
  final withoutEllipsisBreaths = text.replaceAllMapped(_ellipsisTsu, (match) {
    final tail = match.group(2)!;
    final end = match.end;
    final next = end < text.length ? text.substring(end, end + 1) : '';
    // A tsu followed immediately by another letter is part of a word. Inline
    // speech cues can occur inside quoted words, so skip them for this check.
    final lastTsu = _cueOrTsu
        .allMatches(tail)
        .lastWhere((token) => token.group(1) == null);
    final gap = tail.substring(lastTsu.end).replaceAll(_inlineCue, '');
    final separated = _horizontalSpace.hasMatch(gap);
    if (next.isNotEmpty && _wordContinuation.hasMatch(next) && !separated) {
      return match.group(0)!;
    }
    final clean = tail.replaceAllMapped(
      _cueOrTsu,
      (token) => token.group(1) ?? '',
    );
    return '${match.group(1)}$clean';
  });
  // Isolated small tsu can also arrive as its own utterance. Keep interjections
  // such as あっ and literal kana inside quotation marks unchanged.
  return withoutEllipsisBreaths.replaceAllMapped(
    _standaloneSmallTsu,
    (match) => match.group(1)!,
  );
}

final _horizontalSpace = RegExp(r'[ \t\u3000]');
final _wordContinuation = RegExp(r'[\p{L}\p{M}\p{N}々ー]', unicode: true);
final _inlineCue = RegExp(r'\[[^\[\]\r\n]{1,80}\]');
final _cueOrTsu = RegExp(r'(\[[^\[\]\r\n]{1,80}\])|[っつッツ]');
const _gap = r'(?:[ \t\u3000\u200B-\u200D\uFEFF]|\[[^\[\]\r\n]{1,80}\])';
final _ellipsisTsu = RegExp(
  '((?:…+|⋯+|‥+|[.．]{2,})$_gap*)'
  '((?:[っつッツ]$_gap*)+)',
);
final _standaloneSmallTsu = RegExp(
  '((?:^|[\\s：:、，,。.!?！？…⋯‥])$_gap*)'
  r'[っッ]+(?=$|[\s、，,。.!?！？…⋯‥])',
  multiLine: true,
);
