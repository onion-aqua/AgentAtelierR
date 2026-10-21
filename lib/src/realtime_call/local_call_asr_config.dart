import 'dart:io';
import 'dart:typed_data';

/// Local SenseVoice and Silero VAD files. Microphone audio stays on the device.
class LocalCallAsrConfig {
  const LocalCallAsrConfig({
    required this.modelPath,
    required this.tokensPath,
    required this.vadModelPath,
    this.language = 'auto',
    this.silenceSeconds = 0.65,
  });

  factory LocalCallAsrConfig.fromJson(Map<String, dynamic> json) {
    return LocalCallAsrConfig(
      modelPath: json['modelPath'] as String? ?? '',
      tokensPath: json['tokensPath'] as String? ?? '',
      vadModelPath: json['vadModelPath'] as String? ?? '',
      language: json['language'] as String? ?? 'auto',
      silenceSeconds: (json['silenceSeconds'] as num?)?.toDouble() ?? 0.65,
    );
  }

  final String modelPath;
  final String tokensPath;
  final String vadModelPath;
  final String language;
  final double silenceSeconds;

  static const supportedLanguages = ['auto', 'zh', 'en', 'ja', 'ko', 'yue'];
  static const sampleRate = 16000;
  static const vadWindowSamples = 512;

  Map<String, dynamic> toJson() => {
    'modelPath': modelPath,
    'tokensPath': tokensPath,
    'vadModelPath': vadModelPath,
    'language': language,
    'silenceSeconds': silenceSeconds,
  };

  Future<void> validateFiles() async {
    if (!supportedLanguages.contains(language)) {
      throw const FormatException('本地识别语言必须是 auto/zh/en/ja/ko/yue。');
    }
    if (!silenceSeconds.isFinite ||
        silenceSeconds < 0.3 ||
        silenceSeconds > 2) {
      throw const FormatException('断句静音时长应为 0.3–2 秒。');
    }
    for (final entry in {
      'SenseVoice 模型': modelPath,
      'tokens.txt': tokensPath,
      'Silero VAD 模型': vadModelPath,
    }.entries) {
      final file = File(entry.value);
      if (entry.value.trim().isEmpty ||
          !await file.exists() ||
          await file.length() == 0) {
        throw FormatException('请先导入有效的 ${entry.key} 文件。');
      }
    }
  }
}

enum LocalCallAsrEventKind {
  ready,
  speechStarted,
  speechEnded,
  transcript,
  level,
  error,
}

class LocalCallAsrEvent {
  const LocalCallAsrEvent(
    this.kind, {
    this.text = '',
    this.level = 0,
    this.epoch = 0,
  });

  final LocalCallAsrEventKind kind;
  final String text;
  final double level;

  /// Results from an earlier mute/playback boundary must be discarded.
  final int epoch;
}

/// As microphone packets can split a 16-bit sample, retain the trailing byte.
class LocalCallPcm16Decoder {
  int? _lowByte;

  Float32List decode(Uint8List bytes) {
    final output = Float32List(
      (bytes.length + (_lowByte == null ? 0 : 1)) ~/ 2,
    );
    var input = 0;
    var out = 0;
    if (_lowByte != null && bytes.isNotEmpty) {
      output[out++] = _toFloat(_lowByte!, bytes[input++]);
      _lowByte = null;
    }
    while (input + 1 < bytes.length) {
      output[out++] = _toFloat(bytes[input], bytes[input + 1]);
      input += 2;
    }
    if (input < bytes.length) _lowByte = bytes[input];
    return output;
  }

  double _toFloat(int low, int high) {
    var sample = low | (high << 8);
    if (sample >= 0x8000) sample -= 0x10000;
    return sample / 32768;
  }

  void reset() => _lowByte = null;
}

/// Each boundary invalidates queued VAD/ASR results, including a late decode.
class LocalCallAsrGate {
  bool muted = false;
  bool listeningEnabled = true;
  bool captureReady = true;
  int epoch = 0;

  bool get wantsAudio => !muted && listeningEnabled;
  bool get acceptsAudio => wantsAudio && captureReady;

  void reset() => epoch++;

  bool acceptsResult(int resultEpoch) => acceptsAudio && resultEpoch == epoch;
}
