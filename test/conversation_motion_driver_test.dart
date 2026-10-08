import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_speech_driver.dart';

Map<String, dynamic> _driver({
  String id = 'happy_n_test',
  double yaw = 0.4,
  double pitch = 0.3,
  double roll = 0.2,
}) => {
  'id': id,
  'driver': 'head',
  'yawMin': yaw,
  'yawMax': yaw,
  'pitchMin': pitch,
  'pitchMax': pitch,
  'rollMin': roll,
  'rollMax': roll,
  'transitionMin': 0.6,
  'transitionMax': 0.6,
  'holdMin': 10,
  'holdMax': 10,
  'followers': [
    {'part': 'body', 'scale': 0.6, 'delay': 0.4},
    {'part': 'eye', 'scale': 0.4, 'delay': 0.15},
  ],
};

CharacterPerformanceProfile _profile({
  Map<String, Object?> limits = const {},
  double yaw = 0.4,
  double pitch = 0.3,
  double roll = 0.2,
}) => CharacterPerformanceProfile.parse(
  jsonEncode({
    'projectConfig': {'ambientGaze': limits},
    'emotionalGesture': {
      'DriverDefs': [
        {'Spec': jsonEncode(_driver(yaw: yaw, pitch: pitch, roll: roll))},
      ],
    },
  }),
);

Map<String, RigMotion> _sample(
  CharacterPerformanceDirector director, {
  bool speaking = true,
  bool enhanced = true,
  bool suppressed = false,
  double energy = 0,
}) => director.sample(
  delta: 1 / 60,
  emotion: 'happy',
  speaking: speaking,
  energy: energy,
  suppressed: suppressed,
  enhanceConversation: enhanced,
);

void _sameFrame(Map<String, RigMotion> a, Map<String, RigMotion> b) {
  expect(a.keys, unorderedEquals(b.keys));
  for (final part in a.keys) {
    expect(a[part]!.yaw, closeTo(b[part]!.yaw, 0.0000001));
    expect(a[part]!.pitch, closeTo(b[part]!.pitch, 0.0000001));
    expect(a[part]!.roll, closeTo(b[part]!.roll, 0.0000001));
  }
}

