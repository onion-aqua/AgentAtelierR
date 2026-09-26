# AgentAtelierR

**让对话、声音、表情和场景一起参与角色互动。**

AgentAtelierR 是以 Android 为主要开发平台的 Flutter AI 角色互动项目。它把流式 LLM 对话、本地记忆、可选语音合成、角色表现和场景声音连接起来。项目为非官方实验作品，不代表原作官方产品或剧情；仓库中的 Dart 包名 `ryza_chat_mvp` 沿用早期命名。

> 本仓库提供代码和实现文档，不提供完整的原版游戏资源。多数人物图片、Spine 骨骼与贴图、地图和音频，以及本地 `packages/spine_flutter/` 运行时依赖未随仓库提交。克隆仓库后不能直接获得完整角色体验或保证立即构建成功。请只使用具有相应使用权的资源，参阅[人物资源保护与构建说明](docs/PROTECTED_CHARACTER_ASSETS.md)。

## 当前版本与适用范围

当前源码版本为 **AgentAtelierR 1.0.0 正式版 DX**，Android 版本号 `1.0.0+31`，GitHub 标签 `v1.0.0-dx`。变更见[DX 更新记录](docs/CHANGELOG_1.0.0-DX.md)。以下功能以当前源码为准；具体效果会受到本地资源、设备、模型和服务能力影响。

- 莱莎已接入 Spine 动画、地图与场景、商店、背包、炼金、任务和语音闹钟。
- 苏菲已开放独立的角色设定、对话、记忆、存档和语音配置，目前使用静态立绘；她的地图、炼金、任务、商店和语音闹钟仍待接入。
- Android 是主要测试平台。Windows 有受保护资源构建入口，但仓库未包含完整 Windows 工程与本地运行时资源，不代表已有可直接分发的 Windows 安装包。
- 当前 Android release 模式 APK 仍沿用调试签名以兼容现有测试包的覆盖安装，不适用于应用商店上架。

## 对话与叙事

- **流式回复**：支持 OpenAI 兼容的 Chat Completions 接口，以及 Google Gemini 原生 Interactions 接口；正文逐步显示，可停止生成。Gemini 的实际模型权限和线上协议仍取决于服务端，接入细节见[Gemini 文档](docs/GEMINI_INTERACTIONS.md)。
- **旁白、台词与译文**：分段处理角色回复，显示旁白和台词，并保存历史对话的译文。对控制标签进行过滤：隐藏思考和工具调用内容，保留 `answer`、`code` 中的正文，同时处理流式未闭合标签，减少误吞旁白。
- **对话操作**：支持继续、撤回、重播语音、建议回复和图片或文件附件。附件能否被模型识别取决于相应服务的能力。
- **多人文字互动**：结合地点、角色目录和上下文组织其他角色发言；其他角色目前主要是文字互动，不具备莱莎的完整动画和触碰能力。
- **语言配置**：界面、旁白、角色回复和译文语言可分别设置；翻译也可关闭。

## 角色表现与服装

莱莎使用 Spine 4.2 运行时。待机、触碰反馈、视线、表情、姿态、服装和说话动作由当前角色状态及规划结果协调。语音播放时，音频能量包络驱动近似嘴型，并配合轻微的身体动作；这不是音素级唇形识别，也不能保证每套资源具有相同的动作。

服装页面支持横向滑动切换卡片。所有现有服装之后的导入卡片可选择服装 ZIP，或为指定服装导入 PNG 贴图；导入包如有独立预览图，会显示在卡片上。已导入贴图可以在原始/导入版本间切换，也可以删除。导入文件留在应用私有目录，不包含在聊天 JSON 备份中，换设备需要另行迁移。格式与限制见[本地皮肤和贴图导入](docs/LOCAL_SKIN_IMPORT.md)。

