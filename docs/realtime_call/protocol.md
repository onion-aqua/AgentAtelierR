# 实时角色电话：应用内数据与音频约定

本功能直接集成在 Flutter 应用中，不要求另外部署 FastAPI、WebSocket 网关或 PC Agent。麦克风音频只进入本地 VAD 和 Sherpa-ONNX ASR；识别后的文本使用已有角色 LLM 接口。通话跟随“声音与语音”中选择的 Fish Audio API 或 Fish Audio MCP，回复由应用播放并驱动 Spine。

```text
麦克风 16 kHz 单声道 PCM
  → 本地 VAD → 本地 Sherpa-ONNX ASR
  → 识别文字 → 已配置的角色 LLM（增量文本）
  → 按完整短句分段 → 所选 Fish Audio API（流式 PCM）或 MCP（完成音频）
  → 24 kHz / 16-bit / 单声道播放 + Spine 说话状态
```

这条通话链不上传麦克风原始录音，也不会把角色通话识别成 PC Agent 远程控制指令。现有 PC 联动协议和服务器保持独立。

## 使用方法

1. 先在 AI 接口中启用并测试当前角色使用的 LLM；通话沿用同一服务、模型、语言与 API Key。
2. 在“声音与语音”选择 Fish Audio API 或 Fish Audio MCP。API 使用对应 HTTPS 接口、REST API Key 和普通音色；MCP 使用已授权的 OAuth 连接、工具及 MCP 普通音色，不要求 REST Key，不自动回退 API。通话设置会显示当前服务及计费路径。其他语音服务目前不支持电话。
3. 打开“虚拟手机 → 电话 → 右上角设置”，使用模型下载功能自动获取、解压并填入兼容的 SenseVoice `model.int8.onnx`、同包 `tokens.txt` 和 `silero_vad.onnx`，然后点击“保存”。也可继续分别导入这三个文件；文件会复制到应用私有目录，外部原文件之后可以移动或删除。
4. 电话目前只适配莱莎和科洛蒂娅。莱莎使用所选语音服务的普通音色，科洛蒂娅使用应用内置音色。电话设置不再重复配置模型或音色，可点击“前往声音与语音”统一修改。其他 NPC 保留信息聊天功能，不出现在电话通讯录中；切换到其他主角色时不借用其人设扮演莱莎。
5. 返回通讯录点击电话图标。科洛蒂娅首次拨打时会加入当前存档的联系人，其通话与信息聊天共用已保存的记忆。

两人的朗读语言均跟随“设置 → 语言”中的角色回复语言，不读取信息页面独立的 NPC 回复语言。CC 按钮控制原文和译文显示；译文目标跟随主翻译语言设置，选择不翻译或与朗读语言相同则不请求译文。字幕翻译独立异步请求，只用于显示，绝不会送进 TTS；主聊天“独立翻译”开关仍保留其原有生成方式语义。更改语言、换轮或挂断后，过期的字幕翻译结果会被丢弃。

角色播放和思考期间保持收音，用户开始连续说话约 250 ms 后由本地 VAD 触发打断，同时停止播放、取消旧 LLM/TTS 和待播队列，保留插话开头，断句后发送新问题。也可点击原有“打断”按钮。Android 请求硬件回声消除/降噪，并用实际播放 PCM 做有限窗口回声过滤；免提效果受设备回声消除能力、距离和音量影响，耳机可减少外放回录。静音仍暂停收音。扬声器按钮仅在 Android 确认真实输出路由已经切换后改变状态。应用进入后台、系统电话或其他通信应用占用通话音频、切换人物/存档时，本次通话会结束。通话记录与实际完成播放的对话写入当前存档；未播完的模型续写不会进入记忆。

通话录音显式设置 `AudioInterruptionMode.none`，音频焦点与真实来电统一交给现有 `CallAudioGuard` 管理，避免录音插件被本应用播放语音时的焦点请求永久暂停。静音切换查询录音器的真实暂停状态，不使用可能过期的 Dart 缓存。通话中切换 API/MCP 会结束当前通话，重新拨打使用新服务。