void main() {
  test('enabled conversation strengthens head and body but retains eye and rest motion', () {
    final baseline = CharacterPerformanceDirector(
      _profile(),
      random: Random(5),
    );
    final enhanced = CharacterPerformanceDirector(
      _profile(),
      random: Random(5),
    );
    for (var i = 0; i < 300; i++) {
      _sameFrame(
        _sample(enhanced, speaking: false),
        _sample(baseline, speaking: false, enhanced: false),
      );
    }
    Map<String, RigMotion> ordinary = {};
    Map<String, RigMotion> lively = {};
    for (var i = 0; i < 600; i++) {
      ordinary = _sample(baseline, enhanced: false);
      lively = _sample(enhanced);
      expect(lively['eye']!.yaw, ordinary['eye']!.yaw);
      expect(lively['eye']!.pitch, ordinary['eye']!.pitch);
      expect(lively['eye']!.roll, ordinary['eye']!.roll);
    }
    expect(lively['head']!.yaw, greaterThan(ordinary['head']!.yaw * 1.3));
    expect(lively['body']!.yaw, greaterThan(ordinary['body']!.yaw * 1.4));
    expect(
      lively['head']!.yaw,
      lessThanOrEqualTo(ordinary['head']!.yaw * 1.401),
    );
    expect(
      lively['body']!.yaw,
      lessThanOrEqualTo(ordinary['body']!.yaw * 1.551),
    );
  });

  test('conversation gain enters and leaves without a one-frame pose jump', () {
    final director = CharacterPerformanceDirector(
      _profile(),
      random: Random(2),
    );
    Map<String, RigMotion> frame = {};
    for (var i = 0; i < 900; i++) {
      frame = _sample(director, speaking: false);
    }
    final rest = frame;
    frame = _sample(director);
    for (final part in ['head', 'body']) {
      expect(frame[part]!.yaw - rest[part]!.yaw, inExclusiveRange(0, 0.025));
    }
    for (var i = 0; i < 360; i++) {
      frame = _sample(director);
    }
    final speaking = frame;
    frame = _sample(director, speaking: false);
    for (final part in ['head', 'body']) {
      expect(
        speaking[part]!.yaw - frame[part]!.yaw,
        inExclusiveRange(0, 0.025),
      );
    }
    for (var i = 0; i < 900; i++) {
      frame = _sample(director, speaking: false);
    }
    _sameFrame(frame, rest);
  });

  test('enhanced conversation still ignores rapid audio-energy pulses', () {
    final steady = CharacterPerformanceDirector(_profile(), random: Random(11));
    final pulsed = CharacterPerformanceDirector(_profile(), random: Random(11));
    for (var i = 0; i < 1200; i++) {
      _sameFrame(
        _sample(steady),
        _sample(pulsed, energy: (sin(i * pi * 0.43) + 1) / 2),
      );
    }
  });

  test(
    'suppressed conversation yields to tap gaze and explicit animations',
    () {
      final director = CharacterPerformanceDirector(
        _profile(),
        random: Random(8),
      );
      Map<String, RigMotion> frame = {};
      for (var i = 0; i < 360; i++) {
        frame = _sample(director);
      }
      final active = frame['head']!.yaw;
      frame = _sample(director, suppressed: true);
      expect(frame['head']!.yaw, lessThan(active));
      for (var i = 0; i < 240; i++) {
        frame = _sample(director, suppressed: true);
      }
      for (final part in frame.values) {
        expect(part.yaw.abs(), lessThan(0.000001));
        expect(part.pitch.abs(), lessThan(0.000001));
        expect(part.roll.abs(), lessThan(0.000001));
      }
    },
  );

  test('explicit attitude feedback retains its authored amplitude', () {
    final baseline = CharacterPerformanceDirector(
      _profile(),
      random: Random(3),
    );
    final enhanced = CharacterPerformanceDirector(
      _profile(),
      random: Random(3),
    );
    for (var i = 0; i < 600; i++) {
      _sample(baseline, enhanced: false);
      _sample(enhanced);
    }
    final cue = _driver(id: 'explicit_agree', yaw: -0.3, pitch: 0.2, roll: 0.1);
    baseline.cueAttitude(cue);
    enhanced.cueAttitude(cue);
    for (var i = 0; i < 120; i++) {
      final ordinary = _sample(baseline, enhanced: false);
      final actual = _sample(enhanced);
      expect(enhanced.hasActiveAttitudeCue, isTrue);
      _sameFrame(actual, ordinary);
    }
  });

  test('amplification preserves resource asymmetric axis limits', () {
    const limits = <String, Object?>{
      'yawLimit': 0.25,
      'pitchDownLimit': -0.12,
      'pitchUpLimit': 0.35,
      'rollMinusLimit': -0.10,
      'rollPlusLimit': 0.30,
    };
    for (final sign in [-1.0, 1.0]) {
      final director = CharacterPerformanceDirector(
        _profile(
          limits: limits,
          yaw: sign * 0.8,
          pitch: sign * 0.8,
          roll: sign * 0.8,
        ),
        random: Random(9),
      );
      for (var i = 0; i < 900; i++) {
        final frame = _sample(director);
        for (final part in ['head', 'body']) {
          expect(frame[part]!.yaw, inInclusiveRange(-0.25, 0.25));
          expect(frame[part]!.pitch, inInclusiveRange(-0.12, 0.35));
          expect(frame[part]!.roll, inInclusiveRange(-0.10, 0.30));
        }
      }
    }
  });

  test('ten thousand enhanced frames remain bounded and settle to rest', () {
    final director = CharacterPerformanceDirector(
      _profile(),
      random: Random(7),
    );
    for (var i = 0; i < 10000; i++) {
      final frame = _sample(director, energy: i.isEven ? 0 : 1);
      expect(frame['head']!.yaw, inInclusiveRange(0, 0.56));
      expect(frame['body']!.yaw, inInclusiveRange(0, 0.372));
      expect(frame['eye']!.yaw, inInclusiveRange(0, 0.16));
      for (final part in frame.values) {
        expect(
          part.yaw.isFinite && part.pitch.isFinite && part.roll.isFinite,
          isTrue,
        );
      }
    }
    Map<String, RigMotion> frame = {};
    for (var i = 0; i < 900; i++) {
      frame = _sample(director, speaking: false);
    }
    expect(frame['head']!.yaw, closeTo(0.4 * 0.3, 0.000001));
    expect(frame['body']!.yaw, closeTo(0.4 * 0.6 * 0.3, 0.000001));
  });
}
