/// Shared configuration for the documented DashScope TTS HTTP APIs.
///
/// Qwen-Audio-TTS uses SpeechSynthesizer; the earlier Qwen3-TTS HTTP models
/// use multimodal-generation. Their parameters and system voices differ.
class QwenTtsConfig {
  static const legacyEndpoint =
      'https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation';
  static const modernPath = '/api/v1/services/audio/tts/SpeechSynthesizer';
  static const legacyPath =
      '/api/v1/services/aigc/multimodal-generation/generation';
  static const customizationPath = '/api/v1/services/audio/tts/customization';
  static const regions = {'cn-beijing': '北京', 'ap-southeast-1': '新加坡'};

  static const models = [
    'qwen-audio-3.1-tts-flash',
    'qwen-audio-3.0-tts-plus',
    'qwen-audio-3.0-tts-flash',
    'qwen3-tts-flash',
  ];

  static const languages = {
    'auto': '自动识别',
    'zh': '中文',
    'ja': '日语',
    'en': '英语',
    'ko': '韩语',
    'fr': '法语',
    'de': '德语',
    'ru': '俄语',
    'pt': '葡萄牙语',
    'es': '西班牙语',
    'it': '意大利语',
    'th': '泰语',
    'id': '印尼语',
    'vi': '越南语',
    'ms': '马来西亚语',
    'fil': '菲律宾语',
    'ar': '阿拉伯语',
  };
  static const legacyLanguages = {
    'auto': 'Auto',
    'zh': 'Chinese',
    'en': 'English',
    'ja': 'Japanese',
    'ko': 'Korean',
    'fr': 'French',
    'de': 'German',
    'ru': 'Russian',
    'pt': 'Portuguese',
    'es': 'Spanish',
    'it': 'Italian',
  };
  static const _otherLanguageNames = {
    'thai': 'th',
    'indonesian': 'id',
    'vietnamese': 'vi',
    'malay': 'ms',
    'filipino': 'fil',
    'arabic': 'ar',
  };

  // A compact selection from the official system-voice catalogs. Custom IDs
  // remain editable; a catalog is not an allowlist for cloned/future voices.
  static const modern31Voices = [
    'longanhuan_v3.1',
    'longanlingxin_v3.1',
    'longanfengyue_v3.1',
    'xunanchuan_v3.1',
  ];
  static const modern30PlusVoices = ['longanlingxin', 'longanlufeng'];
  static const modern30FlashVoices = [
    'longanfengyue',
    'longanyuanfei',
    'longanlingxi',
    'longanxiaoxin',
    'longanhuan_v3.6',
    'longjielidou_v3.6',
    'longpaopao_v3.6',
    'longhuohuo_v3.6',
    'longchuanshu_v3.6',
    'loongmary',
    'loongeva_v3.6',
    'loongjohn',
  ];
  static const legacyVoices = [
    'Cherry',
    'Serena',
    'Ethan',
    'Chelsie',
    'Momo',
    'Vivian',
    'Moon',
    'Maia',
    'Kai',
    'Nofish',
    'Bella',
    'Jennifer',
    'Ryan',
    'Katerina',
    'Aiden',
    'Eldric Sage',
    'Mia',
    'Mochi',
    'Bellona',
    'Vincent',
    'Bunny',
    'Neil',
    'Elias',
    'Arthur',
    'Nini',
    'Seren',
    'Pip',
    'Stella',
    'Bodega',
    'Sonrisa',
    'Alek',
    'Dolce',
    'Sohee',
    'Ono Anna',
    'Lenn',
    'Emilien',
    'Andre',
    'Radio Gol',
    'Jada',
    'Dylan',
    'Li',
    'Marcus',
    'Roy',
    'Peter',
    'Sunny',
    'Eric',
    'Rocky',
    'Kiki',
  ];

  static bool isModernModel(String model) =>
      model.trim().toLowerCase().startsWith('qwen-audio-');

  static bool isRealtimeModel(String model) =>
      model.trim().toLowerCase().contains('realtime');

  static bool supportsInstructions(String model, {String voice = ''}) {
    if (isRealtimeModel(model)) return false;
    if (model.trim() == 'qwen-audio-3.0-tts-flash' &&
        const ['loongmary', 'loongeva_v3.6', 'loongjohn'].contains(voice)) {
      return false;
    }
    return isModernModel(model) ||
        model.trim().toLowerCase().startsWith('qwen3-tts-instruct-');
  }

