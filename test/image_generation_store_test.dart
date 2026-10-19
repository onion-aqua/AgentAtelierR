import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/image_generation_store.dart';

Uint8List _png() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

String _id(int value) => 'img_${value.toRadixString(16).padLeft(32, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late ImageGenerationStore store;
  var nextId = 1;
  var tick = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('image_task_store_');
    store = ImageGenerationStore(
      directoryProvider: () async => directory,
      idGenerator: () => _id(nextId++),
      clock: () => DateTime.utc(2026, 10, 19, 10, 0, tick++),
    );
  });

  tearDown(() async {
    store.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'stores original image, metadata, message link and unread state',
    () async {
      final queued = await store.createTask(
        prompt: ' 莱莎在海边 ',
        protocol: 'openAiImages',
        model: 'gpt-image',
        messageId: 'user-message-1',
      );
      expect(queued.prompt, '莱莎在海边');
      expect(queued.status, ImageGenerationTaskStatus.queued);
      expect(store.activeCount, 1);

      final generating = await store.markGenerating(queued.id);
      expect(generating.status, ImageGenerationTaskStatus.generating);
      final bytes = _png();
      final completed = await store.complete(
        queued.id,
        bytes: bytes,
        mimeType: 'image/png',
        messageId: 'assistant-image-1',
      );

      expect(completed.status, ImageGenerationTaskStatus.completed);
      expect(completed.messageId, 'assistant-image-1');
      expect(completed.mimeType, 'image/png');
      expect(completed.seen, isFalse);
      expect(completed.outcomeUnknown, isFalse);
      expect(store.activeCount, 0);
      expect(store.unseenCompletedCount, 1);
      expect(await store.readImage(queued.id), bytes);
      expect(File(completed.localPath!).parent.path, directory.path);

      final manifest = await File('${directory.path}/tasks.v1.json')
          .readAsString();
      expect(manifest, isNot(contains(directory.path)));
      expect(manifest, contains('${queued.id}.png'));
      expect(manifest, contains('assistant-image-1'));
    },
  );

  test('completed images and seen state survive process restart', () async {
    final task = await store.createTask(prompt: '水彩风工坊');
    await store.markGenerating(task.id, protocol: 'gemini', model: 'imagen');
    await store.complete(task.id, bytes: _png());
    await store.markSeen(task.id);
    store.dispose();

    final restored = ImageGenerationStore(
      directoryProvider: () async => directory,
    );
    addTearDown(restored.dispose);
    await restored.load();

    expect(restored.tasks, hasLength(1));
    final item = restored.tasks.single;
    expect(item.id, task.id);
    expect(item.protocol, 'gemini');
    expect(item.model, 'imagen');
    expect(item.status, ImageGenerationTaskStatus.completed);
    expect(item.seen, isTrue);
    expect(restored.unseenCompletedCount, 0);
    expect(await restored.readImage(task.id), _png());
  });

  test('mark all seen, link message and delete persist atomically', () async {
    final first = await store.createTask(prompt: '第一张');
    await store.complete(first.id, bytes: _png());
    final second = await store.createTask(prompt: '第二张');
    final completedSecond = await store.complete(second.id, bytes: _png());
    final secondFile = File(completedSecond.localPath!);
    expect(store.unseenCompletedCount, 2);

    await store.linkMessage(first.id, 'result-1');
    await store.markAllCompletedSeen();
    expect(store.unseenCompletedCount, 0);
    expect(store.taskById(first.id)?.messageId, 'result-1');

    await store.delete(second.id);
    expect(store.taskById(second.id), isNull);
    expect(await secondFile.exists(), isFalse);
    expect(store.tasks.single.id, first.id);
  });

  test(
    'failed and cancelled tasks can retry while terminal writes are blocked',
    () async {
      final failed = await store.createTask(prompt: '失败任务');
      await store.markGenerating(failed.id);
      final failure = await store.fail(
        failed.id,
        'network failed Authorization: Bearer secret-token '
        'https://example.test?key=hidden',
      );
      expect(failure.status, ImageGenerationTaskStatus.failed);
      expect(failure.error, contains('network failed'));
      expect(failure.error, isNot(contains('secret-token')));
      expect(failure.error, isNot(contains('key=hidden')));
      expect(failure.error, contains('[REDACTED]'));
      expect(
        (await store.retry(failed.id)).status,
        ImageGenerationTaskStatus.queued,
      );

      final cancelled = await store.cancel(failed.id);
      expect(cancelled.status, ImageGenerationTaskStatus.cancelled);
      await expectLater(
        store.complete(failed.id, bytes: _png()),
        throwsStateError,
      );
      await expectLater(store.cancel(failed.id), throwsStateError);
    },
  );

  test(
    'in-flight task becomes unknown-outcome failure after restart',
    () async {
      final task = await store.createTask(prompt: '不能盲目重试');
      await store.markGenerating(task.id);
      store.dispose();

      final restored = ImageGenerationStore(
        directoryProvider: () async => directory,
        clock: () => DateTime.utc(2026, 10, 19, 11),
      );
      addTearDown(restored.dispose);
      await restored.load();
      final item = restored.tasks.single;
      expect(item.status, ImageGenerationTaskStatus.failed);
      expect(item.error, contains('远端结果状态未知'));
      expect(item.outcomeUnknown, isTrue);
      expect(item.completedAt, DateTime.utc(2026, 10, 19, 11));
      await expectLater(restored.retry(task.id), throwsStateError);
      final retried = await restored.retry(task.id, allowUnknownOutcome: true);
      expect(retried.status, ImageGenerationTaskStatus.queued);
      expect(retried.outcomeUnknown, isFalse);
    },
  );

  test(
    'unknown failure persists and always requires explicit retry consent',
    () async {
      final task = await store.createTask(prompt: '请求可能已经送达');
      await store.markGenerating(task.id);
      final failed = await store.fail(
        task.id,
        '连接在提交后中断',
        outcomeUnknown: true,
      );
      expect(failed.outcomeUnknown, isTrue);
      store.dispose();

      final restored = ImageGenerationStore(
        directoryProvider: () async => directory,
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.tasks.single.outcomeUnknown, isTrue);
      await expectLater(restored.retry(task.id), throwsStateError);
      expect(
        restored.taskById(task.id)?.status,
        ImageGenerationTaskStatus.failed,
      );
    },
  );

  test(
    'old queued task becomes retryable instead of loading forever',
    () async {
      final task = await store.createTask(prompt: '还没提交');
      store.dispose();

      final restored = ImageGenerationStore(
        directoryProvider: () async => directory,
        clock: () => DateTime.utc(2026, 10, 19, 12),
      );
      addTearDown(restored.dispose);
      await restored.load();
      final item = restored.taskById(task.id)!;
      expect(item.status, ImageGenerationTaskStatus.failed);
      expect(item.error, contains('请求提交前中断'));
      expect(restored.isGenerating, isFalse);
      expect(
        (await restored.retry(task.id)).status,
        ImageGenerationTaskStatus.queued,
      );
    },
  );

  test(
    'missing or corrupt completed image is not exposed after restart',
    () async {
      final task = await store.createTask(prompt: '会损坏');
      final completed = await store.complete(task.id, bytes: _png());
      await File(completed.localPath!).writeAsBytes([1, 2, 3], flush: true);
      store.dispose();

      final restored = ImageGenerationStore(
        directoryProvider: () async => directory,
      );
      addTearDown(restored.dispose);
      await restored.load();
      final item = restored.tasks.single;
      expect(item.status, ImageGenerationTaskStatus.failed);
      expect(item.localPath, isNull);
      expect(item.error, contains('损坏'));
      await expectLater(restored.readImage(task.id), throwsStateError);
    },
  );

  test(
    'invalid saved MIME is normalized without failing the whole load',
    () async {
      final task = await store.createTask(prompt: '元数据损坏但原图有效');
      await store.complete(task.id, bytes: _png());
      final manifestFile = File('${directory.path}/tasks.v1.json');
      final manifest = jsonDecode(await manifestFile.readAsString()) as Map;
      (manifest['tasks'] as List).single['mimeType'] = 'broken/not-an-image';
      await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
      store.dispose();

      final restored = ImageGenerationStore(
        directoryProvider: () async => directory,
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.tasks, hasLength(1));
      final item = restored.tasks.single;
      expect(item.status, ImageGenerationTaskStatus.completed);
      expect(item.mimeType, 'image/png');
      expect(item.outcomeUnknown, isFalse);
      expect(await restored.readImage(task.id), _png());
      final rewritten = jsonDecode(await manifestFile.readAsString()) as Map;
      expect((rewritten['tasks'] as List).single['mimeType'], 'image/png');
    },
  );

  test(
    'rejects non-images and MIME mismatches without partial files',
    () async {
      final task = await store.createTask(prompt: '校验图片');
      await expectLater(
        store.complete(task.id, bytes: Uint8List.fromList([1, 2, 3, 4])),
        throwsFormatException,
      );
      await expectLater(
        store.complete(task.id, bytes: _png(), mimeType: 'image/jpeg'),
        throwsFormatException,
      );
      expect(store.taskById(task.id)?.status, ImageGenerationTaskStatus.queued);
      expect(
        await directory
            .list()
            .where((entry) => entry.path.endsWith('.png'))
            .toList(),
        isEmpty,
      );
    },
  );

  test('copies input bytes before queued storage work runs', () async {
    final task = await store.createTask(prompt: '快照');
    final bytes = _png();
    final completion = store.complete(task.id, bytes: bytes);
    bytes.fillRange(0, bytes.length, 0);
    final completed = await completion;
    expect(await File(completed.localPath!).readAsBytes(), _png());
  });

  test(
    'malformed records and path traversal cannot escape managed storage',
    () async {
      final outside = File('${directory.parent.path}/outside-image.png');
      await outside.writeAsBytes(_png());
      addTearDown(() async {
        if (await outside.exists()) await outside.delete();
      });
      await File('${directory.path}/tasks.v1.json').writeAsString(
        jsonEncode({
          'version': 1,
          'tasks': [
            {
              'id': _id(99),
              'prompt': 'unsafe',
              'status': 'completed',
              'createdAt': '2026-10-19T00:00:00Z',
              'imageFile': '../outside-image.png',
              'seen': false,
            },
            {'id': '../../escape', 'prompt': 'bad'},
          ],
        }),
        flush: true,
      );

      await store.load();
      expect(store.tasks.single.status, ImageGenerationTaskStatus.failed);
      expect(store.tasks.single.localPath, isNull);
      expect(await outside.exists(), isTrue);
      final rewritten = await File('${directory.path}/tasks.v1.json')
          .readAsString();
      expect(rewritten, isNot(contains('../outside-image.png')));
    },
  );
}
