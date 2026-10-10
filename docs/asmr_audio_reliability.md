# 持续 ASMR 音频加载可靠性修复

## 问题与处理

用户反馈 Fish Audio、关闭立体声时，持续 ASMR 出现 Android `Failed to set source` / `MEDIA_ERROR_UNKNOWN [what:13]`。本轮修复持续 ASMR 的音频准备、自动播放与重播流程。

检查发现：无法解码或零帧的音频原先仍可能进入播放队列；Android 音频错误也会广播到播放完成监听，原先该监听没有错误处理。此外，快速点击重播可能同时准备多个音源。

现在的行为：

- 音频进入缓存前，检查能否取得有效的音频包络和正时长。损坏、截断或零帧文件会被删除，同一文本重新合成一次；仍然失败时显示明确的重试提示。已有超长语音检查继续生效。
- Android 本地文件音源准备遇到 `AndroidAudioError` 时，释放原音源，使用完全相同的音频字节备用加载一次。不会因此再次调用 TTS 服务；其他平台或其他错误直接交给页面处理。
- 准备阶段的原生错误交由播放助手处理；准备成功后，在调用原生开始播放前切换错误处理阶段。开始播放的瞬间或之后报错都会及时停止，并退出播放黑屏、显示重试提示，避免漏掉错误后一直等待。
- 准备重播时防止重复设源，停止或退出后的过期操作不会继续启动音频。

本次没有更换 Android 播放器、TTS 模型或系统解码器。普通聊天与持续 ASMR 的固定声位设置仍在合成或会话开始时确定。

## 已完成验证

2026-10-10 验证结果：

- `flutter analyze --no-pub`：全项目通过。
- 58 项音频及 ASMR 回归测试通过，覆盖损坏音频重试与清理、两次失败停止、取消、快速重播、Android 备用加载、真正 EventChannel 错误广播、原生开始播放期间的错误（之后有／无完成事件），以及响度、立体声、包络和连续播放页面。
- Android 模拟器 `emulator-5554`（Pixel_10_Pro）执行 59 项原生音频检查，0 项失败。使用真实 Android MediaPlayer 与本地原生解码，覆盖 24 kHz / 44.1 kHz / 48 kHz 单声道、固定位置立体声、字节音源、MP3 及解码后处理，以及同一播放器连续 40 段单声道音频自然播放完成后的音源切换。
- 截断 WAV 按预期触发同类音源准备错误，模拟器返回 `what:1`。这证明损坏文件的错误路径可以被验证，不能据此认定用户设备的 `what:13` 是同一原因。
- 最终修复已使用加密脚本构建正常 `lib/main.dart` debug 包，安装到 `emulator-5554`。已确认正常主界面加载、应用进程存活，启动检查未发现 Android 崩溃记录。该次模拟器检查 APK 为 `build/app/outputs/flutter-apk/app-debug.apk`；恢复界面截图为 `build/asmr-app-restored.png`。

正式发布使用正常 main 入口的受保护 Android 与 Windows release 构建，版本为 `1.0.4+39`，覆盖更新 `v1.0.4`；产物信息见 [1.0.4 更新说明](CHANGELOG_1.0.4.md)。

原生结果保存在本地 `build/asmr-native-audio-report.json`，完成截图为 `build/asmr-native-audio-finished.png`。这些是开发检查产物，不包含线上 Fish Audio 响应。

**尚未完成：** 用户真实手机、实际 Fish Audio 响应的同场景复测，以及耳机主观听感验收。当次 `what:13` 的具体根因仍需要设备日志或出错音频确认；模拟器通过不能替代该项验收。

## 回归命令

在项目根目录执行：

```powershell
flutter analyze --no-pub
flutter test --no-pub test/speech_file_playback_test.dart test/speech_spatial_test.dart test/speech_stereo_file_test.dart test/speech_loudness_test.dart test/speech_envelope_test.dart test/continuous_asmr_page_test.dart test/tts_stereo_playback_test.dart --reporter expanded
```

## 原生诊断入口

`tool/debug_asmr_audio.dart` 只供 debug 检查，正常 `lib/main.dart` 不引用它。它生成测试 PCM 音频，读取本地提供的 MP3，调用实际音频插件；不调用线上 AI，也不读取或改写真实服务设置。MP3 测试文件不提交到仓库。

以下命令会把模拟器上的应用临时替换为诊断入口。先准备一个有权使用的本地 MP3，替换示例文件路径：

```powershell
pwsh -NoProfile -File ./tool/build_protected.ps1 -Target apk -Mode debug -DeviceId emulator-5554 -Install -EntryPoint ./tool/debug_asmr_audio.dart
adb -s emulator-5554 push 'C:\test-audio\sample.mp3' /data/local/tmp/aar-asmr-test-fixture.mp3
adb -s emulator-5554 shell run-as com.example.ryza_chat_mvp mkdir -p cache
adb -s emulator-5554 shell run-as com.example.ryza_chat_mvp cp /data/local/tmp/aar-asmr-test-fixture.mp3 cache/asmr-test-fixture.mp3
adb -s emulator-5554 shell am start -n com.example.ryza_chat_mvp/.MainActivity
```

点击“开始检查”。缺少 MP3 文件时，该项检查会明确失败。应用缓存中的报告位置为 `cache/asmr-audio-diagnostics/report.json`。

检查后必须重新构建并安装正常入口，避免把诊断 APK 当成正常应用交付：

```powershell
pwsh -NoProfile -File ./tool/build_protected.ps1 -Target apk -Mode debug -DeviceId emulator-5554 -Install
```

所有构建均使用资源加密脚本。debug 包用于调试，其性能不代表 release 包表现。
