# RyzaChat AI 1.1.1 动作运行时与当前实现对照

核对日期：2026-09-25。对象是 `C:\\Users\\Aria\\Desktop\\apks\\RyzaChat_AI_1.1.1` 与当前 `ryza_chat_mvp` 工作区。

## 结论

APK 的角色动作不是“播放一个 Spine 动画”的单层逻辑，而是一个带资源解析、动作占用调度、表情/眼神、触摸中断、语音口型和服务端动作恢复的运行时。当前工程已经复用了同一套莱莎 Spine 资源，并实现了一个可用的本地动作系统，但动作编排仍是较薄的 `MotionGroup + queue + timer` 层。

最重要的事实：APK 内置坐姿和站姿的动作资源，与当前工程对应文件逐个相同。差异主要在 Dart/AOT 运行时代码，不在动作素材。

## 证据与边界

- APK 包名是 `ai.gospiral.atelierryza`，角色逻辑位于 Flutter AOT 的 `lib/arm64-v8a/libapp.so`；反编译得到的 `smali` 主要是 Android/Flutter 桥接代码，不能当作角色动作源码。
- AOT 中存在可识别的源码文件名和方法名，例如 `package:craft/features/spine_avatar/server_gesture_motion.dart`、`_parseGesturePatternDefs`、`_dispatchAttitudeGesture`、`applyServerMotion`、`AmbientGazeEngine`、`_captureServerMotionSnapshot`、`_restoreServerMotionSnapshotAfterTap`、`_applyLipSyncScrubClip`。
- AOT 已优化/压缩，无法从 APK 恢复原始 Dart 文件的精确实现；下面的运行时流程是由 AOT 符号、资源字段和调用职责重建的行为分析。

资源 SHA-256 对照：

| 资源 | APK | 当前工程 | 结果 |
| --- | --- | --- | --- |
| 坐姿 gesture JSON | `18d55efdb357302610d77979626cbbc5c91f60808f8df5fe3706865a40a9fb33` | 相同 | 相同 |
| 坐姿 skeleton | `bd3228debb5d1868398f4aac903caa18b0c2f366bc841e9ea7d40d1a3d51d42e` | 相同 | 相同 |
| 站姿 gesture JSON | `fe78d6498e90e6ad50728d2ab6e0cf0080fa5398f1c7a0031fa2a79225a7ab4b` | 相同 | 相同 |
| 站姿 skeleton | `113f48eb086d115e1de9b9ee5e7e749deb3a871aec29dc58ae8f153417dbf027` | 相同 | 相同 |

## APK 的动作运行时

### 1. 资源解析层

APK 读取 schema 4 的 gesture JSON，并解析：

| 项目 | 坐姿 | 站姿 |
| --- | ---: | ---: |
| `MotionGroups` 行数 | 140 | 53 |
| 唯一动作组 | 95 | 53 |
| `GesturePatternDefs` | 21 | 21 |
| `AttitudePatterns` | 57 | 57 |
| `PoseTypeSets` | 36 | 49 |
| `TapReactions` | 7 | 7 |
| 情绪 profile | 9 | 9 |

AOT 中对应的解析/校验职责包括 `_parseMotionGroupOccupancy`、`_parseMotionGroupLayerDouble`、`_parseGesturePatternDefs`、`_parseAttitudePatterns`、`_parsePoseMotionSets`、`_parseEmotionProfilesV4`、`_importTapReactions`、`_validateMotionGroupPair` 及 `validateMotionGroup`。这意味着 `GroupId`、占用部位、双动画 alpha/speed、姿态限制、变体连续性和表情权重都会在运行时参与校验。

### 2. 基础姿态与手臂通道

资源配置明确使用 `fixedBasePoseMode: true`、坐姿使用 `lockSittingAxis: true`，并为坐姿/站姿分别提供 `ArmIdleGroupIds`。APK 的运行时符号显示它使用 `BaseMotionBuilder`、`_applyBasePoseAnimation`、`_applyPoseMotionSetRow`、`ArmTrackController`、`_freeArmTracks`、`_groupFitsFreeArmTracks` 和 `_applyArmPairRoutedAction`。

