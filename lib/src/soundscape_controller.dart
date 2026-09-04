import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'stage_environment_catalog.dart';

class SoundscapeController {
  final _bgmPlayer = AudioPlayer();
  final _ambientPlayer = AudioPlayer();
  bool? _bgmEnabled;
  bool? _ambientEnabled;
  SceneTime? _sceneTime;
  String? _selectedStageId;
  String? _bgmAsset;
  String? _ambientAsset;
  double? _bgmVolume;
  double? _ambientVolume;
  late final Future<Set<String>> _availableAssets = _loadAvailableAssets();

  Future<void> sync(
    AppController controller, {
    required bool worldMapVisible,
  }) async {
    final nextBgmAsset = worldMapVisible
        ? StageEnvironmentCatalog.worldMapBgmAsset
        : await _chatBgmAssetFor(controller.selectedStageId);
    if (_bgmEnabled != controller.bgmEnabled || _bgmAsset != nextBgmAsset) {
      _bgmEnabled = controller.bgmEnabled;
      _bgmAsset = nextBgmAsset;
      await _bgmPlayer.stop();
      if (controller.bgmEnabled) {
        await _bgmPlayer.setReleaseMode(ReleaseMode.loop);
        await _bgmPlayer.play(
          AssetSource(nextBgmAsset),
          volume: controller.bgmVolume,
        );
      }
    }
    if (_bgmVolume != controller.bgmVolume) {
      _bgmVolume = controller.bgmVolume;
      await _bgmPlayer.setVolume(controller.bgmVolume);
    }
    final nextAmbientAsset = StageEnvironmentCatalog.ambientAssetFor(
      controller.selectedStageId,
      controller.sceneTime,
    );
    if (_ambientEnabled != controller.ambientEnabled ||
        _selectedStageId != controller.selectedStageId ||
        _sceneTime != controller.sceneTime ||
        _ambientAsset != nextAmbientAsset) {
      _ambientEnabled = controller.ambientEnabled;
      _selectedStageId = controller.selectedStageId;
      _sceneTime = controller.sceneTime;
      _ambientAsset = nextAmbientAsset;
      await _ambientPlayer.stop();
      if (controller.ambientEnabled && nextAmbientAsset != null) {
        await _ambientPlayer.setReleaseMode(ReleaseMode.loop);
        await _ambientPlayer.play(
          AssetSource(nextAmbientAsset),
          volume: controller.ambientVolume,
        );
      }
    }
    if (_ambientVolume != controller.ambientVolume) {
      _ambientVolume = controller.ambientVolume;
      await _ambientPlayer.setVolume(controller.ambientVolume);
    }
  }

  Future<String> _chatBgmAssetFor(String stageId) async {
    try {
      final availableAssets = await _availableAssets;
      for (final candidate in StageEnvironmentCatalog.chatBgmCandidatesFor(
        stageId,
      )) {
        if (availableAssets.contains('assets/$candidate')) return candidate;
      }
    } catch (_) {
      // Asset manifest failures should not prevent the default music playing.
    }
    return StageEnvironmentCatalog.defaultChatBgmAsset;
  }

  Future<Set<String>> _loadAvailableAssets() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    return manifest.listAssets().toSet();
  }

  Future<void> dispose() async {
    await _bgmPlayer.dispose();
    await _ambientPlayer.dispose();
  }
}
