import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/stage_environment_catalog.dart';

void main() {
  test('shared stage backgrounds resolve to the original scene group', () {
    expect(
      StageEnvironmentCatalog.sceneAssetIdFor(
        'stage_01_003_01',
        SceneTime.evening,
      ),
      'stage_01_003_03_eve',
    );
    expect(
      StageEnvironmentCatalog.sceneAssetIdFor(
        'stage_03_004_02',
        SceneTime.night,
      ),
      'stage_03_004_05_ngt',
    );
  });

  test('ambient tracks follow stage and day/night bindings', () {
    expect(
      StageEnvironmentCatalog.ambientAssetFor(
        'stage_01_002_01',
        SceneTime.morning,
      ),
      'audio/ambient/amb_007_day.m4a',
    );
    expect(
      StageEnvironmentCatalog.ambientAssetFor(
        'stage_01_002_01',
        SceneTime.night,
      ),
      'audio/ambient/amb_007_night.m4a',
    );
    expect(
      StageEnvironmentCatalog.ambientAssetFor(
        'stage_05_010_01',
        SceneTime.night,
      ),
      'audio/ambient/amb_047_day.m4a',
    );
  });

  test('unknown stages use the fallback scene without fake ambient audio', () {
    expect(
      StageEnvironmentCatalog.sceneAssetIdFor(
        'stage_unknown',
        SceneTime.afternoon,
      ),
      'stage_00_000_00_aft',
    );
    expect(
      StageEnvironmentCatalog.ambientAssetFor(
        'stage_unknown',
        SceneTime.afternoon,
      ),
      isNull,
    );
  });

  test('chat BGM prefers the exact stage before its shared background', () {
    expect(
      StageEnvironmentCatalog.chatBgmCandidatesFor('stage_01_003_01'),
      <String>[
        'audio/bgm/bgm_stage_01_003_01.m4a',
        'audio/bgm/bgm_stage_01_003_03.m4a',
      ],
    );
    expect(
      StageEnvironmentCatalog.chatBgmCandidatesFor('stage_01_002_01'),
      <String>['audio/bgm/bgm_stage_01_002_01.m4a'],
    );
  });
}
