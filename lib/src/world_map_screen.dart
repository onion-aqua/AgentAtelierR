import 'dart:convert';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'glass_ui.dart';
import 'world_map_localization.dart';

const Size worldMapLogicalSize = Size(2048, 1152);

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

@immutable
class MapFieldLayout {
  const MapFieldLayout({required this.pin, this.focusScale = 2.15});

  final Offset pin;
  final double focusScale;
}

const Map<String, MapFieldLayout> _fieldLayouts = {
  'field_01_001': MapFieldLayout(pin: Offset(0.73, 0.90), focusScale: 2.35),
  'field_01_002': MapFieldLayout(pin: Offset(0.854, 0.647), focusScale: 2.55),
  'field_01_003': MapFieldLayout(pin: Offset(0.657, 0.508)),
  'field_01_004': MapFieldLayout(pin: Offset(0.524, 0.654), focusScale: 2.35),
  'field_01_005': MapFieldLayout(pin: Offset(0.4, 0.746)),
  'field_01_006': MapFieldLayout(pin: Offset(0.87, 0.41), focusScale: 2.35),
  'field_01_007': MapFieldLayout(pin: Offset(0.88, 0.12)),
  'field_01_008': MapFieldLayout(pin: Offset(0.645, 0.117)),
  'field_01_009': MapFieldLayout(pin: Offset(0.445, 0.328)),
  'field_01_010': MapFieldLayout(pin: Offset(0.418, 0.133)),
  'field_01_011': MapFieldLayout(pin: Offset(0.296, 0.431)),
  'field_01_012': MapFieldLayout(pin: Offset(0.24, 0.18)),
  'field_01_013': MapFieldLayout(pin: Offset(0.193, 0.694)),
  'field_01_014': MapFieldLayout(pin: Offset(0.089, 0.785)),
  'field_02_001': MapFieldLayout(pin: Offset(0.317, 0.24)),
  'field_02_002': MapFieldLayout(pin: Offset(0.541, 0.222)),
  'field_02_003': MapFieldLayout(pin: Offset(0.283, 0.648)),
  'field_02_004': MapFieldLayout(pin: Offset(0.881, 0.365)),
  'field_02_005': MapFieldLayout(pin: Offset(0.679, 0.66)),
  'field_03_001': MapFieldLayout(pin: Offset(0.573, 0.792)),
  'field_03_002': MapFieldLayout(pin: Offset(0.621, 0.317)),
  'field_03_003': MapFieldLayout(pin: Offset(0.805, 0.784)),
  'field_03_004': MapFieldLayout(pin: Offset(0.251, 0.645)),
  'field_03_005': MapFieldLayout(pin: Offset(0.235, 0.246)),
  'field_04_001': MapFieldLayout(pin: Offset(0.473, 0.519)),
  'field_04_002': MapFieldLayout(pin: Offset(0.588, 0.867)),
  'field_04_003': MapFieldLayout(pin: Offset(0.585, 0.258)),
  'field_05_001': MapFieldLayout(pin: Offset(0.483, 0.562)),
  'field_05_002': MapFieldLayout(pin: Offset(0.124, 0.644)),
  'field_05_003': MapFieldLayout(pin: Offset(0.751, 0.511)),
  'field_05_004': MapFieldLayout(pin: Offset(0.133, 0.846)),
  'field_05_005': MapFieldLayout(pin: Offset(0.522, 0.216)),
  'field_05_006': MapFieldLayout(pin: Offset(0.282, 0.618)),
  'field_05_007': MapFieldLayout(pin: Offset(0.434, 0.903)),
  'field_05_008': MapFieldLayout(pin: Offset(0.674, 0.349)),
  'field_05_009': MapFieldLayout(pin: Offset(0.157, 0.406)),
  'field_05_010': MapFieldLayout(pin: Offset(0.783, 0.225)),
  'field_05_012': MapFieldLayout(pin: Offset(0.337, 0.231)),
};

MapFieldLayout fieldMapLayout({
  required String areaId,
  required String fieldId,
  required int index,
  required int total,
}) {
  final calibrated = _fieldLayouts[fieldId];
  if (calibrated != null) return calibrated;

  final columns = max(2, sqrt(total * 16 / 9).ceil());
  final rows = max(2, (total / columns).ceil());
  final column = index % columns;
  final row = index ~/ columns;
  final x = 0.16 + (columns == 1 ? 0.5 : column / (columns - 1)) * 0.68;
  final y = 0.20 + (rows == 1 ? 0.5 : row / (rows - 1)) * 0.60;
  return MapFieldLayout(pin: Offset(x, y));
}