## MCP 通话

实现：`lib/src/realtime_call/call_mcp_tts.dart`。复用现有 `FishMcpService.synthesize` 的 OAuth、工具发现和 Studio 逻辑；指定 `drama-3` 时通过 Studio 项目 `default_backend` 设置模型，不向普通 `text_to_speech` 塞入未声明字段。

MCP 先返回完成的音频，再在本地转换为 24 kHz、PCM16、单声道交给同一播放器；它不等于 REST 的实时网络音频流，首段等待可能更长。插话/挂断立即停止本地播放并使待返回结果失效，晚到的临时音频会清理，不断开主聊天共享的 MCP 连接。已提交的云端生成可能仍消耗积分；不会自动重试或改走 API。

每次拨号从“声音与语音”读取所选服务、模型和普通音色；科洛蒂娅使用内置音色。API 和 MCP 的凭据与音色不会交叉使用。旧版电话模型与联系人音色覆盖值不再参与运行，保存电话设置时会清除，语音识别模型与断句设置保留。

通话设置只保留本地识别模型下载、识别语言和停顿断句。手动文件导入收在“手动导入与模型说明”中，语音配置修改后下次拨号生效。冷启动尚未叫醒莱莎时，拨号会提示先回主聊天点击叫醒，不会启动麦克风或发送生成请求。

## 本地模型下载

设置页的“下载并安装本地模型”先查询公开 Gitee Release 附件，再回退官方 GitHub；下载过程中显示来源、进度、自动解压及安装状态，可以取消。解压在工作 isolate 中执行；下载、校验、解压失败或取消不会覆盖原来配置的模型。完成后原有三行文件名会自动填入，点击右上角“保存”启用；不需要手工解压或浏览手机私有目录。

- Gitee 默认目录：`https://gitee.com/api/v5/repos/MugenMahoro/AgentAtelierR/releases?per_page=100`。按附件精确文件名查找，并验证与固定官方版本相同的大小和 SHA-256；可通过编译参数 `CALL_ASR_GITEE_RELEASES_URL` 替换公开 Release 目录。
- 官方备用目录：`https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/`。
- SenseVoice 包：`sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2`，163,002,883 字节，SHA-256 `7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e`。
- VAD 文件：`silero_vad.onnx`，643,854 字节，SHA-256 `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6`。

2026-10-21 检查时，上述 Gitee 仓库还没有公开的模型 Release 附件，当前会明确显示回退官方源；只有将这两个原样文件托管为 Gitee Release 附件后，国内镜像下载才能实际使用。客户端已实现优先级和故障回退，本次未发布模型附件。HTTPS 校验保持启用，不包含任何仓库访问令牌。

## Fish 流客户端

实现：`lib/src/realtime_call/fish_call_tts.dart`。

```dart
final audio = FishCallTtsClient().synthesize(
  apiKey: fishRestKey, // 从既有 SecretStore 获取
  text: sentence,
  voiceId: configuredVoiceId,
  model: configuredFishModel,
  endpoint: configuredFishEndpoint,
  speed: configuredSpeed,
);
await for (final bytes in audio.pcm) {
  // bytes 为 24 kHz / PCM signed 16-bit little-endian / 单声道；
  // 每个 chunk 保证完整采样点，不保证等于一个完整句子。
  await playback.write(bytes);
}
// 用户插话、挂断、权限撤回、真实系统通话抢占时：
await audio.cancel();
```

`synthesize` 返回单次、单订阅的 `FishCallTtsStream`。开始监听 `pcm` 才发出请求；监听前取消不会生成语音。每次生成使用独立 HTTP transport，取消不关闭主聊天使用的播放器或 TTS 客户端。Windows 沿用既有 Fish Audio 系统代理预探测；该探测不会生成语音，实际 POST 不自动重试。

