import 'package:jp_transliterate/jp_transliterate.dart';

import 'app_localization.dart';

final RegExp _japaneseText = RegExp(r'[\u3040-\u30ff\u3400-\u9fff]');
final RegExp _japaneseKanji = RegExp(r'[\u3400-\u9fff]');
final RegExp _spaceBeforePunctuation = RegExp(r'\s+([。、，！？!?；：:…」』）》〉】\]])');
final RegExp _spaceAfterOpening = RegExp(r'([「『（(《〈【])\s+');

/// CosyVoice 3's mobile tokenizer has no Japanese reading frontend.
///
/// The upstream model examples pass Japanese as spaced katakana. Keeping this
/// conversion here means chat and voice enrollment use the same pronunciation
/// input, while the original Japanese remains visible in the conversation UI.
Future<String> normalizeJapaneseForCosyVoice3(
  String text, {
  AppLanguage preferredLanguage = AppLanguage.japanese,
}) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty || !_japaneseText.hasMatch(trimmed)) return trimmed;

  var katakana = _hiraganaToKatakana(trimmed);
  if (_japaneseKanji.hasMatch(trimmed)) {
    try {
      final words = await JpTransliterate.transliterateWords(kanji: trimmed);
      final converted = words
          .map((word) => word.katakana.trim())
          .where((word) => word.isNotEmpty)
          .join(' ');
      if (converted.isNotEmpty) katakana = converted;
    } on Object {
      // Keep kana-only fallback if the optional platform transliterator is
      // unavailable. The Android plugin is present in production builds.
    }
  }

  // Avoid changing Chinese-only text when a caller explicitly selected it.
  if (preferredLanguage != AppLanguage.japanese &&
      !containsJapaneseKana(trimmed)) {
    return trimmed;
  }
  return katakana
      .replaceAllMapped(_spaceBeforePunctuation, (match) => match.group(1)!)
      .replaceAllMapped(_spaceAfterOpening, (match) => match.group(1)!)
      .trim();
}

/// Returns true when the text contains Japanese hiragana or katakana.
///
/// A voice profile may have a Chinese reference sentence even when the
/// current reply language is Japanese. Such a prompt must stay unchanged so
/// its text still matches the enrolled reference audio.
bool containsJapaneseKana(String text) =>
    RegExp(r'[\u3040-\u30ff]').hasMatch(text);

String _hiraganaToKatakana(String input) => input.runes.map((rune) {
  if (rune >= 0x3041 && rune <= 0x3096) {
    return String.fromCharCode(rune + 0x60);
  }
  return String.fromCharCode(rune);
}).join();
