import 'dart:math' as math;
import 'dart:isolate';

/// Retrieve a small local catalogue window; this function never plays a motion.
/// Descriptions are indexed once per immutable capability map. Technical data
/// (skin, pose and animation ids) is omitted from text matching because it is
/// already validated by the runtime and otherwise overwhelms gesture semantics.
Map<String, String> selectMotionCandidates(
  Map<String, String> catalogue,
  String query, {
  int limit = 16,
  Iterable<String> recentKeys = const <String>[],
  Iterable<String> preferredKeys = const <String>[],
}) {
  if (catalogue.isEmpty || limit <= 0) return <String, String>{};
  final index = _motionIndexFor(catalogue);
  final tokens = _motionTokens(_expandedMotionQuery(query));
  final normalizedQuery = _normalizeMotionText(query);
  final intent = _motionIntent(query);
  final recent = recentKeys.map((key) => key.trim().toLowerCase()).toSet();
  final preferred = preferredKeys
      .map((key) => key.trim().toLowerCase())
      .where((key) => key.isNotEmpty)
      .toSet();

  // The catalogue can contain tens of thousands of generated recipes. Query
  // the semantic tree first and only score entries in the matching branches.
  // A family request is strict: when that family is absent we return no
  // gesture candidates so the planner can report unsupported instead of
  // silently replacing, for example, “驱赶” with a normal wave.
  final pool = index.poolFor(intent, tokens);
  if (pool.isEmpty) return <String, String>{};

  // Only keep the best bounded window rather than sorting all 38k recipes.
  // Reserve a few places for similarly relevant occupancy families so tied
  // combinations of the same hand track cannot consume the entire window.
  final best = <_MotionCandidate>[];
  final directArms = <_MotionCandidate>[];
  final asksForArmsCrossed = _motionAliases['双手抱臂']!.any(
    query.toLowerCase().contains,
  );
  final bucketBest = <String, _MotionCandidate>{};
  for (final entry in pool) {
    var score = 0.0;
    for (final token in tokens) {
      if (entry.tokens.contains(token)) {
        // Common words (“身体”, “动作”) provide almost no evidence. A rarer
        // authored gesture phrase (“抱臂”, “拍手”) contributes much more.
        score += index.weights[token] ?? 0;
      }
    }
    // A short complete phrase is stronger than a collection of generic chars.
    if (normalizedQuery.length >= 2 &&
        normalizedQuery.length <= 32 &&
        entry.normalized.contains(normalizedQuery)) {
      score += 20;
    }
    if (intent.families.any(entry.families.contains)) score += 8;
    // A semantic family is a stronger signal than its physical area. Do not
    // let a recently used hand variant beat a fresh equivalent merely because
    // its occupancy happens to match the implied “hands” area; area scoring is
    // reserved for broad area-only requests and multi-branch unions.
    if (intent.families.isEmpty && intent.areas.any(entry.areas.contains)) {
      score += 5;
    }
    if (preferred.contains(entry.idLower)) score += 5;
    if (recent.contains(entry.idLower)) score -= 4;
    final candidate = _MotionCandidate(entry, score);
    // Combinatorial recipes share common words such as "胸前" with a request
    // for crossed arms. Keep the verified direct source gesture in the same
    // bounded window so those recipes cannot hide an existing capability.
    // This retrieves candidates only; the planner still validates the intent.
    if (asksForArmsCrossed && _isDirectArmsCrossedCandidate(entry)) {
      _insertBounded(directArms, candidate, math.min(2, limit));
    }
    _insertBounded(best, candidate, limit);
    final leader = bucketBest[entry.bucket];
    if (leader == null || _compareCandidates(candidate, leader) < 0) {
      bucketBest[entry.bucket] = candidate;
    }
  }

  final cutoff = best.last.score;
  final selected = <_MotionCandidate>[];
  final selectedIds = <String>{};
  for (final candidate in directArms) {
    selected.add(candidate);
    selectedIds.add(candidate.entry.id);
  }
  final leaders =
      bucketBest.values.where((candidate) => candidate.score >= cutoff).toList()
        ..sort(_compareCandidates);
  for (final candidate in leaders) {
    if (selected.length >= limit) break;
    if (selectedIds.add(candidate.entry.id)) selected.add(candidate);
  }
  for (final candidate in best) {
    if (selected.length >= limit) break;
    if (selectedIds.add(candidate.entry.id)) selected.add(candidate);
  }
  selected.sort(_compareCandidates);
  return {
    for (final candidate in selected)
      candidate.entry.id: candidate.entry.description,
  };
}

