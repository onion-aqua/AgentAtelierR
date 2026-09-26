import 'dart:convert';

import 'package:flutter/services.dart';

import 'app_localization.dart';

class CharacterNames {
  const CharacterNames({
    required this.chinese,
    required this.english,
    required this.japanese,
  });

  final String chinese;
  final String english;
  final String japanese;

  String forLanguage(AppLanguage language) => switch (language) {
    AppLanguage.chinese => chinese,
    AppLanguage.english => english,
    AppLanguage.japanese => japanese,
  };
}

class CharacterProfile {
  const CharacterProfile({
    required this.id,
    required this.names,
    required this.avatarFile,
    required this.systemPrompt,
  });

  final String id;
  final CharacterNames names;
  final String avatarFile;
  final String systemPrompt;

  String get avatarAsset => 'assets/images/chara_icons/$avatarFile';

  String get encounterPrompt {
    const startMarker = '【身份与经历】';
    const endMarker = '【人物关系】';
    final start = systemPrompt.indexOf(startMarker);
    final end = systemPrompt.indexOf(endMarker);
    if (start < 0 || end <= start) return systemPrompt;
    return systemPrompt.substring(start, end).trim();
  }
}

class EncounterCharacter {
  const EncounterCharacter({required this.profile, required this.weight});

  final CharacterProfile profile;
  final double weight;
}

class _NpcBase {
  const _NpcBase({this.areaId, this.fieldId, this.stageId, required this.pct});

  final String? areaId;
  final String? fieldId;
  final String? stageId;
  final double pct;
}

class _NpcPlacement {
  const _NpcPlacement({
    required this.characterId,
    required this.resolveOrder,
    required this.bases,
    required this.areaMove,
    required this.fieldMove,
    required this.stageMove,
  });

  final String characterId;
  final int resolveOrder;
  final List<_NpcBase> bases;
  final double areaMove;
  final double fieldMove;
  final double stageMove;
}

class CharacterCatalog {
  CharacterCatalog._(this._profiles, this._placements);

  factory CharacterCatalog.empty() => CharacterCatalog._({}, const []);

  static CharacterCatalog? current;

  final Map<String, CharacterProfile> _profiles;
  final List<_NpcPlacement> _placements;

  static const _placementAliases = {
    'klaudia': 'claudia',
    'empel': 'ampel',
    'patricia': 'patrizia',
    'clifford': 'cliford',
  };

