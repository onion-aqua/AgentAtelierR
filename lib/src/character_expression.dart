enum CharacterExpression {
  neutral,
  happy,
  laughing,
  angry,
  sad,
  crying,
  shy,
  tease,
  cuddle,
}

CharacterExpression characterExpressionFromTag(String value) {
  final normalized = value.trim().toLowerCase();
  return CharacterExpression.values.firstWhere(
    (expression) => expression.name == normalized,
    orElse: () => CharacterExpression.neutral,
  );
}

class CharacterExpressionPreset {
  const CharacterExpressionPreset({
    required this.eye,
    required this.eyebrow,
    required this.mouth,
    required this.lipSync,
    this.blush,
    this.tear,
  });

  final String eye;
  final String eyebrow;
  final String mouth;
  final String lipSync;
  final String? blush;
  final String? tear;
}

const _seatedExpressionPresets =
    <CharacterExpression, CharacterExpressionPreset>{
      CharacterExpression.neutral: CharacterExpressionPreset(
        eye: 'facial_eye_004_idle',
        eyebrow: 'facial_eyebrow_001_idle',
        mouth: 'facial_mouth_001_idle',
        lipSync: 'facial_mouth_002_scrub_02',
      ),
      CharacterExpression.happy: CharacterExpressionPreset(
        eye: 'facial_eye_005_idle',
        eyebrow: 'facial_eyebrow_001_idle',
        mouth: 'facial_mouth_002_idle',
        lipSync: 'facial_mouth_002_scrub_02',
      ),
      CharacterExpression.laughing: CharacterExpressionPreset(
        eye: 'facial_eye_004_idle',
        eyebrow: 'facial_eyebrow_001_idle',
        mouth: 'facial_mouth_002_idle',
        lipSync: 'facial_mouth_002_scrub_02',
      ),
      CharacterExpression.angry: CharacterExpressionPreset(
        eye: 'facial_eye_006_idle',
        eyebrow: 'facial_eyebrow_012_idle',
        mouth: 'facial_mouth_034_idle',
        lipSync: 'facial_mouth_017_scrub_02',
      ),
      CharacterExpression.sad: CharacterExpressionPreset(
        eye: 'facial_eye_007_idle',
        eyebrow: 'facial_eyebrow_010_idle',
        mouth: 'facial_mouth_009_idle',
        lipSync: 'facial_mouth_013_scrub_02',
      ),
      CharacterExpression.crying: CharacterExpressionPreset(
        eye: 'facial_eye_007_idle',
        eyebrow: 'facial_eyebrow_010_idle',
        mouth: 'facial_mouth_009_idle',
        lipSync: 'facial_mouth_013_scrub_02',
        tear: 'facial_add_tear_001_on',
      ),
      CharacterExpression.shy: CharacterExpressionPreset(
        eye: 'facial_eye_006_idle',
        eyebrow: 'facial_eyebrow_002_idle',
        mouth: 'facial_mouth_016_idle',
        lipSync: 'facial_mouth_013_scrub_02',
        blush: 'facial_add_blush_001_on',
      ),
      CharacterExpression.tease: CharacterExpressionPreset(
        eye: 'facial_eye_010_idle',
        eyebrow: 'facial_eyebrow_002_idle',
        mouth: 'facial_mouth_014_idle',
        lipSync: 'facial_mouth_017_scrub_02',
      ),
      CharacterExpression.cuddle: CharacterExpressionPreset(
        eye: 'facial_eye_006_idle',
        eyebrow: 'facial_eyebrow_003_idle',
        mouth: 'facial_mouth_016_idle',
        lipSync: 'facial_mouth_002_scrub_02',
        blush: 'facial_add_blush_001_on',
      ),
    };

const _standingExpressionPresets =
    <CharacterExpression, CharacterExpressionPreset>{
      CharacterExpression.neutral: CharacterExpressionPreset(
        eye: 'facial_eye_001_idle',
        eyebrow: 'facial_eyebrow_001_idle',
        mouth: 'facial_mouth_001_idle',
        lipSync: 'facial_mouth_002_scrub_02',
      ),
      CharacterExpression.happy: CharacterExpressionPreset(
        eye: 'facial_eye_001_idle',
        eyebrow: 'facial_eyebrow_001_idle',
        mouth: 'facial_mouth_001_idle',
        lipSync: 'facial_mouth_002_scrub_02',
      ),
      CharacterExpression.laughing: CharacterExpressionPreset(
        eye: 'facial_eye_003_idle',
        eyebrow: 'facial_eyebrow_001_idle',
        mouth: 'facial_mouth_002_idle',
        lipSync: 'facial_mouth_002_scrub_02',
      ),
      CharacterExpression.angry: CharacterExpressionPreset(
        eye: 'facial_eye_005_idle',
        eyebrow: 'facial_eyebrow_003_idle',
        mouth: 'facial_mouth_003_idle',
        lipSync: 'facial_mouth_002_scrub_02',
      ),
      CharacterExpression.sad: CharacterExpressionPreset(
        eye: 'facial_eye_010_idle',
        eyebrow: 'facial_eyebrow_002_idle',
        mouth: 'facial_mouth_004_idle',
        lipSync: 'facial_mouth_002_scrub_02',
      ),
      CharacterExpression.crying: CharacterExpressionPreset(
        eye: 'facial_eye_007_idle',
        eyebrow: 'facial_eyebrow_002_idle',
        mouth: 'facial_mouth_006_idle',
        lipSync: 'facial_mouth_002_scrub_02',
        tear: 'facial_add_tear_on',
      ),
      CharacterExpression.shy: CharacterExpressionPreset(
        eye: 'facial_eye_010_idle',
        eyebrow: 'facial_eyebrow_002_idle',
        mouth: 'facial_mouth_001_idle',
        lipSync: 'facial_mouth_002_scrub_02',
        blush: 'facial_add_blush_on',
      ),
      CharacterExpression.tease: CharacterExpressionPreset(
        eye: 'facial_eye_001_idle',
        eyebrow: 'facial_eyebrow_001_idle',
        mouth: 'facial_mouth_002_idle',
        lipSync: 'facial_mouth_002_scrub_02',
      ),
      CharacterExpression.cuddle: CharacterExpressionPreset(
        eye: 'facial_eye_001_idle',
        eyebrow: 'facial_eyebrow_002_idle',
        mouth: 'facial_mouth_001_idle',
        lipSync: 'facial_mouth_002_scrub_02',
        blush: 'facial_add_blush_on',
      ),
    };

CharacterExpressionPreset characterExpressionPreset(
  String appearanceId,
  CharacterExpression expression,
) {
  final presets = appearanceId == 'standing_99'
      ? _standingExpressionPresets
      : _seatedExpressionPresets;
  return presets[expression] ?? presets[CharacterExpression.neutral]!;
}