void _insertBounded(
  List<_MotionCandidate> best,
  _MotionCandidate candidate,
  int limit,
) {
  if (best.length >= limit && _compareCandidates(candidate, best.last) >= 0) {
    return;
  }
  var at = 0;
  while (at < best.length && _compareCandidates(candidate, best[at]) >= 0) {
    at++;
  }
  best.insert(at, candidate);
  if (best.length > limit) best.removeLast();
}

int _compareCandidates(_MotionCandidate a, _MotionCandidate b) {
  final score = b.score.compareTo(a.score);
  return score != 0 ? score : a.entry.id.compareTo(b.entry.id);
}

class _MotionCandidate {
  const _MotionCandidate(this.entry, this.score);
  final _IndexedMotionCandidate entry;
  final double score;
}

bool _isDirectArmsCrossedCandidate(_IndexedMotionCandidate entry) =>
    const {'grp_b_05', 'grp_fg_023', 'grp_fg_002'}.contains(entry.idLower) &&
    (entry.normalized.contains('抱臂') ||
        entry.normalized.contains('抱胸') ||
        entry.normalized.contains('腕組') ||
        entry.normalized.contains('腕を組') ||
        entry.normalized.contains('crossedarms') ||
        entry.normalized.contains('foldedarms'));

class _IndexedMotionCandidate {
  _IndexedMotionCandidate(this.id, this.description)
    : idLower = id.toLowerCase(),
      normalized = _normalizeMotionText(_semanticMotionText(description)),
      tokens = _motionTokens(_semanticMotionText(description)),
      bucket = _motionBucket(id, description),
      areas = _motionAreas(id, description),
      families = _motionFamilies(id, description);

  final String id, idLower, description, normalized, bucket;
  final Set<String> tokens;
  final Set<String> areas;
  final Set<String> families;
}

/// Public classification helpers are useful to diagnostics and tests. They
/// only classify retrieval hints; they never author or execute an action.
String? motionAreaForQuery(String query) => _motionIntent(query).primaryArea;

String? motionFamilyForQuery(String query) =>
    _motionIntent(query).primaryFamily;

class _MotionIntent {
  const _MotionIntent({
    this.areas = const {},
    this.families = const {},
    this.hasExplicitArea = false,
  });

  final Set<String> areas;
  final Set<String> families;
  final bool hasExplicitArea;

  String? get primaryArea => areas.isEmpty ? null : areas.first;
  String? get primaryFamily => families.isEmpty ? null : families.first;
  bool get hasStrictFamily => families.isNotEmpty;
}

_MotionIntent _motionIntent(String query) {
  final lower = query.toLowerCase();
  final areas = <String>{};
  for (final entry in _motionAreaAliases.entries) {
    if (entry.value.any(lower.contains)) areas.add(entry.key);
  }
  final hasExplicitArea = areas.isNotEmpty;
  final families = <String>{};
  for (final entry in _motionFamilyAliases.entries) {
    if (entry.value.any(lower.contains)) families.add(entry.key);
  }
  // Known semantic families imply their physical branch. This keeps a phrase
  // such as “拍手” in hand candidates even when it does not mention “手”.
  for (final family in families) {
    areas.addAll(_areasForFamily[family] ?? const {});
  }
  return _MotionIntent(
    areas: areas,
    families: families,
    hasExplicitArea: hasExplicitArea,
  );
}