苏菲当前显示静态立绘，立绘文件仅用于本地构建和已发布的安装包，不纳入 GitHub 源码仓库。两位人物的设定、世界书、对话、记忆、存档和语音配置按角色隔离；苏菲动态资源的接口预留给后续接入。不能将莱莎的地图、动作和背包功能视为苏菲已实现的功能。

## 语音合成与持续 ASMR

| 服务 | 当前用途 |
| --- | --- |
| Fish Audio | 角色语音、普通/ASMR 音色和演绎标签 |
| 百炼 DashScope Qwen-TTS | 语音合成与引导式音色克隆配置 |
| 通用 OpenAI TTS | 兼容 `/audio/speech` 的语音服务 |
| MiMo TTS | 预置音色、参考音频克隆与文字音色设计 |

语音服务需要用户自行配置。普通对话和持续 ASMR 的新合成语音会尝试本地响度均衡，减少句内及分段音量差；不支持的音频或解码失败时回退原音频。该处理不修复已经削波的音频，真实听感仍需按服务和设备试听，见[商店与语音实现记录](docs/商店与TTS响度均衡_2026-09-26.md)。

主页提供普通/ASMR 模式。持续 ASMR 页面先确认主题并在后台准备稿件与语音，点击播放后才进入黑色朗读界面，显示当前文字、译文和语音列表。音色和模型对情绪标签的响应各不相同，演绎效果不保证每次一致。

## 地图、商店与日常状态

- **地图与场景**：莱莎可浏览世界、区域和地点，在切换地点后让位置进入对话上下文；背景、BGM、环境音和昼夜场景按地点与时间选择。缺失的媒体会按已有映射回退，应用不会自动提供未提交的素材。
- **商店与背包**：商品卡片显示名称、图片、价格和购买按钮；点击图片查看描述及效果。购买后的物品与背包、存档状态联动。
- **任务与炼金**：莱莎的欢迎任务、进度、奖励和炼金页面使用本地状态保存；实际内容依赖相关数据与资源。
- **饱食度与食品补给**：目前只适用于莱莎，并需开启剧情时钟与联网 Agent。用户上传可读取的食物图片、明确邀请品尝，且模型确认实际品尝后，才由本地工具结算饱食度；在指定地点可每天准备一次食品补给。条件和上限见[饱食度说明](docs/饱食度适配_2026-09-26.md)。
- **语音闹钟**：莱莎在 Android 端接入系统闹钟、锁屏提醒和本地语音。响铃仍受通知、精确闹钟权限及设备后台策略影响。

## 记忆、存档与数据迁移

对话历史、人物状态、用户设定和记忆主要保存在本机。最近记忆通常按约 4 轮对话整理；累计约 8 条待整理的最近记忆后，再整理长期记忆，前提是相关记忆设置已开启且 LLM 服务可用。长期记忆提示词可编辑，也可手动触发整理，在确认卡片中读写结果和译文后一起保存。自动整理依赖模型判断，不保证永不遗漏或重复。

数据管理支持版本化 JSON 导入/导出。导出时可以选择是否包含 API 服务配置及密钥；**包含密钥的 JSON 是明文文件**，请自行保管，不要公开上传。切换到新存档会重置相应人物的状态；角色数据分别保存，避免两位人物的历史和关系混用。

## Agent、服务与隐私

联网 Agent 为可选功能，可根据服务能力调用搜索和受限设备工具，例如时间、位置、周边服务及可启动应用列表。定位和其他权限按操作需要申请；模型是否能使用工具取决于相应接口。设备工具不等于任意读取其他应用的数据或执行系统命令。

应用没有自建账户和云同步；迁移主要通过本地文件完成。API Key 由平台安全存储管理，普通导出不必包含密钥。**本地优先不等于完全离线**：对话、相关设定、记忆和附件会按请求发送到用户配置的 LLM 服务，朗读文本与音色参数会发送到配置的 TTS 服务；服务可能产生费用。运行日志和备份也可能包含私人内容，分享前请检查。

