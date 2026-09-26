import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_envelope.dart';
import 'runtime_log.dart';

Future<AudioAmplitudeEnvelope?> loadSpeechEnvelope(
  String path,
  Uint8List bytes,
) async {
  final wav = await compute(_parseWavEnvelope, bytes);
  if (wav != null) return wav;
  if (!Platform.isAndroid) return null;
  try {
    final values = await const MethodChannel('agent_atelier_r/speech_envelope')
        .invokeListMethod<num>('analyze', {'path': path});
    if (values == null || values.isEmpty) return null;
    return AudioAmplitudeEnvelope.fromRms(
      values.map((v) => v.toDouble()).toList(),
    );
  } on Object catch (error, stack) {
    RuntimeLog.instance.error('LipSync', error, stack);
    return null;
  }
}

AudioAmplitudeEnvelope? _parseWavEnvelope(Uint8List bytes) =>
    AudioAmplitudeEnvelope.tryParseWav(bytes);
