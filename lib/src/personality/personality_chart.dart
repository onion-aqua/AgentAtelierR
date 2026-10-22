import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import 'personality_profile.dart';

enum PersonalityChartGroup {
  axes('坐标'),
  basic('基础'),
  relationships('关系'),
  tuning('表现');

  const PersonalityChartGroup(this.label);
  final String label;

  static PersonalityChartGroup forParameter(String key) {
    if (_axisLabels.containsKey(key)) return axes;
    if (PersonalityProfile.tuningLabels.containsKey(key)) return tuning;
    return _relationshipTraits.contains(key) ? relationships : basic;
  }
}

const _relationshipTraits = {
  'attachment',
  'abandonmentFear',
  'possessiveness',
  'jealousySensitivity',
  'boundaryRespect',
  'trust',
  'forgiveness',
  'affectionInitiative',
  'reassuranceSeeking',
};
const _axisLabels = {'selfOther': '自我 ↔ 他人', 'restraintExpression': '克制 ↔ 外放'};

/// Directly edits the current draft through sparse value-change callbacks.
class PersonalityChartPanel extends StatefulWidget {
  const PersonalityChartPanel({
    super.key,
    required this.baseAxes,
    required this.traits,
    required this.tuning,
    required this.group,
    required this.onGroupChanged,
    this.selectedParameter,
    this.onSelectParameter,
    this.onChanged,
    this.editingIdentity,
    this.maxHeight = 480,
  });

  final Map<String, int> baseAxes, traits, tuning;
  final PersonalityChartGroup group;
  final ValueChanged<PersonalityChartGroup> onGroupChanged;
  final String? selectedParameter;
  final ValueChanged<String>? onSelectParameter;

  /// Only keys changed by this gesture are returned; null makes values read-only.
  final ValueChanged<Map<String, int>>? onChanged;

  /// Changing profile/draft identity cancels a pointer still held on the canvas.
  final Object? editingIdentity;
  final double maxHeight;

  @override
  State<PersonalityChartPanel> createState() => _PersonalityChartPanelState();
}

class _PersonalityChartPanelState extends State<PersonalityChartPanel> {
  bool _collapsed = false;
  String? _localSelection;
  String? _dragKey;
  PersonalityChartGroup? _dragGroup;
  Object? _dragIdentity;
  Offset? _pointerStart;

