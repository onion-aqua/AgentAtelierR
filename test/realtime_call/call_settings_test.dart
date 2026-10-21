import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_settings.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_model_download.dart';
import 'package:ryza_chat_mvp/src/realtime_call/local_call_asr_config.dart';

final class _PickedFile extends PlatformFile {
  _PickedFile(this.name, this.bytes, {this.reportedLength});
  @override
  final String name;
  final Uint8List bytes;
  final int? reportedLength;
  @override
  Uri get uri => Uri.parse('content://provider/models/$name');
  @override
  XFile get xFile => throw UnsupportedError('not a local path');
  @override
  Future<int> length() async => reportedLength ?? bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

class _InstalledAsr extends LocalCallAsrConfig {
  const _InstalledAsr()
    : super(
        modelPath: '/private/realtime_call/asr/model.int8.onnx',
        tokensPath: '/private/realtime_call/asr/tokens.txt',
        vadModelPath: '/private/realtime_call/asr/silero_vad.onnx',
      );
  @override
  Future<void> validateFiles() async {}
}

class _ModelDownloader extends CallAsrModelDownloader {
  @override
  Future<LocalCallAsrConfig> install({
    required LocalCallAsrConfig previous,
    void Function(CallModelDownloadProgress)? onProgress,
  }) async {
    onProgress?.call(const CallModelDownloadProgress('Gitee · 模型下载完成'));
    return const _InstalledAsr();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'configuration persists across store instances without credentials',
    () async {
      final settings = CallSettings(
        asr: const LocalCallAsrConfig(
          modelPath: '/private/call/model.int8.onnx',
          tokensPath: '/private/call/tokens.txt',
          vadModelPath: '/private/call/silero_vad.onnx',
          language: 'ja',
        ),
        fishModel: 'future-model',
        voiceOverrides: {'npc-kara': 'kara-voice'},
      );
      await CallSettingsStore().save(settings);
      final restored = await CallSettingsStore().load();
      expect(restored.toJson(), settings.toJson());
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getKeys(), {CallSettingsStore.preferenceKey});
      expect(
        preferences.getString(CallSettingsStore.preferenceKey),
        isNot(contains('apiKey')),
      );
    },
  );

  test(
    'corrupt stored configuration falls back without crashing settings',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final store = CallSettingsStore(preferences: preferences);
      for (final malformed in ['{', '[]', '{"asr":{"language":5}}']) {
        await preferences.setString(CallSettingsStore.preferenceKey, malformed);
        expect((await store.load()).fishModel, 'drama-3');
        expect((await store.load()).asr.modelPath, isEmpty);
      }
    },
  );

  test(
    'NPC cannot inherit main character voice and overrides are immutable',
    () {
      final voices = {'npc-kara': 'kara-voice'};
      final settings = CallSettings(voiceOverrides: voices);
      voices['npc-kara'] = 'changed';
      expect(settings.voiceFor('npc-kara'), 'kara-voice');
      expect(
        settings.voiceFor('npc-fee', mainCharacterVoice: 'ryza-voice'),
        isEmpty,
      );
      expect(
        settings.voiceFor(
          'ryza',
          isMainCharacter: true,
          mainCharacterVoice: 'ryza-voice',
        ),
        'ryza-voice',
      );
      expect(
        () => settings.voiceOverrides['npc-kara'] = 'changed',
        throwsUnsupportedError,
      );
    },
  );

  testWidgets('Klaudia explains its built-in voice fallback', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: RealtimeCallSettingsPage(
          contacts: [
            CallContactOption(id: 'claudia', name: '科洛蒂娅'),
            CallContactOption(id: 'kara', name: '卡菈'),
          ],
          defaultFishModel: 'drama-3',
          defaultVoice: '',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('call-voice-claudia')),
      420,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('留空使用应用内置的科洛蒂娅音色'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('留空使用应用内置的科洛蒂娅音色'), findsOneWidget);
    expect(find.text('此 NPC 需要独立音色'), findsOneWidget);
  });

  testWidgets('download fills model rows and Save persists installed paths', (
    tester,
  ) async {
    final store = CallSettingsStore();
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeCallSettingsPage(
          contacts: const [],
          defaultFishModel: 'drama-3',
          defaultVoice: '',
          store: store,
          downloader: _ModelDownloader(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('call-download-models')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('call-download-models')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('call-download-models')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('三个本地模型文件已就绪'),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('三个本地模型文件已就绪'), findsOneWidget);
    // Download fills the form; it does not silently bypass the existing Save.
    expect((await store.load()).asr.modelPath, isEmpty);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = await store.load();
    expect(saved.asr.toJson(), const _InstalledAsr().toJson());
  });

  group('model import', () {
    late Directory support;
    late CallAsrModelImporter importer;
    setUp(() async {
      support = await Directory.systemTemp.createTemp(
        'ryza-call-model-import-',
      );
      importer = CallAsrModelImporter(directoryProvider: () async => support);
    });
    tearDown(() => support.delete(recursive: true));

    test(
      'Android content URI imports by stream into durable local file',
      () async {
        final picked = _PickedFile(
          'model.int8.onnx',
          Uint8List.fromList([1, 2, 3]),
        );
        expect(picked.path, isNull);
        final imported = await importer.importPickedFile(
          picked,
          CallAsrModelFile.senseVoice,
        );
        expect(imported, contains('realtime_call/asr'));
        expect(await File(imported).readAsBytes(), [1, 2, 3]);
        expect(imported, endsWith('.onnx'));
      },
    );

    test('oversize, empty or wrong file type cannot be imported', () async {
      for (final file in [
        _PickedFile('model.onnx', Uint8List(0)),
        _PickedFile('model.jpg', Uint8List.fromList([1])),
        _PickedFile(
          'model.onnx',
          Uint8List.fromList([1]),
          reportedLength: CallAsrModelImporter.maximumFileBytes + 1,
        ),
      ]) {
        await expectLater(
          importer.importPickedFile(file, CallAsrModelFile.senseVoice),
          throwsFormatException,
        );
      }
      expect(await support.list(recursive: true).toList(), isEmpty);
    });

    test(
      'truncated/expanded copy removes .part and keeps previous model',
      () async {
        final valid = await importer.importPickedFile(
          _PickedFile('model.onnx', Uint8List.fromList([1, 2])),
          CallAsrModelFile.senseVoice,
        );
        for (final length in [1, 3]) {
          await expectLater(
            importer.importPickedFile(
              _PickedFile(
                'model.onnx',
                Uint8List.fromList([4, 5]),
                reportedLength: length,
              ),
              CallAsrModelFile.senseVoice,
            ),
            throwsFormatException,
          );
        }
        expect(await File(valid).readAsBytes(), [1, 2]);
        expect(
          (await support.list(recursive: true).toList()).whereType<File>().map(
            (f) => f.absolute.path.replaceAll('\\', '/'),
          ),
          [File(valid).absolute.path.replaceAll('\\', '/')],
        );
      },
    );

    test(
      'managed cleanup removes replaced models but rejects external paths',
      () async {
        final oldModel = await importer.importPickedFile(
          _PickedFile('old.onnx', Uint8List.fromList([1, 2])),
          CallAsrModelFile.senseVoice,
        );
        final outside = File('${support.path}/keep.onnx');
        await outside.writeAsBytes([3, 4]);

        expect(await importer.deleteManagedFile(outside.path), isFalse);
        expect(await outside.exists(), isTrue);
        expect(await importer.deleteManagedFile(oldModel), isTrue);
        expect(await File(oldModel).exists(), isFalse);
        expect(await importer.deleteManagedFile(oldModel), isFalse);
      },
    );
  });
}
