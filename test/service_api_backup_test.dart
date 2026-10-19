import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/service_api_backup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const store = SecretStore();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('all service keys round-trip through an optional backup', () async {
    await store.writeOpenAiSlotKeys({0: 'open-0', 1: 'open-1', 2: 'open-2'});
    await store.writeGeminiKey('gemini');
    await store.writeFishAudioKey('fish');
    await store.writeDashScopeKey('dash');
    await store.writeGenericTtsKey('generic');
    await store.writeMimoTtsKey('mimo');
    await store.writeImageGenerationKey('image');

    final exported = await ServiceApiBackup.capture(store);
    expect(exported['version'], 2);
    expect(exported['openAiSlotKeys'], ['open-0', 'open-1', 'open-2']);
    await store.writeOpenAiSlotKeys({0: '', 1: '', 2: ''});
    await store.writeGeminiKey('');
    await store.writeFishAudioKey('');
    await store.writeDashScopeKey('');
    await store.writeGenericTtsKey('');
    await store.writeMimoTtsKey('');
    await store.writeImageGenerationKey('');

    await ServiceApiBackup.parse(exported)!.restore(store);
    expect(await store.readOpenAiKey(slot: 0), 'open-0');
    expect(await store.readOpenAiKey(slot: 1), 'open-1');
    expect(await store.readOpenAiKey(slot: 2), 'open-2');
    expect(await store.readGeminiKey(), 'gemini');
    expect(await store.readFishAudioKey(), 'fish');
    expect(await store.readDashScopeKey(), 'dash');
    expect(await store.readGenericTtsKey(), 'generic');
    expect(await store.readMimoTtsKey(), 'mimo');
    expect(await store.readImageGenerationKey(), 'image');
  });

  test('version 1 credential backup keeps the current image key', () async {
    await store.writeImageGenerationKey('keep-image');
    final legacy = {
      'version': 1,
      'openAiSlotKeys': ['', '', ''],
      'gemini': '',
      'fishAudio': '',
      'dashScope': '',
      'genericTts': '',
      'mimoTts': '',
    };

    await ServiceApiBackup.parse(legacy)!.restore(store);

    expect(await store.readImageGenerationKey(), 'keep-image');
  });

  test('legacy backup leaves current keys untouched', () async {
    await store.writeGeminiKey('existing');
    expect(ServiceApiBackup.parse(null), isNull);
    expect(await store.readGeminiKey(), 'existing');
  });

  test('malformed credential data is rejected before restore', () {
    expect(
      () => ServiceApiBackup.parse({
        'version': 1,
        'openAiSlotKeys': ['only-one'],
        'gemini': 'key',
      }),
      throwsFormatException,
    );
  });
}
