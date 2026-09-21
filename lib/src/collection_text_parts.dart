class CollectionTextPart {
  const CollectionTextPart(this.text, [this.audioIndex]);
  final String text;
  final int? audioIndex;
}

/// Match in order, ignoring whitespace but retaining the original display text.
/// Old collections without reliable mappings remain readable as plain text.
List<CollectionTextPart> collectionTextParts(
  String text,
  List speech,
  int audioCount,
) {
  final offsets = <int>[];
  final normalized = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (!RegExp(r'\s').hasMatch(text[i])) {
      normalized.write(text[i]);
      offsets.add(i);
    }
  }
  final searchable = normalized.toString();
  final result = <CollectionTextPart>[];
  var cursor = 0;
  var searchCursor = 0;
  for (final entry in speech) {
    if (entry is! Map ||
        entry['text'] is! String ||
        entry['audioIndex'] is! int) {
      continue;
    }
    final audioIndex = entry['audioIndex'] as int;
    if (audioIndex < 0 || audioIndex >= audioCount) continue;
    final target = (entry['text'] as String).replaceAll(RegExp(r'\s'), '');
    if (target.isEmpty) continue;
    final found = searchable.indexOf(target, searchCursor);
    if (found < 0) continue;
    final start = offsets[found];
    final end = offsets[found + target.length - 1] + 1;
    if (start > cursor) {
      result.add(CollectionTextPart(text.substring(cursor, start)));
    }
    result.add(CollectionTextPart(text.substring(start, end), audioIndex));
    cursor = end;
    searchCursor = found + target.length;
  }
  if (cursor < text.length) {
    result.add(CollectionTextPart(text.substring(cursor)));
  }
  return result;
}