const Map<String, Offset> _stageOffsets = {
  'stage_01_001_01': Offset(-0.24, 0.06),
  'stage_01_001_02': Offset(-0.08, -0.83),
  'stage_01_001_04': Offset(-0.84, -0.25),
  'stage_01_001_05': Offset(-0.84, 0.73),
  'stage_01_001_06': Offset(0.09, 0.73),
  'stage_01_001_08': Offset(0.34, -0.15),
  'stage_01_002_01': Offset(-0.25, 0.83),
  'stage_01_002_02': Offset(-1.29, 0.33),
  'stage_01_002_03': Offset(0.5, 0.1),
  'stage_01_002_04': Offset(0.47, -0.79),
  'stage_01_003_01': Offset(0.08, 2.64),
  'stage_01_003_02': Offset(0.72, 0.28),
  'stage_01_003_03': Offset(0.03, -1.14),
  'stage_01_003_04': Offset(0.13, -2.64),
  'stage_01_003_05': Offset(-1.38, -0.34),
  'stage_01_004_01': Offset(0.42, -0.01),
  'stage_01_004_02': Offset(-0.46, 0.77),
  'stage_01_004_03': Offset(-0.32, -0.52),
  'stage_01_005_01': Offset(-0.03, -1.15),
  'stage_01_005_02': Offset(0.1, -0.12),
  'stage_01_005_03': Offset(-0.01, 0.7),
  'stage_01_006_01': Offset(-0.4, 0.3),
  'stage_01_006_02': Offset(0.27, -0.58),
  'stage_01_007_01': Offset(-0.57, 0.99),
  'stage_01_007_02': Offset(0.12, 0.36),
  'stage_01_007_03': Offset(0.83, -0.03),
  'stage_01_008_01': Offset(-0.41, 0.32),
  'stage_01_008_02': Offset(0.49, 0.62),
  'stage_01_009_01': Offset(0.03, 0.81),
  'stage_01_009_02': Offset(-0.03, 0.1),
  'stage_01_009_03': Offset(-0.2, -0.74),
  'stage_01_010_01': Offset(0, 0.35),
  'stage_01_011_01': Offset(0.79, 0.96),
  'stage_01_011_02': Offset(0.19, 0.09),
  'stage_01_011_03': Offset(-0.53, -0.48),
  'stage_01_011_04': Offset(-0.34, -1.27),
  'stage_01_012_01': Offset(-0.08, 0.95),
  'stage_01_012_02': Offset(-0.49, 0.07),
  'stage_01_012_03': Offset(0.32, -0.03),
  'stage_01_013_01': Offset(-0.5, 0.31),
  'stage_01_013_02': Offset(-1.1, -0.86),
  'stage_01_013_03': Offset(0.37, 1.04),
  'stage_01_013_04': Offset(-1.65, 1.35),
  'stage_01_013_05': Offset(-0.34, 2.01),
  'stage_01_013_06': Offset(0.67, 2.65),
  'stage_02_001_01': Offset(0.62, 0.26),
  'stage_02_001_02': Offset(-0.76, 0.29),
  'stage_02_001_03': Offset(0.11, -1.6),
  'stage_02_002_01': Offset(0.61, 0.93),
  'stage_02_002_02': Offset(0, 0.26),
  'stage_02_002_03': Offset(0.43, -0.51),
  'stage_02_002_04': Offset(-0.77, 1.14),
  'stage_02_003_01': Offset(-2.44, -1.72),
  'stage_02_003_02': Offset(-0.86, -2.02),
  'stage_02_003_03': Offset(-0.56, 0.13),
  'stage_02_003_04': Offset(1.33, -0.23),
  'stage_02_003_05': Offset(1.82, -0.62),
  'stage_02_003_06': Offset(2.07, 2.12),
  'stage_02_003_07': Offset(0.06, 3.29),
  'stage_02_003_08': Offset(-2.92, 3.02),
  'stage_02_004_01': Offset(0.3, -2.1),
  'stage_02_004_02': Offset(-0.01, -1.22),
  'stage_02_004_03': Offset(-1.86, -1.03),
  'stage_02_004_04': Offset(0.39, 0.36),
  'stage_02_004_05': Offset(0.27, 2.01),
  'stage_02_004_06': Offset(-0.62, 1.13),
  'stage_02_005_01': Offset(-0.6, 0.75),
  'stage_02_005_02': Offset(0.76, 1.38),
  'stage_02_005_03': Offset(1.49, -0.48),
  'stage_03_001_01': Offset(1, -0.95),
  'stage_03_001_02': Offset(0.96, -2.39),
  'stage_03_001_03': Offset(0.03, -2.17),
  'stage_03_001_04': Offset(-1.34, -0.16),
  'stage_03_001_05': Offset(-0.75, 0.54),
  'stage_03_002_01': Offset(-0.97, 2.55),
  'stage_03_002_02': Offset(2.23, 1.53),
  'stage_03_002_03': Offset(-0.76, -0.19),
  'stage_03_002_04': Offset(-1.99, -1.56),
  'stage_03_002_05': Offset(-0.09, -1.5),
  'stage_03_002_06': Offset(1.8, -1.88),
  'stage_03_003_01': Offset(-0.3, 0),
  'stage_03_003_02': Offset(0.75, 0.41),
  'stage_03_003_03': Offset(-0.04, 1.48),
  'stage_03_004_01': Offset(1.11, 1.76),
  'stage_03_004_02': Offset(0.03, 0.74),
  'stage_03_004_03': Offset(0.84, -0.36),
  'stage_03_004_04': Offset(0.42, -1.7),
  'stage_03_004_05': Offset(-0.65, -0.66),
  'stage_03_005_01': Offset(-1.11, 1.25),
  'stage_03_005_02': Offset(-0.11, 0.63),
  'stage_03_005_03': Offset(0.46, -0.8),
  'stage_04_001_01': Offset(0.1, 0.51),
  'stage_04_001_02': Offset(0.77, 1.37),
  'stage_04_001_03': Offset(-1.06, 1.66),
  'stage_04_001_04': Offset(1.21, -1.75),
  'stage_04_001_05': Offset(0.32, -2.77),
  'stage_04_001_06': Offset(-1.28, -2.32),
  'stage_04_002_01': Offset(0.33, -1.37),
  'stage_04_002_02': Offset(-0.58, 0.1),
  'stage_04_002_03': Offset(0.23, 0.55),
  'stage_04_003_01': Offset(0.37, 0.88),
  'stage_04_003_02': Offset(0.01, -0.37),
  'stage_04_003_03': Offset(-0.03, -1.24),
  'stage_04_003_04': Offset(-0.4, -1.81),
  'stage_04_003_05': Offset(0.34, -1.4),
};