  static String normalizeLanguage(String value) {
    final normalized = value.trim().toLowerCase().replaceAll('_', '-');
    if (normalized.isEmpty || normalized == '自动' || normalized == '自动识别') {
      return 'auto';
    }
    if (languages.containsKey(normalized)) return normalized;
    for (final entry in legacyLanguages.entries) {
      if (entry.value.toLowerCase() == normalized) return entry.key;
    }
    for (final entry in languages.entries) {
      if (entry.value == value.trim()) return entry.key;
    }
    if (_otherLanguageNames.containsKey(normalized)) {
      return _otherLanguageNames[normalized]!;
    }
    final primary = normalized.split('-').first;
    return languages.containsKey(primary) ? primary : value.trim();
  }

  static String legacyLanguage(String value) {
    final normalized = normalizeLanguage(value);
    return legacyLanguages[normalized] ?? value.trim();
  }

  static Map<String, String> languagesForModel(String model) =>
      isModernModel(model)
      ? languages
      : {for (final code in legacyLanguages.keys) code: languages[code]!};

  static List<String> voicesForModel(String model) {
    final value = model.trim();
    if (value == 'qwen-audio-3.1-tts-flash') return modern31Voices;
    if (value == 'qwen-audio-3.0-tts-plus') return modern30PlusVoices;
    if (value == 'qwen-audio-3.0-tts-flash') return modern30FlashVoices;
    if (value.startsWith('qwen3-tts-') &&
        !value.contains('-vc-') &&
        !value.contains('-vd-')) {
      return legacyVoices;
    }
    return const [];
  }

  static String modelLabel(String model) => switch (model) {
    'qwen-audio-3.1-tts-flash' => 'Qwen-Audio 3.1 Flash（多语种）',
    'qwen-audio-3.0-tts-plus' => 'Qwen-Audio 3.0 Plus',
    'qwen-audio-3.0-tts-flash' => 'Qwen-Audio 3.0 Flash',
    'qwen3-tts-flash' => 'Qwen3-TTS Flash（兼容旧配置）',
    'qwen3-tts-instruct-flash' => '旧兼容指令模型（需账号支持）',
    _ => model,
  };

  /// Flags only known cross-model mismatches; future/custom IDs pass through.
  static String? voiceCompatibilityError(String model, String voice) {
    final selected = model.trim();
    final configured = voice.trim();
    if (isModernModel(selected) && legacyVoices.contains(configured)) {
      return '音色 $configured 属于旧版 Qwen-TTS，请为 $selected 选择对应系统音色或复刻音色';
    }
    for (final family in models.where(isModernModel)) {
      final knownVoice =
          voicesForModel(family).contains(configured) ||
          configured.startsWith('$family-');
      if (knownVoice &&
          selected != family &&
          (isModernModel(selected) || selected.startsWith('qwen3-tts-'))) {
        return '音色 $configured 属于 $family，不能与 $selected 混用';
      }
    }
    return null;
  }

