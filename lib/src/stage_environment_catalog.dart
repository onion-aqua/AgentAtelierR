import 'app_controller.dart';

/// Original stage routing reconstructed from the bundled 1.0.3 assets.
///
/// The catalog intentionally contains paths only. The referenced media stays
/// local and is excluded from source control.
abstract final class StageEnvironmentCatalog {
  static const defaultChatBgmAsset = 'audio/bgm/bgm_opening.m4a';
  static const worldMapBgmAsset = 'audio/bgm/bgm_world_map.m4a';

  static String backgroundIdFor(String stageId) => switch (stageId) {
    'stage_00_000_00' => 'stage_00_000_00',
    'stage_01_001_01' => 'stage_01_001_01',
    'stage_01_001_02' => 'stage_01_001_02',
    'stage_01_001_04' => 'stage_01_001_04',
    'stage_01_001_05' => 'stage_01_001_05',
    'stage_01_001_06' => 'stage_01_001_06',
    'stage_01_001_08' => 'stage_01_001_08',
    'stage_01_002_01' => 'stage_01_002_01',
    'stage_01_002_02' => 'stage_01_002_02',
    'stage_01_002_03' => 'stage_01_002_03',
    'stage_01_002_04' => 'stage_01_002_04',
    'stage_01_003_01' ||
    'stage_01_003_02' ||
    'stage_01_003_03' ||
    'stage_01_003_04' ||
    'stage_01_003_05' => 'stage_01_003_03',
    'stage_01_004_01' ||
    'stage_01_004_02' ||
    'stage_01_004_03' => 'stage_01_004_01',
    'stage_01_005_01' ||
    'stage_01_005_02' ||
    'stage_01_005_03' => 'stage_01_005_01',
    'stage_01_006_01' || 'stage_01_006_02' => 'stage_01_006_02',
    'stage_01_007_01' ||
    'stage_01_007_02' ||
    'stage_01_007_03' => 'stage_01_007_01',
    'stage_01_008_01' || 'stage_01_008_02' => 'stage_01_008_02',
    'stage_01_009_01' ||
    'stage_01_009_02' ||
    'stage_01_009_03' => 'stage_01_009_02',
    'stage_01_010_01' => 'stage_01_010_01',
    'stage_01_011_01' ||
    'stage_01_011_02' ||
    'stage_01_011_03' ||
    'stage_01_011_04' => 'stage_01_011_02',
    'stage_01_012_01' ||
    'stage_01_012_02' ||
    'stage_01_012_03' => 'stage_01_012_03',
    'stage_01_013_01' ||
    'stage_01_013_02' ||
    'stage_01_013_03' ||
    'stage_01_013_04' ||
    'stage_01_013_05' ||
    'stage_01_013_06' => 'stage_01_013_03',
    'stage_01_014_01' => 'stage_01_014_01',
    'stage_02_001_01' ||
    'stage_02_001_02' ||
    'stage_02_001_03' => 'stage_02_001_01',
    'stage_02_002_01' ||
    'stage_02_002_02' ||
    'stage_02_002_03' ||
    'stage_02_002_04' => 'stage_02_002_02',
    'stage_02_003_01' ||
    'stage_02_003_02' ||
    'stage_02_003_03' ||
    'stage_02_003_04' ||
    'stage_02_003_05' ||
    'stage_02_003_06' ||
    'stage_02_003_07' ||
    'stage_02_003_08' => 'stage_02_003_04',
    'stage_02_004_01' ||
    'stage_02_004_02' ||
    'stage_02_004_03' ||
    'stage_02_004_04' ||
    'stage_02_004_05' ||
    'stage_02_004_06' => 'stage_02_004_02',
    'stage_02_005_01' ||
    'stage_02_005_02' ||
    'stage_02_005_03' => 'stage_02_005_03',
    'stage_03_001_01' ||
    'stage_03_001_02' ||
    'stage_03_001_03' ||
    'stage_03_001_04' ||
    'stage_03_001_05' => 'stage_03_001_03',
    'stage_03_002_01' ||
    'stage_03_002_02' ||
    'stage_03_002_03' ||
    'stage_03_002_04' ||
    'stage_03_002_05' ||
    'stage_03_002_06' => 'stage_03_002_01',
    'stage_03_003_01' ||
    'stage_03_003_02' ||
    'stage_03_003_03' => 'stage_03_003_01',
    'stage_03_004_01' ||
    'stage_03_004_02' ||
    'stage_03_004_03' ||
    'stage_03_004_04' ||
    'stage_03_004_05' => 'stage_03_004_05',
    'stage_03_005_01' ||
    'stage_03_005_02' ||
    'stage_03_005_03' => 'stage_03_005_01',
    'stage_04_001_01' ||
    'stage_04_001_02' ||
    'stage_04_001_03' ||
    'stage_04_001_04' ||
    'stage_04_001_05' ||
    'stage_04_001_06' => 'stage_04_001_01',
    'stage_04_002_01' ||
    'stage_04_002_02' ||
    'stage_04_002_03' => 'stage_04_002_01',
    'stage_04_003_01' ||
    'stage_04_003_02' ||
    'stage_04_003_03' ||
    'stage_04_003_04' ||
    'stage_04_003_05' => 'stage_04_003_01',
    'stage_05_001_01' ||
    'stage_05_002_01' ||
    'stage_05_002_02' ||
    'stage_05_002_03' ||
    'stage_05_002_04' ||
    'stage_05_003_01' ||
    'stage_05_004_01' ||
    'stage_05_005_01' ||
    'stage_05_006_01' ||
    'stage_05_007_01' ||
    'stage_05_008_01' ||
    'stage_05_009_01' ||
    'stage_05_010_01' ||
    'stage_05_012_01' => stageId,
    _ => 'stage_00_000_00',
  };