动作不是固定地把 `B/C/E/FG` 直接映射到几个轨道后清空全部旧动作，而是先根据占用部位查找可用轨道，保留不冲突的层；双臂动作还会经过 in/out 中间姿势、handoff 和可选延迟。资源里的 `armInOutPartConfig` 给出了 0.4 到 1.0 秒的自然进出时间、左右手 rank、休息组和双臂配对规则。

### 3. 自主动作、眼神和情绪

APK 有独立的 `AmbientGazeEngine`、`AmbientGazePathGenerator`、`_resolveAmbientPatternCandidates`、`_updateAttitudeFromTension` 和 `setAttitude`。`GesturePatternDefs` 描述眼睛、脸、身体、倾斜、方向、路线、点数和停留；`AttitudePatterns` 再按 `talk_low/talk_mid/talk_high/idle_*` 以及 agree/deny/question 等状态加权选择模式。

资源中的眼神参数包含：yaw/pitch/roll 上限、短中长停留、快中慢速度、曲线宽度、头部跟随延迟 0.1 秒、身体跟随延迟 0.6 秒、跟随强度、看向用户的 tau 以及回到正面的速度。APK 还有 `_blinkController`、`startBlink`、`startBurstBlink`、`_resetBlinkTimer`，所以眨眼是独立调度器，不是表情切换时顺带播一次。

情绪系统由 `applyEmotion`、`EmotionProfilesV4`、`EmotionIntensityProfile`、`switchEmotionProfile` 和 effect pipeline 驱动；表情眼睛、眉毛、嘴、脸部效果与肢体动作分层更新。

### 4. 明确动作与服务端动作

APK 同时支持三类明确动作：

1. `playOneShot` / `activateOneShot`：一次性反馈动画。
2. `applyMotionGroupComposition`：从资源动作组按占用部位组合并播放。
3. `applyServerMotion`：读取服务端动作层；AOT 中有 `parseServerGestureActions1`、`resolveServerMotionByConvention`、`ServerMotionLayer`、`activeServerMotionDurationSeconds` 和 `effectiveServerMotionDurationSeconds`。

服务端动作有独立的 duration、层、占用和完成轮询。运行时会用 `_recomputeServerMotionReservedOccupancyMask` 预留通道，并在动作完成或过期时释放。一次性动作会通过 `_suppressScopeForOneShotGesture` 暂时压低自主动作，结束后再恢复。

### 5. 语音、触摸和其它交互

- 口型：`lipsync_amplitude.dart`、`lipsync_closure.dart`，并配合 `_buildLipsyncEnvelope`、`_applyLipSyncScrubClip`、`lookupLipsyncOpenAtElapsedMs`、`_storeLipsyncClosurePcmChunk`。口型轨道与眼睛/表情/肢体轨道分开。
- 触摸：`selectTapReaction`、`playTapReaction`、`_handleTapServerMotionInterruption`。点击开始时保存服务端动作快照，触摸片段结束后由 `_restoreServerMotionSnapshotAfterTap` 恢复未完成的动作，而不是把所有动作清空后重新开始。
- 眼睛/手指：`_applyFingerTracking`、`setFingerTrackingTarget`、`_smoothFingerTracking`；这是一条独立的跟踪输入链。
- 睡眠/唤醒：`_applySleepAdditiveMotions`、`_applySleepFacial`、`enterSleep`、`completeSleepWake`、`_reapplyLowerStateAfterSleep`；睡眠状态会改变叠加动作、面部和视线。

## 当前工程的实际方式

当前动作入口主要集中在：

