import 'dart:math';

import 'audio_envelope.dart';

class TtsAudioTooLongException implements Exception {
  const TtsAudioTooLongException({required this.actual, required this.maximum});

  final Duration actual;
  final Duration maximum;
}

/// Facts about the exact request and completed audio. Include local tempo
/// processing when the provider does not expose a numeric speed parameter.
class TtsDurationContext {
  const TtsDurationContext({
    required this.text,
    this.languageCode,
    this.effectiveSpeed = 1.0,
    this.asmr = false,
  });

  final String text;
  final String? languageCode;
  final double effectiveSpeed;
  final bool asmr;
}

/// Duration is a broad plausibility check, not speech recognition. A clip that
/// merely exceeds the normal estimate remains playable; only a large excess is
/// rejected. These estimates cannot prove a model read the right words.
class TtsDurationAssessment {
  const TtsDurationAssessment._({
    required this.actual,
    required this.expected,
    required this.softMaximum,
    required this.maximum,
    required this.languageCode,
    required this.effectiveSpeed,
    required this.spokenUnits,
    required this.pauseBudget,
    required this.hasSpeech,
  });

  final Duration actual;
  final Duration expected;
  final Duration softMaximum;
  final Duration maximum;
  final String languageCode;
  final double effectiveSpeed;
  final double spokenUnits;
  final Duration pauseBudget;
  final bool hasSpeech;

  bool get isOverlong => actual > maximum;
  bool get isSuspicious => !isOverlong && actual > softMaximum;

  String get reason {
    if (!hasSpeech) return 'no_spoken_content';
    if (actual <= Duration.zero) return 'invalid_duration';
    if (isOverlong) return 'excessive_duration';
    if (isSuspicious) return 'longer_than_expected';
    return 'within_expected_range';
  }

  /// Safe to log: no dialogue, cue bodies, URLs or account identifiers.
  Map<String, Object> get summary => {
    'reason': reason,
    'language': languageCode,
    'effectiveSpeed': effectiveSpeed,
    'spokenUnits': (spokenUnits * 100).round() / 100,
    'pauseBudgetMs': pauseBudget.inMilliseconds,
    'actualMs': actual.inMilliseconds,
    'expectedMs': expected.inMilliseconds,
    'softMaximumMs': softMaximum.inMilliseconds,
    'maximumMs': maximum.inMilliseconds,
  };
}

final _inlineCue = RegExp(r'\[[^\[\]\r\n]+\]');

/// Retained for callers that need a display count. Duration estimation below
/// uses pronunciation units rather than assigning equal time to every rune.
int ttsVisibleRuneCount(String text) => text
    .replaceAll(_inlineCue, '')
    .replaceAll(RegExp(r'\s+'), '')
    .trim()
    .runes
    .length;

Duration? ttsAudioDuration(AudioAmplitudeEnvelope? envelope) {
  if (envelope == null) return null;
  final precise = envelope.duration;
  if (precise != null && precise > Duration.zero) return precise;
  if (envelope.values.isEmpty) return null;
  final frameMicros = envelope.frameDuration.inMicroseconds;
  if (frameMicros <= 0) return null;
  // Do not truncate an actual excessive clip to ten minutes: it must remain
  // distinguishable from an accepted clip. Decoders enforce their own limits.
  return Duration(microseconds: frameMicros * envelope.values.length);
}

