import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/conversation_motion_policy.dart';

bool _leg({
  bool speaking = true,
  String sittingId = 'sitting_normal',
  String occupancy = 'C',
  String groupId = 'grp_c_01',
  double roll = 0,
  bool resourcesReady = true,
  Duration? sinceLastLeg,
  bool paused = false,
  bool tapActive = false,
  bool gazeActive = false,
  bool explicitMotionActive = false,
  bool pendingExplicit = false,
}) => ConversationMotionPolicy.shouldPlayLeg(
  speaking: speaking,
  sittingId: sittingId,
  occupancy: occupancy,
  groupId: groupId,
  roll: roll,
  resourcesReady: resourcesReady,
  sinceLastLeg: sinceLastLeg,
  paused: paused,
  tapActive: tapActive,
  gazeActive: gazeActive,
  explicitMotionActive: explicitMotionActive,
  pendingExplicit: pendingExplicit,
);

void main() {
  test(
    'conversation broad motion grows without changing rest or eye motion',
    () {
      for (final part in ['head', 'body']) {
        final rest = ConversationMotionPolicy.partScale(part, talkStrength: 0);
        final talk = ConversationMotionPolicy.partScale(part, talkStrength: 1);
        expect(rest, 1);
        expect(talk, greaterThan(rest));
        expect(talk, lessThanOrEqualTo(1.6));
      }
      for (final part in ['eye', 'unknown']) {
        expect(ConversationMotionPolicy.partScale(part, talkStrength: 1), 1);
      }
    },
  );

  test('speech gain follows the eased blend without a state-toggle jump', () {
    for (final part in ['head', 'body']) {
      final rest = ConversationMotionPolicy.partScale(part, talkStrength: 0);
      final first = ConversationMotionPolicy.partScale(
        part,
        talkStrength: 0.01,
      );
      final halfway = ConversationMotionPolicy.partScale(
        part,
        talkStrength: 0.5,
      );
      final full = ConversationMotionPolicy.partScale(part, talkStrength: 1);
      expect(first - rest, inExclusiveRange(0, 0.01));
      expect(halfway, closeTo((rest + full) / 2, 0.000001));
      expect(
        ConversationMotionPolicy.partScale(part, talkStrength: double.nan),
        rest,
      );
      expect(ConversationMotionPolicy.partScale(part, talkStrength: -1), rest);
      expect(ConversationMotionPolicy.partScale(part, talkStrength: 2), full);
    }
  });

  test('leg beats wait at least six seconds even during long speech', () {
    expect(_leg(sinceLastLeg: const Duration(seconds: -1)), isFalse);
    expect(_leg(sinceLastLeg: const Duration(seconds: 5)), isFalse);
    expect(_leg(sinceLastLeg: const Duration(milliseconds: 5999)), isFalse);
    expect(_leg(sinceLastLeg: const Duration(seconds: 6)), isTrue);
    expect(_leg(sinceLastLeg: const Duration(seconds: 12)), isTrue);
    expect(_leg(), isTrue);
  });

  test(
    'speaking beats happen more often while authored rest timing is intact',
    () {
      const authoredRest = (minimum: 7.5, maximum: 14.0);
      final rest = ConversationMotionPolicy.intervalSeconds(
        speaking: false,
        idleMinimum: authoredRest.minimum,
        idleMaximum: authoredRest.maximum,
      );
      final talk = ConversationMotionPolicy.intervalSeconds(
        speaking: true,
        idleMinimum: authoredRest.minimum,
        idleMaximum: authoredRest.maximum,
      );
      expect(rest, authoredRest);
      expect(talk.minimum, greaterThan(0));
      expect(talk.maximum, greaterThanOrEqualTo(talk.minimum));
      expect(talk.maximum, lessThan(rest.minimum));
    },
  );

  test('speech provides frequent leg opportunities without allowing posture clips', () {
    final random = Random(41);
    var selected = 0;
    for (var i = 0; i < 10000; i++) {
      if (_leg(roll: random.nextDouble())) selected++;
    }
    // Previous speech policy allowed 15% of beats. The new cadence is noticeably
    // more frequent but leaves most beats available for torso/attention motion.
    expect(selected / 10000, greaterThan(0.35));
    expect(selected / 10000, lessThan(0.55));
    for (final unsafe in ['grp_c_02', 'grp_c_03', 'grp_c_99', 'unknown', '']) {
      expect(_leg(groupId: unsafe), isFalse, reason: unsafe);
    }
    expect(_leg(occupancy: 'CE'), isFalse);
    expect(_leg(occupancy: ''), isFalse);
  });

  test(
    'explicit head body and legs clips all take priority over natural motion',
    () {
      // Each authored part can influence downstream rig constraints. Yield to
      // any explicit clip instead of trying to infer overlap from its display name.
      for (final part in ['head', 'body', 'legs']) {
        expect(
          ConversationMotionPolicy.canAnimate(
            resourcesReady: true,
            explicitMotionActive: true,
          ),
          isFalse,
          reason: part,
        );
        expect(_leg(explicitMotionActive: true), isFalse, reason: part);
      }
      expect(_leg(pendingExplicit: true), isFalse);
      expect(
        ConversationMotionPolicy.canAnimate(
          resourcesReady: true,
          pendingExplicit: true,
        ),
        isFalse,
      );
    },
  );

  test('tap and finger gaze own movement until their response has ended', () {
    expect(_leg(tapActive: true), isFalse);
    expect(_leg(gazeActive: true), isFalse);
    expect(
      ConversationMotionPolicy.canAnimate(
        resourcesReady: true,
        tapActive: true,
      ),
      isFalse,
    );
    expect(
      ConversationMotionPolicy.canAnimate(
        resourcesReady: true,
        gazeActive: true,
      ),
      isFalse,
    );
    expect(_leg(), isTrue);
  });

  test(
    'idle, cross-legged, standing and missing resources never gain foot swings',
    () {
      expect(_leg(speaking: false), isFalse);
      for (final sitting in [
        'sitting_agura',
        'standing',
        'static',
        '',
        'unknown',
      ]) {
        expect(_leg(sittingId: sitting), isFalse, reason: sitting);
      }
      expect(_leg(resourcesReady: false), isFalse);
      expect(_leg(paused: true), isFalse);
      expect(
        ConversationMotionPolicy.canAnimate(resourcesReady: false),
        isFalse,
      );
    },
  );

  test(
    'speech leg alpha improves visibility and never alters rest clip alpha',
    () {
      final speech = ConversationMotionPolicy.alphaScale(
        speaking: true,
        occupancy: 'C',
        groupId: 'grp_c_01',
      );
      expect(speech, greaterThan(0.45));
      expect(speech, lessThan(1));
      expect(
        ConversationMotionPolicy.alphaScale(
          speaking: false,
          occupancy: 'C',
          groupId: 'grp_c_01',
        ),
        1,
      );
      expect(
        ConversationMotionPolicy.alphaScale(
          speaking: true,
          occupancy: 'FG',
          groupId: 'grp_fg_024',
        ),
        1,
      );
    },
  );

  test(
    'malformed timing and chance inputs cannot create rapid or forced beats',
    () {
      final interval = ConversationMotionPolicy.intervalSeconds(
        speaking: false,
        idleMinimum: double.nan,
        idleMaximum: double.infinity,
      );
      expect(interval.minimum.isFinite, isTrue);
      expect(interval.maximum.isFinite, isTrue);
      expect(interval.minimum, greaterThan(1));
      expect(interval.maximum, greaterThanOrEqualTo(interval.minimum));
      for (final chance in [double.nan, double.infinity, -1.0, 1.0]) {
        expect(_leg(roll: chance), isFalse);
      }
    },
  );
}
