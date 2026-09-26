import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'runtime_log.dart';
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
  bool _suspended = false;
  late final Future<Set<String>> _availableAssets = _loadAvailableAssets();
  Future<void>? _pendingSync;

  Future<void> sync(AppController controller, {required bool worldMapVisible}) {
    final previous = _pendingSync ?? Future<void>.value();
    final next = previous.then(
      (_) => _syncNow(controller, worldMapVisible: worldMapVisible),
    );
    final guarded = next.catchError((Object error, StackTrace stackTrace) {
      RuntimeLog.instance.error('Soundscape', error, stackTrace);
    });
    _pendingSync = guarded;
    return guarded;
  }

  void invalidate() {
    _bgmEnabled = null;
    _ambientEnabled = null;
    _sceneTime = null;
    _selectedStageId = null;
    _bgmAsset = null;
    _ambientAsset = null;
    _bgmVolume = null;
    _ambientVolume = null;
  }

  Future<void> _syncNow(
    AppController controller, {
    required bool worldMapVisible,
  }) async {
    if (controller.continuousAsmr || controller.activeCharacterId == 'sophie') {
      if (!_suspended) {
        await _bgmPlayer.stop();
        await _ambientPlayer.stop();
      }
      _suspended = true;
      invalidate();
      return;
    }
    _suspended = false;
    final nextBgmAsset = worldMapVisible
        ? StageEnvironmentCatalog.worldMapBgmAsset
        : await _chatBgmAssetFor(controller.selectedStageId);
    if (_bgmEnabled != controller.bgmEnabled || _bgmAsset != nextBgmAsset) {
      await _bgmPlayer.stop();
      if (controller.bgmEnabled) {
        await _bgmPlayer.setReleaseMode(ReleaseMode.loop);
        await _bgmPlayer.play(
          AssetSource(nextBgmAsset),
          volume: controller.bgmVolume,
        );
      }
      _bgmEnabled = controller.bgmEnabled;
      _bgmAsset = nextBgmAsset;
    }
    if (_bgmVolume != controller.bgmVolume) {
      await _bgmPlayer.setVolume(controller.bgmVolume);
      _bgmVolume = controller.bgmVolume;
    }
    final nextAmbientAsset = StageEnvironmentCatalog.ambientAssetFor(
      controller.selectedStageId,
      controller.sceneTime,
    );
    if (_ambientEnabled != controller.ambientEnabled ||
        _selectedStageId != controller.selectedStageId ||
        _sceneTime != controller.sceneTime ||
        _ambientAsset != nextAmbientAsset) {
      await _ambientPlayer.stop();
      if (controller.ambientEnabled && nextAmbientAsset != null) {
        await _ambientPlayer.setReleaseMode(ReleaseMode.loop);
        await _ambientPlayer.play(
          AssetSource(nextAmbientAsset),
          volume: controller.ambientVolume,
        );
      }
      _ambientEnabled = controller.ambientEnabled;
      _selectedStageId = controller.selectedStageId;
      _sceneTime = controller.sceneTime;
      _ambientAsset = nextAmbientAsset;
    }
    if (_ambientVolume != controller.ambientVolume) {
      await _ambientPlayer.setVolume(controller.ambientVolume);
      _ambientVolume = controller.ambientVolume;
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
