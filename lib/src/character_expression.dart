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
    this.lipSyncAlpha = 0.56,
    this.blush,
    this.tear,
  });

  final String eye;
  final String eyebrow;
  final String mouth;
  final String lipSync;
  final double lipSyncAlpha;
  final String? blush;
  final String? tear;
}

class CharacterFacialDetail {
  const CharacterFacialDetail({
    required this.eye,
    required this.eyebrow,
    required this.closedEye,
  });

  final String eye;
  final String eyebrow;
  final String closedEye;
}

const _seatedFacialDetails = <CharacterExpression, List<CharacterFacialDetail>>{
  CharacterExpression.neutral: [
    CharacterFacialDetail(
      eye: 'facial_eye_004_idle',
      eyebrow: 'facial_eyebrow_001_idle',
      closedEye: 'facial_eye_001_idle',
    ),
    CharacterFacialDetail(
      eye: 'facial_eye_005_idle',
      eyebrow: 'facial_eyebrow_002_idle',
      closedEye: 'facial_eye_001_idle',
    ),
    CharacterFacialDetail(
      eye: 'facial_eye_006_idle',
      eyebrow: 'facial_eyebrow_003_idle',
      closedEye: 'facial_eye_001_idle',
    ),
  ],
  CharacterExpression.happy: [
    CharacterFacialDetail(
      eye: 'facial_eye_005_idle',
      eyebrow: 'facial_eyebrow_001_idle',
      closedEye: 'facial_eye_002_idle',
    ),
    CharacterFacialDetail(
      eye: 'facial_eye_010_idle',
      eyebrow: 'facial_eyebrow_003_idle',
      closedEye: 'facial_eye_001_idle',
    ),
    CharacterFacialDetail(
      eye: 'facial_eye_016_idle',
      eyebrow: 'facial_eyebrow_007_idle',
      closedEye: 'facial_eye_001_idle',
    ),
  ],
  CharacterExpression.laughing: [
    CharacterFacialDetail(
      eye: 'facial_eye_004_idle',
      eyebrow: 'facial_eyebrow_001_idle',
      closedEye: 'facial_eye_001_idle',
    ),
    CharacterFacialDetail(
      eye: 'facial_eye_005_idle',
      eyebrow: 'facial_eyebrow_003_idle',
      closedEye: 'facial_eye_002_idle',
    ),
    CharacterFacialDetail(
      eye: 'facial_eye_006_idle',
      eyebrow: 'facial_eyebrow_007_idle',
      closedEye: 'facial_eye_001_idle',
    ),
  ],
  CharacterExpression.angry: [
    CharacterFacialDetail(
      eye: 'facial_eye_006_idle',
      eyebrow: 'facial_eyebrow_012_idle',
      closedEye: 'facial_eye_001_idle',
    ),
    CharacterFacialDetail(
      eye: 'facial_eye_006_idle',
      eyebrow: 'facial_eyebrow_013_idle',
      closedEye: 'facial_eye_001_idle',
    ),
  ],
  CharacterExpression.sad: [
    CharacterFacialDetail(
      eye: 'facial_eye_007_idle',
      eyebrow: 'facial_eyebrow_010_idle',
      closedEye: 'facial_eye_001_idle',
    ),
    CharacterFacialDetail(
      eye: 'facial_eye_011_idle',
      eyebrow: 'facial_eyebrow_009_idle',
      closedEye: 'facial_eye_001_idle',
    ),
  ],
  CharacterExpression.crying: [
    CharacterFacialDetail(
      eye: 'facial_eye_007_idle',
      eyebrow: 'facial_eyebrow_010_idle',
      closedEye: 'facial_eye_001_idle',
    ),
    CharacterFacialDetail(
      eye: 'facial_eye_013_idle',
      eyebrow: 'facial_eyebrow_009_idle',
      closedEye: 'facial_eye_003_idle',
    ),
  ],
  CharacterExpression.shy: [
    CharacterFacialDetail(
      eye: 'facial_eye_006_idle',
      eyebrow: 'facial_eyebrow_002_idle',
      closedEye: 'facial_eye_001_idle',
    ),
    CharacterFacialDetail(
      eye: 'facial_eye_011_idle',
      eyebrow: 'facial_eyebrow_004_idle',
      closedEye: 'facial_eye_003_idle',
    ),
  ],
  CharacterExpression.tease: [
    CharacterFacialDetail(
      eye: 'facial_eye_010_idle',
      eyebrow: 'facial_eyebrow_002_idle',
      closedEye: 'facial_eye_001_idle',
    ),
    CharacterFacialDetail(
      eye: 'facial_eye_011_idle',
      eyebrow: 'facial_eyebrow_003_idle',
      closedEye: 'facial_eye_001_idle',
    ),
    CharacterFacialDetail(
      eye: 'facial_eye_016_idle',
      eyebrow: 'facial_eyebrow_007_idle',
      closedEye: 'facial_eye_001_idle',
    ),
  ],
  CharacterExpression.cuddle: [
    CharacterFacialDetail(
      eye: 'facial_eye_006_idle',
      eyebrow: 'facial_eyebrow_003_idle',
      closedEye: 'facial_eye_001_idle',
    ),
    CharacterFacialDetail(
      eye: 'facial_eye_010_idle',
      eyebrow: 'facial_eyebrow_009_idle',
      closedEye: 'facial_eye_001_idle',
    ),
  ],
};