首次使用可先配置 LLM 的服务地址、模型和密钥，测试文字对话，再配置 TTS 并用短句试音。Gemini 应按[原生 Interactions 接入说明](docs/GEMINI_INTERACTIONS.md)填写地址；旧文档中仅使用 `/v1beta/openai` 的配置说明已不适用。

## 获取代码与本地构建

```powershell
git clone https://github.com/onion-aqua/AgentAtelierR.git
cd AgentAtelierR
flutter doctor -v
```

工程的 Dart SDK 约束为 `^3.13.2`。Android 构建还需要匹配的 Flutter、JDK、Android SDK 和本地资源；特别是 `packages/spine_flutter/` 与受保护人物素材未随仓库提供。请先核对[资源保护与构建说明](docs/PROTECTED_CHARACTER_ASSETS.md)。

资源齐全后，统一使用加密构建脚本。脚本会准备受保护资源、注入本地解密密钥并构建；直接运行 `flutter build` 不会完成这一步。

```powershell
# 在连接的 Android 设备上运行
powershell -ExecutionPolicy Bypass -File .\tool\run_protected.ps1 -Device a43d2d7a

# 构建并安装调试 APK；可用 -DeviceId dc4a3f49 指定另一台设备
powershell -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target apk -Mode debug -Install -DeviceId a43d2d7a

# 构建 release 模式 APK
powershell -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target apk -Mode release
```

APK 输出位于 `build/app/outputs/flutter-apk/`。Windows 目标还需 Visual Studio C++ 桌面开发工具、Windows SDK 及本地 Windows 工程和运行时资源；可用相同脚本的 `-Target windows -Mode release` 入口。脚本生成的密钥、资源包、APK 和符号文件均不应提交仓库。

## 代码与实现文档

| 位置 | 主要职责 |
| --- | --- |
| `lib/src/app_controller.dart` | 角色状态、设定、提示词、记忆与存档 |
| `lib/src/chat_screen.dart`、`lib/src/chat_segments.dart` | 对话界面、语音协调及旁白/台词解析 |
| `lib/src/ai_services.dart`、`lib/src/gemini_interactions.dart` | LLM、TTS 与 Gemini 协议适配 |
| `lib/src/character_*.dart` | 角色资源、动作、表情、视线与语音表现 |
| `lib/src/continuous_asmr_page.dart` | 持续 ASMR 的准备与播放界面 |
| `lib/src/world_map_screen.dart`、`lib/src/stage_environment_catalog.dart` | 地图、地点和场景映射 |
| `lib/src/local_skin_store.dart`、`lib/src/appearance_picker_page.dart` | 本地服装导入与切换 |
| `lib/src/memory_timeline.dart`、`lib/src/manual_memory_consolidation.dart` | 记忆时间线与手动整理 |
| `tool/build_protected.ps1`、`tool/run_protected.ps1` | 受保护资源构建与运行入口 |

更多记录：[人物表现映射](docs/CHARACTER_PERFORMANCE_MAPPING.md) · [动画运行时对照](docs/APK_RUNTIME_RECHECK_2026-09-26.md) · [DX 更新记录](docs/CHANGELOG_1.0.0-DX.md) · [提交历史](https://github.com/onion-aqua/AgentAtelierR/commits/main/)。历史文档描述的是各阶段实现，遇到差异以当前源码和版本记录为准。

## 资源与反馈

仓库不提供原版人物骨骼、贴图、地图、音频或 APK 解包文件的再分发授权。已获准公开的品牌图标等个别文件不代表其他角色素材可以公开。Spine Runtime、各插件和自行导入的媒体还需遵守各自许可或授权；本仓库没有一份覆盖整个项目的统一根目录许可证。详见[资源审计](docs/ORIGINAL_ASSET_AUDIT.md)。

反馈问题时请提供应用版本、平台、复现步骤以及预期和实际表现。涉及接口时可附去除隐私后的模型 ID、HTTP 状态和响应片段；请勿提交 API Key、完整私人对话或未授权资源。
