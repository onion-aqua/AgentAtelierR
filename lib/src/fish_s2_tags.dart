/// Official S2 backend identifiers. Do not guess aliases or apply S2 controls
/// to an unknown model, a service default, or Drama 3.
bool isFishS2Model(String? model) => const {
  's2-pro',
  's2.1-pro',
  's2.1-pro-free',
}.contains(model?.trim().toLowerCase());

/// S2 interprets square-bracket directions as natural-language performance
/// guidance. Keep this description separate from the generic cue normalizer,
/// which deliberately shortens whisper descriptions during noise cleanup.
const fishS2WhisperCue =
    '[whispering intimately into the microphone, hushed and clearly articulated throughout]';

final _s2Cue = RegExp(r'\[([^\[\]\r\n]+)\]');
final _s2WhisperDirection = RegExp(
  r'^(?:whisper(?:ing)?|unvoiced whispering|near-whisper)(?:$|[\s,])',
  caseSensitive: false,
);

/// Strengthens an existing explicit whisper direction once per synthesis
/// chunk, after common tag cleanup. No delivery is inferred from plain words,
/// and no extra breath sounds or new emotional direction are introduced.
/// Other cues and every spoken character are retained in their original order.
String compileFishS2Text(String text) {
  var whisperAdded = false;
  return text.replaceAllMapped(_s2Cue, (match) {
    final direction = match.group(1)!.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (!_s2WhisperDirection.hasMatch(direction)) return match.group(0)!;
    if (whisperAdded) return '';
    whisperAdded = true;
    return fishS2WhisperCue;
  });
}
