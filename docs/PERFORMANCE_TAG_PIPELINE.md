# 表情、动作与语音标签执行流程

本文档描述当前对话系统中，LLM 输出如何被解析为角色表情、动作、姿态和 TTS 语气。动作由模型根据语境和本轮能力目录输出，客户端不通过用户文字关键词猜测动作。

## 一、标签类型

### 莱莎表情

输出格式：`[face:标签]`

支持标签：

`neutral`、`happy`、`laughing`、`angry`、`sad`、`crying`、`shy`、`tease`、`cuddle`

九个名称来自 `CharacterExpression`。解析器还接受 `[face:happy/weak]` 等 `weak`、`normal`、`strong` 强度后缀；常规模型输出协议只要求上面的九个基础名称。未知名称回退为 `neutral`。

### 莱莎动作

输出格式：`[action:标签]`

支持标签：

`none`、`acknowledge`、`disagree`、`think`、`explain`、`excited`、`wave`、`shy`、`surprised`、`comfort`、`playful`、`invite`

| 标签 | 语义 |
| --- | --- |
| `none` | 不新增主要动作；延续当前状态 |
| `acknowledge` | 点头、确认、回应 |
| `disagree` | 否定、拒绝、制止 |
| `think` | 思考、回忆、疑问 |
| `explain` | 解释、展示 |
| `excited` | 发现、庆祝、兴奋 |
| `wave` | 问候、告别、挥手 |
| `shy` | 害羞、遮脸 |
| `surprised` | 意外发现 |
| `comfort` | 安慰、陪伴 |
| `playful` | 善意调侃 |
| `invite` | 邀请靠近、伸手或拥抱 |

这些是意图标签，不保证某个精确肢体姿势。未知语义标签回退为 `none`。

### 精确动作组标签

当本轮运行时能力目录中出现 `motionGroups` 时，模型可以选择目录中列出的精确动作组：

```text
莱莎：[confident][face:tease][action:grp_b_03]看吧，我就说这个办法可行！
```

`grp_*` 是资源组 ID，不是可以自由猜测的动画名。模型只能复制本轮 `motionGroups` 中的键，不能输出目录外的 ID、Spine 动画片段名或轨道名。精确动作组适合用户明确要求“叉腰、拍手、嘘、伸懒腰”等具体姿势的情况；没有精确匹配时，退回到语义动作（例如 `explain`、`think`、`invite`），而不是虚构旁白。

能力目录中的值是给模型阅读的自然语言说明，可能包含资源标签、占用骨骼、适用基础姿势和坐姿限制。它描述“客户端能够尝试播放什么”，不代表模型可以绕过客户端校验。`action:none` 仍表示本节不新增主要动作，不是取消上一个动作。

### 持续坐姿标签

需要切换坐姿时，在动作标签后追加 `[posture:sitting_normal]` 或 `[posture:sitting_agura]`，并且只能使用本轮 `availablePostures` 中的值。没有切换时省略；用户手动选定姿态时不输出。它是应用演出标签，不进入 TTS。

### Fish Audio 情绪标签

`relaxed`、`happy`、`curious`、`excited`、`confident`、`surprised`、`worried`、`empathetic`、`calm`、`angry`、`anxious`、`ashamed`、`bored`、`compassionate`、`contemptuous`、`confused`、`delighted`、`depressed`、`determined`、`disappointed`、`disdainful`、`disgusted`、`doubtful`、`embarrassed`、`encouraging`、`enthusiastic`、`envious`、`friendly`、`frustrated`、`grateful`、`guilty`、`hopeful`、`hysterical`、`indifferent`、`jealous`、`lonely`、`moved`、`mysterious`、`nervous`、`nostalgic`、`optimistic`、`pessimistic`、`proud`、`regretful`、`relieved`、`resigned`、`sad`、`sarcastic`、`satisfied`、`scared`、`sympathetic`、`uncertain`、`unhappy`、`upset`、`urgent`、`warm and happy`

### Fish Audio 表演标签

`in a hurry tone`、`shouting`、`screaming`、`whispering`、`unvoiced whispering`、`whisper`、`near-whisper`、`soft tone`、`breathy`、`very breathy voice`、`extremely breathy voiced speech`、`low volume`、`low voice`、`soft intimate voice`、`soft breathy voice`、`airy voice`、`inhale`、`exhale`、`sigh`、`emphasis`、`laughing`、`chuckling`、`sobbing`、`crying loudly`、`sighing`、`groaning`、`panting`、`gasping`、`yawning`、`snoring`、`clear throat`、`audience laughing`、`background laughter`、`crowd laughing`、`break`、`long-break`、`pause`、`short pause`

## 二、LLM 输出协议

每个非空行使用中文机器前缀 `旁白：`、`莱莎：`、`角色[角色ID]：` 或 `译文：`。角色 ID 必须是当前候选角色的稳定 ID。莱莎台词先写一个主情绪标签，再写一个表情和一个动作；必要时追加姿态标签：