  @override
  void didUpdateWidget(covariant PersonalityChartPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedParameter != oldWidget.selectedParameter) {
      _localSelection = widget.selectedParameter;
    }
    if (widget.group != oldWidget.group ||
        widget.editingIdentity != oldWidget.editingIdentity ||
        widget.onChanged == null) {
      _endGesture();
    }
  }

  Map<String, String> get _labels => switch (widget.group) {
    PersonalityChartGroup.axes => _axisLabels,
    PersonalityChartGroup.tuning => PersonalityProfile.tuningLabels,
    _ => {
      for (final entry in PersonalityProfile.traitLabels.entries)
        if (_relationshipTraits.contains(entry.key) ==
            (widget.group == PersonalityChartGroup.relationships))
          entry.key: entry.value,
    },
  };

  Map<String, int> get _values => switch (widget.group) {
    PersonalityChartGroup.axes => widget.baseAxes,
    PersonalityChartGroup.tuning => widget.tuning,
    _ => widget.traits,
  };

  int _score(String key) =>
      (_values[key] ??
              (widget.group == PersonalityChartGroup.axes
                  ? 0
                  : widget.group == PersonalityChartGroup.tuning
                  ? PersonalityProfile.tuningDefaults[key] ?? 50
                  : 50))
          .clamp(widget.group == PersonalityChartGroup.axes ? -100 : 0, 100);

  String? get _selected {
    final candidate = _localSelection ?? widget.selectedParameter;
    return _labels.containsKey(candidate) ? candidate : null;
  }

  void _select(String key) {
    setState(() => _localSelection = key);
    widget.onSelectParameter?.call(key);
  }

  void _emit(Map<String, int> changes) {
    final changed = <String, int>{
      for (final entry in changes.entries)
        if (_score(entry.key) != entry.value) entry.key: entry.value,
    };
    if (changed.isNotEmpty) widget.onChanged?.call(changed);
  }

  void _adjust(String key, int by) {
    if (widget.onChanged == null) return;
    _select(key);
    _emit({
      key: (_score(key) + by).clamp(
        widget.group == PersonalityChartGroup.axes ? -100 : 0,
        100,
      ),
    });
  }

  double _radius(Size size) => personalityChartRadius(size, widget.group);

  String? _hitKey(Offset position, Size size) {
    final center = size.center(Offset.zero);
    final radius = _radius(size);
    if (radius <= 0) return null;
    if (widget.group == PersonalityChartGroup.axes) {
      final point =
          center +
          Offset(
            _score('selfOther') / 100 * radius,
            -_score('restraintExpression') / 100 * radius,
          );
      return (point - position).distance <= 28 ? 'xy' : null;
    }
    final keys = _labels.keys.toList(growable: false);
    final offset = position - center;
    // Coincident zero nodes are selected by the legend before dragging out.
    if (offset.distance <= 20) return _selected ?? keys.first;
    String? nearestNode;
    var nodeDistance = 23.0;
    for (var index = 0; index < keys.length; index++) {
      final point = personalityRadarPoint(
        index: index,
        count: keys.length,
        score: _score(keys[index]).toDouble(),
        center: center,
        radius: radius,
      );
      final distance = (position - point).distance;
      if (distance < nodeDistance) {
        nearestNode = keys[index];
        nodeDistance = distance;
      }
    }
    if (nearestNode != null) return nearestNode;
    String? nearestAxis;
    var axisDistance = 16.0;
    for (var index = 0; index < keys.length; index++) {
      final angle = -math.pi / 2 + 2 * math.pi * index / keys.length;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final along = offset.dx * direction.dx + offset.dy * direction.dy;
      final across = (offset.dx * direction.dy - offset.dy * direction.dx)
          .abs();
      if (along >= 14 && along <= radius + 20 && across < axisDistance) {
        nearestAxis = keys[index];
        axisDistance = across;
      }
    }
    return nearestAxis;
  }

  void _beginGesture(Offset position, Size size) {
    if (widget.onChanged == null) return;
    final key = _hitKey(position, size);
    if (key == null) return;
    _dragKey = key;
    _dragGroup = widget.group;
    _dragIdentity = widget.editingIdentity;
    if (key != 'xy') _select(key);
  }

  void _moveGesture(Offset position, Size size) {
    final key = _dragKey;
    if (key == null ||
        widget.onChanged == null ||
        _dragGroup != widget.group ||
        _dragIdentity != widget.editingIdentity) {
      return;
    }
    final offset = position - size.center(Offset.zero);
    final radius = _radius(size);
    if (radius <= 0) return;
    if (key == 'xy') {
      _emit({
        'selfOther': (offset.dx / radius * 100).round().clamp(-100, 100),
        'restraintExpression': (-offset.dy / radius * 100).round().clamp(
          -100,
          100,
        ),
      });
      return;
    }
    final keys = _labels.keys.toList(growable: false);
    final index = keys.indexOf(key);
    if (index < 0) return;
    final angle = -math.pi / 2 + 2 * math.pi * index / keys.length;
    final projection =
        offset.dx * math.cos(angle) + offset.dy * math.sin(angle);
    _emit({key: (projection / radius * 100).round().clamp(0, 100)});
  }

  void _endGesture() {
    _dragKey = null;
    _dragGroup = null;
    _dragIdentity = null;
    _pointerStart = null;
  }

  void _inspectCompactChart() {
    var group = widget.group;
    String? selected = _selected;
    var axes = Map<String, int>.from(widget.baseAxes);
    var traits = Map<String, int>.from(widget.traits);
    var tuning = Map<String, int>.from(widget.tuning);
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final media = MediaQuery.of(dialogContext);
        final height = math.min(
          560.0,
          (media.size.height -
                  media.viewInsets.bottom -
                  media.padding.vertical) *
              .85,
        );
        return Dialog(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 560,
            height: height,
            child: StatefulBuilder(
              builder: (context, update) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: PersonalityChartPanel(
                      key: const ValueKey('personality-chart-expanded-view'),
                      baseAxes: axes,
                      traits: traits,
                      tuning: tuning,
                      group: group,
                      selectedParameter: selected,
                      editingIdentity: widget.editingIdentity,
                      maxHeight: height - 48,
                      onChanged: widget.onChanged == null
                          ? null
                          : (changes) {
                              update(() {
                                if (group == PersonalityChartGroup.axes) {
                                  axes = {...axes, ...changes};
                                } else if (group ==
                                    PersonalityChartGroup.tuning) {
                                  tuning = {...tuning, ...changes};
                                } else {
                                  traits = {...traits, ...changes};
                                }
                              });
                              widget.onChanged?.call(changes);
                            },
                      onGroupChanged: (value) {
                        update(() {
                          group = value;
                          selected = null;
                        });
                        widget.onGroupChanged(value);
                      },
                      onSelectParameter: (value) {
                        update(() => selected = value);
                        _select(value);
                      },
                    ),
                  ),
                  SizedBox(
                    height: 48,
                    child: TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('返回参数编辑'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final height = widget.maxHeight.isFinite
        ? math.max(0.0, widget.maxHeight)
        : 480.0;
    final compact = _collapsed || height < 170;
    final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
    final headerHeight = scale > 1.4 ? 52.0 : 44.0;
    final desiredHeight = compact
        ? math.min(height, headerHeight + 34)
        : height;
    final key = _selected ?? _labels.keys.first;
    final summary =
        '${_labels[key]}  ${_score(key)}${widget.group == PersonalityChartGroup.axes ? '（−100 至 +100）' : ' / 100'}';
    return SizedBox(
      key: const ValueKey('personality-chart-panel'),
      height: desiredHeight,
      child: Material(
        color: colors.surfaceContainerHighest.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: height < 72
            ? SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _header(context, headerHeight),
                    _summary(context, summary),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(context, headerHeight),
                  if (compact)
                    Expanded(child: _summary(context, summary))
                  else
                    Expanded(child: _chartBody(context)),
                ],
              ),
      ),
    );
  }

  Widget _header(BuildContext context, double height) => SizedBox(
    height: height,
    child: Row(
      children: [
        const SizedBox(width: 4),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final group in PersonalityChartGroup.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: TextButton(
                      key: ValueKey('personality-chart-group-${group.name}'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(42, 34),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        backgroundColor: widget.group == group
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Colors.transparent,
                        foregroundColor: widget.group == group
                            ? Theme.of(context).colorScheme.onPrimaryContainer
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        textStyle: Theme.of(context).textTheme.labelLarge
                            ?.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      onPressed: () {
                        _endGesture();
                        widget.onGroupChanged(group);
                      },
                      child: Semantics(
                        selected: widget.group == group,
                        child: Text(group.label),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('personality-chart-toggle'),
          tooltip: _collapsed || widget.maxHeight < 170 ? '展开人格图表' : '收起人格图表',
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          onPressed: widget.maxHeight < 170
              ? _inspectCompactChart
              : () {
                  _endGesture();
                  setState(() => _collapsed = !_collapsed);
                },
          icon: Icon(
            _collapsed || widget.maxHeight < 170
                ? Icons.expand_more
                : Icons.expand_less,
          ),
        ),
        const SizedBox(width: 4),
      ],
    ),
  );

  Widget _summary(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
    child: Semantics(
      label: text,
      child: ExcludeSemantics(
        child: Align(
          alignment: Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              text,
              key: const ValueKey('personality-chart-summary'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ),
    ),
  );

  Widget _chartBody(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Column(
        children: [
          Text(
            widget.onChanged == null
                ? '只读图表 · 点选图例查看数值'
                : widget.group == PersonalityChartGroup.axes
                ? '按住圆点拖动调整两轴'
                : '拖动节点或轴线调整 · 中心重合时先点选图例',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(fontSize: 11),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= 620) {
                  return Row(
                    children: [
                      Expanded(child: _canvas(context)),
                      const SizedBox(width: 12),
                      Expanded(child: _legend(context)),
                    ],
                  );
                }
                final plotHeight = math.min(
                  300.0,
                  math.max(
                    48.0,
                    constraints.maxHeight *
                        (MediaQuery.textScalerOf(context).scale(11) > 15
                            ? .55
                            : .64),
                  ),
                );
                return Column(
                  children: [
                    SizedBox(
                      height: plotHeight,
                      width: double.infinity,
                      child: _canvas(context),
                    ),
                    const SizedBox(height: 4),
                    Expanded(child: _legend(context)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _canvas(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final colors = Theme.of(context).colorScheme;
      final keys = _labels.keys.toList(growable: false);
      final painter = widget.group == PersonalityChartGroup.axes
          ? _AxesPainter(
              x: _score('selfOther'),
              y: _score('restraintExpression'),
              colors: colors,
              fontFamily: Theme.of(context).textTheme.bodySmall?.fontFamily,
            )
          : _RadarPainter(
              values: keys.map(_score).toList(),
              labels: keys.map((key) => _labels[key]!).toList(),
              selectedIndex: _selected == null ? -1 : keys.indexOf(_selected!),
              colors: colors,
              fontFamily: Theme.of(context).textTheme.bodySmall?.fontFamily,
            );
      return RawGestureDetector(
        key: const ValueKey('personality-chart-interactive-canvas'),
        behavior: HitTestBehavior.opaque,
        gestures: widget.onChanged == null
            ? const <Type, GestureRecognizerFactory>{}
            : <Type, GestureRecognizerFactory>{
                _ChartPanRecognizer:
                    GestureRecognizerFactoryWithHandlers<_ChartPanRecognizer>(
                      _ChartPanRecognizer.new,
                      (recognizer) {
                        recognizer
                          ..accepts = ((position) =>
                              _hitKey(position, size) != null)
                          ..onDown = ((details) {
                            _pointerStart = details.localPosition;
                          })
                          ..onStart = ((details) {
                            _beginGesture(
                              _pointerStart ?? details.localPosition,
                              size,
                            );
                            _moveGesture(details.localPosition, size);
                          })
                          ..onUpdate = ((details) {
                            _moveGesture(details.localPosition, size);
                          })
                          ..onEnd = ((_) {
                            _endGesture();
                          })
                          ..onCancel = _endGesture;
                      },
                    ),
              },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: widget.onChanged == null
              ? null
              : (details) {
                  _beginGesture(details.localPosition, size);
                  _moveGesture(details.localPosition, size);
                  _endGesture();
                },
          child: ExcludeSemantics(
            child: CustomPaint(
              key: ValueKey(
                widget.group == PersonalityChartGroup.axes
                    ? 'personality-chart-axes'
                    : 'personality-chart-radar',
              ),
              painter: painter,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
    },
  );

  Widget _legend(BuildContext context) {
    final entries = _labels.entries.toList(growable: false);
    return SingleChildScrollView(
      key: const ValueKey('personality-chart-legend'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns =
              widget.group == PersonalityChartGroup.axes ||
                  MediaQuery.textScalerOf(context).scale(11) > 15
              ? 2
              : 3;
          final width = (constraints.maxWidth - 6 * (columns - 1)) / columns;
          return Wrap(
            spacing: 6,
            runSpacing: 5,
            children: [
              for (var i = 0; i < entries.length; i++)
                SizedBox(
                  width: width,
                  child: _legendItem(context, entries[i], i),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _legendItem(
    BuildContext context,
    MapEntry<String, String> entry,
    int index,
  ) {
    final selected = _selected == entry.key;
    final colors = Theme.of(context).colorScheme;
    final value = _score(entry.key);
    final min = widget.group == PersonalityChartGroup.axes ? -100 : 0;
    final editable = widget.onChanged != null;
    return Semantics(
      label: entry.value,
      value: widget.group == PersonalityChartGroup.axes
          ? '$value，范围负100至正100'
          : '$value / 100',
      selected: selected,
      button: true,
      increasedValue: editable && value < 100 ? '${value + 1}' : null,
      decreasedValue: editable && value > min ? '${value - 1}' : null,
      onIncrease: editable && value < 100 ? () => _adjust(entry.key, 1) : null,
      onDecrease: editable && value > min ? () => _adjust(entry.key, -1) : null,
      child: Material(
        color: selected
            ? colors.primaryContainer.withValues(alpha: .7)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          key: ValueKey('personality-chart-parameter-${entry.key}'),
          onTap: () => _select(entry.key),
          borderRadius: BorderRadius.circular(7),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${index + 1} ${entry.value}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                  Text(
                    widget.group == PersonalityChartGroup.axes
                        ? '$value'
                        : '$value / 100',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: selected ? colors.primary : colors.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reject drags in the canvas margin before entering the gesture arena, so the
/// surrounding settings page can continue to scroll there.
class _ChartPanRecognizer extends PanGestureRecognizer {
  _ChartPanRecognizer()
    : super(allowedButtonsFilter: (buttons) => buttons == kPrimaryButton);
  bool Function(Offset)? accepts;
  @override
  bool isPointerAllowed(PointerEvent event) =>
      (accepts?.call(event.localPosition) ?? false) &&
      super.isPointerAllowed(event);

  // A node has already been hit-tested. Match the page's scroll threshold so
  // short vertical edits are not stolen by its enclosing scroll view.
  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      globalDistanceMoved.abs() >
      computeHitSlop(pointerDeviceKind, gestureSettings);
}

/// Shared by the painter and geometry tests: 0 is center, 100 is outer ring.
@visibleForTesting
double personalityChartRadius(Size size, PersonalityChartGroup group) =>
    group == PersonalityChartGroup.axes
    ? math.max(0.0, math.min(size.width / 2 - 24, size.height / 2 - 24))
    : math.max(0.0, math.min(size.width / 2 - 60, size.height / 2 - 28));

/// [Size.center] with Offset.zero is the shared canvas origin.
@visibleForTesting
Offset personalityRadarPoint({
  required int index,
  required int count,
  required double score,
  required Offset center,
  required double radius,
}) {
  final angle = -math.pi / 2 + 2 * math.pi * index / count;
  final distance = radius * score.clamp(0, 100) / 100;
  return center +
      Offset(math.cos(angle) * distance, math.sin(angle) * distance);
}

class _RadarPainter extends CustomPainter {
  const _RadarPainter({
    required this.values,
    required this.labels,
    required this.selectedIndex,
    required this.colors,
    this.fontFamily,
  });
  final List<int> values;
  final List<String> labels;
  final int selectedIndex;
  final ColorScheme colors;
  final String? fontFamily;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = personalityChartRadius(size, PersonalityChartGroup.basic);
    Offset point(int index, double score) => personalityRadarPoint(
      index: index,
      count: values.length,
      score: score,
      center: center,
      radius: radius,
    );
    Path polygon(double score) {
      final path = Path()..moveTo(point(0, score).dx, point(0, score).dy);
      for (var i = 1; i < values.length; i++) {
        final p = point(i, score);
        path.lineTo(p.dx, p.dy);
      }
      return path..close();
    }

    final grid = Paint()
      ..color = colors.outlineVariant
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7;
    for (final score in [25.0, 50.0, 75.0, 100.0]) {
      canvas.drawPath(polygon(score), grid);
    }
    for (var i = 0; i < values.length; i++) {
      canvas.drawLine(center, point(i, 100), grid);
      final direction = Offset(
        math.cos(-math.pi / 2 + 2 * math.pi * i / values.length),
        math.sin(-math.pi / 2 + 2 * math.pi * i / values.length),
      );
      final label = TextPainter(
        text: TextSpan(
          text: '${i + 1} ${labels[i]}',
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: 10,
            fontWeight: i == selectedIndex ? FontWeight.w700 : FontWeight.w500,
            color: i == selectedIndex
                ? colors.primary
                : colors.onSurfaceVariant,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: 100);
      final anchor = point(i, 100) + direction * 18;
      label.paint(
        canvas,
        Offset(
          (anchor.dx - label.width / 2).clamp(
            0.0,
            math.max(0.0, size.width - label.width),
          ),
          (anchor.dy - label.height / 2).clamp(
            0.0,
            math.max(0.0, size.height - label.height),
          ),
        ),
      );
    }
    final shape = Path();
    for (var i = 0; i < values.length; i++) {
      final p = point(i, values[i].toDouble());
      if (i == 0) {
        shape.moveTo(p.dx, p.dy);
      } else {
        shape.lineTo(p.dx, p.dy);
      }
    }
    shape.close();
    canvas.drawPath(
      shape,
      Paint()..color = colors.primary.withValues(alpha: .18),
    );
    canvas.drawPath(
      shape,
      Paint()
        ..color = colors.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    for (var i = 0; i < values.length; i++) {
      final p = point(i, values[i].toDouble());
      if (i == selectedIndex) {
        canvas.drawLine(
          center,
          point(i, 100),
          Paint()
            ..color = colors.primary.withValues(alpha: .65)
            ..strokeWidth = 2,
        );
        canvas.drawCircle(p, 6, Paint()..color = colors.primaryContainer);
      }
      canvas.drawCircle(
        p,
        i == selectedIndex ? 3.5 : 2,
        Paint()..color = colors.primary,
      );
    }
    _paintText(
      canvas,
      '0',
      center + const Offset(3, 1),
      colors.onSurfaceVariant,
      fontFamily: fontFamily,
    );
    _paintText(
      canvas,
      '50',
      point(0, 50) + const Offset(3, -3),
      colors.onSurfaceVariant,
      fontFamily: fontFamily,
    );
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      !listEquals(values, oldDelegate.values) ||
      !listEquals(labels, oldDelegate.labels) ||
      selectedIndex != oldDelegate.selectedIndex ||
      colors != oldDelegate.colors ||
      fontFamily != oldDelegate.fontFamily;
}

class _AxesPainter extends CustomPainter {
  const _AxesPainter({
    required this.x,
    required this.y,
    required this.colors,
    this.fontFamily,
  });
  final int x, y;
  final ColorScheme colors;
  final String? fontFamily;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = personalityChartRadius(size, PersonalityChartGroup.axes);
    final grid = Paint()
      ..color = colors.outlineVariant
      ..strokeWidth = .7;
    canvas.drawRect(
      Rect.fromCenter(center: center, width: radius * 2, height: radius * 2),
      grid..style = PaintingStyle.stroke,
    );
    canvas.drawLine(
      center - Offset(radius, 0),
      center + Offset(radius, 0),
      grid,
    );
    canvas.drawLine(
      center - Offset(0, radius),
      center + Offset(0, radius),
      grid,
    );
    final value = center + Offset(x / 100 * radius, -y / 100 * radius);
    canvas.drawLine(
      center,
      value,
      Paint()
        ..color = colors.primary.withValues(alpha: .5)
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(
      value,
      7,
      Paint()..color = colors.primary.withValues(alpha: .15),
    );
    canvas.drawCircle(value, 4, Paint()..color = colors.primary);
    _paintText(
      canvas,
      '自我',
      Offset(0, center.dy - 6),
      colors.onSurfaceVariant,
      fontFamily: fontFamily,
    );
    _paintText(
      canvas,
      '他人',
      Offset(size.width - 21, center.dy - 6),
      colors.onSurfaceVariant,
      fontFamily: fontFamily,
    );
    _paintText(
      canvas,
      '外放',
      Offset(center.dx - 10, center.dy - radius - 20),
      colors.onSurfaceVariant,
      fontFamily: fontFamily,
    );
    _paintText(
      canvas,
      '克制',
      Offset(center.dx - 10, center.dy + radius + 7),
      colors.onSurfaceVariant,
      fontFamily: fontFamily,
    );
    _paintText(
      canvas,
      '0',
      center + const Offset(3, 2),
      colors.onSurfaceVariant,
      fontFamily: fontFamily,
    );
  }

  @override
  bool shouldRepaint(covariant _AxesPainter oldDelegate) =>
      x != oldDelegate.x ||
      y != oldDelegate.y ||
      colors != oldDelegate.colors ||
      fontFamily != oldDelegate.fontFamily;
}

void _paintText(
  Canvas canvas,
  String text,
  Offset offset,
  Color color, {
  String? fontFamily,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontSize: 9, color: color, fontFamily: fontFamily),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, offset);
}
