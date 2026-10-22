# 人格倾向编写指南

适用：AgentAtelierR 当前人格系统，`schemaVersion: 1`。更新日期：2026-10-22。

## 1. 先选一个接近的预设

入口：虚拟手机 → 设置 → 角色与世界 → 人格倾向（试用）。从预设新建，编辑图形参数、动机和规则，开启人格倾向并保存。拖动图形只修改草稿，保存后才用于下一次对话。

当前 11 种预设都通过同一个解释器：元气冒险家、温柔守护者、傲娇、隐忍病娇、外放病娇、腹黑、慢热型、雌小鬼、冷静理性型、姐姐型引导者、笨拙真诚型。本次修复让它们在没有触发特殊规则的普通对话里，也会注入各自的常态描述和说话方式。已有预设档案保留这些字段，无需重新创建。

人格影响当前角色的表达，不改变角色身份、世界观、历史事实、语言设置和回复格式，不直接增减心情或关系点数。实际呈现仍受所选模型影响。

后续修订：全部内置预设和自定义人格都会明确注入“当前扮演指令”，要求从本轮持续按保存的风格、参数、动机和情境规则扮演，不等待用户在聊天中再次要求扮演。自定义人格不需要 `presetId`，只调图形参数、未填写 summary/style 的档案也适用；手调内容与整体强度仍优先。名称只标识档案，不从名称猜测未配置的特征；保留关闭、对话风格关闭、强度为零时不注入的行为。

“雌小鬼”在整体强度至少 40、调侃至少 85、玩心至少 75 时，额外提供得意逗弄、偶尔称“小笨蛋”、被反击后嘴硬的台词演法和两句语感示例。示例不作为对话历史，需按当前回复语言改写，不应照抄。降低上述参数或清除 presetId 后不注入这段；识别到拒绝、低落或当前悲伤/担忧情绪时也不注入。

## 2. 用三层内容描述人格

| 层次 | 字段 | 写什么 |
| --- | --- | --- |
| 平时是什么样 | `metadata.summary` | 两三项稳定特征及其矛盾，例如“爱逗人、好胜，被反击时嘴硬”。 |
| 平时怎么说话 | `metadata.style` | 可观察的句式和节奏，例如“短句、反问、小挑战；认真求助时直接帮忙”。 |
| 特定情境怎么反应 | `contradictions`、`situations` | 明确触发条件、外在反应、内在需求与限制。 |

不要只写“很傲娇”“非常腹黑”，也不要仅填人格名称。名称和 `presetId` 本身不会自动产生风格。写清楚台词如何变化，比堆形容词有效。

常态描述在提示词中最多取 55 字符，说话方式最多取 90 字符，重要内容放前面。页面里的“说明”保存到 `metadata.description`，只是备注，**不会作为说话风格注入**。当前页面没有单独的 summary/style 编辑框；要改这两个字段，请导出 JSON 修改后再导入。

不要将所有风格都藏在“受到夸奖”“久未联系”等规则中，否则普通闲聊无法体现。也不要让所有规则都使用“一般情境”，挤占真正需要的场景规则。

## 3. 参数怎么配

两个坐标取整数 −100～100：

| 字段 | 负方向 | 正方向 |
| --- | --- | --- |
| `selfOther` | 重视自主判断与个人目标 | 重视照顾与关系维护 |
| `restraintExpression` | 克制、含蓄 | 直接、主动 |

18 项人格参数取整数 0～100：