Offset stageMapPosition({
  required String stageId,
  required Offset fieldPosition,
  required int index,
  required int total,
}) {
  final angle = total <= 1 ? 0.0 : index * 2 * pi / total;
  final offset =
      _stageOffsets[stageId] ?? Offset(cos(angle) * 0.6, sin(angle) * 0.6);
  return fieldPosition + offset * 0.08;
}

Offset projectMapPosition({
  required Offset mapPosition,
  required Offset focusPosition,
  required Size viewport,
  required double zoom,
}) {
  final cover = max(
    viewport.width / worldMapLogicalSize.width,
    viewport.height / worldMapLogicalSize.height,
  );
  final scale = cover * zoom;
  return Offset(
    viewport.width / 2 +
        (mapPosition.dx - focusPosition.dx) * worldMapLogicalSize.width * scale,
    viewport.height / 2 +
        (mapPosition.dy - focusPosition.dy) *
            worldMapLogicalSize.height *
            scale,
  );
}

List<Offset> stageNodePositions(int count) {
  const compact = <Offset>[
    Offset(0.25, 0.56),
    Offset(0.52, 0.70),
    Offset(0.73, 0.49),
    Offset(0.70, 0.24),
    Offset(0.43, 0.28),
    Offset(0.27, 0.31),
  ];
  if (count <= compact.length) return compact.take(count).toList();

  return List.generate(count, (index) {
    final angle = -pi / 2 + index * 2 * pi / count;
    return Offset(0.5 + cos(angle) * 0.32, 0.5 + sin(angle) * 0.30);
  });
}

class WorldMapScreen extends StatefulWidget {
  const WorldMapScreen({
    super.key,
    required this.controller,
    required this.onMenuPressed,
    required this.onClose,
  });

  final AppController controller;
  final VoidCallback onMenuPressed;
  final VoidCallback onClose;

  @override
  State<WorldMapScreen> createState() => _WorldMapScreenState();
}

