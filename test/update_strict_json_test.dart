import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/update/strict_json.dart';

void main() {
  test(
    'duplicate keys including escaped aliases are rejected at every depth',
    () {
      expect(
        () => decodeStrictUpdateJson(
          '{"payload":{"release_seq":1,"release_seq":2}}',
        ),
        throwsFormatException,
      );
      expect(
        () => decodeStrictUpdateJson(r'{"a":1,"\u0061":2}'),
        throwsFormatException,
      );
      expect(
        () => decodeStrictUpdateJson('[{"a":1,"a":2}]'),
        throwsFormatException,
      );
    },
  );
  test('strings, nested arrays and repeated keys in separate objects remain valid', () {
    final result = decodeStrictUpdateJson(
      r'{"a":"braces {[,] and quote \"", "nested":[{"a":1},{"a":2}],"b":null}',
    );
    expect((result as Map)['nested'], [
      {'a': 1},
      {'a': 2},
    ]);
    expect(() => decodeStrictUpdateJson('{"a":'), throwsFormatException);
  });
}