  static String workspaceBaseUrl({
    required String workspaceId,
    String region = 'cn-beijing',
  }) {
    if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(workspaceId.trim()) ||
        _placeholder(workspaceId.trim())) {
      throw const FormatException('请填写有效的百炼业务空间 ID');
    }
    if (!regions.containsKey(region)) {
      throw const FormatException('请选择北京或新加坡地域');
    }
    return 'https://${workspaceId.trim()}.$region.maas.aliyuncs.com';
  }

  static String synthesisEndpoint(String configured, String model) =>
      _endpoint(configured, isModernModel(model) ? modernPath : legacyPath);

  static String customizationEndpoint(String configured) =>
      _endpoint(configured, customizationPath, forcePath: true);

  static String _endpoint(
    String configured,
    String path, {
    bool forcePath = false,
  }) {
    final uri = Uri.tryParse(
      configured.trim().isEmpty ? legacyEndpoint : configured.trim(),
    );
    if (uri == null ||
        !const {'https', 'http'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.host.contains('{') ||
        uri.host.contains('}') ||
        _placeholder(uri.host.split('.').first)) {
      throw const FormatException('请填写有效的百炼 HTTPS 地址，并替换业务空间 ID 占位符');
    }
    if (uri.scheme != 'https' &&
        !const {'localhost', '127.0.0.1', '::1'}.contains(uri.host)) {
      throw const FormatException('百炼公网接口必须使用 HTTPS，不能通过明文 HTTP 发送 API Key');
    }
    if (path == modernPath &&
        const {
          'dashscope.aliyuncs.com',
          'dashscope-intl.aliyuncs.com',
          'dashscope-us.aliyuncs.com',
        }.contains(uri.host)) {
      throw const FormatException(
        'Qwen-Audio-TTS 请配置对应地域的业务空间专属 HTTPS 地址：'
        'https://业务空间ID.cn-beijing.maas.aliyuncs.com（或新加坡地域）',
      );
    }
    final current = uri.path.replaceAll(RegExp(r'/+$'), '');
    final normalize =
        forcePath ||
        const {
          '',
          '/api/v1',
          '/v1',
          '/compatible-mode/v1',
          modernPath,
          legacyPath,
        }.contains(current);
    return uri
        .replace(path: normalize ? path : uri.path)
        .removeFragment()
        .toString();
  }

  static bool _placeholder(String value) =>
      const {'workspaceid', 'yourworkspaceid', 'yourworkspace'}.contains(
        Uri.decodeComponent(value)
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]'), ''),
      );
}

class QwenTtsOptions {
  const QwenTtsOptions({
    this.sampleRate = 24000,
    this.rate = 1.0,
    this.pitch = 1.0,
    this.volume = 50,
    this.optimizeInstructions = true,
  });

  static const sampleRates = [8000, 12000, 16000, 22050, 24000, 44100, 48000];
  final int sampleRate;
  final double rate;
  final double pitch;
  final int volume;
  final bool optimizeInstructions;

  factory QwenTtsOptions.fromJson(Object? value) {
    if (value is! Map) return const QwenTtsOptions();
    final sample = value['sample_rate'];
    final rate = value['rate'];
    final pitch = value['pitch'];
    final volume = value['volume'];
    return QwenTtsOptions(
      sampleRate: sample is int && sampleRates.contains(sample)
          ? sample
          : 24000,
      rate: rate is num && rate.isFinite && rate >= 0.5 && rate <= 2
          ? rate.toDouble()
          : 1,
      pitch: pitch is num && pitch.isFinite && pitch >= 0.5 && pitch <= 2
          ? pitch.toDouble()
          : 1,
      volume: volume is int && volume >= 0 && volume <= 100 ? volume : 50,
      optimizeInstructions: value['optimize_instructions'] is bool
          ? value['optimize_instructions'] as bool
          : true,
    );
  }

  Map<String, dynamic> toJson() => {
    'sample_rate': sampleRate,
    'rate': rate,
    'pitch': pitch,
    'volume': volume,
    'optimize_instructions': optimizeInstructions,
  };

  QwenTtsOptions copyWith({
    int? sampleRate,
    double? rate,
    double? pitch,
    int? volume,
    bool? optimizeInstructions,
  }) => QwenTtsOptions(
    sampleRate: sampleRate ?? this.sampleRate,
    rate: rate ?? this.rate,
    pitch: pitch ?? this.pitch,
    volume: volume ?? this.volume,
    optimizeInstructions: optimizeInstructions ?? this.optimizeInstructions,
  );

  String? get validationError {
    if (!sampleRates.contains(sampleRate)) return '不支持的 Qwen-TTS 采样率';
    if (!rate.isFinite || rate < 0.5 || rate > 2) return '语速应为 0.5–2.0';
    if (!pitch.isFinite || pitch < 0.5 || pitch > 2) return '音调应为 0.5–2.0';
    if (volume < 0 || volume > 100) return '音量应为 0–100';
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is QwenTtsOptions &&
      sampleRate == other.sampleRate &&
      rate == other.rate &&
      pitch == other.pitch &&
      volume == other.volume &&
      optimizeInstructions == other.optimizeInstructions;

  @override
  int get hashCode =>
      Object.hash(sampleRate, rate, pitch, volume, optimizeInstructions);
}
