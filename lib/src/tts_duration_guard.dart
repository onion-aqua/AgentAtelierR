import 'dart:math';

import 'audio_envelope.dart';

class TtsAudioTooLongException implements Exception {
  const TtsAudioTooLongException({required this.actual, required this.maximum});

  final Duration actual;
  final Duration maximum;
}

/// Returns the number of visible speech runes after removing inline TTS cues.
int ttsVisibleRuneCount(String text) {
  final clean = text
      .replaceAll(RegExp(r'\[[^\[\]\r\n]+\]'), '')
      .replaceAll(RegExp(r'\s+'), '')
      .trim();
  return clean.runes.length;
}

Duration? ttsAudioDuration(AudioAmplitudeEnvelope? envelope) {
  if (envelope == null || envelope.values.isEmpty) return null;
  final frameMicros = envelope.frameDuration.inMicroseconds;
  if (frameMicros <= 0) return null;
  return Duration(
    microseconds: min(
      frameMicros * envelope.values.length,
      const Duration(minutes: 10).inMicroseconds,
    ),
  );
}

/// Keeps normal slow, emotional, and ASMR speech playable while rejecting
/// responses that contain a large amount of unintended trailing audio.
Duration maximumTtsAudioDuration(String text, {bool asmr = false}) {
  final runes = ttsVisibleRuneCount(text);
  if (runes == 0) return Duration.zero;
  final baseMilliseconds = max(4000, runes * 320 + 1800);
  final relaxedMilliseconds = asmr
      ? (baseMilliseconds * 1.25).round()
      : baseMilliseconds;
  return Duration(milliseconds: relaxedMilliseconds);
}

bool isTtsAudioOverlong(String text, Duration actual, {bool asmr = false}) {
  final maximum = maximumTtsAudioDuration(text, asmr: asmr);
  return maximum > Duration.zero && actual > maximum;
}
