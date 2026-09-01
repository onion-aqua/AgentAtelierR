import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';

class WorldArea {
  const WorldArea({required this.id, required this.name, required this.fields});

  factory WorldArea.fromJson(Map<String, dynamic> json) => WorldArea(
    id: json['id'] as String,
    name: json['name'] as String,
    fields: (json['fields'] as List<dynamic>)
        .map((value) => WorldField.fromJson(value as Map<String, dynamic>))
        .toList(),
  );

  final String id;
  final String name;
  final List<WorldField> fields;
}

class WorldField {
  const WorldField({
    required this.id,
    required this.name,
    required this.stages,
  });

  factory WorldField.fromJson(Map<String, dynamic> json) => WorldField(
    id: json['id'] as String,
    name: json['name'] as String,
    stages: (json['stages'] as List<dynamic>)
        .map((value) => WorldStage.fromJson(value as Map<String, dynamic>))
        .toList(),
  );

  final String id;
  final String name;
  final List<WorldStage> stages;
}

class WorldStage {
  const WorldStage({required this.id, required this.name});

  factory WorldStage.fromJson(Map<String, dynamic> json) =>
      WorldStage(id: json['id'] as String, name: json['name'] as String);

  final String id;
  final String name;
}

class MapNpc {
  const MapNpc({required this.id, required this.name, required this.stageIds});

  factory MapNpc.fromJson(Map<String, dynamic> json) => MapNpc(
    id: json['id'] as String,
    name: json['name'] as String,
    stageIds: (json['bases'] as List<dynamic>? ?? <dynamic>[])
        .map((value) => (value as Map<String, dynamic>)['stageId'] as String?)
        .whereType<String>()
        .toList(),
  );

  final String id;
  final String name;
  final List<String> stageIds;
}

class WorldMapData {
  const WorldMapData({required this.areas, required this.npcs});

  final List<WorldArea> areas;
  final List<MapNpc> npcs;
}

class WorldMapScreen extends StatefulWidget {
  const WorldMapScreen({
    super.key,
    required this.controller,
    required this.onMenuPressed,
  });

  final AppController controller;
  final VoidCallback onMenuPressed;

  @override
  State<WorldMapScreen> createState() => _WorldMapScreenState();
}

class _WorldMapScreenState extends State<WorldMapScreen> {
  late final Future<WorldMapData> _data = _loadData();
  String? _expandedFieldId;

  Future<WorldMapData> _loadData() async {
    final files = await Future.wait([
      rootBundle.loadString('assets/world_map/world_hierarchy.json'),
      rootBundle.loadString('assets/world_map/npc_placement.json'),
    ]);
    final worldJson = jsonDecode(files[0]) as Map<String, dynamic>;
    final npcJson = jsonDecode(files[1]) as Map<String, dynamic>;
    return WorldMapData(
      areas: (worldJson['areas'] as List<dynamic>)
          .map((value) => WorldArea.fromJson(value as Map<String, dynamic>))
          .toList(),
      npcs: (npcJson['npcs'] as List<dynamic>)
          .map((value) => MapNpc.fromJson(value as Map<String, dynamic>))
          .toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: widget.onMenuPressed,
          tooltip: '菜单',
          icon: const Icon(Icons.menu),
        ),
        title: const Text('世界地图'),
      ),
      body: FutureBuilder<WorldMapData>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('地图数据读取失败'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator.adaptive());
          }
          return _buildMap(context, snapshot.data!);
        },
      ),
    );
  }

  Widget _buildMap(BuildContext context, WorldMapData data) {
    final selectedArea = data.areas.firstWhere(
      (area) => area.id == widget.controller.selectedAreaId,
      orElse: () => data.areas.first,
    );
    final selectedStage = selectedArea.fields
        .expand((field) => field.stages)
        .where((stage) => stage.id == widget.controller.selectedStageId)
        .firstOrNull;
    final occupants = data.npcs
        .where(
          (npc) => npc.stageIds.contains(widget.controller.selectedStageId),
        )
        .take(6)
        .toList();

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 52,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              scrollDirection: Axis.horizontal,
              itemCount: data.areas.length,
              separatorBuilder: (_, _) => const SizedBox(width: 7),
              itemBuilder: (context, index) {
                final area = data.areas[index];
                return ChoiceChip(
                  selected: area.id == selectedArea.id,
                  label: Text('区域 ${index + 1}'),
                  onSelected: (_) {
                    final firstStage = area.fields.first.stages.first;
                    widget.controller.selectLocation(
                      areaId: area.id,
                      stageId: firstStage.id,
                    );
                    setState(() => _expandedFieldId = area.fields.first.id);
                  },
                );
              },
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Stack(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.asset(
                  'assets/world_map/areas/${selectedArea.id}.jpg',
                  fit: BoxFit.cover,
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black54],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 18,
                right: 18,
                bottom: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selectedArea.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      selectedStage?.name ?? '选择一个地点',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (occupants.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  const Text(
                    '可能遇见',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 38,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: occupants.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 7),
                        itemBuilder: (context, index) => Chip(
                          avatar: CircleAvatar(
                            backgroundImage: AssetImage(
                              _npcIcon(occupants[index].id),
                            ),
                          ),
                          label: Text(occupants[index].name),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 28),
          sliver: SliverList.builder(
            itemCount: selectedArea.fields.length,
            itemBuilder: (context, index) {
              final field = selectedArea.fields[index];
              final expanded =
                  _expandedFieldId == field.id ||
                  field.stages.any(
                    (stage) => stage.id == widget.controller.selectedStageId,
                  );
              return _FieldSection(
                field: field,
                expanded: expanded,
                selectedStageId: widget.controller.selectedStageId,
                onToggle: () => setState(
                  () => _expandedFieldId = expanded ? null : field.id,
                ),
                onStageSelected: (stage) {
                  widget.controller.selectLocation(
                    areaId: selectedArea.id,
                    stageId: stage.id,
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('目的地已设为：${stage.name}')),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  String _npcIcon(String id) {
    const aliases = {
      'npc_ryza': 'ryza',
      'npc_klaudia': 'claudia',
      'npc_empel': 'ampel',
      'npc_patricia': 'patrizia',
      'npc_boos': 'boos',
    };
    final name = aliases[id] ?? id.replaceFirst('npc_', '');
    return 'assets/images/chara_icons/$name.png';
  }
}

class _FieldSection extends StatelessWidget {
  const _FieldSection({
    required this.field,
    required this.expanded,
    required this.selectedStageId,
    required this.onToggle,
    required this.onStageSelected,
  });

  final WorldField field;
  final bool expanded;
  final String selectedStageId;
  final VoidCallback onToggle;
  final ValueChanged<WorldStage> onStageSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: const Icon(Icons.place_outlined),
          title: Text(
            field.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text('${field.stages.length} 个地点'),
          trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          onTap: onToggle,
        ),
        if (expanded)
          for (final stage in field.stages)
            ListTile(
              contentPadding: const EdgeInsets.only(left: 52, right: 8),
              selected: stage.id == selectedStageId,
              selectedTileColor: const Color(0xFFE1EFEA),
              leading: Icon(
                stage.id == selectedStageId
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 19,
              ),
              title: Text(stage.name),
              onTap: () => onStageSelected(stage),
            ),
        const Divider(height: 1),
      ],
    );
  }
}