class _WorldMapScreenState extends State<WorldMapScreen>
    with SingleTickerProviderStateMixin {
  late final Future<WorldMapData> _data = _loadData();
  late final TransformationController _mapTransform;
  late final AnimationController _cameraController;
  Animation<Matrix4>? _cameraAnimation;
  String? _activeAreaId;
  String? _focusedFieldId;
  String? _previewStageId;
  Size _viewportSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _activeAreaId = widget.controller.selectedAreaId;
    _mapTransform = TransformationController();
    _cameraController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 520),
        )..addListener(() {
          final animation = _cameraAnimation;
          if (animation != null) _mapTransform.value = animation.value;
        });
  }

  @override
  void dispose() {
    _cameraController.dispose();
    _mapTransform.dispose();
    super.dispose();
  }

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

  double _coverScale(Size viewport) => max(
    viewport.width / worldMapLogicalSize.width,
    viewport.height / worldMapLogicalSize.height,
  );

  Matrix4 _cameraMatrix(Offset normalizedPoint, double scale) {
    final point = Offset(
      normalizedPoint.dx * worldMapLogicalSize.width,
      normalizedPoint.dy * worldMapLogicalSize.height,
    );
    final target = Offset(_viewportSize.width / 2, _viewportSize.height * 0.44);
    final scaledWidth = worldMapLogicalSize.width * scale;
    final scaledHeight = worldMapLogicalSize.height * scale;
    final minX = min(0.0, _viewportSize.width - scaledWidth);
    final minY = min(0.0, _viewportSize.height - scaledHeight);
    final translateX = (target.dx - point.dx * scale)
        .clamp(minX, 0.0)
        .toDouble();
    final translateY = (target.dy - point.dy * scale)
        .clamp(minY, 0.0)
        .toDouble();
    return Matrix4.identity()
      ..translateByDouble(translateX, translateY, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _animateCamera(Offset point, double scale) {
    if (_viewportSize.isEmpty) return;
    _cameraController.stop();
    _cameraAnimation =
        Matrix4Tween(
          begin: _mapTransform.value,
          end: _cameraMatrix(point, scale),
        ).animate(
          CurvedAnimation(
            parent: _cameraController,
            curve: Curves.easeInOutCubic,
          ),
        );
    _cameraController.forward(from: 0);
  }

  void _initializeViewport(Size size, WorldArea area) {
    if (size == _viewportSize) return;
    _viewportSize = size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final currentField = _fieldContainingStage(
        area,
        widget.controller.selectedStageId,
      );
      final index = currentField == null
          ? -1
          : area.fields.indexOf(currentField);
      final layout = currentField == null
          ? const MapFieldLayout(pin: Offset(0.5, 0.5))
          : fieldMapLayout(
              areaId: area.id,
              fieldId: currentField.id,
              index: index,
              total: area.fields.length,
            );
      _mapTransform.value = _cameraMatrix(layout.pin, _coverScale(size) * 1.02);
    });
  }

  void _focusField(WorldArea area, WorldField field) {
    final index = area.fields.indexOf(field);
    final layout = fieldMapLayout(
      areaId: area.id,
      fieldId: field.id,
      index: index,
      total: area.fields.length,
    );
    final currentStage = field.stages
        .where((stage) => stage.id == widget.controller.selectedStageId)
        .firstOrNull;
    setState(() {
      _focusedFieldId = field.id;
      _previewStageId = currentStage?.id ?? field.stages.firstOrNull?.id;
    });
    _animateCamera(layout.pin, _coverScale(_viewportSize) * layout.focusScale);
  }

  void _leaveField(WorldArea area, WorldField field) {
    final layout = fieldMapLayout(
      areaId: area.id,
      fieldId: field.id,
      index: area.fields.indexOf(field),
      total: area.fields.length,
    );
    setState(() {
      _focusedFieldId = null;
      _previewStageId = null;
    });
    _animateCamera(layout.pin, _coverScale(_viewportSize) * 1.02);
  }

  WorldField? _fieldContainingStage(WorldArea area, String stageId) {
    for (final field in area.fields) {
      if (field.stages.any((stage) => stage.id == stageId)) return field;
    }
    return null;
  }

  WorldArea _areaById(WorldMapData data, String id) => data.areas.firstWhere(
    (area) => area.id == id,
    orElse: () => data.areas.first,
  );

  void _returnToCurrent(WorldMapData data) {
    final area = _areaById(data, widget.controller.selectedAreaId);
    final field = _fieldContainingStage(
      area,
      widget.controller.selectedStageId,
    );
    setState(() {
      _activeAreaId = area.id;
      _focusedFieldId = null;
      _previewStageId = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (field == null) {
        _animateCamera(const Offset(0.5, 0.5), _coverScale(_viewportSize));
        return;
      }
      final layout = fieldMapLayout(
        areaId: area.id,
        fieldId: field.id,
        index: area.fields.indexOf(field),
        total: area.fields.length,
      );
      _animateCamera(layout.pin, _coverScale(_viewportSize) * 1.02);
    });
  }

  void _confirmTravel(WorldArea area, WorldStage stage) {
    final language = widget.controller.interfaceLanguage;
    final areaName = localizedWorldPlaceName(
      id: area.id,
      fallback: area.name,
      language: language,
    );
    final stageName = localizedWorldPlaceName(
      id: stage.id,
      fallback: stage.name,
      language: language,
    );
    widget.controller.selectLocation(
      areaId: area.id,
      stageId: stage.id,
      areaName: areaName,
      stageName: stageName,
    );
    setState(() => _previewStageId = stage.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          language.text(
            '已前往：$stageName',
            'Travelled to: $stageName',
            '移動先：$stageName',
          ),
        ),
      ),
    );
  }

  Future<void> _showAreaPicker(WorldMapData data) async {
    final language = widget.controller.interfaceLanguage;
    final selected = await showModalBottomSheet<WorldArea>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassSurface(
            liquidGlass: widget.controller.liquidGlassChatUi,
            borderRadius: BorderRadius.circular(18),
            fallbackColor: const Color(0xEE191817),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 8, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            language.text('选择区域', 'Choose area', '地域を選択'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          color: Colors.white,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: data.areas.length,
                      itemBuilder: (context, index) {
                        final area = data.areas[index];
                        final active = area.id == _activeAreaId;
                        return ListTile(
                          leading: Icon(
                            active ? Icons.location_on : Icons.map_outlined,
                            color: active
                                ? const Color(0xFFFFB02E)
                                : Colors.white70,
                          ),
                          title: Text(
                            localizedWorldPlaceName(
                              id: area.id,
                              fallback: area.name,
                              language: language,
                            ),
                            style: const TextStyle(color: Colors.white),
                          ),
                          subtitle: Text(
                            language.text(
                              '${area.fields.length} 个地区',
                              '${area.fields.length} fields',
                              '${area.fields.length}エリア',
                            ),
                            style: const TextStyle(color: Colors.white60),
                          ),
                          trailing: active
                              ? const Icon(
                                  Icons.check_rounded,
                                  color: Colors.white,
                                )
                              : null,
                          onTap: () => Navigator.pop(context, area),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (selected == null || selected.id == _activeAreaId || !mounted) return;
    setState(() {
      _activeAreaId = selected.id;
      _focusedFieldId = null;
      _previewStageId = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _animateCamera(const Offset(0.5, 0.5), _coverScale(_viewportSize));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF171514),
      body: FutureBuilder<WorldMapData>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _MapLoadError(
              language: widget.controller.interfaceLanguage,
              onClose: widget.onClose,
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator.adaptive());
          }
          return _buildMap(snapshot.data!);
        },
      ),
    );
  }

  Widget _buildMap(WorldMapData data) {
    final language = widget.controller.interfaceLanguage;
    final area = _areaById(
      data,
      _activeAreaId ?? widget.controller.selectedAreaId,
    );
    final focusedField = _focusedFieldId == null
        ? null
        : area.fields.where((field) => field.id == _focusedFieldId).firstOrNull;
    final previewStage = focusedField?.stages
        .where((stage) => stage.id == _previewStageId)
        .firstOrNull;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        _initializeViewport(size, area);
        return Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: ImageFiltered(
                enabled: focusedField != null,
                imageFilter: ImageFilter.blur(sigmaX: 11, sigmaY: 11),
                child: IgnorePointer(
                  ignoring: focusedField != null,
                  child: _InteractiveAreaMap(
                    area: area,
                    controller: widget.controller,
                    transform: _mapTransform,
                    minScale: _coverScale(size) * 0.82,
                    maxScale: _coverScale(size) * 4.2,
                    onFieldSelected: (field) => _focusField(area, field),
                  ),
                ),
              ),
            ),
            const IgnorePointer(child: _MapEdgeShade()),
            if (focusedField != null)
              _FieldFocusOverlay(
                area: area,
                field: focusedField,
                previewStageId: _previewStageId,
                currentStageId: widget.controller.selectedStageId,
                npcs: data.npcs,
                language: widget.controller.interfaceLanguage,
                onStageSelected: (stage) {
                  setState(() => _previewStageId = stage.id);
                },
              ),
            _MapTopBar(
              title: focusedField == null
                  ? localizedWorldPlaceName(
                      id: area.id,
                      fallback: area.name,
                      language: language,
                    )
                  : localizedWorldPlaceName(
                      id: focusedField.id,
                      fallback: focusedField.name,
                      language: language,
                    ),
              subtitle: focusedField == null
                  ? widget.controller.interfaceLanguage.text(
                      '拖动地图并选择地区',
                      'Drag the map and choose a field',
                      'マップを動かして地域を選択',
                    )
                  : widget.controller.interfaceLanguage.text(
                      '选择具体地点',
                      'Choose a destination',
                      '目的地を選択',
                    ),
              liquidGlass: widget.controller.liquidGlassChatUi,
              onClose: focusedField == null
                  ? widget.onClose
                  : () => _leaveField(area, focusedField),
              onMenu: widget.onMenuPressed,
            ),
            _MapBottomBar(
              areaName: localizedWorldPlaceName(
                id: area.id,
                fallback: area.name,
                language: language,
              ),
              liquidGlass: widget.controller.liquidGlassChatUi,
              language: widget.controller.interfaceLanguage,
              canTravel:
                  previewStage != null &&
                  (previewStage.id != widget.controller.selectedStageId ||
                      area.id != widget.controller.selectedAreaId),
              onAreaPressed: () => _showAreaPicker(data),
              onActionPressed:
                  previewStage != null &&
                      (previewStage.id != widget.controller.selectedStageId ||
                          area.id != widget.controller.selectedAreaId)
                  ? () => _confirmTravel(area, previewStage)
                  : () => _returnToCurrent(data),
            ),
          ],
        );
      },
    );
  }
}

