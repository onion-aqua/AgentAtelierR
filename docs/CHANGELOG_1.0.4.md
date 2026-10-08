# AgentAtelierR 1.0.4 正式版

Android 版本：`1.0.4+38`。GitHub 标签：`v1.0.4`。

## 本次更新

- 动作规划增加按意图、身体区域、语义动作族、姿态和轨道的分层召回；手部、腿部、身体和多区域组合动作会在真实资源范围内检索。
- 未指定具体动作时，规划器只接收当前区域的候选并参考当前人物状态、情绪和最近动作；没有准确动作时保持 `none/unsupported`，不使用相近动作冒充。
- 新增动作目录索引、抱臂回归覆盖和分层检索测试，保留现有动作播放硬校验。
- 增加本地服装 `crf_skn_002_0006_01`（东方旗袍·紫色）；Spine、预览图和动作数据只在本地参与受保护构建，运行时以加密资源包加载，不上传原始或加密服装文件。
- 保留近期记忆与长期记忆分层整理、追加式记忆账本、虚拟手机、NPC 信息和 PC Agent 联动能力。
- 版本标识统一为 `1.0.4`，内部 Android versionCode 为 `38`。

## 构建与验证

使用受保护构建脚本生成 release APK，启用人物资源加密、Dart 混淆和分离调试符号：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target apk -Mode release
```

APK：`build/app/outputs/flutter-apk/app-release.apk`。

本次 Android 构建产物大小为 `645,910,684` 字节，SHA-256 为 `f87419cc07f2355331023d4412c0858c0695ceab03aac27a28680c3506690182`。APK 元数据已核对为 `versionName=1.0.4`、`versionCode=38`，APK Signature Scheme v2 验证通过。Windows release 运行目录已打包为 `AgentAtelierR-1.0.4-windows-release.zip`，大小 `598,946,157` 字节，SHA-256 为 `abb7a8797f08be1941b99276145819f34ba8489b518aa394eaa272ac433cefb1`。本版本的动作、索引、规划器和新服装兼容性测试在发布前运行；涉及原生 Spine 的测试仍以本机实际运行时资源为准。Android release 继续使用现有调试签名，以便覆盖安装测试包，不代表应用商店签名。

## PC 版同步范围

当前 checkout 没有独立的 dshagalt/PC 源码或完整 Windows 工程。动作分层改动位于 Flutter 共用 Dart 层，PC checkout 可用时应同步以下文件和数据：

- `lib/src/motion_candidate_search.dart`
- `lib/src/independent_performance_tools.dart`
- `lib/src/motion_recipe.dart`
- `lib/src/character_motion_semantics.dart`
- `assets/data/motion_recipes.json`
- `assets/data/motion_recipes_extra.json`

本次发布不把 Android 专属 Gradle、Manifest、资源或设备配置复制到 PC 端；完整 PC 版构建和联调需要独立 PC checkout 及其运行时资源。