```text
莱莎：[happy][face:tease][action:playful] 怎么样？
```

旁白可出现在台词之前或之后，描写环境、可观察的神态或已经确认能执行的动作。旁白、NPC 和译文不使用莱莎的表情、动作、姿态或语音标签：

```text
旁白：森林里的风突然停了下来。
角色[lent]：你们回来啦。
译文：You're back.
```

启用翻译时，每条莱莎或 NPC 台词后紧跟一条对应的 `译文：`，旁白不翻译。正文语言由当前旁白、角色回复和译文语言设置控制，前缀保持中文。每个自然节拍最多一个主要动作；连续台词如果没有新的动作，应输出 `action:none`，避免重复播放上一动作。动作必须与当前坐姿、站姿和服装兼容。否定、引用、假设或过去事件不构成即时动作请求。

## 三、客户端执行链路

1. **构建请求和接收响应**：`app_controller.dart` 构建输出协议与能力上下文；`chat_screen.dart` 调用模型并接收流式文本。
2. **分段**：`chat_segments.dart` 按 `旁白：`、`莱莎：`、`角色[ID]：`、`译文：` 分离消息。
3. **解析标签**：使用 `face`、`action` 和 `posture` 正则提取应用标签；Fish 标签按 TTS 设置处理。
4. **清理显示文本**：从用户可见文本中移除控制标签，保留正文和译文。
5. **表情映射**：`character_expression.dart` 将 `face` 标签映射到表情预设、眼睛、眉毛、嘴型和微表情。
6. **动作映射**：`character_performance.dart` 将 `action` 标签按当前姿态映射到动作组或 one-shot 动画；找不到兼容资源时安全回退为空动作。
7. **队列调度**：`character_performance_queue.dart` 对表情和动作去重、限长，并等待当前动作结束后播放下一个动作。
8. **语音处理**：仅莱莎台词进入 TTS；旁白、NPC 和译文不使用莱莎声音。Fish 情绪和表演标签根据设置的情感程度、句内演出密度及 ASMR 模式处理。
9. **同步播放**：TTS 播放期间驱动口型、眨眼、头部微动作和动作动画；语音结束后恢复待机状态。
10. **异常回退**：非法或未知标签转换为 `neutral` / `none`，不阻断消息显示和语音播放。

### 运行时能力快照

真实请求在 `chat_screen.dart` 创建 `CharacterPerformancePromptContext`，再传给 `AppController.buildCharacterPrompt`。快照来自当前已经加载的 Spine 骨骼和 gesture JSON，而不是从用户输入推断：

```json
{
  "status": "ready",
  "appearanceId": "crf_skn_002_0001_01",
  "posture": "sitting",
  "revision": 12003,
  "actions": {
    "think": "思考、犹豫、疑惑；可执行资源……"
  },
  "motionGroups": {
    "grp_b_03": "双手叉腰，自信或佯装不满；资源标签……"
  }
}
```

快照生成和播放使用同一套兼容性条件：当前外观、基础姿势、坐姿限制、占用轨道、骨骼动画是否存在、Alpha 是否可见，以及资源作者标记的禁用项（`使わない` 或 `_ignore`）。`status=ready` 时非 `none` 动作只能从本轮 `actions` 或 `motionGroups` 中选择；`status=not_ready/stale` 时模型只能使用 `action:none`；`status=unknown` 只允许语义判断，不能承诺具体肢体姿势。播放前客户端仍会再次校验组 ID，过期或不兼容的组会被丢弃。

这条链路的职责边界是：模型理解语境并选择语义或目录中的精确动作，客户端解析标签、校验能力、排队和播放。客户端不把“叉腰”“挥手”等用户文字关键词转换为动作，也不覆盖模型已经输出的合法标签。

## 四、关键约束

- 不根据用户文本在本地匹配“叉腰、挥手”等关键词来触发动作。
- 不用本地规则覆盖模型已经输出的动作标签。
- 本地只负责解析、合法性校验、姿态兼容性检查和播放调度。
- 提示词负责让模型理解动作意图，并要求动作、表情和语义一致。
- API key、原版图片、音频、模型和 Spine 资源不进入公开仓库。

## 五、调试方法

检查运行日志中的三段内容：

1. LLM 原始响应：确认是否输出了 `face` 和 `action`。
2. 解析后的 `ChatSegment`：确认标签是否被正确识别，旁白/NPC 是否被误判为莱莎。
3. 动作计划和 TTS 请求：确认动作资源存在、姿态兼容，且 TTS 标签只出现在莱莎语音请求中。

如果日志中出现 `action:none`，先确认模型原始输出是否确实为 `none`；不要直接在客户端用关键词覆盖。应优先优化系统提示词或提高模型能力。
