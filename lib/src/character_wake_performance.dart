import 'dart:math' as math;

import 'package:spine_flutter/spine_flutter.dart';

import 'character_expression.dart';
import 'character_startup_sleep.dart';
import 'character_wake_variants.dart';

/// A local, deterministic greeting. No LLM/TTS request or save mutation.
class CharacterWakePerformance {
  static const touchEnd = 1.0;
  static const stretchEnd = 4.6;
  static const duration = 5.8;

  CharacterWakePerformance({
    required this.state,
    required this.data,
    required String appearanceId,
    required String? pose,
    String sittingId = 'sitting_normal',
    String? touchAnimation,
    int variant = 0,
  }) {
    final preset = characterExpressionPreset(
      appearanceId,
      CharacterExpression.neutral,
    );
    final sleep = resolveStartupSleepFace(appearanceId, _has);
    closedEye = sleep.eye;
    openEye = _available(preset.eye);
    eyebrow = _available(preset.eyebrow);
    restingMouth = _available(preset.mouth);
    yawnMouth = appearanceId == 'standing_99'
        ? _available(preset.lipSync)
        : _available('facial_mouth_017_scrub_01') ?? _available(preset.lipSync);
    tear = _available(
      characterExpressionPreset(appearanceId, CharacterExpression.crying).tear,
    );
    tearOff = _available(
      appearanceId == 'standing_99'
          ? 'facial_add_tear_off'
          : 'facial_add_tear_000_off',
    );
    final motions = CharacterWakeMotions.resolve(
      appearanceId: appearanceId,
      pose: pose,
      sittingId: sittingId,
      hasAnimation: _has,
      touchAnimation: touchAnimation,
      variant: variant,
    );
    touch = motions.touch;
    stretch = motions.stretch;
  }

  final AnimationState state;
  final SkeletonData data;
  late final String? closedEye, openEye, eyebrow, restingMouth, yawnMouth;
  late final String? tear, tearOff, touch, stretch;
  final _owned = <int, TrackEntry>{};
  final _slotAlphas = <Slot, double>{};
  double elapsed = 0;
  int _phase = -1;
  bool _cleared = false;
  bool get finished => elapsed >= duration;
  double get progress => (elapsed / duration).clamp(0, 1);
  static double _smooth(double t) {
    t = t.clamp(0, 1);
    return t * t * (3 - 2 * t);
  }

  double get tearOpacity =>
      .38 * _smooth((elapsed - 2.2) / .6) * (1 - _smooth((elapsed - 4.6) / .7));

  bool _has(String name) => data.findAnimation(name) != null;
  String? _available(String? name) => name != null && _has(name) ? name : null;

  TrackEntry? _set(int track, String? name, {double mix = .25}) {
    if (name == null) return null;
    final entry = state.setAnimationByName(track, name, false)
      ..setMixDuration(mix)
      ..setTimeScale(0)
      ..setMixBlend(MixBlend.replace);
    _owned[track] = entry;
    return entry;
  }

  void restoreSlots() {
    for (final entry in _slotAlphas.entries) {
      final color = entry.key.getColor();
      entry.key.setColor(Color(color.r, color.g, color.b, entry.value));
    }
    _slotAlphas.clear();
  }

  /// Called before animation application, so background suspension pauses the
  /// whole sequence and queued timers cannot silently unlock the composer.
  void advance(double delta) {
    if (_cleared) return;
    restoreSlots();
    elapsed = math.min(
      duration,
      elapsed + (delta.isFinite ? delta.clamp(0.0, .05) : 0),
    );
    final phase = elapsed < touchEnd
        ? 0
        : elapsed < stretchEnd
        ? 1
        : 2;
    if (phase != _phase) {
      _phase = phase;
      if (phase == 0) {
        _set(1, touch, mix: .18);
        _set(11, closedEye);
        _set(12, eyebrow);
        _set(13, restingMouth);
      } else if (phase == 1) {
        state.setEmptyAnimation(1, .35);
        _owned.remove(1);
        _set(2, stretch, mix: .55);
        _set(13, yawnMouth, mix: .5);
        _set(15, tear, mix: .3);
      } else {
        state.setEmptyAnimation(2, .8);
        _owned.remove(2);
        _set(11, openEye, mix: .55);
        _set(13, restingMouth, mix: .55);
      }
    }
    final touchEntry = _owned[1];
    if (phase == 0 && touchEntry != null) {
      touchEntry.setTrackTime(
        touchEntry.getAnimation().getDuration() * _smooth(elapsed / touchEnd),
      );
    }
    final stretchEntry = _owned[2];
    if (phase == 1 && stretchEntry != null) {
      stretchEntry.setTrackTime(
        stretchEntry.getAnimation().getDuration() *
            ((elapsed - touchEnd) / (stretchEnd - touchEnd)).clamp(0, 1),
      );
    }
    final mouth = _owned[13];
    if (phase == 1 && mouth != null && yawnMouth!.contains('scrub')) {
      final opening =
          _smooth((elapsed - touchEnd) / .65) *
          (1 - _smooth((elapsed - 3.8) / .8));
      mouth.setTrackTime(mouth.getAnimation().getDuration() * .65 * opening);
    }
  }

  /// Attachment timelines switch discretely; fading the actual tear slots
  /// makes a small yawn tear appear and disappear without a crying expression.
  void applyTearOpacity(Skeleton skeleton) {
    for (final slot in skeleton.getSlots()) {
      if (!slot.getData().getName().toLowerCase().contains('tear')) continue;
      final color = slot.getColor();
      _slotAlphas[slot] = color.a;
      slot.setColor(Color(color.r, color.g, color.b, color.a * tearOpacity));
    }
  }

  void clear({bool nativeAlive = true}) {
    if (_cleared) return;
    _cleared = true;
    // The Spine child may already have disposed its drawable when the parent
    // screen unmounts. Discard wrappers without dereferencing freed pointers.
    if (!nativeAlive) {
      _slotAlphas.clear();
      _owned.clear();
      return;
    }
    restoreSlots();
    for (final track in _owned.keys) {
      state.setEmptyAnimation(track, .25);
    }
    if (tearOff != null) {
      state.setAnimationByName(15, tearOff!, false).setMixDuration(.2);
    }
    _owned.clear();
  }
}