class _MotionCatalogueIndex {
  _MotionCatalogueIndex(Map<String, String> catalogue) {
    for (final entry in catalogue.entries) {
      final indexed = _IndexedMotionCandidate(entry.key, entry.value);
      entries.add(indexed);
      for (final area in indexed.areas) {
        areas.putIfAbsent(area, () => <_IndexedMotionCandidate>[]).add(indexed);
      }
      for (final family in indexed.families) {
        families
            .putIfAbsent(family, () => <_IndexedMotionCandidate>[])
            .add(indexed);
      }
      for (final token in indexed.tokens) {
        frequencies[token] = (frequencies[token] ?? 0) + 1;
        tokenEntries
            .putIfAbsent(token, () => <_IndexedMotionCandidate>[])
            .add(indexed);
      }
      // Keep a compact fallback set for broad, unclassified chat. Prefer
      // direct authored groups over generated combinations in that set.
      if (!entry.key.toLowerCase().contains('recipe') &&
          !entry.key.toLowerCase().contains('generated')) {
        genericEntries.add(indexed);
      }
    }
    // Clamp rare-word importance. A misspelled one-off label must not dominate
    // the combined semantic evidence of an accurately described gesture.
    for (final entry in frequencies.entries) {
      weights[entry.key] = math
          .log((entries.length + 1) / (entry.value + 1))
          .clamp(0.05, 4.0)
          .toDouble();
    }
  }

  final entries = <_IndexedMotionCandidate>[];
  final frequencies = <String, int>{};
  final weights = <String, double>{};
  final areas = <String, List<_IndexedMotionCandidate>>{};
  final families = <String, List<_IndexedMotionCandidate>>{};
  final tokenEntries = <String, List<_IndexedMotionCandidate>>{};
  final genericEntries = <_IndexedMotionCandidate>[];

  Iterable<_IndexedMotionCandidate> poolFor(
    _MotionIntent intent,
    Set<String> tokens,
  ) {
    final selected = <_IndexedMotionCandidate>{};
    if (intent.families.isNotEmpty) {
      for (final family in intent.families) {
        selected.addAll(families[family] ?? const []);
      }
      if (intent.families.contains('drive_away') &&
          (families['drive_away']?.isEmpty ?? true)) {
        return const <_IndexedMotionCandidate>[];
      }
      // Keep a bounded, real-resource window for the historical “no arms
      // asset” case. The planner will mark it unsupported; this fallback is
      // only for diagnostics and must never fabricate an arms candidate.
      // Apply it before the explicit-area union so Japanese phrases such as
      // 腕を組む (which also match the generic 腕 area alias) behave the same
      // as their Chinese and English equivalents.
      if (selected.isEmpty) {
        // drive_away has no verified local resource and must stay strict;
        // other families may use a bounded real-resource fallback when a
        // sparse/custom catalogue omitted semantic labels.
        if (intent.families.contains('drive_away')) {
          return const <_IndexedMotionCandidate>[];
        }
        return genericEntries.isEmpty ? entries : genericEntries;
      }
      // An explicit area plus a family is a multi-region request (for example
      // “身体轻晃，同时挥手”), so union both branches. A plain family request
      // stays strict and never falls back to an unrelated gesture.
      if (intent.hasExplicitArea) {
        for (final area in intent.areas) {
          selected.addAll(areas[area] ?? const []);
        }
        return selected;
      }
      // A family was explicitly requested. Do not fall back to unrelated
      // areas if no exact family was authored for this outfit.
      if (selected.isEmpty) return const <_IndexedMotionCandidate>[];
      return selected;
    }
    if (intent.areas.isNotEmpty) {
      for (final area in intent.areas) {
        selected.addAll(areas[area] ?? const []);
      }
      if (selected.isNotEmpty) return selected;
      if (intent.hasExplicitArea) {
        return const <_IndexedMotionCandidate>[];
      }
    }
    for (final token in tokens) {
      selected.addAll(tokenEntries[token] ?? const []);
    }
    if (selected.isNotEmpty) return selected;
    // No semantic evidence means ordinary dialogue. A small authored sample
    // is enough for the model to choose a natural idle gesture while keeping
    // the full recipe catalogue out of the prompt.
    return genericEntries.isEmpty ? entries : genericEntries;
  }
}

