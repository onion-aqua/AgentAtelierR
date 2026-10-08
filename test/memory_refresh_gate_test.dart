import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/memory_refresh_gate.dart';

void main() {
  test('stale completion cannot release a newer refresh after invalidation', () {
    final gate = MemoryRefreshGate();
    final first = gate.begin();
    expect(first, isNotNull);
    expect(gate.running, isTrue);

    // A save switch, manual edit, or failed/aborted model request invalidates
    // the in-flight generation before a replacement refresh starts.
    gate.invalidate(afterLoad: true);
    expect(gate.running, isFalse);
    expect(gate.refreshAfterLoad, isTrue);

    final replacement = gate.begin();
    expect(replacement, isNotNull);
    expect(replacement, isNot(first));
    expect(gate.running, isTrue);

    // The old model future may still complete; it must not unlock replacement.
    expect(gate.finish(first!), isFalse);
    expect(gate.running, isTrue);
    expect(gate.owns(replacement!), isTrue);

    expect(gate.finish(replacement), isTrue);
    expect(gate.running, isFalse);
  });

  test('a failed refresh can be finished without leaving the gate locked', () {
    final gate = MemoryRefreshGate();
    final token = gate.begin();
    expect(token, isNotNull);

    // The caller invokes finish in its finally block after transport errors.
    expect(gate.finish(token!), isTrue);
    expect(gate.running, isFalse);
    expect(gate.begin(), isNotNull);
  });
}