const _standingFacialDetails =
    <CharacterExpression, List<CharacterFacialDetail>>{
      CharacterExpression.neutral: [
        CharacterFacialDetail(
          eye: 'facial_eye_001_idle',
          eyebrow: 'facial_eyebrow_001_idle',
          closedEye: 'facial_eye_002_idle',
        ),
        CharacterFacialDetail(
          eye: 'facial_eye_004_idle',
          eyebrow: 'facial_eyebrow_004_idle',
          closedEye: 'facial_eye_002_idle',
        ),
      ],
      CharacterExpression.happy: [
        CharacterFacialDetail(
          eye: 'facial_eye_001_idle',
          eyebrow: 'facial_eyebrow_001_idle',
          closedEye: 'facial_eye_003_idle',
        ),
        CharacterFacialDetail(
          eye: 'facial_eye_004_idle',
          eyebrow: 'facial_eyebrow_003_idle',
          closedEye: 'facial_eye_003_idle',
        ),
        CharacterFacialDetail(
          eye: 'facial_eye_008_idle',
          eyebrow: 'facial_eyebrow_001_idle',
          closedEye: 'facial_eye_003_idle',
        ),
      ],
      CharacterExpression.laughing: [
        CharacterFacialDetail(
          eye: 'facial_eye_003_idle',
          eyebrow: 'facial_eyebrow_001_idle',
          closedEye: 'facial_eye_003_idle',
        ),
        CharacterFacialDetail(
          eye: 'facial_eye_001_idle',
          eyebrow: 'facial_eyebrow_004_idle',
          closedEye: 'facial_eye_003_idle',
        ),
      ],
      CharacterExpression.angry: [
        CharacterFacialDetail(
          eye: 'facial_eye_005_idle',
          eyebrow: 'facial_eyebrow_003_idle',
          closedEye: 'facial_eye_002_idle',
        ),
        CharacterFacialDetail(
          eye: 'facial_eye_006_idle',
          eyebrow: 'facial_eyebrow_003_idle',
          closedEye: 'facial_eye_002_idle',
        ),
      ],
      CharacterExpression.sad: [
        CharacterFacialDetail(
          eye: 'facial_eye_010_idle',
          eyebrow: 'facial_eyebrow_002_idle',
          closedEye: 'facial_eye_002_idle',
        ),
      ],
      CharacterExpression.crying: [
        CharacterFacialDetail(
          eye: 'facial_eye_007_idle',
          eyebrow: 'facial_eyebrow_002_idle',
          closedEye: 'facial_eye_002_idle',
        ),
      ],
      CharacterExpression.shy: [
        CharacterFacialDetail(
          eye: 'facial_eye_010_idle',
          eyebrow: 'facial_eyebrow_002_idle',
          closedEye: 'facial_eye_003_idle',
        ),
        CharacterFacialDetail(
          eye: 'facial_eye_010_idle',
          eyebrow: 'facial_eyebrow_004_idle',
          closedEye: 'facial_eye_003_idle',
        ),
      ],
      CharacterExpression.tease: [
        CharacterFacialDetail(
          eye: 'facial_eye_001_idle',
          eyebrow: 'facial_eyebrow_001_idle',
          closedEye: 'facial_eye_003_idle',
        ),
        CharacterFacialDetail(
          eye: 'facial_eye_006_idle',
          eyebrow: 'facial_eyebrow_003_idle',
          closedEye: 'facial_eye_003_idle',
        ),
        CharacterFacialDetail(
          eye: 'facial_eye_011_idle',
          eyebrow: 'facial_eyebrow_004_idle',
          closedEye: 'facial_eye_003_idle',
        ),
      ],
      CharacterExpression.cuddle: [
        CharacterFacialDetail(
          eye: 'facial_eye_001_idle',
          eyebrow: 'facial_eyebrow_002_idle',
          closedEye: 'facial_eye_003_idle',
        ),
        CharacterFacialDetail(
          eye: 'facial_eye_006_idle',
          eyebrow: 'facial_eyebrow_004_idle',
          closedEye: 'facial_eye_003_idle',
        ),
      ],
    };

