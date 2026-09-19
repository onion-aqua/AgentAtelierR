import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'ai_services.dart' show AiServiceException;
import 'retry_policy.dart';
import 'app_controller.dart';
import 'app_localization.dart';
import 'mimo_tts_config.dart';
import 'runtime_log.dart';

// The official limit applies to the encoded string, not the source file.
const mimoMaxEncodedAudioBytes = 10 * 1000 * 1000;
int mimoEncodedLength(int bytes) => ((bytes + 2) ~/ 3) * 4;

String mimoReferenceDataUri(Uint8List bytes, String name) {
  final extension = name.toLowerCase().split('.').last;
  if (!{'mp3', 'wav'}.contains(extension)) {
    throw const AiServiceException('MiMo 参考音频仅支持 MP3、WAV');
  }
  if (bytes.isEmpty ||
      mimoEncodedLength(bytes.length) > mimoMaxEncodedAudioBytes) {
    throw const AiServiceException(
      '参考音频为空或过大：Base64 编码后需 ≤ 10 MB，原文件建议小于 7.5 MB',
    );
  }
  final wav =
      bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WAVE';
  final mp3 =
      bytes.length >= 3 &&
      ((bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) ||
          (bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0));
  if ((extension == 'wav' && !wav) || (extension == 'mp3' && !mp3)) {
    throw const AiServiceException('音频内容与扩展名不匹配，请选择有效的 MP3 或 WAV 文件');
  }
  return 'data:${extension == 'wav' ? 'audio/wav' : 'audio/mpeg'};base64,${base64Encode(bytes)}';
}

({String text, String instructions}) mimoSpeechPresentation(
  String speech,
  MimoTtsConfig config,
  TtsEmotionIntensity intensity,
  TtsCueDensity density, {
  bool asmr = false,
  AppLanguage? language,
}) {
  const cues = {
    'happy': '开心',
    'sad': '悲伤',
    'angry': '愤怒',
    'excited': '兴奋',
    'curious': '好奇',
    'calm': '平静',
    'relaxed': '放松',
    'sarcastic': '讽刺',
    'worried': '担忧',
    'confident': '自信',
    'surprised': '惊讶',
    'shy': '害羞',
    'whispering': '耳语',
    'whisper': '耳语',
    'near-whisper': '半耳语',
    'breathy': '气声',
    'very breathy voice': '明显气声',
    'extremely breathy voiced speech': '极轻气声',
    'airy voice': '轻盈气声',
    'soft breathy voice': '柔和气声',
    'soft intimate voice': '近距离轻声',
    'low volume': '小声',
    'low voice': '低声',
    'soft tone': '柔和',
    'inhale': '吸气',
    'exhale': '呼气',
    'sigh': '叹气',
    'sighing': '叹气',
    'short pause': '短暂停顿',
    'pause': '停顿',
    'break': '停顿',
    'long-break': '长停顿',
    'emphasis': '重音',
    'laughing': '笑',
    'chuckling': '轻笑',
    'sobbing': '抽泣',
  };
  const delivery = {
    'whispering',
    'whisper',
    'near-whisper',
    'breathy',
    'very breathy voice',
    'extremely breathy voiced speech',
    'airy voice',
    'soft breathy voice',
    'soft intimate voice',
    'low volume',
    'low voice',
    'soft tone',
    'inhale',
    'exhale',
    'sigh',
    'sighing',
    'short pause',
    'pause',
    'break',
    'long-break',
    'emphasis',
    'laughing',
    'chuckling',
    'sobbing',
    'panting',
    'gasping',
    'shouting',
    'screaming',
  };
  final budget = switch (density) {
    TtsCueDensity.off => 0,
    TtsCueDensity.sparse => 1,
    TtsCueDensity.normal => 3,
    TtsCueDensity.frequent => 6,
    TtsCueDensity.everySentence => 12,
  };
  var used = 0;
  var hasText = false;
  final text = speech.replaceAllMapped(
    RegExp(r'\[([^\]\r\n]{1,80})\]|[^\[]+'),
    (match) {
      final tag = match.group(1);
      if (tag == null) {
        if (match.group(0)!.trim().isNotEmpty) hasText = true;
        return match.group(0)!;
      }
      final key = tag.trim().toLowerCase();
      if (key.contains(':')) return ''; // Never read face/action/control tags.
      final isDelivery = delivery.contains(key);
      if (!isDelivery && intensity == TtsEmotionIntensity.off) return '';
      if ((hasText || isDelivery) && used++ >= budget) return '';
      return '[${cues[key] ?? key}]';
    },
  ).trim();
  return (
    text: text,
    instructions: [
      if (config.instructions.trim().isNotEmpty) config.instructions.trim(),
      intensity.voiceInstruction,
      '保持原文语言，只朗读 assistant 中的台词，不朗读标签或演绎指令。情绪连贯过渡，不要突然改变声线。',
      if (density == TtsCueDensity.off) '不主动加入额外呼吸、笑声、叹气等句内音效。',
      if (asmr)
        config.asmrInstructions.trim().isEmpty
            ? const MimoTtsConfig().asmrInstructions
            : config.asmrInstructions.trim(),
      if (asmr) '即使情绪加强，也保持低音量和近距离感，不喊叫。',
      if (language != null)
        '本次语音的目标语言为${language.promptLabel}（由“莱莎回复语言”设置指定）。'
            '使用该语言自然发音，不受参考音频语言或其他演绎指令影响。'
            '只朗读提供的台词，不添加翻译、解释或语言名称；专有名词和外语引用按原文发音。',
    ].join('\n'),
  );
}