// The caller owns immutable capability snapshots. A single cache entry limits
// retained memory when the outfit changes, and is reused for wider retry and
// following turns until that snapshot's appearance/pose revision changes.
_MotionCatalogueIndex? _lastMotionIndex;
Map<String, String>? _lastMotionCatalogue;
Map<String, String>? _preparingCatalogue;
Future<_MotionCatalogueIndex>? _preparingIndex;

/// Cold tokenization of a large catalogue runs off the Flutter UI isolate.
/// Following turns and the optional wider retry reuse this immutable index.
Future<void> prepareMotionCandidateIndex(Map<String, String> catalogue) async {
  if (catalogue.length < 256 || identical(_lastMotionCatalogue, catalogue)) {
    return;
  }
  if (!identical(_preparingCatalogue, catalogue)) {
    _preparingCatalogue = catalogue;
    _preparingIndex = Isolate.run(() => _MotionCatalogueIndex(catalogue));
  }
  final pending = _preparingIndex!;
  try {
    final prepared = await pending;
    if (identical(_preparingCatalogue, catalogue)) {
      _lastMotionIndex = prepared;
      _lastMotionCatalogue = catalogue;
    }
  } finally {
    if (identical(_preparingIndex, pending)) {
      _preparingIndex = null;
      _preparingCatalogue = null;
    }
  }
}

_MotionCatalogueIndex _motionIndexFor(Map<String, String> catalogue) {
  final cached = _lastMotionIndex;
  if (cached != null &&
      identical(_lastMotionCatalogue, catalogue) &&
      cached.entries.length == catalogue.length) {
    return cached;
  }
  final next = _MotionCatalogueIndex(catalogue);
  _lastMotionIndex = next;
  _lastMotionCatalogue = catalogue;
  return next;
}

String _semanticMotionText(String value) => value
    .replaceAll(RegExp(r'；(?:类别|姿态|标签|皮肤)=.*'), '')
    .replaceAll(RegExp(r'由真实\s*gesture\s*资源生成[^。]*。?'), '')
    .replaceAll(RegExp(r'(?:坐姿与站姿|坐姿|站姿)安全动作组合：'), '')
    .replaceAll(RegExp(r'\d+个阶段，脸部由表情工具独立控制'), '')
    .replaceAll(
      RegExp(
        r'(?:motion_(?:add|oneshot)_[a-z]_\d+_active|grp_[a-z0-9_]+)',
        caseSensitive: false,
      ),
      '',
    )
    .replaceAll(
      RegExp(
        r'(?:occupancy|pose|sitting|track|region)\s*[:=]\s*[^；;。,，→]+',
        caseSensitive: false,
      ),
      '',
    )
    .replaceAll(RegExp(r'\d+'), '');

String _normalizeMotionText(String value) => value.toLowerCase().replaceAll(
  RegExp(r'[^a-z\u4e00-\u9fff\u3040-\u30ff]'),
  '',
);

Set<String> _motionTokens(String value) {
  final lower = value.toLowerCase();
  // CJK bigrams retain short gesture commands without the noise and memory cost
  // of every single character. Latin words remain intact instead of matching
  // arbitrary adjacent letters in technical asset ids.
  final result = <String>{
    ...RegExp(r'[a-z]{2,}').allMatches(lower).map((match) => match.group(0)!),
  };
  for (final match in RegExp(
    r'[\u4e00-\u9fff\u3040-\u30ff]+',
  ).allMatches(lower)) {
    final run = match.group(0)!;
    for (var i = 0; i + 1 < run.length; i++) {
      result.add(run.substring(i, i + 2));
    }
  }
  return result;
}

// Retrieval aliases only add search evidence. A greeting, a quoted command or
// a negated request still needs semantic validation by the planner; these
// phrases never execute an action in the client.
String _expandedMotionQuery(String query) {
  final lower = query.toLowerCase();
  return '$query ${_motionAliases.entries.where((entry) => entry.value.any(lower.contains)).map((entry) => entry.key).join(' ')}';
}