List<CharacterFacialDetail> characterFacialDetails(
  String appearanceId,
  CharacterExpression expression,
) {
  final details = appearanceId == 'standing_99'
      ? _standingFacialDetails
      : _seatedFacialDetails;
  return details[expression] ?? const [];
}

const _seatedExpressionPresets =
    <CharacterExpression, CharacterExpressionPreset>{
      CharacterExpression.neutral: CharacterExpressionPreset(
        eye: 'facial_eye_004_idle',
        eyebrow: 'facial_eyebrow_001_idle',
        mouth: 'facial_mouth_001_idle',
        lipSync: 'facial_mouth_002_scrub_01',
      ),
      CharacterExpression.happy: CharacterExpressionPreset(
        eye: 'facial_eye_005_idle',
        eyebrow: 'facial_eyebrow_001_idle',
        mouth: 'facial_mouth_002_idle',
        lipSync: 'facial_mouth_002_scrub_01',
      ),
      CharacterExpression.laughing: CharacterExpressionPreset(
        eye: 'facial_eye_004_idle',
        eyebrow: 'facial_eyebrow_001_idle',
        mouth: 'facial_mouth_002_idle',
        lipSync: 'facial_mouth_002_scrub_01',
      ),
      CharacterExpression.angry: CharacterExpressionPreset(
        eye: 'facial_eye_006_idle',
        eyebrow: 'facial_eyebrow_012_idle',
        mouth: 'facial_mouth_034_idle',
        lipSync: 'facial_mouth_017_scrub_01',
      ),
      CharacterExpression.sad: CharacterExpressionPreset(
        eye: 'facial_eye_007_idle',
        eyebrow: 'facial_eyebrow_010_idle',
        mouth: 'facial_mouth_009_idle',
        lipSync: 'facial_mouth_013_scrub_01',
      ),
      CharacterExpression.crying: CharacterExpressionPreset(
        eye: 'facial_eye_007_idle',
        eyebrow: 'facial_eyebrow_010_idle',
        mouth: 'facial_mouth_009_idle',
        lipSync: 'facial_mouth_013_scrub_01',
        tear: 'facial_add_tear_001_on',
      ),
      CharacterExpression.shy: CharacterExpressionPreset(
        eye: 'facial_eye_006_idle',
        eyebrow: 'facial_eyebrow_002_idle',
        mouth: 'facial_mouth_016_idle',
        lipSync: 'facial_mouth_013_scrub_01',
        blush: 'facial_add_blush_001_on',
      ),
      CharacterExpression.tease: CharacterExpressionPreset(
        eye: 'facial_eye_010_idle',
        eyebrow: 'facial_eyebrow_002_idle',
        mouth: 'facial_mouth_014_idle',
        lipSync: 'facial_mouth_017_scrub_01',
      ),
      CharacterExpression.cuddle: CharacterExpressionPreset(
        eye: 'facial_eye_006_idle',
        eyebrow: 'facial_eyebrow_003_idle',
        mouth: 'facial_mouth_016_idle',
        lipSync: 'facial_mouth_002_scrub_01',
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
