import 'dart:math';

import 'audio_envelope.dart';
import 'character_resource_behavior.dart';

class CharacterLipSyncDynamics {
  CharacterLipSyncDynamics(this.config);

  final CharacterLipSyncClosure config;
  Duration? _previous;
  double _openness = 0;
  int _closedUntilMicros = 0;

  void reset() {
    _previous = null;
    _openness = 0;
    _closedUntilMicros = 0;
  }

  double sample(AudioAmplitudeEnvelope envelope, Duration position) {
    if (!config.enabled) return envelope.valueAt(position);
    if (_previous != null && position < _previous!) reset();
    final frameMicros = envelope.frameDuration.inMicroseconds;
    if (frameMicros <= 0 || envelope.values.isEmpty) return 0;
    final index = (position.inMicroseconds ~/ frameMicros).clamp(
      0,
      envelope.values.length - 1,
    );
    final energy = envelope.valueAt(position);
    final start = max(
      0,
      index - (config.refWindowMs * 1000 / frameMicros).ceil(),
    );
    var reference = 0.0;
    for (var i = start; i <= index; i++) {
      reference = max(reference, envelope.values[i]);
    }
    final inAudio =
        position.inMicroseconds < frameMicros * envelope.values.length;
    final closed =
        !inAudio ||
        energy < config.dipThreshold ||
        (reference > config.dipThreshold && energy < reference * config.ratio);
    if (closed) {
      _closedUntilMicros = max(
        _closedUntilMicros,
        position.inMicroseconds + (config.minHoldMs * 1000).round(),
      );
    }
    double target = 0;
    if (!closed && position.inMicroseconds >= _closedUntilMicros) {
      if (envelope.rawRms.length == envelope.values.length) {
        final rms = envelope.rawRms[index].clamp(0.000001, config.rmsCeiling);
        final db = 20 * log(rms / config.rmsCeiling) / ln10;
        final range = max(
          1.0,
          config.opennessCeilingDb - config.opennessFloorDb,
        );
        target = ((db - config.opennessFloorDb) / range).clamp(0.0, 1.0);
      } else {
        target = energy;
      }
      target = (target * config.opennessOutputScale).clamp(0.0, 1.0);
    }
    final deltaMs = _previous == null
        ? envelope.frameDuration.inMicroseconds / 1000
        : (position - _previous!).inMicroseconds.clamp(0, 100000) / 1000;
    _previous = position;
    final responseMs = target > _openness
        ? config.attackMs
        : max(config.releaseMs, closed ? config.crossfadeMs : 0);
    _openness +=
        (target - _openness) * (1 - exp(-deltaMs / max(1.0, responseMs)));
    if (target == 0 && _openness < 0.005) _openness = 0;
    return _openness.clamp(0.0, 1.0);
  }
}
