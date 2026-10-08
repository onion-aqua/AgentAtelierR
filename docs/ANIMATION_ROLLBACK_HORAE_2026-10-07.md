# 旧版人物演出回档与 Horae 保留

本轮以 GitHub `v1.0.4-beta1.26106` 的实际提交 `a6569cf894390fa6229e76f5ef488705d18bc4d2` 为基准，恢复该版本的人物演出。保留 `1.0.4-beta1-horae.26106+37` 版本标识。

## 恢复范围

- 恢复旧版聊天演出、独立动作与表情规划、播放队列、语音嘴型、程序微动、姿态及轨道切换逻辑。
- `chat_segments.dart`、`character_track_transition.dart`、`motion_recipe.dart`、`motion_candidate_search.dart` 和动作组合测试与上述基准逐字节一致。
- `CharacterPerformancePromptContext` 恢复旧版结构；`chat_screen.dart` 仅在旧版完整回复提交处保留两处 Horae 记忆写入。
- 撤销 vendored Spine Dart 运行时的六处 V3 补丁，恢复原有动画时钟与更新行为。Git 不包含整个 vendored 包，此处还原的是已记录的 V3 补丁；没有替换原生 ABI 或用户角色资源。
- V3 源码、工作台、测试、工具和生成目录迁入本地 `.asset_protection/before-animation-rollback-20261007-190355/inactive-v3/`，从应用构建及活动代码中移除，后续可以恢复。

## 保留的 Horae 功能

保留本地事实账本、增量追加、重复事实处理、来源追踪、关键词召回、当前状态投影、最近记忆及长期整理。用户编辑、删除和旧版纯文本迁移的保护保留；角色与存档仍各自保存记忆。

完整回复提交后才记录本地事实。自动续聊、用户取消和网络失败沿用原规则，取消或失败的半截回复不写入账本。

本轮使用覆盖安装，不卸载应用或清理数据。源码和运行时修改前的副本保存在上述回档目录。

## 验证

- Flutter 静态检查：通过，无问题。
- 相关回归测试：203 项通过；涵盖记忆、角色、动作、规划、语音与失败恢复，新增完整流提交和取消/失败不写记忆的验证。
- 六套真实 Spine 资源原生运行时测试：6 项通过，验证轨道混合、风动、动作推进及骨骼数值稳定。
- 基准比对：`evidence/animation_rollback_baseline.json`。
- 测试与构建日志：`evidence/animation_rollback_*.log`。

加密 release 构建成功，并通过 `adb install -r` 覆盖安装到 `a43d2d7a`。冷启动成功，主界面角色已显示；检查时应用进程存活，崩溃日志未发现本应用记录。版本名称 `1.0.4-beta1-horae.26106`，版本码 `37`，未启用 debuggable。

APK 内容校验通过：六套加密角色资源与本地包一致，不含 V3 数据目录或莱莎明文角色资源。产物为 `build/app/outputs/flutter-apk/app-release.apk`，大小 630488139 字节，SHA256 为 `4767ea9c7442d0b1494389e6ba2290411fcad6f9543aa7deacce9454a4a7411f`。证据见 `evidence/animation_rollback_apk.json` 和 `evidence/animation_rollback_device.json`。

本轮没有新增对话或重新请求 TTS，尚未完整复测在线对话中的语音与动作同步。自动测试不能代替用户对演出生动程度的视觉评价。