  static Future<CharacterCatalog> load() async {
    final files = await Future.wait([
      rootBundle.loadString('assets/data/runtime_prompts.json'),
      rootBundle.loadString('assets/world_map/npc_placement.json'),
    ]);
    final runtime = jsonDecode(files[0]) as Map<String, dynamic>;
    final placement = jsonDecode(files[1]) as Map<String, dynamic>;
    final characterJson = runtime['characters'] as Map<String, dynamic>;
    final profiles = <String, CharacterProfile>{};
    for (final entry in characterJson.entries) {
      final data = entry.value as Map<String, dynamic>;
      final aliases = (data['aliases'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false);
      profiles[entry.key] = CharacterProfile(
        id: entry.key,
        names: CharacterNames(
          chinese: data['display_name'] as String? ?? entry.key,
          english: aliases.length > 2 ? aliases[2] : entry.key,
          japanese: aliases.length > 3 ? aliases[3] : entry.key,
        ),
        avatarFile: data['avatar_file'] as String? ?? '${entry.key}.png',
        systemPrompt: data['system_prompt'] as String? ?? '',
      );
    }
    final placements = (placement['npcs'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((data) {
          final rawId = (data['id'] as String? ?? '').replaceFirst('npc_', '');
          final move = data['move'] as Map<String, dynamic>? ?? const {};
          return _NpcPlacement(
            characterId: _placementAliases[rawId] ?? rawId,
            resolveOrder: data['resolveOrder'] as int? ?? 999,
            bases: (data['bases'] as List<dynamic>? ?? const [])
                .whereType<Map<String, dynamic>>()
                .map(
                  (base) => _NpcBase(
                    areaId: base['areaId'] as String?,
                    fieldId: base['fieldId'] as String?,
                    stageId: base['stageId'] as String?,
                    pct: (base['pct'] as num? ?? 0).toDouble(),
                  ),
                )
                .toList(growable: false),
            areaMove: (move['area'] as num? ?? 0).toDouble(),
            fieldMove: (move['field'] as num? ?? 0).toDouble(),
            stageMove: (move['stage'] as num? ?? 0).toDouble(),
          );
        })
        .toList(growable: false);
    final catalog = CharacterCatalog._(profiles, placements);
    current = catalog;
    return catalog;
  }

  CharacterProfile? profile(String id) => _profiles[id];
  String lookupPrompt(String query) {
    final q = query.trim().toLowerCase();
    if (q.length < 2) return '请提供具体角色名或 ID。';
    final matches = _profiles.values.where(
      (p) => [
        p.id,
        p.names.chinese,
        p.names.english,
        p.names.japanese,
      ].any((n) => n.toLowerCase().contains(q)),
    );
    return jsonEncode({
      'characters': matches
          .take(2)
          .map(
            (p) => {
              'id': p.id,
              'name': p.names.chinese,
              'setting': p.encounterPrompt,
            },
          )
          .toList(),
      'note': '查询不代表人物已在场。',
    });
  }

  String displayName(String id, AppLanguage language) =>
      _profiles[id]?.names.forLanguage(language) ?? id;

  String displayNameForPlacementId(String placementId, AppLanguage language) {
    final rawId = placementId.replaceFirst('npc_', '');
    final characterId = _placementAliases[rawId] ?? rawId;
    return _profiles[characterId]?.names.forLanguage(language) ?? placementId;
  }

  List<EncounterCharacter> encountersFor(String stageId, {int limit = 6}) {
    final fieldId = _fieldIdOf(stageId);
    final areaId = _areaIdOf(stageId);
    final candidates =
        <({CharacterProfile profile, double score, int order})>[];
    for (final placement in _placements) {
      if (placement.characterId == 'ryza') continue;
      final profile = _profiles[placement.characterId];
      if (profile == null) continue;
      var score = 0.0;
      for (final base in placement.bases) {
        final baseField =
            base.fieldId ??
            (base.stageId == null ? null : _fieldIdOf(base.stageId!));
        final baseArea =
            base.areaId ?? (baseField == null ? null : _areaIdOf(baseField));
        if (base.stageId == stageId) {
          score += base.pct * 100;
        } else if (base.fieldId == fieldId) {
          score += base.pct * 50;
        } else if (base.areaId == areaId) {
          score += base.pct * 25;
        } else if (baseField == fieldId) {
          score += base.pct * placement.stageMove / 100;
        } else if (baseArea == areaId) {
          score += base.pct * placement.fieldMove / 100;
        } else {
          score += base.pct * placement.areaMove / 10000;
        }
      }
      if (score > 0.05) {
        candidates.add((
          profile: profile,
          score: score,
          order: placement.resolveOrder,
        ));
      }
    }
    candidates.sort((a, b) {
      final scoreOrder = b.score.compareTo(a.score);
      return scoreOrder != 0 ? scoreOrder : a.order.compareTo(b.order);
    });
    return candidates
        .take(limit)
        .map(
          (item) =>
              EncounterCharacter(profile: item.profile, weight: item.score),
        )
        .toList(growable: false);
  }

  String buildEncounterPrompt(String stageId, AppLanguage speechLanguage) {
    final candidates = encountersFor(stageId);
    if (candidates.isEmpty) return '当前地图没有其他角色候选，保持莱莎单人回应。';
    final ids = candidates.map((item) => item.profile.id).join(', ');
    final profiles = candidates
        .take(4)
        .map((item) {
          final profile = item.profile;
          return '''角色 ID：${profile.id}
显示名：${profile.names.chinese} / ${profile.names.english} / ${profile.names.japanese}
${profile.encounterPrompt}''';
        })
        .join('\n\n');
    return '''当前地图可能遇见的角色 ID（按资源配置的可能性排序）：$ids。
这些只是候选人，不代表一定在场。没有自然的叙事理由时保持莱莎单人回应；需要多人场景时，每轮最多让 1 至 2 位候选角色加入。其他角色台词使用 ${speechLanguage.promptLabel}。

候选角色扮演摘要：
$profiles''';
  }

  String buildCompactEncounterPrompt(String stageId, String context) {
    final candidates = encountersFor(stageId);
    final selected = candidates
        .where((item) {
          final p = item.profile;
          return context.contains('角色[${p.id}]') ||
              [p.names.chinese, p.names.english, p.names.japanese]
                  .where((name) => name.isNotEmpty)
                  .any(
                    (name) =>
                        context.toLowerCase().contains(name.toLowerCase()),
                  );
        })
        .take(2)
        .toList();
    final names = candidates
        .map((e) => '${e.profile.id}=${e.profile.names.chinese}')
        .join('、');
    if (selected.isEmpty) {
      return '附近可能遇见（不代表在场）：$names。尚无被提及或参与对话的 NPC；本轮保持莱莎回应，可提出与候选人见面，未注入设定前不要代其发言。';
    }
    return '仅以下当前话题涉及的 NPC 可发言，不因提及就假定在场，需符合叙事：\n${selected.map((e) => 'ID:${e.profile.id} ${e.profile.names.chinese}/${e.profile.names.english}/${e.profile.names.japanese}\n${e.profile.encounterPrompt}').join('\n')}';
  }

  static String _fieldIdOf(String value) {
    final parts = value.split('_');
    if (parts.length >= 3 && parts.first == 'stage') {
      return 'field_${parts[1]}_${parts[2]}';
    }
    return parts.length >= 3 ? parts.take(3).join('_') : value;
  }

  static String _areaIdOf(String value) {
    final parts = value.split('_');
    if (parts.length >= 2 &&
        (parts.first == 'stage' || parts.first == 'field')) {
      return 'area_${parts[1]}';
    }
    return parts.length >= 2 ? parts.take(2).join('_') : value;
  }
}
