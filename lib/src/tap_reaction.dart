import 'app_localization.dart';

class TapReaction {
  const TapReaction({
    required this.number,
    required this.animation,
    required this.partName,
    required this.label,
  });

  final int number;
  final String animation;
  final String partName;
  final String label;

  String voiceAsset(int variant) {
    final group = number.toString().padLeft(3, '0');
    final clip = variant.clamp(1, 3).toString().padLeft(2, '0');
    return 'audio/tap_voice/jp/normal/'
        'jp_normal_motion_touch_A_${group}_$clip.m4a';
  }

  String localizedVoiceAsset(AppLanguage language, int variant) {
    final locale = language.audioLocaleCode;
    final group = number.toString().padLeft(3, '0');
    final clip = variant.clamp(1, 3).toString().padLeft(2, '0');
    return 'audio/tap_voice/$locale/normal/'
        '${locale}_normal_motion_touch_A_${group}_$clip.m4a';
  }
}

const tapReactionsByPart = <String, List<TapReaction>>{
  'arm_l': [
    TapReaction(
      number: 1,
      animation: 'motion_touch_A_005_active',
      partName: 'arm_l',
      label: '左臂',
    ),
  ],
  'arm_r': [
    TapReaction(
      number: 2,
      animation: 'motion_touch_A_006_active',
      partName: 'arm_r',
      label: '右臂',
    ),
  ],
  'body': [
    TapReaction(
      number: 3,
      animation: 'motion_touch_A_004_active',
      partName: 'body',
      label: '身体',
    ),
  ],
  'breast': [
    TapReaction(
      number: 4,
      animation: 'motion_touch_A_003_active',
      partName: 'breast',
      label: '胸部',
    ),
  ],
  'head': [
    TapReaction(
      number: 5,
      animation: 'motion_touch_A_001_active',
      partName: 'head',
      label: '头部',
    ),
    TapReaction(
      number: 6,
      animation: 'motion_touch_A_002_active',
      partName: 'head',
      label: '头部',
    ),
  ],
  'weast': [
    TapReaction(
      number: 7,
      animation: 'motion_touch_A_007_active',
      partName: 'weast',
      label: '腰部',
    ),
  ],
};

const hitPartNames = <String, String>{
  'BB_head': 'head',
  'BB_body': 'body',
  'BB_arm_L': 'arm_l',
  'BB_arm_R': 'arm_r',
  'BB_weast': 'weast',
  'BB_breast': 'breast',
};

bool polygonContainsPoint(List<double> vertices, double x, double y) {
  if (vertices.length < 6 || vertices.length.isOdd) return false;
  var inside = false;
  var j = vertices.length - 2;
  for (var i = 0; i < vertices.length; i += 2) {
    final xi = vertices[i];
    final yi = vertices[i + 1];
    final xj = vertices[j];
    final yj = vertices[j + 1];
    final crosses =
        ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi);
    if (crosses) inside = !inside;
    j = i;
  }
  return inside;
}
