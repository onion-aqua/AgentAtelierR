import 'dart:async';
import 'dart:convert';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show FlutterSecureStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/settings_detail_page.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AppController> setup(
    WidgetTester tester,
    SettingsSection section,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'dashscope_api_key': 'test-key',
      'openai_api_key': 'test-key',
    });
    final controller = (await tester.runAsync(AppController.load))!;
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger = tester.binding.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(MethodChannel(name), null),
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final events = MethodChannel('xyz.luan/audioplayers/events/$id');
          messenger.setMockMethodCallHandler(events, (_) async => null);
          addTearDown(() => messenger.setMockMethodCallHandler(events, null));
        }
        return null;
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'),
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          controller: controller,
          onMenuPressed: () {},
          initialSection: section,
        ),
      ),
    );
    return controller;
  }

  Future<void> tapVisible(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> openQwen(WidgetTester tester, {bool legacyClone = false}) async {
    await setup(tester, SettingsSection.audio);
    await tapVisible(tester, find.text('百炼 Qwen-TTS'));
    if (legacyClone) {
      // Explicit custom targets retain the former file-based compatibility UI.
      await tester.enterText(
        find.byKey(const ValueKey('qwen-clone-model')),
        'legacy-custom-vc',
      );
      await tester.pump();
      await tester.ensureVisible(find.text('选择音频'));
    }
    await tester.pumpAndSettle();
  }

  Future<void> invokeButton(WidgetTester tester, Finder button) async {
    // Keep the returned Future so a late result must finish without an error.
    final callback = tester.widget<OutlinedButton>(button).onPressed!;
    await (callback as dynamic)();
  }

  for (final stage in ['picker', 'read']) {
    testWidgets('Qwen reference $stage completion after returning is ignored', (
      tester,
    ) async {
      await openQwen(tester, legacyClone: true);
      final picked = Completer<List<PlatformFile>>();
      final bytes = Completer<Uint8List>();
      final fake = _FilePicker(pickMany: () => picked.future);
      final original = FilePickerPlatform.instance;
      FilePickerPlatform.instance = fake;
      addTearDown(() => FilePickerPlatform.instance = original);
      final action = invokeButton(
        tester,
        find.widgetWithText(OutlinedButton, '选择音频'),
      );
      if (stage == 'read') {
        picked.complete([_MemoryFile('voice.wav', read: () => bytes.future)]);
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsDetailPage), findsNothing);
      if (stage == 'picker') {
        picked.complete([_MemoryFile('voice.wav')]);
      } else {
        bytes.complete(Uint8List.fromList([1, 2, 3]));
      }
      await action;
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  for (final success in [true, false]) {
    testWidgets(
      'Qwen clone ${success ? 'success' : 'error'} after Cancel leaves category intact',
      (tester) async {
        await openQwen(tester);
        await tester.enterText(
          find.byKey(const ValueKey('qwen-endpoint')),
          'https://test-workspace.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer',
        );
        await tester.enterText(
          find.byKey(const ValueKey('qwen-reference-url')),
          'https://audio.example/reference.wav',
        );
        await tester.pump();
        final response = Completer<http.Response>();
        var requests = 0;
        final client = MockClient((request) {
          requests++;
          expect(
            request.url.toString(),
            'https://test-workspace.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/customization',
          );
          expect(
            (jsonDecode(request.body) as Map)['model'],
            'voice-enrollment',
          );
          return response.future;
        });
        addTearDown(client.close);
        final action = http.runWithClient(
          () => invokeButton(
            tester,
            find.widgetWithText(OutlinedButton, '创建音色并自动回填 Voice ID'),
          ),
          () => client,
        );
        await tester.pump();
        expect(requests, 1);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        response.complete(
          success
              ? http.Response('{"output":{"voice_id":"test-clone"}}', 200)
              : http.Response('{"message":"test rejection"}', 400),
        );
        await action;
        await tester.pump();
        expect(find.byType(SettingsDetailPage), findsNothing);
        expect(find.text('百炼 Qwen-TTS'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final success in [true, false]) {
    testWidgets(
      'legacy conversion ${success ? 'success' : 'error'} keeps its progress route on system Back',
      (tester) async {
        final controller = await setup(tester, SettingsSection.data);
        controller.configureAi(
          enabled: true,
          baseUrl: 'https://example.test/v1',
          model: 'test-model',
        );
        final original = FilePickerPlatform.instance;
        FilePickerPlatform.instance = _FilePicker(
          pickOne: () async =>
              _MemoryFile('legacy.json', data: utf8.encode('{"messages":[]}')),
        );
        addTearDown(() => FilePickerPlatform.instance = original);
        final response = Completer<http.Response>();
        var requests = 0;
        final client = MockClient((request) {
          requests++;
          return response.future;
        });
        addTearDown(client.close);
        final tile = tester.widget<ListTile>(
          find.widgetWithText(ListTile, '旧数据导入转换器'),
        );
        final action = http.runWithClient(
          () async => await (tile.onTap as dynamic)(),
          () => client,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(requests, 1);
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(AlertDialog), findsOneWidget);
        response.complete(
          success
              ? http.Response(
                  jsonEncode({
                    'choices': [
                      {
                        'message': {'content': '{"messages":[]}'},
                      },
                    ],
                  }),
                  200,
                )
              : http.Response('{"error":{"message":"test rejection"}}', 400),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        if (success) {
          expect(find.byType(SettingsDetailPage), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
        }
        await action;
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('旧数据导入转换器'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('generic TTS format remains usable at 200 percent text size', (
    tester,
  ) async {
    final controller = await setup(tester, SettingsSection.audio);
    tester.view.physicalSize = const Size(320, 700);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: SettingsScreen(
          controller: controller,
          onMenuPressed: () {},
          initialSection: SettingsSection.audio,
        ),
      ),
    );
    await tapVisible(tester, find.text('通用 OpenAI TTS'));
    final format = find.byType(DropdownButtonFormField<String>);
    await tester.ensureVisible(format);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(format);
    await tester.pumpAndSettle();
    await tester.tap(find.text('WAV').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<DropdownButtonFormField<String>>(format).initialValue,
      'wav',
    );
    expect(tester.takeException(), isNull);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirmed repair refreshes an existing card and its translation',
    (tester) async {
      final controller = await setup(tester, SettingsSection.data);
      controller.configureAi(
        enabled: true,
        baseUrl: 'https://example.test/v1',
        model: 'test-model',
      );
      controller.configureLongTermMemory(
        enabled: true,
        summary: jsonEncode({
          'entries': [
            {
              'summary': '莱莎：[happy]えへへ、仲間のこと話すのが新鮮だなあ',
              'translation': '旧译文',
              'category': 'mood',
              'source': 'local_ledger',
            },
          ],
        }),
      );
      await tapVisible(tester, find.text('长期记忆'));
      expect(find.text('旧译文'), findsOneWidget);
      http.Response completion(Object content) => http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': jsonEncode(content)},
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        final messages = body['messages'] as List;
        final prompt = '${(messages.first as Map)['content']}';
        if (prompt.contains('重新整理旧版本地事实记录')) {
          return completion({
            'entries': [
              {
                'sequence': 1,
                'summary': '莱莎谈起伙伴时感到新鲜。',
                'category': 'other',
                'importance': 1,
              },
            ],
          });
        }
        if (!prompt.contains('只翻译提供的记忆文本')) {
          throw StateError('Unexpected memory request');
        }
        return completion({
          'recent': [],
          'entries': [
            {'sequence': 1, 'translation': '伙伴话题的更新译文'},
          ],
        });
      });
      addTearDown(client.close);
      final callback = tester
          .widget<TextButton>(find.byKey(const ValueKey('memory-organize-now')))
          .onPressed!;
      final action = http.runWithClient(
        () async => await (callback as dynamic)(),
        () => client,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('待确认长期记忆'), findsOneWidget);
      expect(find.text('重新整理旧记忆'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('manual-memory-confirm')));
      await tester.pumpAndSettle();
      await action;
      expect(find.text('莱莎谈起伙伴时感到新鲜。'), findsOneWidget);
      expect(find.text('伙伴话题的更新译文'), findsOneWidget);
      expect(find.text('旧译文'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final edit in ['text', 'enabled', 'unchanged']) {
    testWidgets(
      'manual memory result preserves $edit draft and refreshes recent list',
      (tester) async {
        final controller = await setup(tester, SettingsSection.data);
        controller.configureAi(
          enabled: true,
          baseUrl: 'https://example.test/v1',
          model: 'test-model',
        );
        controller.configureLongTermMemory(enabled: true, summary: '原记忆');
        controller.addUserMessage('明天一起采集素材');
        controller.addAssistantMessage('莱莎：好，我们明天一起去。');
        await tapVisible(tester, find.text('长期记忆'));
        final response = Completer<http.Response>();
        var requests = 0;
        http.Response completion(Object content) => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': content is String ? content : jsonEncode(content),
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
        final client = MockClient((request) async {
          requests++;
          if (requests == 1) return response.future;
          final body = jsonDecode(request.body) as Map;
          final messages = body['messages'] as List;
          if (messages.any(
            (message) => '${message['content']}'.contains('只翻译提供的记忆文本'),
          )) {
            final input = jsonDecode(messages.last['content'] as String) as Map;
            return completion({
              'recent': [
                for (final item in input['recent'] as List)
                  {
                    'index': item['index'],
                    'translation': 'Recent memory translation',
                  },
              ],
              'entries': [
                for (final item in input['entries'] as List)
                  {
                    'sequence': item['sequence'],
                    'translation': 'Long-term memory translation',
                  },
              ],
            });
          }
          return completion({
            'entries': [
              {
                'date': '2026-10-12',
                'category': 'promise',
                'importance': 5,
                'summary': '双方约定明天一起采集素材',
              },
            ],
          });
        });
        addTearDown(client.close);
        final callback = tester
            .widget<TextButton>(
              find.byKey(const ValueKey('memory-organize-now')),
            )
            .onPressed!;
        final action = http.runWithClient(
          () async => await (callback as dynamic)(),
          () => client,
        );
        await tester.pump();
        expect(requests, 1);
        if (edit == 'text') {
          await tester.enterText(find.byType(TextField), '用户编辑的记忆');
        } else if (edit == 'enabled') {
          await tester.tap(find.widgetWithText(SwitchListTile, '启用长期记忆'));
          await tester.pump();
        }
        response.complete(completion({'summary': '新生成的最近记忆'}));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        if (edit == 'unchanged') {
          expect(
            find.byKey(const ValueKey('manual-memory-confirm')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('manual-memory-confirm')));
          await tester.pumpAndSettle();
          await action;
          await tester.tap(find.text('最近记忆'));
          await tester.pumpAndSettle();
          expect(find.textContaining('新生成的最近记忆'), findsOneWidget);
          expect(find.textContaining('最近记忆 1 条'), findsOneWidget);
        } else {
          await action;
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.textContaining('记忆草稿已修改'), findsOneWidget);
          expect(controller.memorySummary, '原记忆');
          expect(controller.recentMemories, isEmpty);
          if (edit == 'text') {
            expect(
              tester.widget<TextField>(find.byType(TextField)).controller!.text,
              '用户编辑的记忆',
            );
          } else {
            expect(
              tester
                  .widget<SwitchListTile>(
                    find.widgetWithText(SwitchListTile, '启用长期记忆'),
                  )
                  .value,
              false,
            );
          }
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

final class _MemoryFile extends PlatformFile {
  _MemoryFile(this.name, {List<int> data = const [1, 2, 3], this.read})
    : xFile = XFile.fromData(Uint8List.fromList(data), name: name);
  @override
  final String name;
  @override
  final XFile xFile;
  final Future<Uint8List> Function()? read;
  @override
  Uri get uri => Uri.parse('memory:$name');
  @override
  Future<int> length() => xFile.length();
  @override
  Future<Uint8List> readAsBytes() => read?.call() ?? xFile.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      xFile.openRead().map(Uint8List.fromList);
}

class _FilePicker extends FilePickerPlatform {
  _FilePicker({this.pickOne, this.pickMany});
  final Future<PlatformFile?> Function()? pickOne;
  final Future<List<PlatformFile>> Function()? pickMany;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) => pickOne?.call() ?? Future.value();
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) => pickMany?.call() ?? Future.value([]);
}