请求为 `POST https://api.fish.audio/v1/tts`，用户自定义接口同样必须为 HTTPS。HTTP 头包含：

```text
Authorization: Bearer <本地安全存储中的 Fish REST API Key>
Content-Type: application/json
model: <当前配置的模型>
```

JSON 正文关键字段：

```json
{
  "text": "こんにちは。",
  "reference_id": "<当前角色音色>",
  "format": "pcm",
  "sample_rate": 24000,
  "latency": "low",
  "normalize": true,
  "temperature": 0.55,
  "prosody": {"speed": 1.0, "volume": 0, "normalize_loudness": true}
}
```

官方 REST 接口本身以 HTTP chunked 响应输出音频，不需要、也未在其 TTSRequest schema 声明 `streaming: true`。模型位于 **HTTP `model` 头**，不是自行添加到普通 MCP `text_to_speech` 的未声明参数。客户端不维护模型白名单，账户是否可用由 Fish 服务决定。该链路要求 Fish REST API Key；MCP OAuth 会话不会被当作 REST API Key，也不自动切换计费入口。

## 中断和计费边界

- 由通话控制器为每轮分配 generation/turn 标识；新一轮、插话或挂断使旧一轮失效，丢弃晚到的 LLM、ASR 和音频回调。
- 本轮插话时停止播放并取消该轮 LLM 和正在接收的 Fish HTTP 请求。取消意味着不再本地播放；服务已经接受的生成仍可能收费。
- Fish 流没有自动重试、模型回退、REST/MCP 回退。超时或连接中断时标记 `generationSubmitted` / `outcomeUnknown`，由用户决定是否再次发言，避免自动重复付费。
- 单段限制 2000 字、默认最多接收两分钟音频；拒收空白、仅喘气标签、错误媒体类型、空或截断 PCM。重用已有 Fish 文本清洗，抑制过量喘气和重复停顿标签。
- 不跟随 3xx 重定向，避免 Authorization 被转发到其他源；不关闭 TLS 校验。接口 URL 不允许 userinfo、查询参数或片段。
- 错误只暴露安全错误类型、HTTP 状态和格式受限的 request ID；不抄录服务端任意错误正文，不记录 API Key、Authorization 或整段通话文本。

## 验证范围

`test/realtime_call_fish_tts_test.dart` 使用可替换 HTTP transport，验证渐进到达、奇数字节对齐、请求前取消、等待响应头时取消、402、3xx、超时、错误媒体类型和敏感值不泄漏。通话测试覆盖限定联系人、语言和字幕、播放/思考中语音打断、取消期间插话排队、静音、后台和存档切换；下载测试覆盖 Gitee 优先、源回退、哈希错误、取消清理及不安全归档。测试不调用真实收费生成接口。

官方模型文件已完整下载校验，并用实际 Dart 解压器验证可提取模型和 tokens；这不等同于手机上的收音、推理或通话体验验收。

真机端仍需使用用户配置的 LLM/Fish API 凭据及已安装的本地 ASR 模型，验证语言、麦克风权限、免提/听筒路由、插话和真实电话抢占。未经真实请求测试，不将模拟 transport 测试称为线上语音验收。

## 官方协议依据

于 2026-10-21 读取：

- [Fish Audio Text to Speech](https://docs.fish.audio/api-reference/endpoint/openapi-v1/text-to-speech.md)：PCM 支持 24 kHz、16-bit 单声道；`model` 为头参数；200 响应为 chunked。
- [Fish Audio OpenAPI](https://docs.fish.audio/api-reference/openapi.json)：`TTSRequest.format`、`sample_rate`、`latency`、`prosody` 字段。
- [Fish Audio Real-time Voice Streaming](https://docs.fish.audio/developer-guide/best-practices/real-time-streaming.md)：渐进合成场景和延迟建议。
