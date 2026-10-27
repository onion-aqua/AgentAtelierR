/// Conservative names from the authored Ryza rigs. Unknown foreground objects
/// remain unclassified; an arm bone alone must not turn clothing into skin.
String? characterBodyTouchPart({
  required String slotName,
  String? boneName,
  String? attachmentPath,
}) {
  final slot = slotName.toLowerCase();
  final path = (attachmentPath ?? '').toLowerCase();
  final bone = (boneName ?? '').toLowerCase();
  bool token(String value, String word) => value.split('_').contains(word);
  final unknownCover = RegExp(
    r'(?:^|_)(?:acc|costume|cloth|clothes|frill|shadow|skirt|dress|sleeve|cape|ribbon|sofa|cover|object|background)(?:_|$)',
  );
  if (unknownCover.hasMatch(slot) ||
      unknownCover.hasMatch(path) ||
      RegExp(r'^\d+_ex_body(?:_|$)').hasMatch(slot) ||
      RegExp(r'^600_arm_').hasMatch(slot)) {
    return null;
  }
  if (RegExp(r'(?:^|_)(?:hand|hands|finger|fingers|palm)(?:_|$)')
          .hasMatch(slot) ||
      RegExp(r'(?:^|_)(?:hand|hands|finger|fingers|palm)(?:_|$)')
          .hasMatch(path)) {
    return 'hands';
  }
  // Seated rigs explicitly separate the palm/fingers as their 030 arm layer.
  if (RegExp(r'(?:^|_)arm_[lr]_030(?:_|$)').hasMatch(slot) ||
      RegExp(r'(?:^|_)arm_[lr]_030(?:_|$)').hasMatch(path)) {
    return 'hands';
  }
  // The standing rig uses numeric piece names rather than a 030 hand layer.
  if (const {
        '101_arm_01',
        '102_arm_01',
        '110_arm_01',
        '111_arm_01',
      }.contains(slot) &&
      RegExp(r'^arm_[lr](?:\d+)?$').hasMatch(bone)) {
    return 'hands';
  }
  if (RegExp(r'(?:^|_)(?:leg|legs|foot|feet|thigh|calf)(?:_|$)')
      .hasMatch(slot)) {
    return 'legs';
  }
  if (token(slot, 'arm')) {
    final side =
        RegExp(r'(?:^|_)arm_([lr])(?:_|\d|$)').firstMatch(slot) ??
        RegExp(r'^arm_([lr])(?:\d|$)').firstMatch(bone);
    return side == null ? null : 'arm_${side[1]}';
  }
  if (RegExp(
    r'(?:^|_)(?:head|face|hair|ear|nose|mouth|eyeball|eyebrow|eyewhite|eyerash|eye)(?:_|$)',
  ).hasMatch(slot)) {
    return 'head';
  }
  if (token(slot, 'weast') || token(slot, 'waist')) return 'weast';
  if (token(slot, 'breast') || token(slot, 'chest')) return 'breast';
  if (token(slot, 'body') || token(slot, 'abdomen')) return 'body';
  return null;
}
