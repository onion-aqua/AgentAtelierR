# 人格倾向试用版：实施审计（2026-10-22）

## 现有架构与基线

- Flutter 3.47.2 / Dart 3.13，Android、Windows 共用 `lib/src`。加密构建入口为 `tool/build_protected.ps1`。项目也含 iOS 等 Flutter runner，本轮目标为 Android 模拟器；不改云服务。
- 状态为 `AppController extends ChangeNotifier`，页面通过 AnimatedBuilder 或监听器刷新；设置详情采用 `pushSettingsPage`、`SettingsDetailPage`、`SettingsFormTheme`，保留玻璃效果。
- 原始人物资料为 `character_runtime_profile.dart` 和 `character_prompt_defaults.dart`；当前角色支持莱莎与苏菲，原始人物设定不被人格预设替换。
- 主链路：`chat_screen.dart` → `AppController.buildCharacterPrompt` → `AiChatClient.streamChat` → `chat_segments.dart` → `IndependentPerformanceTools` / `SpeechPlanner` → 已有 Spine 播放器 / TTS 服务。通话主角复用 `buildCharacterPrompt`，NPC 使用独立身份提示词。
- 表情合法集合：neutral/happy/laughing/angry/sad/crying/shy/tease/cuddle；情绪集合由 `CharacterState.emotions` 定义。动作只能来自当前 `CharacterPerformancePromptContext` 的可播放资源，不在新模块里创建动作 ID。
- LLM 支持 OpenAI 兼容与 Gemini；TTS 已支持 Fish API/MCP、Qwen、通用、MiMo、本地。人格只提供语义演出偏好，不向第三方接口新增参数。
- SharedPreferences 保存配置、人物会话和存档；运行时心情及关系属于 `CharacterState`。人格新增独立版本化配置键，按角色隔离，不随旧游戏存档回退，不接受 LLM 写入。完整本地备份可包含该配置。
- 业务代码修改前执行的 26 项基线测试通过：character_state、sophie_prompt_editor_alarm、independent_performance_tools、speech_planner、settings_navigation。原始输出 `build/personality-baseline.log`。

## 实施文件与边界

新增 `lib/src/personality/` 内的数据模型、11预设、确定性解释器和编辑器；在 `app_controller.dart` 接入独立存储及 Prompt，在 `settings_screen.dart` 添加入口，在现有演出 shared_context 传入偏好。新增对应领域、持久化、UI及集成测试。

附件已提供完整11预设的坐标及18项数值；规则触发条件的JSON结构未定义，因此使用显式枚举、关键词和可选情绪/关系范围，并记录当前schema。不存在已发布旧人格格式，不虚构迁移；缺少可选字段补默认，未知未来版本拒绝，损坏的本地数据保留原始内容并回退关闭状态。

## 兼容处理

- 默认关闭且开关在 Prompt 入口生效，关闭时不改变原有 Prompt、解析或演出协议。
- 人格只追加有限长度的行为约束；每次最多3条主要矛盾、2条动机，总区块不超过1200字符。支持真实演出开关，合法资源校验继续由现有规划器负责。
- 页面持有草稿，保存前不影响聊天；本地情境预览明确标注，不冒充LLM实际回复，也不写入心情或记忆。
- 按用户“尝试部署、体验后决定”实施本地试用，使用原有加密构建脚本安装模拟器，不发布远程更新。