TtsDurationAssessment assessTtsAudioDuration(
  TtsDurationContext context,
  Duration actual,
) {
  final plain = context.text.replaceAll(_inlineCue, '');
  final language = _language(context.languageCode, plain);
  final speech = _speechMetrics(plain, language);
  final speed = context.effectiveSpeed.isFinite && context.effectiveSpeed > 0
      ? context.effectiveSpeed.clamp(.5, 2.0).toDouble()
      : 1.0;
  if (speech.units == 0) {
    return TtsDurationAssessment._(
      actual: actual,
      expected: Duration.zero,
      softMaximum: Duration.zero,
      maximum: Duration.zero,
      languageCode: language,
      effectiveSpeed: speed,
      spokenUnits: 0,
      pauseBudget: Duration.zero,
      hasSpeech: false,
    );
  }

  var cueSeconds = 0.0;
  var deliveryPace = context.asmr ? 1.35 : 1.0;
  for (final match in _inlineCue.allMatches(context.text)) {
    final tag = match.group(0)!;
    final name = tag.substring(1, tag.length - 1).trim().toLowerCase();
    cueSeconds += _cuePauseSeconds(name);
    // A delivery style applies once to the utterance, never once per tag.
    deliveryPace = max(deliveryPace, _cuePace(name));
  }
  // Extra performance can explain a short pause or laugh, not a minute of
  // unrelated audio. Repeated known tags saturate and unknown cues add no time.
  cueSeconds = min(cueSeconds, min(6.0, speech.seconds * .35 + .9));
  var punctuationSeconds = 0.0;
  for (final match in RegExp(r'[、，,;；:：。.!！？?…]+|\n+').allMatches(plain)) {
    final value = match.group(0)!;
    punctuationSeconds += value.contains('…')
        ? .65
        : RegExp(r'[。.!！？?\n]').hasMatch(value)
        ? .4
        : .2;
  }
  punctuationSeconds = min(punctuationSeconds, speech.seconds * .5 + .8);
  final pauseSeconds = punctuationSeconds + cueSeconds;
  final expectedSeconds =
      (speech.seconds * deliveryPace + pauseSeconds) / speed + .75;
  // Normal variation is logged at the soft boundary. The hard boundary needs
  // a much larger discrepancy before discarding an already generated clip.
  final expected = _duration(expectedSeconds);
  final softMaximum = _duration(expectedSeconds * 1.65 + 1.25);
  final maximum = _duration(expectedSeconds * 2.4 + 2.5);
  return TtsDurationAssessment._(
    actual: actual,
    expected: expected,
    softMaximum: softMaximum,
    maximum: maximum,
    languageCode: language,
    effectiveSpeed: speed,
    spokenUnits: speech.units,
    pauseBudget: _duration(pauseSeconds / speed),
    hasSpeech: true,
  );
}

/// Compatibility wrappers infer language and assume the service's normal speed.
/// Call assessTtsAudioDuration when the exact request's language/speed is known.
Duration maximumTtsAudioDuration(String text, {bool asmr = false}) =>
    assessTtsAudioDuration(
      TtsDurationContext(text: text, asmr: asmr),
      Duration.zero,
    ).maximum;

bool isTtsAudioOverlong(String text, Duration actual, {bool asmr = false}) =>
    assessTtsAudioDuration(
      TtsDurationContext(text: text, asmr: asmr),
      actual,
    ).isOverlong;

Duration _duration(double seconds) =>
    Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());

String _language(String? requested, String plain) {
  final code = requested?.trim().toLowerCase().replaceAll('_', '-') ?? '';
  if (code == 'jp' || code == 'japanese' || code.split('-').first == 'ja') {
    return 'ja';
  }
  if (code == 'chinese' || code.split('-').first == 'zh') return 'zh';
  if (code == 'english' || code.split('-').first == 'en') return 'en';
  if (plain.runes.any(_isKana)) return 'ja';
  if (plain.runes.any(_isHan)) return 'zh';
  return 'en';
}