| 字段 | 中文名 | 高值倾向 |
| --- | --- | --- |
| `independence` | 独立性 | 自主判断 |
| `responsibility` | 责任感 | 承诺与补救 |
| `playfulness` | 玩心 | 游戏、玩笑、接梗 |
| `curiosity` | 好奇心 | 探索与提问 |
| `emotionalExpressiveness` | 情绪表达 | 直接表达感受 |
| `emotionalReactivity` | 情绪反应 | 明显情绪转折 |
| `recoverySpeed` | 恢复速度 | 更快平复表达 |
| `attachment` | 依恋倾向 | 珍视关系连续性 |
| `abandonmentFear` | 被抛弃恐惧 | 对关系不确定更不安 |
| `possessiveness` | 占有欲 | 更明显的占有情绪 |
| `jealousySensitivity` | 嫉妒敏感度 | 对关系比较更敏感 |
| `controlTendency` | 控制倾向 | 主动安排互动节奏 |
| `boundaryRespect` | 边界尊重 | 主动询问意愿 |
| `trust` | 信任倾向 | 先相信、允许澄清 |
| `forgiveness` | 宽恕倾向 | 接受解释与补救 |
| `affectionInitiative` | 主动亲近 | 邀请、关心、分享 |
| `teasing` | 调侃倾向 | 有来有回的调侃 |
| `reassuranceSeeking` | 寻求安抚 | 询问和确认关系 |

多数参数按低于 40、40～59、60 及以上解释为低、中、高档。调侃和玩心另有 85 及以上的鲜明档位。数值不是连续控制模型的精确权重，不保证 71 与 72 产生不同回答。解释器按场景挑选重要参数，不会将整张参数表送给模型。

表现参数同样为 0～100：

- `intensity`：整体显著程度。0 完全不注入；1～39 细微点缀；40～74 要求普通闲聊自然体现一个特征；75～100 持续鲜明，可组合多个特征。
- `consistency`：表达的长期一致性，不是长期记忆容量。
- `adaptability`：随当前情境调整的倾向。
- `contradictionIntensity`：外在表现与内在需求的张力。
- `relationshipSensitivity`：关系变化对表达的影响。
- `comedyIntensity`：喜剧夸张力度，不决定调侃频率。

建议先用 70 的整体强度，只突出两三项核心特征。不要把全部数值拉满。手动参数优先于预设风格；改成完全不同的人格时，也应同步修改 summary/style，避免彼此冲突。

## 4. 情境规则怎么写

推荐结构：“发生什么 → 如何说/做 → 为什么 → 什么情况下停止”。例如受到夸奖时，先得意地反问一句，再掩饰害羞，不否定对方的真诚。

| 字段 | 作用 |
| --- | --- |
| `id` | 档案内唯一规则编号，矛盾与情境规则之间也不能重复。 |
| `enabled` | 是否参与选择。 |
| `priority` | 0～100，越高越优先。同优先级按原顺序，矛盾规则在情境规则之前。 |
| `triggerType` | 触发类型，见下表。 |
| `keywords` | 非空时必须至少命中一个；使用输入文本包含匹配，忽略字母大小写。 |
| `situations` | 非空时必须至少命中一个文本片段，不是地图或场景数据库编号。 |
| `emotion` | 可选，必须等于当前情绪。 |
| `minCloseness` / `maxCloseness` | 可选，0～100 的亲近程度区间。 |
| `surface` | 表面表现。 |
| `hiddenNeed` | 内在需求，也参与动机选择。 |
| `response` | 具体反应，优先写清楚实际台词怎么表达。 |
| `constraint` | 收敛条件与限制。 |

触发类型：`always` 一般情境、`praise` 受到夸奖、`help` 当前请求帮助、`refusal` 拒绝或暂停、`absence` 久未联系、`jealousy` 关系比较、`conflict` 争执或误会、`mistake` 犯错或失败、`success` 进步或成功、`distress` 低落或疲惫、`affection` 表达亲近、`novelty` 新事物、`keywords` 自定义关键词。

所有附加条件共同满足才会命中；同一关键词列表内任一个命中即可。`keywords` 类型必须填写关键词。情绪允许值：`neutral`、`happy`、`curious`、`shy`、`sad`、`angry`、`worried`、`excited`。内置触发器是本地规则，并非 LLM 语义判断；需要测试否定、引用、过去事件和不同语言。

每轮最多 3 条规则、2 条动机，整段人格提示词最多 1200 字符。规则会按剩余预算截短，具体反应和限制优先，重要内容放在字段开头。不是填写越多，模型看到的就越多。

## 5. 可导入的最小示例

先导出现有配置作备份。下例是完整配置集合，适用于 `ryza`。导入会替换当前配置草稿，而非追加一份档案；如果想保留其他档案，应在原导出文件的 `profiles` 数组中追加，并更新 `activeProfileId`。最后仍需在页面保存。

