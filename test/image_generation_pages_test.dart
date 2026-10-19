import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/image_generation_config.dart';
import 'package:ryza_chat_mvp/src/image_generation_manager_page.dart';
import 'package:ryza_chat_mvp/src/image_generation_settings_page.dart';
import 'package:ryza_chat_mvp/src/image_generation_store.dart';

void main() {
  testWidgets('image settings save public config and independent key', (
    tester,
  ) async {
    ImageGenerationConfig? savedConfig;
    String? savedKey;
    const initial = ImageGenerationConfig(
      enabled: true,
      baseUrl: 'https://images.example.com/v1',
      model: 'draw-v2',
      protocol: ImageGenerationProtocol.asyncTask,
      width: 768,
      height: 1024,
      aspectRatio: '3:4',
      outputFormat: 'webp',
      endpointPath: '/jobs',
      statusEndpointTemplate: '/jobs/{task_id}',
      pollIntervalSeconds: 3,
      maxPollAttempts: 40,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ImageGenerationSettingsPage(
          initialConfig: initial,
          initialApiKey: 'saved-secret',
          onSave: (config, key) async {
            savedConfig = config;
            savedKey = key;
          },
        ),
      ),
    );

    expect(find.byKey(const ValueKey('image-generation-base-url')), findsOne);
    expect(find.byKey(const ValueKey('image-generation-protocol')), findsOne);
    await tester.tap(
      find.byKey(const ValueKey('image-generation-settings-save')),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(savedKey, 'saved-secret');
    expect(savedConfig?.enabled, isTrue);
    expect(savedConfig?.protocol, ImageGenerationProtocol.asyncTask);
    expect(savedConfig?.endpointPath, '/jobs');
    expect(savedConfig?.statusEndpointTemplate, '/jobs/{task_id}');
    expect(savedConfig?.pollIntervalSeconds, 3);
    expect(savedConfig?.maxPollAttempts, 40);
  });

  testWidgets('manager shows a failed task and forwards retry', (tester) async {
    final directory = Directory.systemTemp.createTempSync(
      'image_generation_page_test_',
    );
    final store = ImageGenerationStore(
      directoryProvider: () async => directory,
      idGenerator: () => 'img_${'a' * 32}',
    );
    var retried = false;
    final task = (await tester.runAsync(() async {
      final created = await store.createTask(prompt: '画一只猫');
      await store.markGenerating(created.id);
      await store.fail(created.id, '网络暂时不可用');
      return created;
    }))!;

    await tester.pumpWidget(
      MaterialApp(
        home: ImageGenerationManagerPage(
          store: store,
          onRetry: (_) async => retried = true,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('画一只猫').evaluate().isNotEmpty) break;
    }

    expect(find.text('画一只猫'), findsOne);
    expect(find.text('网络暂时不可用'), findsOne);
    await tester.tap(find.byKey(ValueKey('image-generation-retry-${task.id}')));
    await tester.pump();
    expect(retried, isTrue);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    store.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  testWidgets(
    'unknown result requires a duplicate billing confirmation before retry',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'image_generation_unknown_page_test_',
      );
      final store = ImageGenerationStore(
        directoryProvider: () async => directory,
        idGenerator: () => 'img_${'b' * 32}',
      );
      var retryCalls = 0;
      final task = (await tester.runAsync(() async {
        final created = await store.createTask(prompt: '画一片海');
        await store.markGenerating(created.id);
        return store.fail(created.id, '请求已提交，但连接中断', outcomeUnknown: true);
      }))!;

      await tester.pumpWidget(
        MaterialApp(
          home: ImageGenerationManagerPage(
            store: store,
            onRetry: (_) async => retryCalls++,
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();

      expect(find.text('结果未知'), findsOneWidget);
      expect(find.textContaining('确认前不会重新提交'), findsOneWidget);
      final retry = find.byKey(ValueKey('image-generation-retry-${task.id}'));
      final retryButton = tester.widget<TextButton>(retry);
      retryButton.onPressed!();
      retryButton.onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('image-generation-unknown-retry-dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('可能重复计费，将重新提交生成'), findsOneWidget);
      expect(retryCalls, 0);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(retryCalls, 0);
      expect(store.taskById(task.id)?.outcomeUnknown, isTrue);

      tester.widget<TextButton>(retry).onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final confirmButton = tester.widget<FilledButton>(
        find.byKey(ValueKey('image-generation-confirm-unknown-${task.id}')),
      );
      confirmButton.onPressed!();
      for (var i = 0; i < 30 && retryCalls == 0; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(retryCalls, 1);
      expect(store.taskById(task.id)?.status, ImageGenerationTaskStatus.queued);
      expect(store.taskById(task.id)?.outcomeUnknown, isFalse);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      store.dispose();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    },
  );
}
