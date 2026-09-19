# 模型思考自动适配

设置入口：设置 → AI 接口 → 模型思考。规则位于 `lib/src/model_thinking.dart`。

按模型名称判断能力，并对已知服务端点选择协议。识别不等于已经向每个厂商实际发送过请求；自定义别名、中转协议改写和未来型号不能保证仅靠名称正确识别。未知模型不发送思考参数，继续使用服务默认行为。

## 当前规则

| 模型系列 | 开关与强度 | 请求格式 |
| --- | --- | --- |
| GPT-5.1 及后续 GPT-5.x 常规型号 | 可开关，低/中/高 | `reasoning_effort`；关闭为 `none` |
| GPT-5 基础型号、GPT Codex、GPT-6、o1/o3/o4、GPT-OSS | 不能关闭；按型号调整强度 | `reasoning_effort`，不会发送 `none` |
| GPT Pro | 固定高强度 | `reasoning_effort: high`；具体端点支持仍取决于服务 |
| Gemini 3，原生 Interactions | 不能关闭，按型号选择有效强度 | `generation_config.thinking_level` |
| Gemini 3 / Gemini 2.5，OpenAI 兼容接口 | 3 和 2.5 Pro 不能关闭；2.5 Flash 可关闭 | `reasoning_effort` |
| DeepSeek Chat、V3.1/V3.2、Flash/Pro、V4 Flash/Pro | 可开关 | `thinking.type`；百炼端点改用 `enable_thinking` |
| DeepSeek Reasoner / R1 | 固定思考 | 不伪造关闭参数 |
| Qwen3 混合模型、Qwen Plus/Turbo/Flash | 可开关 | `enable_thinking`；本机非 Ollama 使用 `chat_template_kwargs.enable_thinking` |
| Qwen Thinking / QwQ | 固定思考 | 不伪造关闭参数 |
| Qwen Instruct / Coder、普通 GPT、旧 Claude 等 | 无思考开关 | 不发送控制参数 |
| GLM 4.5/4.6/4.7、GLM 5/5.1/5.2 | 可开关 | `thinking.type` |
| GLM 5.3 / Z1 | 固定思考 | 不伪造关闭参数 |
| Kimi K2.5/K2.6 | 可开关 | `thinking.type` |
| Kimi K2 Thinking / K2.7 Code | 固定思考 | 不伪造关闭参数 |
| Kimi K3 | 固定思考，低/高 | `reasoning_effort` |
| MiniMax M1/M2 系列 | 固定思考 | `reasoning_split: true`，分离推理与回答 |
| MiniMax M3 | 可开关 | `thinking.type: adaptive/disabled`，同时分离推理 |
| Claude 3.7 / Claude 4 系列 | 可开关，思考预算分档 | `thinking.type`、`budget_tokens` |
| Grok 3 Mini、Grok 4.5/4.6 | 固定思考，按型号调整强度 | `reasoning_effort` |
| Grok 4 / Reasoning | 固定思考 | 不伪造关闭参数 |
| 本机 MiMo V2 Flash、Hunyuan A13B | 可开关 | `chat_template_kwargs.enable_thinking` |

模型名忽略大小写并接受 `厂商/模型` 前缀。OpenRouter 使用统一的 `reasoning` 对象；Ollama 官方域名及本机 11434 端口使用其 OpenAI 兼容 `reasoning_effort`。其他端点按已识别模型的常见官方协议处理，界面会提示中转服务可能不同。

原生 Gemini Interactions 当前只对已确认的 Gemini 3 配置思考级别。Gemini 2.5 可通过 Google 的 OpenAI 兼容接口控制；不要向 Interactions 猜测发送 `thinking_budget`。

## 行为与边界

- 可切换模型关闭时发送真实的关闭参数，不再仅省略字段。
- 固定思考模型的开关显示为开启且不可点击；如支持强度，仍可调整。
- 只显示该型号接受的强度，不会把 `minimal` 发送给只接受 `low/medium/high` 的模型。
- 选择未知模型不会清除原先保存的思考偏好；识别信息和请求参数均以本次实际模型为准。
- 普通聊天、建议回复与 Agent 工具轮次共用协议转换。Agent 后续请求保留服务返回的 `reasoning_content` / `reasoning_details`，避免丢失必需状态；这些数据不作为台词或 TTS 文本。
- 不自动替用户改模型 ID，不通过提示词伪装模型硬件思考开关，不在参数被拒绝时重复执行工具。
- 不恢复此前取消的通用输出倍率限制。Claude 开启预算式思考时，按协议设置 `max_tokens = 思考预算 + 8192`，保证大于思考预算。
- 本次适配不新增 Anthropic Messages、OpenAI Responses 等端点。模型本身不支持当前聊天/工具接口时，单靠思考参数无法补足。
- MiMo 与 Hunyuan 的本机规则来自官方开源部署示例；云端未确认的协议、豆包 `ep-*` 部署 ID、其他自定义别名保持默认，不声称已兼容。

## 参考资料（2026-09-19 核对）

- [OpenAI 推理](https://developers.openai.com/api/docs/guides/reasoning)
- [GPT-5.1 支持的强度](https://developers.openai.com/api/docs/models/gpt-5.1)
- [DeepSeek Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode)
- [百炼深度思考](https://help.aliyun.com/zh/model-studio/deep-thinking)
- [GLM Thinking Mode](https://docs.z.ai/guides/capabilities/thinking-mode)
- [Kimi API](https://platform.moonshot.ai/docs/api/chat)
- [Gemini 思考](https://ai.google.dev/gemini-api/docs/thinking)、[OpenAI 兼容映射](https://ai.google.dev/gemini-api/docs/openai)
- [Claude OpenAI 兼容](https://platform.claude.com/docs/en/api/openai-sdk)
- [MiniMax OpenAI 兼容](https://platform.minimax.io/docs/api-reference/text-openai-api)
- [Grok 推理](https://docs.x.ai/docs/guides/reasoning)
- [OpenRouter](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)、[Ollama](https://docs.ollama.com/api/openai-compatibility)、[vLLM](https://docs.vllm.ai/en/latest/features/reasoning_outputs/)
- [MiMo V2 Flash](https://github.com/XiaomiMiMo/MiMo-V2-Flash)、[Hunyuan A13B](https://github.com/Tencent-Hunyuan/Hunyuan-A13B)

自动化测试覆盖请求字段、强制思考保护、未知型号、服务路由、设置持久化、Agent 状态回传与 Gemini 原生请求。它们验证代码生成的协议，不替代各提供商的真实联网验收。