  static String sceneAssetIdFor(String stageId, SceneTime time) {
    final suffix = switch (time) {
      SceneTime.morning => 'mor',
      SceneTime.afternoon => 'aft',
      SceneTime.evening => 'eve',
      SceneTime.night => 'ngt',
    };
    return '${backgroundIdFor(stageId)}_$suffix';
  }

  /// Ordered local BGM overrides for the chat scene.
  ///
  /// A stage-specific track wins over a track shared by stages that use the
  /// same background. The caller falls back to [defaultChatBgmAsset] when none
  /// of these files are bundled.
  static List<String> chatBgmCandidatesFor(String stageId) {
    final backgroundId = backgroundIdFor(stageId);
    return <String>{
      'audio/bgm/bgm_$stageId.m4a',
      'audio/bgm/bgm_$backgroundId.m4a',
    }.toList(growable: false);
  }

  static String? ambientAssetFor(String stageId, SceneTime time) {
    final id = _ambientIdFor(stageId);
    if (id == null) return null;
    final nightBand = time == SceneTime.evening || time == SceneTime.night;
    final band = nightBand && !_dayOnlyAmbients.contains(id) ? 'night' : 'day';
    return 'audio/ambient/amb_${id}_$band.m4a';
  }

  static const _dayOnlyAmbients = <String>{
    '010',
    '012',
    '013',
    '014',
    '015',
    '016',
    '017',
    '026',
    '027',
    '033',
    '035',
    '036',
    '042',
    '043',
    '044',
    '045',
    '046',
    '047',
  };

