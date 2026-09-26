import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/audio_envelope.dart';
import 'package:ryza_chat_mvp/src/character_lipsync.dart';
import 'package:ryza_chat_mvp/src/character_resource_behavior.dart';

void main() {
  test('resource closure holds a real amplitude dip then opens again', () {
    const envelope = AudioAmplitudeEnvelope(
      frameDuration: Duration(milliseconds: 20),
      values: [0.7, 0.8, 0.02, 0.8, 0.8, 0.8, 0.8],
      rawRms: [0.05, 0.08, 0.003, 0.08, 0.08, 0.08, 0.08],
    );
    final dynamics = CharacterLipSyncDynamics(
      const CharacterLipSyncClosure(enabled: true),
    );
    final before = dynamics.sample(envelope, Duration.zero);
    final peak = dynamics.sample(
      envelope,
      const Duration(milliseconds: 20),
    );
    final dip = dynamics.sample(envelope, const Duration(milliseconds: 40));
    final held = dynamics.sample(envelope, const Duration(milliseconds: 60));
    final reopened = dynamics.sample(
      envelope,
      const Duration(milliseconds: 120),
    );
    expect(before, greaterThan(0));
    expect(peak, greaterThan(before));
    expect(dip, lessThan(peak));
    expect(held, lessThan(dip));
    expect(reopened, greaterThan(held));
    expect(
      dynamics.sample(envelope, const Duration(milliseconds: 200)),
      lessThan(reopened),
    );
  });

  test('closure settings are loaded from gesture resources', () {
    final behavior = CharacterResourceBehavior.parse('''
      {"projectConfig":{"lipSyncClosure":{"enabled":true,
      "ratio":0.2,"minHoldMs":80,"opennessFloorDb":-38}}}
    ''');
    expect(behavior.lipSyncClosure.enabled, isTrue);
    expect(behavior.lipSyncClosure.ratio, 0.2);
    expect(behavior.lipSyncClosure.minHoldMs, 80);
    expect(behavior.lipSyncClosure.opennessFloorDb, -38);
  });
}