const _motionAliases = <String, List<String>>{
  '挥手问候': ['wave', 'hello', 'こんにちは', '手を振', '挨拶'],
  '双手拍手': ['clap', 'applause', '拍手', '手を叩'],
  '双手抱臂': [
    '抱臂',
    '抱胸',
    '环胸',
    '抱起双臂',
    '双臂交叉',
    '交叉双臂',
    '双臂抱在胸前',
    'cross your arms',
    'crossed arms',
    'cross arms',
    'fold your arms',
    'folded arms',
    '腕を組',
    '腕組',
  ],
  '伸展伸懒腰': ['stretch', '伸びを', '背伸び'],
  '安慰温柔陪伴': ['comfort', 'reassure', '慰め', '寄り添'],
  '思考疑惑': ['think', '考え', '悩ん'],
  '解释展示': ['explain', 'demonstrate', '説明'],
  '庆祝打气': ['celebrate', 'cheer', 'お祝い', '応援'],
  '拥抱邀请': ['hug', 'embrace', '抱きしめ', 'ハグ'],
  '嘘手势': ['shush', 'しーっ'],
};

// Area aliases are deliberately phrased. Generic words such as “动作” or
// “身体” alone are not enough to constrain a branch and are left to normal
// token scoring. The values are also used by the public diagnostics helpers.
const _motionAreaAliases = <String, List<String>>{
  'hands': [
    '手部',
    '手上',
    '双手',
    '单手',
    '手臂',
    '胳膊',
    '手势',
    'hand',
    'hands',
    'arm',
    'arms',
    '手を',
    '腕',
  ],
  'legs': [
    '腿部',
    '腿上',
    '双腿',
    '脚部',
    '脚步',
    '膝盖',
    '膝',
    'leg',
    'legs',
    'foot',
    'feet',
    '脚',
    '脚を',
    '膝を',
  ],
  'torso': [
    '躯干',
    '上半身',
    '身体',
    '身体倾',
    '身体轻晃',
    '身体轻摇',
    '身体晃',
    '身体摇',
    '身体向',
    '身体往',
    '腰部',
    '肩部',
    'torso',
    'body sway',
    'body lean',
    'shoulder',
  ],
  'head': ['头部', '头顶', '点头', '摇头', '视线', '目光', 'head', 'gaze', 'nod'],
};

final _motionFamilyAliases = <String, List<String>>{
  'wave': const ['wave', 'hello', '挥手', '挥手问候', '打招呼', 'こんにちは', '手を振', '挨拶'],
  'clap': const ['clap', 'applause', '拍手', '手を叩'],
  'cross_arms': _motionAliases['双手抱臂']!,
  'stretch': const ['stretch', '伸びを', '背伸び'],
  'comfort': const ['comfort', 'reassure', '慰め', '寄り添'],
  'think': const ['think', '考え', '悩ん'],
  'explain': const ['explain', 'demonstrate', '説明'],
  'celebrate': const ['celebrate', 'cheer', 'お祝い', '応援'],
  'hug': const ['hug', 'embrace', '抱きしめ', 'ハグ'],
  'shush': const ['shush', 'しーっ'],
  'drive_away': [
    '驱赶',
    '赶走',
    '轰走',
    '挥退',
    '驱逐',
    '赶开',
    'drive away',
    'shoo',
    'chase away',
    '追い払',
    '追い出',
  ],
  'legs': ['晃脚', '晃腿', '摆腿', '腿部动作', '脚部动作', 'leg motion'],
  'torso': [
    '身体动作',
    '身体姿势',
    '身体轻晃',
    '身体轻摇',
    '躯干动作',
    'body motion',
    'torso motion',
  ],
  'hands': ['手部动作', '手势动作', '手的动作', 'hand motion', 'gesture'],
};

const _areasForFamily = <String, Set<String>>{
  'wave': {'hands'},
  'clap': {'hands'},
  'cross_arms': {'hands'},
  'stretch': {'hands', 'torso'},
  'comfort': {'hands', 'torso'},
  'think': {'hands', 'torso'},
  'explain': {'hands'},
  'celebrate': {'hands'},
  'hug': {'hands'},
  'shush': {'hands'},
  'drive_away': {'hands'},
  'legs': {'legs'},
  'torso': {'torso'},
  'hands': {'hands'},
};

