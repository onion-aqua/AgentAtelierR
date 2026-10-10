// Native Android audio diagnostics. Production main never imports this file.
// Build through build_protected.ps1 -Mode debug -EntryPoint <this file>.
// Uses generated PCM tones and a locally supplied MP3; never calls AI services.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/speech_loudness.dart';
import 'package:ryza_chat_mvp/src/speech_file_playback.dart';
import 'package:ryza_chat_mvp/src/tts_spatial_settings.dart';

void main() {
  if (!kDebugMode) throw StateError('Audio diagnostics require a debug build.');
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  runApp(const MaterialApp(home: _AudioDiagnostics()));
}

class _AudioDiagnostics extends StatefulWidget {
  const _AudioDiagnostics();
  @override
  State<_AudioDiagnostics> createState() => _AudioDiagnosticsState();
}

class _AudioDiagnosticsState extends State<_AudioDiagnostics> {
  final results = <Map<String, Object?>>[];
  bool running = false;
  bool finished = false;

  Future<void> run() async {
    if (running) return;
    setState(() {
      running = true;
      finished = false;
      results.clear();
    });
    final directory = await getTemporaryDirectory();
    final work = Directory('${directory.path}/asmr-audio-diagnostics');
    await work.create(recursive: true);
    final player = AudioPlayer();
    await player.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(audioFocus: AndroidAudioFocus.none),
      ),
    );
    Future<void> check(
      String name,
      String path, {
      bool invalid = false,
      bool asBytes = false,
    }) async {
      Object? failure;
      int? duration;
      final complete = Completer<void>();
      final subscription = player.onPlayerComplete.listen(
        (_) {
          if (!complete.isCompleted) complete.complete();
        },
        onError: (Object _) {
          /* Preparation failures are handled by setSource. */
        },
      );
      try {
        if (asBytes) {
          await player.play(
            BytesSource(await File(path).readAsBytes()),
            volume: .1,
          );
        } else {
          await playSpeechFile(
            player,
            path,
            volume: .1,
          ).timeout(const Duration(seconds: 15));
        }
        duration = (await player.getDuration())?.inMilliseconds;
        await complete.future.timeout(const Duration(seconds: 15));
      } on Object catch (error) {
        failure = error;
      } finally {
        await subscription.cancel();
        try {
          await player.stop();
        } on Object {
          /* Failed source may be stopped. */
        }
      }
      final result = <String, Object?>{
        'case': name,
        'ok': invalid ? failure != null : failure == null,
        'bytes': await File(path).length(),
        'durationMs': duration,
        if (failure != null) 'error': failure.toString(),
      };
      debugPrint('AAR_AUDIO_CHECK ${jsonEncode(result)}');
      if (mounted) setState(() => results.add(result));
    }

    try {
      for (final rate in [24000, 44100, 48000]) {
        final file = File('${work.path}/tone-$rate.mp3');
        await file.writeAsBytes(_tone(rate), flush: true);
        await check('PCM mono $rate', file.path);
        for (final position in TtsStereoPosition.values) {
          final path = await balanceSpeechLoudness(
            file.path,
            asmr: true,
            stereoEnabled: true,
            stereoPosition: position,
          );
          await check('PCM stereo $rate ${position.name}', path);
          if (position == TtsStereoPosition.center) {
            await check('PCM stereo $rate bytes', path, asBytes: true);
          }
        }
      }
      final mp3 = File('${directory.path}/asmr-test-fixture.mp3');
      if (await mp3.exists()) {
        await check('Raw MP3', mp3.path);
        for (final enabled in [false, true]) {
          final path = await balanceSpeechLoudness(
            mp3.path,
            asmr: true,
            stereoEnabled: enabled,
          );
          await check('MP3 decode stereo=$enabled', path);
        }
      } else {
        results.add({'case': 'MP3 fixture missing', 'ok': false});
      }
      // Exercise the same MediaPlayer across 40 source replacements.
      for (var index = 1; index <= 40; index++) {
        final file = File('${work.path}/sequential-$index.wav');
        await file.writeAsBytes(_tone(24000), flush: true);
        final path = await balanceSpeechLoudness(file.path, asmr: true);
        await check('Mono sequence $index', path);
      }
      final bad = File('${work.path}/truncated.wav');
      await bad.writeAsBytes([82, 73, 70, 70, 4, 0, 0, 0, 87, 65, 86, 69]);
      await check('Truncated WAV must fail', bad.path, invalid: true);
    } finally {
      await player.dispose();
      await File('${work.path}/report.json')
          .writeAsString(jsonEncode(results), flush: true);
      debugPrint(
        'AAR_AUDIO_DONE ${results.where((r) => r['ok'] != true).length} failures',
      );
      if (mounted) {
        setState(() {
          running = false;
          finished = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ASMR Android 音频检查')),
    body: Column(
      children: [
        FilledButton(
          onPressed: running ? null : run,
          child: Text(running ? '检查中…' : '开始检查'),
        ),
        if (finished)
          Text('完成：${results.where((r) => r['ok'] != true).length} 项失败'),
        Expanded(
          child: ListView(
            children: [
              for (final result in results)
                ListTile(
                  title: Text(
                    '${result['ok'] == true ? 'PASS' : 'FAIL'} ${result['case']}',
                  ),
                  subtitle: Text(
                    '${result['durationMs'] ?? ''} ${result['error'] ?? ''}',
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

Uint8List _tone(int rate) {
  final frames = rate ~/ 2;
  final bytes = Uint8List(44 + frames * 2);
  final data = ByteData.sublistView(bytes);
  for (final part in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    bytes.setRange(part.key, part.key + 4, part.value.codeUnits);
  }
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, frames * 2, Endian.little);
  for (var frame = 0; frame < frames; frame++) {
    data.setInt16(
      44 + frame * 2,
      (4000 * sin(2 * pi * 440 * frame / rate)).round(),
      Endian.little,
    );
  }
  return bytes;
}
