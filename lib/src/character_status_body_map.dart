import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'character_status_silhouette.dart';

class BodyMapMarker {
  const BodyMapMarker({
    required this.id,
    required this.region,
    required this.title,
    required this.value,
    required this.note,
    required this.anchor,
    required this.color,
    this.valueFontSize = 21,
  });

  final String id, region, title, value, note, anchor;
  final Color color;
  final double valueFontSize;
}

/// Shares the exact same image transform between the full-body silhouette and
/// its anatomical anchors. Callout rows grow with actual localized text.
class CharacterStatusBodyMap extends StatelessWidget {
  const CharacterStatusBodyMap({
    super.key,
    required this.markers,
    required this.selectedId,
    required this.onSelected,
    this.silhouette,
    this.keyPrefix = 'body-status',
  });

  final List<BodyMapMarker> markers;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final Future<CharacterStatusSilhouette>? silhouette;
  final String keyPrefix;

  List<(String, TextStyle)> _lines(BodyMapMarker marker, int index) => [
    (
      '${(index + 1).toString().padLeft(2, '0')}  ${marker.region}',
      const TextStyle(fontSize: 9, letterSpacing: .5),
    ),
    (marker.title, const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    (
      marker.value,
      TextStyle(
        fontSize: marker.valueFontSize,
        height: 1.1,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
    (marker.note, const TextStyle(fontSize: 10)),
  ];

  double _height(
    BuildContext context,
    BodyMapMarker marker,
    int index,
    double width,
  ) {
    var height = 24.0;
    for (final (text, style) in _lines(marker, index)) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: width);
      height += painter.height;
      painter.dispose();
    }
    return height;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final heights = [
        for (var i = 0; i < markers.length; i++)
          _height(context, markers[i], i, box.maxWidth * .30 - 12),
      ];
      final rows = [
        for (var i = 0; i < markers.length; i += 2)
          math.max(heights[i], i + 1 < heights.length ? heights[i + 1] : 0.0),
      ];
      final contentHeight = rows.fold(0.0, (a, b) => a + b);
      final height = math.max(
        410.0,
        contentHeight + 44 + 24 * (rows.length - 1),
      );
      final gap = rows.length <= 1
          ? 0.0
          : (height - contentHeight - 44) / (rows.length - 1);
      final tops = <double>[];
      var top = 22.0;
      for (final row in rows) {
        tops.add(top);
        top += row + gap;
      }
      return SizedBox(
        key: const ValueKey('character-status-body-map'),
        height: height,
        child: Stack(
          children: [
            Positioned.fill(
              child: ExcludeSemantics(
                child: RepaintBoundary(
                  child: FutureBuilder<CharacterStatusSilhouette>(
                    future: silhouette,
                    builder: (context, snapshot) => CustomPaint(
                      painter: _SilhouettePainter(
                        silhouette: snapshot.data,
                        accent: Theme.of(context).colorScheme.primary,
                        dark: Theme.of(context).brightness == Brightness.dark,
                        markers: markers,
                        selectedId: selectedId,
                        centers: [
                          for (var i = 0; i < markers.length; i++)
                            tops[i ~/ 2] + heights[i] / 2,
                        ],
                      ),
                      child: snapshot.hasError
                          ? Center(
                              child: Text(
                                Localizations.localeOf(context).languageCode ==
                                        'ja'
                                    ? 'シルエットを表示できません'
                                    : Localizations.localeOf(context)
                                              .languageCode ==
                                          'en'
                                    ? 'Silhouette unavailable'
                                    : '剪影暂不可用',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
            for (var i = 0; i < markers.length; i++)
              Positioned(
                left: i.isEven ? 0 : null,
                right: i.isOdd ? 0 : null,
                top: tops[i ~/ 2],
                width: box.maxWidth * .30,
                child: _callout(context, markers[i], i),
              ),
          ],
        ),
      );
    },
  );

  Widget _callout(BuildContext context, BodyMapMarker marker, int index) {
    final selected = marker.id == selectedId;
    final lines = _lines(marker, index);
    return Semantics(
      selected: selected,
      button: true,
      label: '${marker.region}，${marker.title}，${marker.value}，${marker.note}',
      excludeSemantics: true,
      child: Material(
        color: selected
            ? marker.color.withValues(alpha: .08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          key: ValueKey('$keyPrefix-${marker.id}'),
          borderRadius: BorderRadius.circular(9),
          onTap: () => onSelected(marker.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var line = 0; line < lines.length; line++) ...[
                  if (line > 0) SizedBox(height: line == 3 ? 4 : 3),
                  Text(
                    lines[line].$1,
                    key: line == 2
                        ? ValueKey('$keyPrefix-value-${marker.id}')
                        : null,
                    style: lines[line].$2.copyWith(
                      color: line == 0 || line == 3 ? marker.color : null,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SilhouettePainter extends CustomPainter {
  _SilhouettePainter({
    required this.silhouette,
    required this.accent,
    required this.dark,
    required this.markers,
    required this.selectedId,
    required this.centers,
  });
  final CharacterStatusSilhouette? silhouette;
  final Color accent;
  final bool dark;
  final List<BodyMapMarker> markers;
  final String selectedId;
  final List<double> centers;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = accent.withValues(alpha: dark ? .07 : .05)
      ..strokeWidth = .6;
    for (var x = size.width * .31; x <= size.width * .69; x += 18) {
      canvas.drawLine(Offset(x, 12), Offset(x, size.height - 12), grid);
    }
    for (var y = 12.0; y < size.height - 12; y += 18) {
      canvas.drawLine(
        Offset(size.width * .31, y),
        Offset(size.width * .69, y),
        grid,
      );
    }
    final data = silhouette;
    // No generic person is substituted when the protected character is pending.
    if (data == null) return;
    final source = Size(
      data.image.width.toDouble(),
      data.image.height.toDouble(),
    );
    final fitted = applyBoxFit(
      BoxFit.contain,
      source,
      Size(size.width * .42, size.height - 24),
    );
    final rect = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..colorFilter = ui.ColorFilter.mode(
        accent.withValues(alpha: dark ? .40 : .30),
        ui.BlendMode.srcIn,
      );
    canvas.drawImageRect(data.image, Offset.zero & source, rect, paint);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(rect.center.dx, rect.bottom + 2),
        width: rect.width * .7,
        height: 10,
      ),
      Paint()
        ..color = accent.withValues(alpha: .16)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .7,
    );
    for (var i = 0; i < markers.length; i++) {
      final marker = markers[i];
      final point = marker.id == 'energy'
          ? [
              data.normalizedAnchors['arm_l'],
              data.normalizedAnchors['arm_r'],
            ].whereType<Offset>().fold<Offset?>(
              null,
              (left, next) => left == null || next.dx < left.dx ? next : left,
            )
          : data.normalizedAnchors[marker.anchor];
      if (point == null) continue;
      final anchor = Offset(
        rect.left + point.dx * rect.width,
        rect.top + point.dy * rect.height,
      );
      final end = Offset(size.width * (i.isEven ? .30 : .70), centers[i]);
      final color = markers[i].color;
      final active = markers[i].id == selectedId;
      final line = Paint()
        ..color = color.withValues(alpha: active ? .90 : .50)
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 1.2 : .7;
      canvas.drawPath(
        Path()
          ..moveTo(anchor.dx, anchor.dy)
          ..lineTo((anchor.dx + end.dx) / 2, anchor.dy)
          ..lineTo(end.dx, end.dy),
        line,
      );
      canvas.drawCircle(
        anchor,
        active ? 9 : 5,
        Paint()..color = color.withValues(alpha: active ? .18 : .09),
      );
      canvas.drawCircle(anchor, active ? 3 : 2, Paint()..color = color);
      canvas.drawLine(
        Offset(end.dx - 3, end.dy),
        Offset(end.dx + 3, end.dy),
        line,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SilhouettePainter old) =>
      silhouette != old.silhouette ||
      accent != old.accent ||
      dark != old.dark ||
      selectedId != old.selectedId ||
      !listEquals(centers, old.centers) ||
      !listEquals(markers, old.markers);
}
