import 'dart:math' as math;
import 'dart:typed_data';

import 'local_call_asr_config.dart';

/// A bounded extra guard for speaker echo after Android's acoustic echo
/// canceller. This is a reference matcher, not a replacement for platform AEC.
/// It compares 2 kHz PCM windows across recent playback delays; correlated
/// audio is replaced with silence so the VAD clock still advances normally.
class LocalCallEchoFilter {
  final _referenceDecoder = LocalCallPcm16Decoder();
  final _microphoneDecoder = LocalCallPcm16Decoder();
  final _reference = <double>[];
  final _microphone = <double>[];
  int _referenceSamples = 0;
  int _microphoneSamples = 0;
  double _referenceSum = 0;
  double _microphoneSum = 0;

  static const _maximumReferenceSamples = 3000;
  static const _windowSamples = 120;
  static const _minimumWindowSamples = 80;
  static const _minimumRms = 0.003;
  static const _echoCorrelation = 0.82;

  /// Reference is the actual 24 kHz mono signed PCM16 submitted to AudioTrack.
  void addPlaybackPcm(Uint8List bytes) {
    for (final sample in _referenceDecoder.decode(bytes)) {
      _referenceSum += sample;
      if (++_referenceSamples % 12 == 0) {
        _reference.add(_referenceSum / 12);
        _referenceSum = 0;
      }
    }
    if (_reference.length > _maximumReferenceSamples) {
      _reference.removeRange(0, _reference.length - _maximumReferenceSamples);
    }
  }

  /// Microphone input is 16 kHz mono signed PCM16 after platform effects.
  Uint8List filter(Uint8List bytes) {
    final decoded = _microphoneDecoder.decode(bytes);
    if (decoded.isEmpty) return bytes;
    var energy = 0.0;
    for (final sample in decoded) {
      energy += sample * sample;
      _microphoneSum += sample;
      if (++_microphoneSamples % 8 == 0) {
        _microphone.add(_microphoneSum / 8);
        _microphoneSum = 0;
      }
    }
    if (_microphone.length > _windowSamples) {
      _microphone.removeRange(0, _microphone.length - _windowSamples);
    }
    if (math.sqrt(energy / decoded.length) < _minimumRms || _isEcho()) {
      return Uint8List(bytes.length);
    }
    return bytes;
  }

  bool _isEcho() {
    final count = _microphone.length;
    if (count < _minimumWindowSamples || _reference.length < count) {
      return false;
    }
    final micMean = _microphone.reduce((a, b) => a + b) / count;
    var micEnergy = 0.0;
    for (final sample in _microphone) {
      micEnergy += (sample - micMean) * (sample - micMean);
    }
    if (micEnergy < 1e-8) return false;
    // At most 3000 x 120 scalar products per microphone packet. No audio or
    // arbitrary history accumulates for the duration of a call.
    for (var start = 0; start + count <= _reference.length; start += 2) {
      var sum = 0.0, energy = 0.0, dot = 0.0;
      for (var i = 0; i < count; i++) {
        final sample = _reference[start + i];
        sum += sample;
        energy += sample * sample;
        dot += sample * (_microphone[i] - micMean);
      }
      final centeredEnergy = energy - sum * sum / count;
      if (centeredEnergy < 1e-8) continue;
      // Polarity can invert between the speaker and microphone paths.
      if (dot.abs() / math.sqrt(micEnergy * centeredEnergy) >=
          _echoCorrelation) {
        return true;
      }
    }
    return false;
  }

  void resetMicrophone() {
    _microphone.clear();
    _microphoneDecoder.reset();
    _microphoneSamples = 0;
    _microphoneSum = 0;
  }

  void reset() {
    _reference.clear();
    _referenceDecoder.reset();
    _referenceSamples = 0;
    _referenceSum = 0;
    resetMicrophone();
  }
}
