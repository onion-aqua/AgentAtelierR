import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/speech_performance_dispatch.dart';

const _first = RyzaPerformanceSegment(
  speechText: '拍手だね。',
  motionGroupIds: ['grp_fg_024'],
);
const _second = RyzaPerformanceSegment(
  speechText: 'ちゃんと見てね。',
  motionGroupIds: ['recipe4673'],
);
const _third = RyzaPerformanceSegment(speechText: 'できたよ。');

List<int> _ordinals(List<SpeechPerformanceDispatchCue> cues) =>
    cues.map((cue) => cue.ordinal).toList();

void main() {
  group('SpeechPerformanceDispatch', () {
    test(
      'plan arriving after audio completes still dispatches the gesture',
      () {
        final dispatch = SpeechPerformanceDispatch(1);
        expect(dispatch.startPrimary(0), isEmpty);
        expect(dispatch.finishPlayback(), isEmpty);

        final cues = dispatch.setPlan([_first]);
        expect(_ordinals(cues), [0]);
        expect(cues.single.performance.motionGroupIds, ['grp_fg_024']);
        expect(dispatch.finishPlayback(), isEmpty);
      },
    );

    test('plan arriving between lines retains the completed line', () {
      final dispatch = SpeechPerformanceDispatch(2);
      expect(dispatch.startPrimary(0), isEmpty);

      expect(_ordinals(dispatch.setPlan([_first, _second])), [0]);
      expect(_ordinals(dispatch.startPrimary(1)), [1]);
      expect(dispatch.finishPlayback(), isEmpty);
    });

    test('late plan catches up all started lines in original order', () {
      final dispatch = SpeechPerformanceDispatch(3);
      dispatch.startPrimary(0);
      dispatch.startPrimary(1);

      final cues = dispatch.setPlan([_first, _second, _third]);
      expect(_ordinals(cues), [0, 1]);
      expect(cues[0].performance, same(_first));
      expect(cues[1].performance, same(_second));
      expect(_ordinals(dispatch.startPrimary(2)), [2]);
    });

    test(
      'setting the same plan and starting the same line never repeats it',
      () {
        final dispatch = SpeechPerformanceDispatch(2);
        dispatch.startPrimary(0);
        expect(_ordinals(dispatch.setPlan([_first, _second])), [0]);
        expect(dispatch.setPlan([_first, _second]), isEmpty);
        expect(dispatch.startPrimary(0), isEmpty);
        expect(_ordinals(dispatch.finishPlayback()), [1]);
        expect(dispatch.setPlan([_first, _second]), isEmpty);
        expect(dispatch.startPrimary(1), isEmpty);
      },
    );

    test('a ready plan does not dispatch future dialogue lines', () {
      final dispatch = SpeechPerformanceDispatch(3);
      expect(dispatch.setPlan([_first, _second, _third]), isEmpty);
      expect(_ordinals(dispatch.startPrimary(0)), [0]);
      expect(_ordinals(dispatch.startPrimary(1)), [1]);
      expect(dispatch.setPlan([_first, _second, _third]), isEmpty);
    });

    test(
      'finish includes original lines omitted by TTS availability filters',
      () {
        final dispatch = SpeechPerformanceDispatch(3);
        dispatch.setPlan([_first, _second, _third]);
        // The first original primary line has no usable TTS. Playback starts at
        // original ordinal 1, not ordinal 0 of the filtered audio list.
        expect(_ordinals(dispatch.startPrimary(1)), [1]);
        final remaining = dispatch.finishPlayback();
        expect(_ordinals(remaining), [0, 2]);
        expect(remaining.first.performance.motionGroupIds, ['grp_fg_024']);
      },
    );

    test('finish without any playable audio dispatches all primary lines', () {
      final dispatch = SpeechPerformanceDispatch(2);
      dispatch.setPlan([_first, _second]);
      expect(_ordinals(dispatch.finishPlayback()), [0, 1]);
    });

    test(
      'a wrong plan length fails safely without dispatching a guessed row',
      () {
        final dispatch = SpeechPerformanceDispatch(2);
        dispatch.startPrimary(0);
        expect(() => dispatch.setPlan([_first]), throwsFormatException);
        expect(dispatch.startPrimary(1), isEmpty);
        expect(_ordinals(dispatch.setPlan([_first, _second])), [0, 1]);
      },
    );

    test(
      'a rejected replacement preserves the valid plan and dispatch state',
      () {
        final dispatch = SpeechPerformanceDispatch(2);
        dispatch.setPlan([_first, _second]);
        expect(_ordinals(dispatch.startPrimary(0)), [0]);
        expect(() => dispatch.setPlan([_first]), throwsFormatException);
        final cues = dispatch.startPrimary(1);
        expect(_ordinals(cues), [1]);
        expect(cues.single.performance, same(_second));
      },
    );

    test('retained plan is independent of mutations to its source list', () {
      final dispatch = SpeechPerformanceDispatch(1);
      final source = [_first];
      dispatch.setPlan(source);
      source[0] = _second;
      expect(dispatch.startPrimary(0).single.performance, same(_first));
    });

    test('empty dialogue completes without cues', () {
      final dispatch = SpeechPerformanceDispatch(0);
      expect(dispatch.setPlan([]), isEmpty);
      expect(dispatch.finishPlayback(), isEmpty);
      expect(() => dispatch.startPrimary(0), throwsRangeError);
    });

    test('invalid primary count and ordinals are rejected', () {
      expect(() => SpeechPerformanceDispatch(-1), throwsRangeError);
      final dispatch = SpeechPerformanceDispatch(2);
      expect(() => dispatch.startPrimary(-1), throwsRangeError);
      expect(() => dispatch.startPrimary(2), throwsRangeError);
    });
  });
}
