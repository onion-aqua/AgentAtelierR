enum CharacterAction {
  none,
  acknowledge,
  disagree,
  think,
  explain,
  excited,
  wave,
  shy,
  surprised,
  comfort,
  playful,
}

CharacterAction characterActionFromTag(String value) {
  final normalized = value.trim().toLowerCase();
  return CharacterAction.values.firstWhere(
    (action) => action.name == normalized,
    orElse: () => CharacterAction.none,
  );
}

class CharacterActionPlan {
  const CharacterActionPlan({
    this.motionGroupIds = const [],
    this.oneShotFallback,
  });

  final List<String> motionGroupIds;
  final String? oneShotFallback;
}

const _seatedActionPlans = <CharacterAction, CharacterActionPlan>{
  CharacterAction.acknowledge: CharacterActionPlan(
    oneShotFallback: 'motion_oneshot_D_001_active',
  ),
  CharacterAction.disagree: CharacterActionPlan(
    oneShotFallback: 'motion_oneshot_D_003_active',
  ),
  CharacterAction.think: CharacterActionPlan(
    motionGroupIds: ['grp_fg_106', 'grp_fg_023'],
    oneShotFallback: 'motion_oneshot_D_010_active',
  ),
  CharacterAction.explain: CharacterActionPlan(
    motionGroupIds: ['grp_fg_021', 'grp_fg_121', 'grp_fg_221'],
    oneShotFallback: 'motion_oneshot_D_009_active',
  ),
  CharacterAction.excited: CharacterActionPlan(
    motionGroupIds: ['grp_fg_030'],
    oneShotFallback: 'motion_oneshot_D_002_active',
  ),
  CharacterAction.wave: CharacterActionPlan(
    motionGroupIds: ['grp_fg_033', 'grp_fg_028'],
  ),
  CharacterAction.shy: CharacterActionPlan(
    motionGroupIds: ['grp_fg_111', 'grp_fg_107'],
  ),
  CharacterAction.surprised: CharacterActionPlan(
    motionGroupIds: ['grp_fg_029'],
    oneShotFallback: 'motion_oneshot_D_011_active',
  ),
  CharacterAction.comfort: CharacterActionPlan(motionGroupIds: ['grp_fg_031']),
  CharacterAction.playful: CharacterActionPlan(motionGroupIds: ['grp_fg_016']),
};

const _standingActionPlans = <CharacterAction, CharacterActionPlan>{
  CharacterAction.acknowledge: CharacterActionPlan(
    oneShotFallback: 'motion_oneshot_D_001_active',
  ),
  CharacterAction.disagree: CharacterActionPlan(
    oneShotFallback: 'motion_oneshot_D_003_active',
  ),
  CharacterAction.think: CharacterActionPlan(
    motionGroupIds: ['grp_fg_002', 'grp_fg_g_009'],
    oneShotFallback: 'motion_oneshot_D_010_active',
  ),
  CharacterAction.explain: CharacterActionPlan(
    motionGroupIds: ['grp_fg_g_007'],
    oneShotFallback: 'motion_oneshot_D_009_active',
  ),
  CharacterAction.excited: CharacterActionPlan(
    motionGroupIds: ['grp_fg_003'],
    oneShotFallback: 'motion_oneshot_D_002_active',
  ),
  CharacterAction.wave: CharacterActionPlan(
    motionGroupIds: ['grp_fg_g_004', 'grp_fg_f_004', 'grp_fg_003'],
  ),
  CharacterAction.shy: CharacterActionPlan(
    motionGroupIds: ['grp_fg_004', 'grp_fg_g_008'],
  ),
  CharacterAction.surprised: CharacterActionPlan(
    motionGroupIds: ['grp_eh_61'],
    oneShotFallback: 'motion_oneshot_D_011_active',
  ),
  CharacterAction.comfort: CharacterActionPlan(
    motionGroupIds: ['grp_fg_g_007'],
  ),
  CharacterAction.playful: CharacterActionPlan(
    motionGroupIds: ['grp_fg_g_006', 'grp_fg_g_009'],
  ),
};

CharacterActionPlan characterActionPlan(
  String appearanceId,
  CharacterAction action,
) {
  final plans = appearanceId == 'standing_99'
      ? _standingActionPlans
      : _seatedActionPlans;
  return plans[action] ?? const CharacterActionPlan();
}
