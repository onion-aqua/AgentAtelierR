import 'dart:convert';

import 'app_localization.dart';
import 'update/resource_resolver.dart';
import 'world_map_localization.dart';

class WorldTravelDestination {
  const WorldTravelDestination({
    required this.areaId,
    required this.areaName,
    required this.fieldId,
    required this.fieldName,
    required this.stageId,
    required this.stageName,
  });

  final String areaId;
  final String areaName;
  final String fieldId;
  final String fieldName;
  final String stageId;
  final String stageName;

  String localizedAreaName(AppLanguage language) => localizedWorldPlaceName(
    id: areaId,
    fallback: areaName,
    language: language,
  );

  String localizedFieldName(AppLanguage language) => localizedWorldPlaceName(
    id: fieldId,
    fallback: fieldName,
    language: language,
  );

  String localizedStageName(AppLanguage language) => localizedWorldPlaceName(
    id: stageId,
    fallback: stageName,
    language: language,
  );

  Map<String, String> toToolJson(AppLanguage language) => {
    'area_id': areaId,
    'area_name': localizedAreaName(language),
    'field_id': fieldId,
    'field_name': localizedFieldName(language),
    'stage_id': stageId,
    'stage_name': localizedStageName(language),
  };

  bool matches(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    return [
      areaId,
      fieldId,
      stageId,
      areaName,
      fieldName,
      stageName,
      for (final language in AppLanguage.values) ...[
        localizedAreaName(language),
        localizedFieldName(language),
        localizedStageName(language),
      ],
    ].any((value) => value.toLowerCase().contains(normalized));
  }
}

class WorldTravelCatalog {
  const WorldTravelCatalog(this.destinations);

  final List<WorldTravelDestination> destinations;

  static Future<WorldTravelCatalog> load() async {
    final raw = await ResourceAssetResolver.instance.loadString(
      'assets/world_map/world_hierarchy.json',
    );
    final root = jsonDecode(raw) as Map<String, dynamic>;
    final destinations = <WorldTravelDestination>[];
    for (final areaValue in root['areas'] as List<dynamic>? ?? const []) {
      final area = areaValue as Map<String, dynamic>;
      for (final fieldValue in area['fields'] as List<dynamic>? ?? const []) {
        final field = fieldValue as Map<String, dynamic>;
        for (final stageValue
            in field['stages'] as List<dynamic>? ?? const []) {
          final stage = stageValue as Map<String, dynamic>;
          destinations.add(
            WorldTravelDestination(
              areaId: area['id'] as String,
              areaName: area['name'] as String,
              fieldId: field['id'] as String,
              fieldName: field['name'] as String,
              stageId: stage['id'] as String,
              stageName: stage['name'] as String,
            ),
          );
        }
      }
    }
    return WorldTravelCatalog(List.unmodifiable(destinations));
  }

  WorldTravelDestination? byStageId(String stageId) {
    for (final destination in destinations) {
      if (destination.stageId == stageId) return destination;
    }
    return null;
  }

  List<WorldTravelDestination> search({
    required String query,
    required String currentAreaId,
    int limit = 40,
  }) {
    final normalized = query.trim();
    final matches = normalized.isEmpty
        ? destinations.where((item) => item.areaId == currentAreaId)
        : destinations.where((item) => item.matches(normalized));
    return matches.take(limit).toList(growable: false);
  }
}