class _InteractiveAreaMap extends StatelessWidget {
  const _InteractiveAreaMap({
    required this.area,
    required this.controller,
    required this.transform,
    required this.minScale,
    required this.maxScale,
    required this.onFieldSelected,
  });

  final WorldArea area;
  final AppController controller;
  final TransformationController transform;
  final double minScale;
  final double maxScale;
  final ValueChanged<WorldField> onFieldSelected;

  @override
  Widget build(BuildContext context) {
    final currentFieldId = area.fields
        .where(
          (field) => field.stages.any(
            (stage) => stage.id == controller.selectedStageId,
          ),
        )
        .firstOrNull
        ?.id;
    return InteractiveViewer(
      transformationController: transform,
      constrained: false,
      minScale: minScale,
      maxScale: maxScale,
      boundaryMargin: EdgeInsets.zero,
      clipBehavior: Clip.none,
      child: SizedBox.fromSize(
        size: worldMapLogicalSize,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Image.asset(
                'assets/world_map/areas/${area.id}.jpg',
                fit: BoxFit.fill,
                filterQuality: FilterQuality.high,
              ),
            ),
            for (var index = 0; index < area.fields.length; index++)
              _FieldPin(
                field: area.fields[index],
                language: controller.interfaceLanguage,
                layout: fieldMapLayout(
                  areaId: area.id,
                  fieldId: area.fields[index].id,
                  index: index,
                  total: area.fields.length,
                ),
                current:
                    area.id == controller.selectedAreaId &&
                    area.fields[index].id == currentFieldId,
                onTap: () => onFieldSelected(area.fields[index]),
              ),
          ],
        ),
      ),
    );
  }
}

