import 'dart:convert';

/// Uses the SDK parser for JSON grammar, then checks object keys before callers
/// canonicalize the parsed map. JsonDecoder alone silently keeps the last
/// occurrence of a duplicate key, which is forbidden by the signed protocol.
Object? decodeStrictUpdateJson(String source) {
  final value = jsonDecode(source);
  final stack = <_JsonContainer>[];
  for (var index = 0; index < source.length; index++) {
    switch (source.codeUnitAt(index)) {
      case 0x7b: // {
        stack.add(_JsonContainer.object());
      case 0x5b: // [
        stack.add(_JsonContainer.array());
      case 0x7d || 0x5d: // } ]
        stack.removeLast();
      case 0x2c: // ,
        if (stack.isNotEmpty && stack.last.keys != null) {
          stack.last.expectsKey = true;
        }
      case 0x22: // "
        final start = index;
        index++;
        while (source.codeUnitAt(index) != 0x22) {
          if (source.codeUnitAt(index) == 0x5c) index++;
          index++;
        }
        if (stack.isNotEmpty && stack.last.expectsKey) {
          final container = stack.last;
          final key = jsonDecode(source.substring(start, index + 1)) as String;
          if (!container.keys!.add(key)) {
            throw const FormatException('Duplicate JSON object key');
          }
          container.expectsKey = false;
        }
    }
  }
  return value;
}

class _JsonContainer {
  _JsonContainer.object() : keys = <String>{}, expectsKey = true;
  _JsonContainer.array() : keys = null, expectsKey = false;

  final Set<String>? keys;
  bool expectsKey;
}
