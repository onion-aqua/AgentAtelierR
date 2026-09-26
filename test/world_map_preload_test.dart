import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/ryza_loading_indicator.dart';
import 'package:ryza_chat_mvp/src/world_map_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingMapImageBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) {
    if (key == 'assets/world_map/areas/area_02.jpg') {
      return Future.error(StateError('Map image unavailable'));
    }
    return rootBundle.load(key);
  }
}

Future<void> _pumpUntilVisible(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 20 && finder.evaluate().isEmpty; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('preloaded map has data and image on its first frame', (
    tester,
  ) async {
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    late BuildContext preloadContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            preloadContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    await tester.runAsync(() => WorldMapScreen.preload(
      preloadContext,
      controller,
    ).timeout(const Duration(seconds: 12)));
    await tester.pumpWidget(
      MaterialApp(
        home: WorldMapScreen(
          controller: controller,
          onMenuPressed: () {},
          onClose: () {},
        ),
      ),
    );

    expect(find.byType(RyzaLoadingIndicator), findsNothing);
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('map image failure shows retry and recovers', (tester) async {
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    controller.selectedAreaId = 'area_02';
    late BuildContext preloadContext;
    final failingBundle = _FailingMapImageBundle();
    await tester.pumpWidget(
      MaterialApp(
        home: DefaultAssetBundle(
          bundle: failingBundle,
          child: Builder(
            builder: (context) {
              preloadContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    await tester.runAsync(
      () => expectLater(
        WorldMapScreen.preload(
          preloadContext,
          controller,
        ).timeout(const Duration(seconds: 12)),
        throwsStateError,
      ),
    );

    Widget mapWithBundle(AssetBundle bundle) => MaterialApp(
      home: DefaultAssetBundle(
        bundle: bundle,
        child: WorldMapScreen(
          controller: controller,
          onMenuPressed: () {},
          onClose: () {},
        ),
      ),
    );

    await tester.pumpWidget(mapWithBundle(failingBundle));
    await _pumpUntilVisible(tester, find.text('地图数据读取失败'));
    expect(find.text('地图数据读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.pumpWidget(mapWithBundle(rootBundle));
    await tester.tap(find.text('重试'));
    await tester.pump();
    await _pumpUntilVisible(tester, find.byType(InteractiveViewer));
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });
}
