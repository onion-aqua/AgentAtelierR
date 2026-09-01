import 'package:audioplayers/audioplayers.dart';

import 'app_controller.dart';

class SoundscapeController {
  final _bgmPlayer = AudioPlayer();
  final _ambientPlayer = AudioPlayer();
  bool? _bgmEnabled;
  bool? _ambientEnabled;
  SceneTime? _sceneTime;
  double? _bgmVolume;
  double? _ambientVolume;

  Future<void> sync(AppController controller) async {
    if (_bgmEnabled != controller.bgmEnabled) {
      _bgmEnabled = controller.bgmEnabled;
      if (controller.bgmEnabled) {
        await _bgmPlayer.setReleaseMode(ReleaseMode.loop);
        await _bgmPlayer.play(
          AssetSource('audio/soundscape/bgm_opening.m4a'),
          volume: controller.bgmVolume,
        );
      } else {
        await _bgmPlayer.stop();
      }
    }
    if (_bgmVolume != controller.bgmVolume) {
      _bgmVolume = controller.bgmVolume;
      await _bgmPlayer.setVolume(controller.bgmVolume);
    }
    if (_ambientEnabled != controller.ambientEnabled ||
        _sceneTime != controller.sceneTime) {
      _ambientEnabled = controller.ambientEnabled;
      _sceneTime = controller.sceneTime;
      await _ambientPlayer.stop();
      if (controller.ambientEnabled) {
        final isNight = controller.sceneTime == SceneTime.night;
        await _ambientPlayer.setReleaseMode(ReleaseMode.loop);
        await _ambientPlayer.play(
          AssetSource(
            'audio/soundscape/${isNight ? 'ambient_night' : 'ambient_day'}.m4a',
          ),
          volume: controller.ambientVolume,
        );
      }
    }
    if (_ambientVolume != controller.ambientVolume) {
      _ambientVolume = controller.ambientVolume;
      await _ambientPlayer.setVolume(controller.ambientVolume);
    }
  }

  Future<void> dispose() async {
    await _bgmPlayer.dispose();
    await _ambientPlayer.dispose();
  }
}