class _FieldPin extends StatelessWidget {
  const _FieldPin({
    required this.field,
    required this.language,
    required this.layout,
    required this.current,
    required this.onTap,
  });

  final WorldField field;
  final AppLanguage language;
  final MapFieldLayout layout;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: layout.pin.dx * worldMapLogicalSize.width - 60,
      top: layout.pin.dy * worldMapLogicalSize.height - 32,
      width: 120,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (current)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFD94C12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white70),
                ),
                child: Text(
                  language.text('当前地', 'Current', '現在地'),
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFFFE889), Color(0xFFFF870F)],
                ),
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: const Icon(
                Icons.location_on_rounded,
                color: Colors.white,
                size: 25,
              ),
            ),
            Transform.translate(
              offset: const Offset(0, -3),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 120),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.76),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text(
                  localizedWorldPlaceName(
                    id: field.id,
                    fallback: field.name,
                    language: language,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldFocusOverlay extends StatelessWidget {
  const _FieldFocusOverlay({
    required this.area,
    required this.field,
    required this.previewStageId,
    required this.currentStageId,
    required this.npcs,
    required this.language,
    required this.onStageSelected,
  });

  final WorldArea area;
  final WorldField field;
  final String? previewStageId;
  final String currentStageId;
  final List<MapNpc> npcs;
  final AppLanguage language;
  final ValueChanged<WorldStage> onStageSelected;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final portrait = size.height > size.width;
    final width = min(size.width * (portrait ? 0.92 : 0.72), 760.0);
    final height = min(size.height * (portrait ? 0.46 : 0.68), width * 0.92);
    final fieldIndex = area.fields.indexOf(field);
    final focus = fieldMapLayout(
      areaId: area.id,
      fieldId: field.id,
      index: fieldIndex,
      total: area.fields.length,
    );
    final positions = List<Offset>.generate(field.stages.length, (index) {
      final mapPosition = stageMapPosition(
        stageId: field.stages[index].id,
        fieldPosition: focus.pin,
        index: index,
        total: field.stages.length,
      );
      return projectMapPosition(
        mapPosition: mapPosition,
        focusPosition: focus.pin,
        viewport: Size(width, height),
        zoom: focus.focusScale,
      );
    });
    final previewNpcs = npcs
        .where(
          (npc) =>
              previewStageId != null && npc.stageIds.contains(previewStageId),
        )
        .take(4)
        .toList();

    return Center(
      child: Transform.translate(
        offset: Offset(0, portrait ? -22 : 4),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.90, end: 1),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutBack,
          builder: (context, value, child) => Opacity(
            opacity: value.clamp(0, 1),
            child: Transform.scale(scale: value, child: child),
          ),
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(height * 0.34),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x99FFB52B),
                          blurRadius: 28,
                          spreadRadius: 2,
                        ),
                        BoxShadow(
                          color: Colors.black54,
                          blurRadius: 34,
                          offset: Offset(0, 14),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(height * 0.34),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _FocusedMapImage(
                            asset: 'assets/world_map/areas/${area.id}.jpg',
                            center: focus.pin,
                            zoom: focus.focusScale,
                          ),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                radius: 0.82,
                                colors: [
                                  Colors.transparent,
                                  const Color(0xFFFF9D24)
                                      .withValues(alpha: 0.20),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(height * 0.34),
                        border: Border.all(
                          color: const Color(0xFFFFD36A),
                          width: 2.5,
                        ),
                      ),
                    ),
                  ),
                ),
                for (var index = 0; index < field.stages.length; index++)
                  _StagePin(
                    stage: field.stages[index],
                    language: language,
                    position: positions[index],
                    selected: field.stages[index].id == previewStageId,
                    current: field.stages[index].id == currentStageId,
                    onTap: () => onStageSelected(field.stages[index]),
                  ),
                if (previewNpcs.isNotEmpty)
                  Positioned(
                    left: 14,
                    top: 14,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.58),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Text(
                        language.text(
                          '可能遇见：${previewNpcs.map((npc) => npc.name).join(' / ')}',
                          'May meet: ${previewNpcs.map((npc) => npc.name).join(' / ')}',
                          '会えるかも：${previewNpcs.map((npc) => npc.name).join(' / ')}',
                        ),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StagePin extends StatelessWidget {
  const _StagePin({
    required this.stage,
    required this.language,
    required this.position,
    required this.selected,
    required this.current,
    required this.onTap,
  });

  final WorldStage stage;
  final AppLanguage language;
  final Offset position;
  final bool selected;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: position.dx - 61,
      top: position.dy - 36,
      width: 122,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (current)
              Container(
                margin: const EdgeInsets.only(bottom: 3),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFD94C12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white70),
                ),
                child: Text(
                  language.text('当前地', 'Current', '現在地'),
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            Container(
              width: selected ? 31 : 27,
              height: selected ? 31 : 27,
              alignment: Alignment.center,
              child: Transform.rotate(
                angle: pi / 4,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: selected ? 24 : 20,
                  height: selected ? 24 : 20,
                  decoration: BoxDecoration(
                    color: selected
                        ? const Color(0xFFFF8A22)
                        : const Color(0xFFF34B37),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.white, width: 2.5),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 7),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 3),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              constraints: const BoxConstraints(maxWidth: 122),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xE636241B)
                    : Colors.black.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: selected ? const Color(0xFFFFC05A) : Colors.white24,
                ),
              ),
              child: Text(
                localizedWorldPlaceName(
                  id: stage.id,
                  fallback: stage.name,
                  language: language,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FocusedMapImage extends StatelessWidget {
  const _FocusedMapImage({
    required this.asset,
    required this.center,
    required this.zoom,
  });

  final String asset;
  final Offset center;
  final double zoom;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        final cover = max(
          viewport.width / worldMapLogicalSize.width,
          viewport.height / worldMapLogicalSize.height,
        );
        final scale = cover * zoom;
        final point = Offset(
          center.dx * worldMapLogicalSize.width,
          center.dy * worldMapLogicalSize.height,
        );
        final scaledSize = Size(
          worldMapLogicalSize.width * scale,
          worldMapLogicalSize.height * scale,
        );
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              left: viewport.width / 2 - point.dx * scale,
              top: viewport.height / 2 - point.dy * scale,
              width: scaledSize.width,
              height: scaledSize.height,
              child: Image.asset(
                asset,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.high,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MapTopBar extends StatelessWidget {
  const _MapTopBar({
    required this.title,
    required this.subtitle,
    required this.liquidGlass,
    required this.onClose,
    required this.onMenu,
  });

  final String title;
  final String subtitle;
  final bool liquidGlass;
  final VoidCallback onClose;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GlassIconButton(
              liquidGlass: liquidGlass,
              icon: Icons.close_rounded,
              tooltip: '关闭',
              onPressed: onClose,
              size: 52,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GlassSurface(
                liquidGlass: liquidGlass,
                borderRadius: BorderRadius.circular(8),
                fallbackColor: Colors.black.withValues(alpha: 0.54),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            GlassIconButton(
              liquidGlass: liquidGlass,
              icon: Icons.menu_rounded,
              tooltip: '菜单',
              onPressed: onMenu,
              size: 52,
            ),
          ],
        ),
      ),
    );
  }
}

class _MapBottomBar extends StatelessWidget {
  const _MapBottomBar({
    required this.areaName,
    required this.liquidGlass,
    required this.language,
    required this.canTravel,
    required this.onAreaPressed,
    required this.onActionPressed,
  });

  final String areaName;
  final bool liquidGlass;
  final AppLanguage language;
  final bool canTravel;
  final VoidCallback onAreaPressed;
  final VoidCallback onActionPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        child: Row(
          children: [
            Expanded(
              child: _GlassActionButton(
                liquidGlass: liquidGlass,
                onTap: onAreaPressed,
                child: Row(
                  children: [
                    const Icon(
                      Icons.location_on_rounded,
                      color: Color(0xFFFFC437),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        areaName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Colors.white70,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 108,
              child: _GlassActionButton(
                liquidGlass: liquidGlass,
                onTap: onActionPressed,
                child: Center(
                  child: Text(
                    canTravel
                        ? language.text('前往', 'Travel', '移動')
                        : language.text('当前地', 'Current', '現在地'),
                    style: TextStyle(
                      color: canTravel ? const Color(0xFFFFC437) : Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassActionButton extends StatelessWidget {
  const _GlassActionButton({
    required this.liquidGlass,
    required this.onTap,
    required this.child,
  });

  final bool liquidGlass;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      liquidGlass: liquidGlass,
      borderRadius: BorderRadius.circular(26),
      fallbackColor: Colors.black.withValues(alpha: 0.62),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _MapEdgeShade extends StatelessWidget {
  const _MapEdgeShade();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.22),
            Colors.transparent,
            Colors.transparent,
            Colors.black.withValues(alpha: 0.72),
          ],
          stops: const [0, 0.16, 0.70, 1],
        ),
      ),
    );
  }
}

class _MapLoadError extends StatelessWidget {
  const _MapLoadError({required this.language, required this.onClose});

  final AppLanguage language;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.map_outlined, color: Colors.white54, size: 48),
          const SizedBox(height: 12),
          Text(
            language.text(
              '地图数据读取失败',
              'Unable to load map data',
              'マップデータを読み込めません',
            ),
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onClose, child: const Text('返回')),
        ],
      ),
    );
  }
}