  static String? _ambientIdFor(String stageId) => switch (stageId) {
    'stage_01_001_01' => '001',
    'stage_01_001_02' => '002',
    'stage_01_001_04' => '003',
    'stage_01_001_05' => '004',
    'stage_01_001_06' => '005',
    'stage_01_001_08' => '006',
    'stage_01_002_01' => '007',
    'stage_01_002_02' ||
    'stage_01_002_04' ||
    'stage_03_002_02' ||
    'stage_03_002_03' ||
    'stage_03_002_05' ||
    'stage_03_002_06' => '008',
    'stage_01_002_03' => '009',
    'stage_01_003_01' => '010',
    'stage_01_003_02' ||
    'stage_01_003_03' ||
    'stage_01_003_04' ||
    'stage_01_003_05' => '011',
    'stage_01_004_01' || 'stage_01_004_02' || 'stage_01_004_03' => '012',
    'stage_01_005_01' || 'stage_01_005_02' || 'stage_01_005_03' => '013',
    'stage_01_006_01' || 'stage_01_006_02' => '014',
    'stage_01_007_01' || 'stage_01_007_02' || 'stage_01_007_03' => '015',
    'stage_01_008_01' || 'stage_01_008_02' => '016',
    'stage_01_009_01' ||
    'stage_01_009_02' ||
    'stage_01_009_03' ||
    'stage_01_010_01' ||
    'stage_02_003_01' ||
    'stage_02_003_02' ||
    'stage_02_003_03' ||
    'stage_02_003_04' ||
    'stage_02_003_05' ||
    'stage_02_003_06' ||
    'stage_02_003_07' ||
    'stage_02_003_08' ||
    'stage_05_003_01' ||
    'stage_05_012_01' => '017',
    'stage_01_011_01' ||
    'stage_01_011_02' ||
    'stage_01_011_03' ||
    'stage_01_011_04' => '018',
    'stage_01_012_01' => '019',
    'stage_01_012_02' || 'stage_01_012_03' => '020',
    'stage_01_013_01' ||
    'stage_01_013_02' ||
    'stage_01_013_03' ||
    'stage_01_013_04' ||
    'stage_01_013_05' ||
    'stage_01_013_06' => '021',
    'stage_03_001_01' ||
    'stage_03_001_02' ||
    'stage_03_001_03' ||
    'stage_03_001_04' ||
    'stage_03_001_05' ||
    'stage_03_002_04' => '022',
    'stage_03_002_01' => '024',
    'stage_04_001_01' ||
    'stage_04_001_02' ||
    'stage_04_001_03' ||
    'stage_04_001_04' ||
    'stage_04_001_05' ||
    'stage_04_001_06' => '025',
    'stage_03_004_01' ||
    'stage_03_004_02' ||
    'stage_03_004_03' ||
    'stage_03_004_04' ||
    'stage_03_004_05' ||
    'stage_04_002_01' ||
    'stage_04_002_02' ||
    'stage_04_002_03' => '026',
    'stage_01_014_01' => '027',
    'stage_02_001_01' || 'stage_02_001_02' || 'stage_02_001_03' => '028',
    'stage_02_002_02' => '029',
    'stage_02_002_03' || 'stage_02_002_04' => '030',
    'stage_02_002_01' => '031',
    'stage_02_004_01' ||
    'stage_02_004_02' ||
    'stage_02_004_03' ||
    'stage_02_004_04' ||
    'stage_02_004_05' ||
    'stage_02_004_06' => '032',
    'stage_02_005_01' || 'stage_02_005_02' || 'stage_02_005_03' => '033',
    'stage_03_003_01' || 'stage_03_003_02' || 'stage_03_003_03' => '034',
    'stage_03_005_01' || 'stage_03_005_02' || 'stage_03_005_03' => '035',
    'stage_04_003_01' ||
    'stage_04_003_02' ||
    'stage_04_003_03' ||
    'stage_04_003_04' ||
    'stage_04_003_05' => '036',
    'stage_05_001_01' || 'stage_05_004_01' => '037',
    'stage_05_002_01' => '038',
    'stage_05_002_02' => '039',
    'stage_05_002_03' => '040',
    'stage_05_002_04' => '041',
    'stage_05_005_01' => '042',
    'stage_05_006_01' => '043',
    'stage_05_007_01' => '044',
    'stage_05_008_01' => '045',
    'stage_05_009_01' => '046',
    'stage_05_010_01' => '047',
    _ => null,
  };
}
