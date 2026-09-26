# RyzaChat AI 1.1.1 角色运行时复查

核查日期：2026-09-26。对照对象是当前 `ryza_chat_mvp` 工作区与
`C:\Users\Aria\Desktop\apks\RyzaChat_AI_1.1.1`。本文更新
`APK_RUNTIME_ACTION_COMPARISON_2026-09-25.md` 中已过时的判断。

## 本轮实现进度

用户确认以可见运行效果为目标。本轮已把 `AttitudePatterns` 中的语义
one-shot 动画接入聊天演出，并让同一条资源模式驱动眼神；schema 4 的
方向、倾斜、路线、点数与重复次数现在参与采样。指尖视线开始使用资源的
中心骨骼、范围、延迟、头身比例与阈值。语音口型开始使用
`lipSyncClosure` 的低谷闭口、保持、dB 映射及开合响应参数。

当前仍使用既有的手臂轨道混合和本地动作租约。APK 的精确手臂绕行与
服务端动作协议没有原始 Dart 源码，不能仅凭 AOT 符号保证视觉一致。
本地 debug APK 已按受保护资源流程构建、覆盖安装并在连接的 Android
设备上正常显示角色。参考 APK 在这台设备上未能稳定停留于角色交互页，
因此还没有完成同场景逐帧对照。

## 证据边界

- 坐姿 `crf_skn_002_0001_01` 和站姿 `crf_skn_002_0001_99` 的 gesture JSON、
  skeleton 文件在两边分别具有相同 SHA-256。资源相同不等于播放行为相同。
- APK 的 Flutter 业务逻辑编译于 `lib/arm64-v8a/libapp.so`。AOT 中能检索到
  `ArmTrackController`、`ServerMotionLayer`、`applyServerMotion`、
  `_captureServerMotionSnapshot`、`_restoreServerMotionSnapshotAfterTap`、
  `_applyFingerTracking`、`_applySleepAdditiveMotions` 等符号；不能据此还原
  原始 Dart 的完整控制流或断言每条路径何时触发。
- 下表“APK 资源”指 JSON 中可直接验证的数据，“APK AOT”只表示有对应符号。
  本地结论以当前代码的调用链为准，未把旧报告当作现状。

## 已对齐的部分

| 能力 | 当前实现及核查结果 |
| --- | --- |
| Spine 素材 | 两套内置 gesture JSON 和 skeleton 与 APK 逐文件哈希相同。坐姿有 140 行 / 95 个唯一 MotionGroup，站姿有 53 行 / 53 个唯一组。 |
| schema 4 眼神 | `CharacterPerformanceProfile.parse` 读取 21 个 `GesturePatternDefs` 与 57 条 `AttitudePatterns`；`CharacterPerformanceDirector.sample` 实际按 `talk_*` / `idle_*` 权重选择并推动眼、头、身体。旧报告“未解析、始终 fallback”已失效。 |
| 姿态/情绪资源 | 已读取 `PoseTypeSets` 转移权重、各强度的表情组合、手臂组权重与效果资源；自主动作使用姿态和情绪权重。 |
| 动作占用 | `CharacterMotionLayers` 按 2–10 轨道发放租约；队列允许与活动租约轨道不重叠的动作组并行。旧报告“每个动作都会清空全部叠加层”已失效。 |
| 触摸恢复 | 点击前保存本地动作组、剩余时长、轨道及 `trackTime`，触摸后恢复可播放的动作组。旧报告“只恢复表情”已失效。 |
| 口型与指尖注视 | 当前有音频 RMS 包络驱动的口型 scrub，也有按住屏幕时眼睛及头身跟随的指针视线。不能再说完全没有跟手视线。 |

## 尚未等价的运行行为

以下表格记录本轮修改前的核查基线；已接入项目在上方“本轮实现进度”更新，
仍需通过实际运行画面校准幅度和时序。