- `lib/src/character_appearance.dart:203`：解析 `MotionGroups` 和 `EmotionProfilesV4`，按 `GroupId` 选择动作。
- `lib/src/character_resource_behavior.dart:46`：读取 `fixedBasePoseMode`、`armInOutPartConfig`、表情资源和效果动画。
- `lib/src/character_speech_driver.dart:76`：只解析旧式 `DriverDefs`、aim/roll 骨骼、情绪 profile 和 `ambientGaze`。
- `lib/src/chat_screen.dart:760`：基础 idle 变更；资源开启 `fixedBasePoseMode` 时直接返回。
- `lib/src/chat_screen.dart:1095`：按 `occupiedTracks` 在 Spine 轨道播放一个动作组，并在完成后清理叠加层。
- `lib/src/chat_screen.dart:1553`：音频驱动口型；`lib/src/chat_screen.dart:1668`：逐帧头身/眼神驱动。
- `lib/src/chat_screen.dart:1988`：眨眼；`lib/src/chat_screen.dart:2046`：每 5 到 8 秒触发一次 ambient 动作。
- `lib/src/chat_screen.dart:2190`：接收 semantic `action` 或 `grp_*`；`lib/src/chat_screen.dart:2263`：最多两个队列项、5 秒过期、语义动作 3 秒冷却。
- `lib/src/chat_screen.dart:2489`：点击命中后清空动作队列和叠加轨道，播放 touch 片段，结束后重新应用当前表情。
- `lib/src/character_performance.dart:1`：11 个语义动作标签，按坐姿/站姿静态映射到少量 `grp_*` 或 one-shot 回退。

当前还额外加入了 `assets/data/motion_recipes.json` 和多阶段 recipe 播放。这是本工程的扩展机制，APK 中没有对应的 `motion_recipes.json` 资源；APK 使用的是自己的动作组组合器和服务端动作层。

## 逐项对比

| 能力 | APK 1.1.1 | 当前工程 | 判断 |
| --- | --- | --- | --- |
| Spine 资源 | schema 4，坐姿/站姿完整资源 | 同一资源，已验证哈希相同 | 已对齐 |
| 动作组解析 | 解析并校验 MotionGroups、变体、占用、姿态和组合 | 解析 MotionGroups、姿态、alpha/speed 和部分表情权重 | 基础已覆盖 |
| GesturePatternDefs / AttitudePatterns | 21 个模式、57 条态度调度实际参与运行 | 未解析；只保留资源目录和中文目录报告 | 关键缺口 |
| 自主眼神 | AmbientGazeEngine + 路径、停留、速度、跟随延迟 | `CharacterPerformanceDirector` 随机目标 + 手写边界 | 行为不同 |
| 旧 DriverDefs | 兼容旧资源 | 兼容，但 APK 这两份内置资源 DriverDefs 为 0 | 当前会走 fallback |
| 基础姿态 | BaseMotionBuilder、PoseMotionSets、姿态轴规则 | 初始 idle + fixedBasePoseMode 早退，盘腿有专门恢复组 | 部分覆盖 |
| 手臂进出 | rank、左右 handoff、双臂中间姿势和延迟 | 使用 `groupMix` 估算混合，固定轨道播放 | 明显简化 |
| 动作叠加 | 占用通道分配、冲突检测、保留非冲突轨道 | 播放前清理大多数旧 overlay，队列串行化 | 明显简化 |
| 服务端动作 | ServerMotionLayer、duration、reserved occupancy、完成轮询 | 没有同等协议；只接受 `[action:*]` / `[action:grp_*]` | 关键缺口 |
| 语义动作 | attitude/one-shot/动作组由运行时按资源态度选取 | 11 个静态 action，少量固定组和回退 | 表达能力较低 |
| 表情效果 | emotion profile、intensity、effect pipeline | 表情 preset + 部分资源 expression/effect | 基础覆盖 |
| 眨眼 | 独立 controller、普通/快速/爆发/闭眼状态 | timer + `eyeModeEntries`，缺省时固定随机间隔 | 部分覆盖 |
| 口型 | amplitude/closure envelope、PCM 快照、scrub 校验 | envelope 或合成相位，驱动一个 lip-sync track | 部分覆盖 |
| 触摸中断 | 保存并恢复未完成服务端动作 | 清空队列和 overlay，结束后只恢复表情 | 行为不同 |
| 手指跟踪 | 独立目标和平滑器 | 有屏幕指针 gaze，但没有同等 finger target 管线 | 缺口 |
| 睡眠/唤醒 | 睡眠叠加、睡眠面部、唤醒完成回调 | 没有角色睡眠动作状态机 | 缺口 |
| 调度完成语义 | 动作/服务端层完成后释放对应占用 | `_motionBusyUntil` + 局部 TrackEntry listener | 近似实现 |

