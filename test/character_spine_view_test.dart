import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spine_flutter/spine_flutter.dart';
import 'package:ryza_chat_mvp/src/character_spine_view.dart';

class DelayedSkinBundle extends CachingAssetBundle {
  final pending = Completer<ByteData>();
  final requested = <String>[];
  @override
  Future<ByteData> load(String key) {
    requested.add(key);
    return pending.future;
  }
}

void main() {
  testWidgets(
    'late failure after skin view disposal does not update disposed state',
    (tester) async {
      final bundle = DelayedSkinBundle();
      await tester.pumpWidget(
        MaterialApp(
          home: CharacterSpineView(
            atlas: 'old.atlas',
            skeleton: 'old.skel',
            bundle: bundle,
            controller: SpineWidgetController(),
          ),
        ),
      );
      expect(bundle.requested, ['old.atlas']);
      await tester.pumpWidget(const SizedBox.shrink());
      bundle.pending.completeError(StateError('obsolete read'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('superseded load cannot replace the selected skin', (
    tester,
  ) async {
    final first = DelayedSkinBundle(), second = DelayedSkinBundle();
    final controller = SpineWidgetController();
    Widget view(DelayedSkinBundle bundle, String name) => MaterialApp(
      home: CharacterSpineView(
        atlas: '$name.atlas',
        skeleton: '$name.skel',
        bundle: bundle,
        controller: controller,
      ),
    );
    await tester.pumpWidget(view(first, 'first'));
    await tester.pumpWidget(view(second, 'second'));
    first.pending.completeError(StateError('obsolete read'));
    await tester.pump();
    expect(find.textContaining('皮肤加载失败'), findsNothing);
    expect(second.requested, ['second.atlas']);
    await tester.pumpWidget(const SizedBox.shrink());
    second.pending.completeError(StateError('cancelled read'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('active skin load failure notifies the startup layer', (
    tester,
  ) async {
    final bundle = DelayedSkinBundle();
    var failures = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CharacterSpineView(
          atlas: 'missing.atlas',
          skeleton: 'missing.skel',
          bundle: bundle,
          controller: SpineWidgetController(),
          onLoadFailed: () => failures++,
        ),
      ),
    );

    bundle.pending.completeError(StateError('missing skin'));
    await tester.pump();
    expect(failures, 1);
    expect(find.textContaining('皮肤加载失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