```json
{
  "schemaVersion": 1,
  "characterId": "ryza",
  "enabled": true,
  "activeProfileId": "custom-playful-01",
  "profiles": [
    {
      "schemaVersion": 1,
      "profileId": "custom-playful-01",
      "name": "俏皮挑战者",
      "characterId": "ryza",
      "baseAxes": {"selfOther": -25, "restraintExpression": 65},
      "traits": {"teasing": 95, "playfulness": 90, "boundaryRespect": 85},
      "motives": ["想让交谈有来有回，也希望对方看见自己的本领。"],
      "contradictions": [],
      "situations": [
        {
          "id": "playful-praise-01",
          "triggerType": "praise",
          "priority": 70,
          "surface": "得意，但有一点不好意思。",
          "hiddenNeed": "希望夸奖是真心的。",
          "response": "先用一句俏皮反问接住夸奖，再自然回应具体内容。",
          "constraint": "不机械复读口头禅，不贬低对方。"
        }
      ],
      "expression": {"dialogue": true, "face": true, "action": true, "voice": true},
      "tuning": {"intensity": 75, "comedyIntensity": 40},
      "metadata": {
        "summary": "爱逗人、好胜，被反击时会嘴硬，仍愿意认真帮助对方。",
        "style": "短句、反问和小挑战；接住对方的梗，避免每次都以温柔附和结尾。"
      }
    }
  ]
}
```

省略的人格参数默认为 50，坐标为 0，演出开关为 true；未填的表现参数采用应用默认值。自定义档案可以不填 `presetId`。`profileId`、规则 `id` 使用字母/数字开头，后接字母、数字、下划线、点、冒号或连字符，总长最多 96 字符。

其他限制：每角色 1～24 份档案；每类最多 24 条规则；动机最多 12 条，每条 240 字符。未知数值参数名、越界或小数、重复编号、其他角色配置和未来 schemaVersion 都会被拒绝。不要用 JSON 注释或省略号。

## 6. 怎样判断效果

1. 先用“情境测试”检查命中规则、动机和参数解释。它是本地示意，不调用模型，也不是实际聊天效果证明。
2. 保存并开启人格，确认“对话风格”打开，整体显著程度不为 0。
3. 用同一模型比较普通闲聊、夸奖、反击、认真求助、明确拒绝五类输入。观察实际台词的句式和反应，不能只看旁白。
4. 如仍偏弱，核对实际请求内的“可选人格倾向”段是否包含 summary/style，是否与手调参数冲突，再考虑增加强度。
5. 不要为了测试删除真实记忆或存档。切换人格只改变之后的表达，旧回复不会被改写。关闭并保存即可恢复原链路。

表情、动作和语音偏好可分别关闭，仍受当前台词、情绪、姿态、可用动画和 TTS 标签能力限制。人格本身不会创造新动画或修改音色 ID。

## 7. 在源码中增加内置预设

主要文件：

- `lib/src/personality/personality_presets.dart`：在 names、ids、_traits、_descriptions 中使用同一个新 ID，提供 axes、motives、rules、scenes、summary、style。
- `lib/src/personality/personality_profile.dart`：格式、参数名、默认值和导入校验。
- `lib/src/personality/personality_interpreter.dart`：常态表达、参数解释、场景触发和提示词预算。
- `lib/src/personality/personality_editor_page.dart`：草稿编辑、导入导出及保存。

新增预设后检查普通闲聊下仍有风格；增加新的参数或 triggerType 时，还需同步解释器、编辑器和校验，不能仅在 JSON 里添加字段。修改预设模板不会自动覆盖用户已经保存的档案；本次通用解释器修复则能直接用于已有档案。

推荐运行：

```powershell
flutter test --no-pub test/personality_domain_test.dart test/personality_integration_test.dart test/personality_performance_test.dart test/personality_chart_test.dart test/personality_editor_page_test.dart
dart analyze lib/src/personality
```

Android/Windows 打包必须使用项目 `tool/build_protected.ps1`，保留人物资源加密流程。