class MimoTtsClient {
  MimoTtsClient({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  void close() => _client.close();

  Future<String> synthesize({
    required MimoTtsConfig config,
    required String apiKey,
    required String text,
    required TtsEmotionIntensity intensity,
    required TtsCueDensity density,
    required AppLanguage language,
    bool asmr = false,
  }) async {
    Uint8List? reference;
    if (config.isClone) {
      final file = File(config.referencePath);
      if (!await file.exists()) {
        throw const AiServiceException('MiMo 参考音频不存在，请在设置中重新选择');
      }
      if (mimoEncodedLength(await file.length()) > mimoMaxEncodedAudioBytes) {
        throw const AiServiceException('MiMo 参考音频编码后超过 10 MB');
      }
      reference = await file.readAsBytes();
    }
    final bytes = await synthesizeBytes(
      config: config,
      apiKey: apiKey,
      text: text,
      intensity: intensity,
      density: density,
      asmr: asmr,
      referenceBytes: reference,
      language: language,
    );
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/mimo_tts_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<Uint8List> synthesizeBytes({
    required MimoTtsConfig config,
    required String apiKey,
    required String text,
    required TtsEmotionIntensity intensity,
    required TtsCueDensity density,
    bool asmr = false,
    Uint8List? referenceBytes,
    AppLanguage? language,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const AiServiceException('请填写 MiMo API Key');
    }
    if (config.validationError case final error?) {
      throw AiServiceException(error);
    }
    final presentation = mimoSpeechPresentation(
      text,
      config,
      intensity,
      density,
      asmr: asmr,
      language: language,
    );
    if (presentation.text
        .replaceAll(RegExp(r'\[[^\]]*\]'), '')
        .trim()
        .isEmpty) {
      throw const AiServiceException('请填写需要朗读的文字');
    }
    final voice = config.isClone
        ? mimoReferenceDataUri(
            referenceBytes ?? Uint8List(0),
            config.referencePath,
          )
        : config.voice.trim();
    final base = config.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final endpoint = base.endsWith('/chat/completions')
        ? base
        : '$base/chat/completions';
    final body = {
      'model': config.model,
      'messages': [
        {'role': 'user', 'content': presentation.instructions},
        {'role': 'assistant', 'content': presentation.text},
      ],
      'audio': {'format': 'wav', if (!config.isDesign) 'voice': voice},
      'stream': false,
    };
    final log = RuntimeLog.instance;
    log.communication(
      source: 'TTS',
      direction: 'request',
      method: 'POST',
      url: endpoint,
      payload: {
        ...body,
        'audio': {
          'format': 'wav',
          if (!config.isDesign)
            'voice': config.isClone
                ? '[参考音频 ${referenceBytes!.length} bytes；Base64 已省略]'
                : voice,
        },
      },
    );
    final started = DateTime.now();
    final response = await withAiRequestRetries<http.Response>(
      () => _client
          .post(
            Uri.parse(endpoint),
            headers: {
              'Authorization': 'Bearer ${apiKey.trim()}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 120)),
      shouldRetryResult: (result) => isRetryableHttpStatus(result.statusCode),
    );
    Map<String, dynamic>? decoded;
    try {
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is Map<String, dynamic>) decoded = value;
    } on FormatException {
      /* Report a readable protocol error below. */
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final serverError = decoded?['error'];
      var detail = serverError is Map ? '${serverError['message'] ?? ''}' : '';
      detail = detail.replaceAll(apiKey.trim(), '[API Key]');
      if (voice.isNotEmpty) detail = detail.replaceAll(voice, '[voice]');
      final message =
          'MiMo TTS 请求失败 (${response.statusCode}) ${detail.length > 500 ? detail.substring(0, 500) : detail}';
      log.communication(
        source: 'TTS',
        direction: 'response',
        method: 'POST',
        url: endpoint,
        statusCode: response.statusCode,
        payload: {'error': message},
        duration: DateTime.now().difference(started),
      );
      throw AiServiceException(message);
    }
    final choices = decoded?['choices'];
    final choice = choices is List && choices.isNotEmpty ? choices.first : null;
    final message = choice is Map ? choice['message'] : null;
    final audio = message is Map ? message['audio'] : null;
    final data = audio is Map ? audio['data'] : null;
    Uint8List? bytes;
    if (data is String) {
      try {
        bytes = base64Decode(data);
      } on FormatException {
        /* Invalid payload. */
      }
    }
    log.communication(
      source: 'TTS',
      direction: 'response',
      method: 'POST',
      url: endpoint,
      statusCode: response.statusCode,
      duration: DateTime.now().difference(started),
      payload: {
        'model': decoded?['model'],
        'usage': decoded?['usage'],
        'audio_bytes': bytes?.length ?? 0,
        'format': 'wav',
        'finish_reason': choice is Map ? choice['finish_reason'] : null,
      },
    );
    if (bytes == null ||
        bytes.length < 12 ||
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != 'WAVE') {
      throw const AiServiceException('MiMo 没有返回有效 WAV 音频，请查看运行日志中的返回状态');
    }
    return bytes;
  }
}