Set<String> _motionAreas(String id, String description) {
  final lowerId = id.toLowerCase();
  final text = _semanticMotionText(description).toLowerCase();
  final result = <String>{};
  final occupancy =
      RegExp(
        r'occupancy\s*[:=]\s*([a-z]+)',
        caseSensitive: false,
      ).firstMatch(description)?.group(1)?.toUpperCase() ??
      '';
  final group = RegExp(
    r'^grp_([a-z]+)',
    caseSensitive: false,
  ).firstMatch(lowerId)?.group(1)?.toUpperCase();
  final letters = occupancy.isNotEmpty ? occupancy : (group ?? '');
  if (letters.contains('C') || letters.contains('I') || letters.contains('J')) {
    result.add('legs');
  }
  if (letters.contains('D')) result.add('head');
  if (letters.contains('E') || letters.contains('H')) result.add('torso');
  if (letters.contains('F') || letters.contains('G')) result.add('hands');
  // B is an upper-body/arm track. Known B sidecar groups are arm gestures;
  // unknown B resources remain conservative torso candidates.
  if (letters.contains('B')) {
    if (const {
      'grp_b_02',
      'grp_b_03',
      'grp_b_05',
      'grp_b_07',
      'grp_b_12',
      'grp_b_13',
    }.contains(lowerId)) {
      result.add('hands');
    } else {
      result.add('torso');
    }
  }
  if (result.isEmpty) {
    for (final entry in _motionAreaAliases.entries) {
      if (entry.value.any(text.contains)) result.add(entry.key);
    }
  }
  return result.isEmpty ? {'other'} : result;
}

Set<String> _motionFamilies(String id, String description) {
  final lowerId = id.toLowerCase();
  final text = _semanticMotionText(description).toLowerCase();
  final result = <String>{};
  final known = <String, String>{
    'grp_b_05': 'cross_arms',
    'grp_fg_002': 'cross_arms',
    'grp_fg_023': 'cross_arms',
    'grp_fg_024': 'clap',
    'grp_fg_028': 'wave',
    'grp_fg_033': 'wave',
    'grp_b_12': 'stretch',
    'grp_b_13': 'legs',
    'grp_c_01': 'legs',
    'grp_c_02': 'legs',
    'grp_c_03': 'legs',
    'grp_c_04': 'legs',
    'grp_c_05': 'legs',
  };
  final direct = known[lowerId];
  if (direct != null) result.add(direct);
  for (final entry in _motionFamilyAliases.entries) {
    if (entry.value.any(text.contains)) result.add(entry.key);
  }
  final areas = _motionAreas(id, description);
  if (result.isEmpty) {
    if (areas.contains('legs')) result.add('legs');
    if (areas.contains('torso')) result.add('torso');
    if (areas.contains('hands')) result.add('hands');
  }
  return result.isEmpty ? {'other'} : result;
}

String _motionBucket(String id, String description) {
  final direct = RegExp(r'^grp_(b|c|eh|fg)(?:_|$)')
      .firstMatch(id.toLowerCase());
  if (direct != null) return direct.group(1)!;
  final tracks = <String>{
    ...RegExp(
      r'(?:track|region)\s*[:=]\s*([a-z]+)',
      caseSensitive: false,
    ).allMatches(description).map((match) => match.group(1)!.toLowerCase()),
    ...RegExp(
      r'motion_(?:add|oneshot)_([a-z])_',
      caseSensitive: false,
    ).allMatches(description).map((match) => match.group(1)!.toLowerCase()),
  }.toList()..sort();
  if (tracks.isNotEmpty) return 'track:${tracks.join('+')}';
  final occupancy = RegExp(
    r'occupancy\s*=\s*([a-z]+)',
    caseSensitive: false,
  ).firstMatch(description);
  return occupancy?.group(1)?.toLowerCase() ?? 'other';
}
