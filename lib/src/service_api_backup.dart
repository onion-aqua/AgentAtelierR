import 'ai_services.dart';
import 'openai_configuration_slots.dart';

class ServiceApiBackup {
  const ServiceApiBackup._(
    this.openAiSlotKeys,
    this.serviceKeys, {
    required this.includesImageGeneration,
  });

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
  final bool includesImageGeneration;

  static Future<Map<String, dynamic>> capture(SecretStore store) async => {
    'version': 2,
    'openAiSlotKeys': [
      for (var slot = 0; slot < OpenAiConfigurationSlots.count; slot++)
        await store.readOpenAiKey(slot: slot),
    ],
    'gemini': await store.readGeminiKey(),
    'fishAudio': await store.readFishAudioKey(),
    'dashScope': await store.readDashScopeKey(),
    'genericTts': await store.readGenericTtsKey(),
    'mimoTts': await store.readMimoTtsKey(),
    'imageGeneration': await store.readImageGenerationKey(),
  };

  static ServiceApiBackup? parse(Object? value) {
    if (value == null) return null;
    if (value is! Map || (value['version'] != 1 && value['version'] != 2)) {
      throw const FormatException('备份中的 API 密钥格式无效');
    }
    final version = value['version'] as int;
    final slots = value['openAiSlotKeys'];
    if (slots is! List ||
        slots.length != OpenAiConfigurationSlots.count ||
        slots.any((key) => key is! String) ||
        _names.any((name) => value[name] is! String) ||
        (version >= 2 && value['imageGeneration'] is! String)) {
      throw const FormatException('备份中的 API 密钥格式无效');
    }
    return ServiceApiBackup._(List<String>.from(slots), {
      for (final name in _names) name: value[name] as String,
      if (version >= 2) 'imageGeneration': value['imageGeneration'] as String,
    }, includesImageGeneration: version >= 2);
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
    // Version 1 backups predate image generation. Restoring one must keep the
    // device's existing image key instead of silently deleting it.
    if (includesImageGeneration) {
      await store.writeImageGenerationKey(serviceKeys['imageGeneration']!);
    }
  }
}
