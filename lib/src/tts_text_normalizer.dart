import 'fish_asmr_delivery.dart';
import 'japanese_dialogue_filter.dart';

/// Reduces long repeated punctuation runs before synthesis. This keeps the
/// visible assistant message untouched while preventing TTS engines from
/// over-extending pauses, sighs, or emphatic sounds.
String compressRepeatedTtsPunctuation(String text) {
  final pattern = RegExp(r'([.!?。！？…~～、，,：:；;])\1+');
  return text.replaceAllMapped(pattern, (match) {
    final run = match.group(0)!;
    final keep = (run.runes.length + 1) ~/ 2;
    final codePoint = run.runes.first;
    return String.fromCharCodes(List<int>.filled(keep, codePoint));
  });
}

/// Fish Audio can misread a small tsu after an ellipsis as a breath sound.
/// Keep normal Japanese gemination, such as 待って, unchanged.
String normalizeFishAudioText(String text) =>
    filterJapaneseDialogueArtifacts(text);

/// Keep spoken words intact. Fish performs delivery tags as audio; repeated
/// breath instructions can turn a short line into a long breathing sequence.
/// Apply at the transport boundary so saved plans and old prompts are covered.
String normalizeFishAudioSynthesisText(String text, {bool asmr = false}) {
  var input = normalizeFishAudioText(text);
  input = input.replaceAllMapped(RegExp(r'([.!?。！？…~～、，,：:；;])\1+'), (match) {
    final mark = match.group(1)!;
    final limit = mark == '.'
        ? 3
        : mark == '…'
        ? 2
        : 1;
    return mark * limit;
  });
  final cue = RegExp(r'\[([^\[\]\r\n]+)\]');
  final spoken = input.replaceAll(cue, '').trim();
  var whisperAdded = false;
  var pauseCount = 0;
  var effectCount = 0;
  final maximumPauses = (spoken.runes.length ~/ 80 + 1).clamp(1, 3);
  final result = input.replaceAllMapped(cue, (match) {
    var name = match.group(1)!.trim().replaceAll(RegExp(r'\s+'), ' ');
    final lower = name.toLowerCase();
    final breath = RegExp(
      r'\b(?:breath(?:y|iness|ing|s)?|inhale|exhale|panting|gasping|gasp|wheezing|airy)\b|喘息|喘气|吸气|呼气|气声|呼吸|喘氣|吸氣|呼氣|氣聲|息遣い|吐息|息を吸|息を吐',
      caseSensitive: false,
    ).hasMatch(lower);
    final whisper = lower.contains('whisper');
    if (breath || whisper) {
      // Compound emotion directions may include breath timing. Preserve their
      // emotion clause while keeping only an explicitly requested whisper.
      final first = name.split(',').first.trim();
      final emotional = RegExp(
        r'^(?:(?:slightly|very|extremely|clearly|intensely)\s+)?(?:happy|sad|angry|relaxed|calm|curious|worried|hopeful|excited|confident|shy|surprised|empathetic|friendly|grateful|relieved|nervous)\b',
        caseSensitive: false,
      ).hasMatch(first);
      final emotion = emotional ? '[$first]' : '';
      if (whisper && !whisperAdded) {
        whisperAdded = true;
        return '$emotion[whispering]';
      }
      return emotion;
    }
    if (RegExp(
      r'^(?:(?:short|long)[ -]?)?(?:pause|break)$',
      caseSensitive: false,
    ).hasMatch(lower)) {
      if (pauseCount++ >= maximumPauses ||
          input.substring(match.end).replaceAll(cue, '').trim().isEmpty) {
        return '';
      }
      return '[short pause]';
    }
    if (RegExp(
      r'\b(?:sigh(?:ing)?|groaning|sobbing|yawning|snoring)\b|叹气|嘆氣|呻吟|啜泣|打哈欠|打鼾|ため息|あくび|いびき',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return '';
    }
    if (RegExp(
      r'\b(?:laughing|chuckling|crying|screaming|shouting)\b',
      caseSensitive: false,
    ).hasMatch(lower)) {
      if (effectCount++ >= 1) return '';
    }
    name = name.replaceAll(RegExp(r'\s+'), ' ');
    return '[$name]';
  });
  final cleaned = result.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
  return asmr ? scopeFishAsmrDelivery(cleaned, addWhisperBase: false) : cleaned;
}
