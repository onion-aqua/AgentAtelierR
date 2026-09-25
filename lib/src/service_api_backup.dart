import 'ai_services.dart';
import 'openai_configuration_slots.dart';

class ServiceApiBackup {
  const ServiceApiBackup._(this.openAiSlotKeys, this.serviceKeys);

  static const field = 'serviceApiKeys';
  static const _names = [
    'gemini',
    'fishAudio',
    'dashScope',
    'genericTts',
    'mimoTts',
  ];

  final List<String> openAiSlotKeys;
  final Map<String, String> serviceKeys;

  static Future<Map<String, dynamic>> capture(SecretStore store) async => {
    'version': 1,
    'openAiSlotKeys': [
      for (var slot = 0; slot < OpenAiConfigurationSlots.count; slot++)
        await store.readOpenAiKey(slot: slot),
    ],
    'gemini': await store.readGeminiKey(),
    'fishAudio': await store.readFishAudioKey(),
    'dashScope': await store.readDashScopeKey(),
    'genericTts': await store.readGenericTtsKey(),
    'mimoTts': await store.readMimoTtsKey(),
  };

  static ServiceApiBackup? parse(Object? value) {
    if (value == null) return null;
    if (value is! Map || value['version'] != 1) {
      throw const FormatException('备份中的 API 密钥格式无效');
    }
    final slots = value['openAiSlotKeys'];
    if (slots is! List ||
        slots.length != OpenAiConfigurationSlots.count ||
        slots.any((key) => key is! String) ||
        _names.any((name) => value[name] is! String)) {
      throw const FormatException('备份中的 API 密钥格式无效');
    }
    return ServiceApiBackup._(List<String>.from(slots), {
      for (final name in _names) name: value[name] as String,
    });
  }

  Future<void> restore(SecretStore store) async {
    await store.writeOpenAiSlotKeys({
      for (var slot = 0; slot < openAiSlotKeys.length; slot++)
        slot: openAiSlotKeys[slot],
    });
    await store.writeGeminiKey(serviceKeys['gemini']!);
    await store.writeFishAudioKey(serviceKeys['fishAudio']!);
    await store.writeDashScopeKey(serviceKeys['dashScope']!);
    await store.writeGenericTtsKey(serviceKeys['genericTts']!);
    await store.writeMimoTtsKey(serviceKeys['mimoTts']!);
  }
}
