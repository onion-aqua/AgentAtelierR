import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/llm_dialogue_signal.dart';

void main() {
  test('signal thresholds include each ten-second boundary', () {
    const cases = <int, int>{
      0: 4,
      9999: 4,
      10000: 4,
      10001: 3,
      20000: 3,
      20001: 2,
      30000: 2,
      30001: 1,
      40000: 1,
      40001: 0,
    };
    for (final entry in cases.entries) {
      expect(
        LlmDialogueSignalSampler.barsForLatency(
          Duration(milliseconds: entry.key),
        ),
        entry.value,
        reason: '${entry.key}ms',
      );
    }
  });

  test('updates on tenth reply and holds result until twentieth reply', () {
    var now = Duration.zero;
    final sampler = LlmDialogueSignalSampler(monotonicNow: () => now);
    expect(sampler.bars, isNull);
    for (var round = 1; round <= 20; round++) {
      final turn = sampler.beginTurn(dataRevision: 0);
      now += Duration(seconds: round == 20 ? 25 : 8);
      sampler.receiveContent(turn, 'ライザです。', dataRevision: 0);
      // The rest of a long streamed answer must not degrade the measurement.
      now += const Duration(seconds: 60);
      sampler.receiveContent(turn, '続きの文章。', dataRevision: 0);
      expect(
        sampler.completeTurn(turn, dataRevision: 0),
        round == 10 || round == 20,
      );
      expect(sampler.completedTurns, round);
      expect(sampler.bars, round < 10 ? null : (round < 20 ? 4 : 2));
    }
    expect(sampler.latency, const Duration(seconds: 25));
  });

  test('empty response and cancellation do not count as dialogue rounds', () {
    var now = Duration.zero;
    final sampler = LlmDialogueSignalSampler(monotonicNow: () => now);
    for (var round = 0; round < 9; round++) {
      final turn = sampler.beginTurn(dataRevision: 0);
      sampler.receiveContent(turn, 'text', dataRevision: 0);
      sampler.completeTurn(turn, dataRevision: 0);
    }
    final cancelled = sampler.beginTurn(dataRevision: 0);
    now += const Duration(seconds: 50);
    sampler.receiveContent(cancelled, 'partial text', dataRevision: 0);
    sampler.cancelTurn(cancelled);
    expect(sampler.completeTurn(cancelled, dataRevision: 0), isFalse);
    final empty = sampler.beginTurn(dataRevision: 0);
    sampler.receiveContent(empty, ' \n ', dataRevision: 0);
    expect(sampler.completeTurn(empty, dataRevision: 0), isFalse);
    expect(sampler.completedTurns, 9);
    expect(sampler.bars, isNull);
    final retry = sampler.beginTurn(dataRevision: 0);
    now += const Duration(seconds: 12);
    sampler.receiveContent(retry, 'valid reply', dataRevision: 0);
    expect(sampler.completeTurn(retry, dataRevision: 0), isTrue);
    expect(sampler.bars, 3);
    expect(sampler.completedTurns, 10);
  });

  test('stale save reply cannot change count or invalidate the next reply', () {
    var now = Duration.zero;
    final sampler = LlmDialogueSignalSampler(monotonicNow: () => now);
    for (var round = 0; round < 9; round++) {
      final turn = sampler.beginTurn(dataRevision: 0);
      sampler.receiveContent(turn, 'text', dataRevision: 0);
      sampler.completeTurn(turn, dataRevision: 0);
    }
    final stale = sampler.beginTurn(dataRevision: 0);
    now += const Duration(seconds: 45);
    sampler.receiveContent(stale, 'old save reply', dataRevision: 1);
    expect(sampler.completeTurn(stale, dataRevision: 1), isFalse);
    expect(sampler.completedTurns, 9);
    final current = sampler.beginTurn(dataRevision: 1);
    now += const Duration(seconds: 6);
    sampler.cancelTurn(stale);
    sampler.receiveContent(stale, 'late old content', dataRevision: 1);
    sampler.receiveContent(current, 'new save reply', dataRevision: 1);
    expect(sampler.completeTurn(current, dataRevision: 1), isTrue);
    expect(sampler.bars, 4);
  });

  test(
    'tool content chunks and repeated completion count only one dialogue',
    () {
      final sampler = LlmDialogueSignalSampler();
      final turn = sampler.beginTurn(dataRevision: 0);
      sampler.receiveContent(turn, 'first chunk', dataRevision: 0);
      sampler.receiveContent(turn, 'second chunk', dataRevision: 0);
      sampler.completeTurn(turn, dataRevision: 0);
      sampler.completeTurn(turn, dataRevision: 0);
      expect(sampler.completedTurns, 1);
    },
  );

  test('a failed later sample keeps the prior signal until a valid retry', () {
    var now = Duration.zero;
    final sampler = LlmDialogueSignalSampler(monotonicNow: () => now);
    for (var round = 0; round < 19; round++) {
      final turn = sampler.beginTurn(dataRevision: 0);
      now += const Duration(seconds: 15);
      sampler.receiveContent(turn, 'reply', dataRevision: 0);
      sampler.completeTurn(turn, dataRevision: 0);
    }
    expect(sampler.bars, 3);
    final failed = sampler.beginTurn(dataRevision: 0);
    now += const Duration(seconds: 50);
    sampler.receiveContent(failed, 'partial', dataRevision: 0);
    sampler.cancelTurn(failed);
    expect(sampler.bars, 3);
    expect(sampler.completedTurns, 19);
    final retry = sampler.beginTurn(dataRevision: 0);
    now += const Duration(seconds: 41);
    sampler.receiveContent(retry, 'complete', dataRevision: 0);
    expect(sampler.completeTurn(retry, dataRevision: 0), isTrue);
    expect(sampler.bars, 0);
  });
}