| 项目 | APK 中可见的依据 | 当前实现 | 差异/证据等级 |
| --- | --- | --- | --- |
| 眼神路径 | 资源有 `route`：`1点`、`見回す`、`散らす`、`外して戻る`、`往復`；还有 `eyeMovement`、`bodyTilt`、`tilts`、`points`、重复次数。AOT 有 `AmbientGazeEngine`。 | 转换器按方向生成对称 yaw/pitch 范围；`points` 使水平符号交替。`route` 虽存入 driver，但采样时未读取；`eyeMovement`、倾斜类型和 schema 4 的 `repeatMin/Max` 未参与采样。 | 资源与本地代码直接证实路径语义缺失；APK 的精确路径算法仍未知。 |
| agree/deny/question | 两套 APK 资源各有 15 条对应 `AttitudePatterns`，均含 `oneShotAnimation` 和权重。 | 解析器仅把这些条目作为眼神候选；采样入口只选择 `talk_*` / `idle_*`。聊天页的语义动作优先查 `fixedGestureBindingsByAttitude`，但两套内置 JSON 均无此字段，因此走 `characterActionPlan` 静态映射。 | 直接证实当前没有按这 15 条资源权重组合眼神与 one-shot；APK 如何调度由 AOT 符号推断。 |
| 手臂进出 | 资源启用 `enableArmInOutRouting`，提供 rank、rest、pairOverrides、同部位绕行及双臂起步延迟；AOT 有 `ArmTrackController`、`_applyArmPairRoutedAction`。 | `groupMix` 根据 rank 距离计算混合时长，动作仍直接落到固定的占用轨道。没有读取这些绕行、配对和延迟规则来构造中间动作。 | 资源与本地代码直接证实配置未完整使用；APK 精确 handoff 行为未还原。 |
| 服务端动作层 | AOT 有 `ServerMotionLayer`、`applyServerMotion` 和服务端快照符号。 | 当前服务端/模型演出协议暴露语义 `action`、`grp_*` 与本地 recipe；没有等价的服务端层数据模型、持续时长和预留占用的解析/播放链。 | 本地缺口直接证实；APK 协议字段及返回格式无法仅凭符号确定。 |
| 中断范围 | AOT 有服务端动作快照恢复符号。 | 触摸仅快照本地 MotionGroup 租约；点击会清空队列和叠加轨道。recipe 通过独立阶段和全局重置播放，不进入租约快照。 | 本地行为直接证实；不能断言 APK 对所有动作都恢复。 |
| 口型闭合 | 资源 `lipSyncClosure.enabled=true`，包含闭合比例、保持时间、dB 映射和 attack/release；AOT 有 `_applyLipSyncScrubClip`。 | Kotlin 解码为 RMS 窗，Dart 将能量映射到 scrub 位置；未读取 `lipSyncClosure` 配置。无包络时使用合成相位。 | 资源与本地代码直接证实闭合参数未接入。 |
| 跟手参数 | 资源有 `fingerTrackDelay=0.1`、头/身体比例和阈值、范围；AOT 有 `_applyFingerTracking`。 | 现有 pointer gaze 会推动眼、头、身体，但没有消费这些 fingerTrack 配置项。 | 直接证实参数行为不同；APK 精确平滑公式未知。 |
| 睡眠状态 | AOT 有睡眠叠加、面部及唤醒相关符号。 | `story_clock` 可记录剧情时间的 sleep，角色渲染侧没有相应睡眠/唤醒动作状态机。 | 本地缺口直接证实；APK 触发条件未知。 |

## 重要实现边界

1. 本地 MotionGroup 的并行单位是固定 Spine 轨道。`CharacterMotionLayers` 管理的不是 APK 服务端动作层；调用 `_resetMotionOverlays` 时仍会清空这些本地租约。姿态切换、recipe 和触摸路径会调用该重置。
2. 本地触摸恢复是在触摸前计算剩余时长，恢复时从保存的 `trackTime` 继续；它覆盖本地 MotionGroup，不覆盖 recipe 或独立 one-shot。此处“已经有恢复”与“完整复刻 APK 快照”不能混为一谈。
3. `fixedBasePoseMode` 使 `_scheduleIdleChange` 跳过基础 idle 自动切换；`PoseTypeSets` 当前主要用于自主动作组加权，不表示 APK 的基础姿态构造器已对齐。
4. APK 的 smali 大多是 Flutter/Android 桥接。若需确认服务端协议、精确路径或手臂轨道分配，仍需要针对 AOT 做更深入的静态/动态分析；符号名不足以写出精确等价实现。

## 优先补齐顺序

1. 将 schema 4 `AttitudePatterns` 的路径、重复与 agree/deny/question one-shot 接入独立的资源态度调度器，并覆盖资源条目的权重与动画可用性。
2. 用 `armInOutPartConfig` 实现左右手路由与中间姿势；保持当前租约的轨道所有权，补上 recipe/one-shot 的统一占用和触摸快照。
3. 确认 APK 服务端动作协议后再引入 `ServerMotionLayer` 等价模型，包含持续时间、层所有权、完成与触摸恢复。
4. 接入 `lipSyncClosure`、fingerTrack 参数及睡眠状态，分别验证音频、指针和状态切换时的动作观感。

## 本次验证

- 重新计算两套 gesture JSON 与 skeleton 的 SHA-256，双方逐文件相同。
- 用结构化 JSON 读取确认坐姿 21 个 pattern、57 条 attitude、36 条 PoseTypeSet，以及语义条目和资源配置。
- 原始复查的 29 项资源、眼神、动作租约测试全部通过。
- 本轮调整后，眼神、跟手、口型、资源、动作租约和音频包络相关的 39 项测试全部通过；修改文件的 `flutter analyze --no-pub` 无问题。
- `tool/build_protected.ps1 -Target apk -Mode debug` 构建成功，并在连接的 Android 设备上覆盖安装、确认角色正常显示。参考 APK 未能稳定进入可比较的角色页，因此没有完成逐帧视觉一致性验证。
