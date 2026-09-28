# AgentAtelierR 1.0.3 beta6 测试版

Android 版本号：`1.0.3-beta6+34`。本次提供的是使用加密资源脚本构建的 Android debug 测试包，不是商店发布包。

## Debug 测试警告

debug 模式会保留调试检查和日志开销，可能导致设备运行本应用时动画掉帧、界面卡顿、耗电或发热增加，也可能比 release 模式更不稳定。测试包的性能表现不能代表 release 包。

## 本次更新

- CosyVoice 3 日语朗读增加片假名读音前端：日文台词和日文音色参考文本会按模型要求转换，减少汉字误读、漏字和跳字。
- 修复日语参考文本没有从 Flutter 传到 Android 合成运行时的问题；旧的日语克隆音色无需重新提取特征。
- 修复日语标点清理可能把 `$1` 字面量送入 TTS 的问题。
- 日语模式的 CosyVoice 试听默认使用日文示例句，避免把中文试听句误当作日语输入。
- 保留 CosyVoice 3 本地中日文合成、音色克隆及 Android arm64 运行时；模型权重仍按本地模型安装说明单独获取。

## 构建与验证

统一使用受保护构建脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target apk -Mode debug -Install -DeviceId a43d2d7a
```

本次在 `a43d2d7a` 未连接时使用在线设备 `dc4a3f49` 覆盖安装测试。APK 输出为 `build/app/outputs/flutter-apk/app-debug.apk`。

验证项目：

- `flutter analyze --no-pub` 通过。
- `test/local_tts_models_test.dart` 5 项通过。
- 全量测试中一次炼金测试出现时序性失败，单独重跑该文件 12 项全部通过；其余失败未发现与本次 TTS 改动相关的问题。
- APK 使用加密资源脚本构建，CosyVoice Kuromoji 日语资源已随 Android 包编译。