## 运行时行为差异的实际影响

1. **同一动作素材的观感会不同。** 当前实现可以播出 `grp_fg_*`，但会在播放前清掉共享轨道；APK 能让不冲突的身体、手臂、表情和眼神继续同时存在。
2. **当前模型无法可靠表达 APK 的全部动作语言。** 资源里存在 148 个唯一动作组，但当前 semantic action 只静态覆盖少量组；`GesturePatternDefs` 也没有成为可选能力输入。
3. **当前无服务端动作层。** 如果 APK 的后端返回带层、时长和占用的动作，当前解析器会把它当作普通文本或普通 `action`，无法复现 APK 的行为。
4. **点击后的恢复不同。** APK 触摸只暂时打断动作并恢复快照；当前点击后动作层被清空，可能回到 idle 或等待下一次动作。
5. **内置资源实际会走 fallback gaze。** 两份 APK gesture JSON 的 `DriverDefs` 都是 0；当前 `CharacterPerformanceProfile.parse` 因而没有 legacy driver，`CharacterPerformanceDirector` 会使用 `_fallbackDriver`。APK 则通过新版 `GesturePatternDefs`/`AttitudePatterns` 和 `AmbientGazeEngine` 工作。
6. **当前的 recipe 不是 APK 等价物。** 多阶段 recipe 能补足少数组合，但它没有 APK 的通道预留、服务端动作恢复、手臂自然进出和自主动作冲突处理。

## 建议的实现顺序

1. 先增加 schema 4 的 `GesturePatternDefs`、`AttitudePatterns`、`PoseMotionSets` 解析，并把当前 emotion/tension 状态转换成 APK 同样的 attitude 候选；这一步能直接改善 idle、说话和回答后的眼神/身体节奏。
2. 把动作播放从“清理共享轨道后播放”改成 occupancy reservation：动作开始时记录占用、保留不冲突轨道，结束时只释放自己的 generation。
3. 增加统一的 `ServerMotion` 数据模型，至少包含动画名、occupancy、duration、alpha、speed、mix 和 one-shot/additive 类型；再接入独立的完成回执。
4. 将 touch 改为 snapshot/restore，保存被触摸前的动作层、剩余时间和表达式，而不是只调用 `_resetMotionOverlays()`。
5. 最后接入睡眠/唤醒、finger tracking 和 closure lip-sync。它们依赖前面的轨道所有权，否则会继续互相清理。

不建议先增加更多静态 `CharacterAction` 名称。APK 的核心优势是资源能力目录和运行时调度，先把能力目录、占用和完成语义接通，动作标签才有可靠含义。

## 文件来源

- APK 资源：`C:\\Users\\Aria\\Desktop\\apks\\RyzaChat_AI_1.1.1\\assets\\flutter_assets\\assets\\spine\\crf_chr_002\\...`
- APK AOT：`C:\\Users\\Aria\\Desktop\\apks\\RyzaChat_AI_1.1.1\\lib\\arm64-v8a\\libapp.so`
- 当前资源解析：`lib/src/character_appearance.dart`、`lib/src/character_resource_behavior.dart`
- 当前演出调度：`lib/src/chat_screen.dart`、`lib/src/character_performance.dart`、`lib/src/character_performance_queue.dart`
- 当前 gaze / speech：`lib/src/character_gaze.dart`、`lib/src/character_speech_driver.dart`、`lib/src/audio_envelope.dart`
