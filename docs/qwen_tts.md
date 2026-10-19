# 百炼 Qwen-TTS 配置

依据截至 **2026-10-19** 查阅的阿里云百炼官方文档更新。Android 与 PC 使用相同的配置和请求逻辑。

## 选择模型与接入地址

进入 **设置 → TTS → 百炼 Qwen-TTS**。可选择官方模型，也可保留或手动填写自定义模型。

| 模型 | 接口与音色注意事项 |
| --- | --- |
| `qwen-audio-3.1-tts-flash` | 当前推荐的新接口；使用该模型自己的音色，例如 `longanhuan_v3.1`。 |
| `qwen-audio-3.0-tts-plus` | 新接口；系统音色包括 `longanlingxin`、`longanlufeng`。 |
| `qwen-audio-3.0-tts-flash` | 新接口；系统音色包括 `longanfengyue`、`longanlingxi`、`longanhuan_v3.6`。 |
| `qwen3-tts-flash` | 旧版 Qwen3-TTS 接口，系统音色例如 `Cherry`；不会与新版字段混发。 |

新接口可按地域和 Workspace ID 配置，或填写完整服务地址：

```text
北京：https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer
新加坡：https://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer
```

将 `{WorkspaceId}` 替换为对应地域的真实业务空间 ID，使用**相同地域的 API Key**。旧版 Qwen3-TTS 使用 `/api/v1/services/aigc/multimodal-generation/generation`。

现有地址、模型、普通/ASMR 音色与 Key 会保留。选择新模型不意味着旧音色或旧 Key 自动适用于新接口；迁移时请核对地域、业务空间和音色绑定的模型。Key 沿用安全存储，不写入普通配置文本。

## 音色、语言与朗读参数

- 普通音色和 ASMR 音色分别配置；填写 ASMR 音色后才可启用该语音模式。试音使用当前语音模式对应的音色。
- 新版音色与模型必须匹配，不能把 `Cherry` 直接用于 Qwen-Audio-TTS，也不能跨模型复用复刻音色。
- 3.1 的多语种音色 `longanhuan_v3.1`、`longanlingxin_v3.1`、`longanfengyue_v3.1`、`xunanchuan_v3.1` 明确支持日语等语言。精品中文音色仅普通话，精品英文音色仅英语。
- 3.0 Plus/Flash 上述中文系统音色支持普通话和英语；日语应选择经确认支持日语的音色或为目标模型创建复刻音色。

普通聊天使用设置中的合成目标语言；持续 ASMR 按其朗读语言设置目标语言，避免画面语言与语音不一致。

新版合成使用 `language_hints`，支持 `zh`、`en`、`fr`、`de`、`ja`、`ko`、`ru`、`pt`、`th`、`id`、`vi`、`es`、`it`、`ms`、`fil`、`ar`。自动识别时省略该字段。指定日语可帮助改善数字、缩写和符号的读音，但不能让仅支持中文的系统音色获得日语能力。

新接口默认生成 **WAV / 24000 Hz**，可调整以下参数：

| 设置 | 官方范围 |
| --- | --- |
| 采样率 | 8000、12000、16000、22050、24000、44100、48000 Hz |
| 语速 `rate` | 0.5～2.0，默认1.0 |
| 音调 `pitch` | 0.5～2.0，默认1.0 |
| 音量 `volume` | 0～100，默认50 |

自然语言控制使用 `instruction`，例如“请用轻柔、清晰的日语自然朗读”。普通聊天、持续 ASMR 和设置试音使用同一套模型能力判断。具体效果仍取决于模型与音色；部分3.0精品英文系统音色的官方音色表注明不支持指令控制。

旧版 Qwen3-TTS 使用 `language_type`，支持 `Auto`、`Chinese`、`English`、`German`、`Italian`、`Portuguese`、`Spanish`、`Japanese`、`Korean`、`French`、`Russian`；当前官方文档限制单次文本600字符。新接口的采样率、语速等参数不会作为旧版参数直接发送。

## 新版声音复刻

1. 选择后续实际用于合成的 Qwen-Audio-TTS 模型。
2. 填写**可由阿里云服务公开读取的参考音频 HTTPS URL**。此入口不将本地文件自动上传，也不把 Base64 data URI 当作公网 URL。
3. 独立选择参考音频的语言，例如日语 `ja`。这里描述样本语种，与上方合成目标语言分别设置。
4. 填写1～10位英文字母或数字组成的名称前缀，创建成功后保存返回的音色 ID。

新版使用同地域的 `/api/v1/services/audio/tts/customization`，请求模型为 `voice-enrollment`、操作为 `create_voice`。`target_model` 必须与之后合成所用模型**完全一致**；更换模型后需要为新模型分别创建音色。

官方参考音频要求：WAV（16-bit）、MP3 或 M4A；推荐10～20秒、最长60秒、大小不超过10 MB、采样率至少16 kHz；包含至少5秒连续清晰朗读，避免背景音乐和其他人声。双声道仅处理首声道。

当前官方合成总览列明3.1 Flash 支持北京和新加坡；声音复刻指南的新加坡支持列表仅列3.0 Plus/Flash，尚未列3.1。需要3.1复刻时优先使用北京，并以对应地域的实际模型权限为准。

旧模型的本地参考音频创建入口仅作为兼容功能保留。旧 `qwen-voice-enrollment` 格式不属于本次查阅的新接口文档，不保证旧服务或旧模型继续可用，也不会将其冒充为新版复刻流程。

## 保存、备份与验证

新增选项随现有 TTS 配置持久化，并纳入应用原有配置导入导出流程；API Key 继续按原有安全凭据和备份开关处理。导入旧备份时，缺少的新选项保留现有值；首次使用采用兼容默认值。

配置保存不会自动生成付费音频；点击试音会正常调用服务并可能计费。本次更新使用本地请求模拟验证参数与兼容行为，未使用账户生成音频，也未以此宣称真实音质或账户权限已验证。

## 官方文档

- [非实时语音合成总览](https://help.aliyun.com/zh/model-studio/qwen-tts)
- [Qwen-Audio-TTS HTTP API](https://help.aliyun.com/zh/model-studio/qwen-audio-tts-http-api)
- [Qwen-Audio-TTS 音色列表](https://help.aliyun.com/zh/model-studio/qwen-audio-tts-voice-list)
- [声音复刻指南](https://help.aliyun.com/zh/model-studio/voice-cloning-user-guide)
- [声音复刻 HTTP API](https://help.aliyun.com/zh/model-studio/voice-clone-design-http-api)
- [旧版 Qwen3-TTS API](https://help.aliyun.com/zh/model-studio/qwen-tts-api)
- [旧版 Qwen3-TTS 音色列表](https://help.aliyun.com/zh/model-studio/qwen-tts-voice-list)