({double seconds, double units}) _speechMetrics(String plain, String language) {
  var seconds = 0.0;
  var units = 0.0;
  // English words are measured by approximate syllables, not by letter count.
  // Spelled short acronyms use one unit per letter as a conservative fallback.
  final nonLatin = plain.replaceAllMapped(
    RegExp(r"[A-Za-z]+(?:['’][A-Za-z]+)*"),
    (match) {
      final word = match.group(0)!;
      final syllables = _englishSyllables(word);
      units += syllables;
      seconds += syllables * .25;
      return ' ';
    },
  );
  var precedingKana = false;
  for (final rune in nonLatin.runes) {
    if (_isHan(rune)) {
      // Japanese kanji often expand into multiple morae. Without a dictionary,
      // a conservative expansion is safer than treating each as one kana.
      final amount = language == 'ja' ? 2.2 : 1.0;
      units += amount;
      seconds += language == 'ja' ? amount * .16 : .24;
    } else if (_isKana(rune)) {
      final small = const {
        0x3041,
        0x3043,
        0x3045,
        0x3047,
        0x3049,
        0x3083,
        0x3085,
        0x3087,
        0x308e,
        0x30a1,
        0x30a3,
        0x30a5,
        0x30a7,
        0x30a9,
        0x30e3,
        0x30e5,
        0x30e7,
        0x30ee,
        0xff67,
        0xff68,
        0xff69,
        0xff6a,
        0xff6b,
        0xff6c,
        0xff6d,
        0xff6e,
      }.contains(rune);
      if (!small || !precedingKana) {
        units += 1;
        seconds += .16;
      }
      precedingKana = true;
      continue;
    } else if (rune >= 0x30 && rune <= 0x39) {
      units += language == 'ja' ? 2 : 1;
      seconds += language == 'ja' ? .32 : .24;
    } else if (_isOtherSpeechLetter(rune)) {
      // Keep non-English accented letters and other scripts readable without
      // assigning speech time to emoji, markup, or punctuation.
      units += 1;
      seconds += .2;
    }
    if (rune != 0x3099 && rune != 0x309a && rune != 0xff9e && rune != 0xff9f) {
      precedingKana = false;
    }
  }
  return (seconds: seconds, units: units);
}

int _englishSyllables(String word) {
  if (word.length <= 6 && word.length > 1 && word == word.toUpperCase()) {
    return word.length;
  }
  final lower = word.toLowerCase().replaceAll(RegExp("['’]"), '');
  var groups = RegExp(r'[aeiouy]+').allMatches(lower).length;
  if (lower.length > 3 &&
      lower.endsWith('e') &&
      !lower.endsWith('le') &&
      groups > 1) {
    groups -= 1;
  }
  return max(1, groups);
}

bool _isHan(int rune) =>
    rune >= 0x3400 && rune <= 0x4dbf ||
    rune >= 0x4e00 && rune <= 0x9fff ||
    rune >= 0xf900 && rune <= 0xfaff ||
    rune >= 0x20000 && rune <= 0x323af;

bool _isKana(int rune) =>
    rune >= 0x3041 && rune <= 0x3096 ||
    rune >= 0x309d && rune <= 0x309f ||
    rune >= 0x30a1 && rune <= 0x30fa ||
    rune >= 0x30fc && rune <= 0x30ff ||
    rune >= 0xff66 && rune <= 0xff9d;

bool _isOtherSpeechLetter(int rune) =>
    rune >= 0xc0 && rune <= 0x2af && rune != 0xd7 && rune != 0xf7 ||
    rune >= 0x370 && rune <= 0x52f ||
    rune >= 0x5d0 && rune <= 0x5ea ||
    rune >= 0x620 && rune <= 0x64a ||
    rune >= 0x900 && rune <= 0x97f ||
    rune >= 0xac00 && rune <= 0xd7a3;

double _cuePace(String name) => switch (name) {
  'whispering' ||
  'unvoiced whispering' ||
  'whisper' ||
  'near-whisper' ||
  'soft intimate voice' ||
  'soft breathy voice' => 1.2,
  'sad' || 'depressed' || 'calm' || 'slow' || 'slowly' || 'slow speech' => 1.15,
  _ => 1.0,
};

double _cuePauseSeconds(String name) => switch (name) {
  'short pause' => .35,
  'pause' || 'break' => .7,
  'long pause' || 'long-break' => 1.4,
  'inhale' || 'exhale' || 'breath' || 'breathing' => .7,
  'sigh' || 'sighing' || 'yawning' => .9,
  'laughing' || 'sobbing' || 'crying loudly' => 1.2,
  'chuckling' || 'groaning' || 'panting' => .75,
  'gasping' || 'clear throat' => .5,
  _ => 0,
};
