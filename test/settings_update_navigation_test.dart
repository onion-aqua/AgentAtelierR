import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';
import 'package:ryza_chat_mvp/src/update/apk_update_installer.dart';
import 'package:ryza_chat_mvp/src/update/update_build_config.dart';
import 'package:ryza_chat_mvp/src/update/update_center_page.dart';
import 'package:ryza_chat_mvp/src/update/update_downloader.dart';
import 'package:ryza_chat_mvp/src/update/update_notes_loader.dart';
import 'package:ryza_chat_mvp/src/update/update_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AppController> loadController(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    return (await tester.runAsync(AppController.load))!;
  }

  Future<void> openAbout(WidgetTester tester) async {
    final about = find.byKey(const ValueKey('settings-category-about'));
    await tester.scrollUntilVisible(
      about,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(about);
    await tester.pumpAndSettle();
    await tester.tap(about);
    await tester.pumpAndSettle();
  }

  testWidgets('about explains when update runtime is unavailable', (
    tester,
  ) async {
    final controller = await loadController(tester);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(controller: controller, onMenuPressed: () {}),
      ),
    );

    await openAbout(tester);
    expect(find.text('更新服务尚未初始化，当前不可用'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('about-update-center-tile')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('当前无法检查或下载更新'), findsOneWidget);
  });

  testWidgets('about opens the injected update runtime', (tester) async {
    final controller = await loadController(tester);
    addTearDown(controller.dispose);
    final runtime = UpdateRuntime(
      buildConfig: const UpdateBuildConfig.disabled(),
      installed: null,
      service: null,
      downloader: UpdateDownloader(),
      installer: ApkUpdateInstaller(),
      notesLoader: UpdateNotesLoader(),
      disabledReason: 'not_configured',
    );
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          controller: controller,
          updateRuntime: runtime,
          onMenuPressed: () {},
        ),
      ),
    );

    await openAbout(tester);
    await tester.tap(find.byKey(const ValueKey('about-update-center-tile')));
    await tester.pumpAndSettle();

    expect(find.byType(UpdateCenterPage), findsOneWidget);
    expect(find.byKey(const ValueKey('update-auto-check')), findsOneWidget);
    expect(find.text('自动更新未配置'), findsOneWidget);
  });
}
