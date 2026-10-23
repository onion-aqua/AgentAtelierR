# Fish Audio MCP 接入与 StateError 诊断

本次加入了独立的 Fish Audio MCP TTS Provider。原有 Fish Audio REST、百炼、通用 OpenAI TTS、MiMo 和本地 CosyVoice 仍然保留；MCP 不会进入 LLM 请求链，也不会覆盖普通 API Key。

## 已实现

- 使用 `mcp_dart 2.4.3` 连接 `https://api.fish.audio/mcp` 的 Streamable HTTP。
- 新增 `Fish Audio MCP（OAuth）` TTS Provider，聊天和持续 ASMR 共用现有音频缓存、响度均衡、立体声和 Spine 播放流程。
- 使用 Fish Audio OAuth Authorization Code + PKCE（S256）。首次点击设置页的“登录并探测 tools/list”时才进行动态客户端注册和浏览器授权。
- OAuth access token、refresh token、有效期和客户端 ID 使用独立的安全存储命名空间；普通 API 服务导出不会包含这些内容。
- 启用 MCP 语音后，首帧显示完成、返回应用前台或切换到 MCP 时自动恢复已有授权；聊天、持续 ASMR、通话和试音也会在使用前检查连接。恢复不阻塞启动加载，不注册新客户端或弹出浏览器，授权失效时提示用户重新登录。
- 并发恢复共用一次连接和工具发现，同一连接的过期令牌刷新也会合并。手动断开或退出后，本次运行不自动重连；重新点击连接即可恢复。自动恢复只涉及授权、初始化和工具发现，不重发已提交的语音生成请求。
- 授权回调使用 `fishmcp://oauth/callback`。Android 已配置 intent-filter，Windows 使用 `app_links` 的同一自定义 scheme；Windows 启动时会在当前用户注册 `fishmcp` URL 协议。
- 授权后先执行 `tools/list`，保存工具名、描述和完整 input schema；未完成工具探测时，生成请求会被阻止。
- 按真实工具 schema 选择生成路径：“服务默认”使用 `text_to_speech`；明确模型优先使用完整的 Studio MCP 工具和项目 `default_backend`。Studio 不完整但普通工具真实声明模型字段时，才使用普通工具的该字段。不再改写 `additionalProperties` 或附带未声明的模型参数。
- 支持 MCP 返回的内嵌音频，以及 `https://*.fish.audio` 音频 URL；拒绝非 HTTPS 或非 Fish Audio 域名。
- MCP 连接失败不会自动删除现有 Fish REST 配置。设置页保留 MCP 失败回退开关字段，原有 Provider 可随时切回。
- MCP 模型提供下拉选择：`s2.1-pro`、`drama-3`，兼容已保存的自定义值；“服务默认”不指定模型。设置页显示当前草稿对应的实际生成路径及缺失的 Studio 工具。下拉选项不代表账号具有相应模型权益。
- 模型和音色修改先作为本页草稿，点击“保存并使用 MCP”后下次调用才生效；返回或取消不会自动保存。模型下方区分最近请求、Studio 已确认的后端配置及云端返回模型；配置读回不冒充实际推理模型证明。草稿与最近请求不同时会标明旧记录不能作为本次选择的结果。
- 普通音色与 ASMR 音色分别设置，莱莎未自定义时使用各自内置音色；持续 ASMR 始终使用 ASMR 音色。音色 ID 输入框不回显已保存值，留空保留当前配置，填写后保存可替换，也可恢复默认。科洛蒂娅固定音色已内置，MCP 模式下和主角共用当前 MCP 模型与连接，仅为真实台词生成语音。
- 莱莎普通模式使用新的内置音色；ASMR 在 `s2-pro`、`s2.1-pro`、`s2.1-pro-free` 下使用原专用 ASMR 音色，Drama 3 继续使用新的内置音色。按当前请求模型动态选择，兼容已保存的新旧内置值，其他自定义 ASMR 音色优先。聊天、持续 ASMR、设置试听和允许的 REST 回退采用同一规则。ASMR 使用整段耳语：兼容模式发送一次 `[whispering]`，Drama 3 转成覆盖整段的 `<whisper>…</whisper>`；呼吸与喘息标签继续清理。情感关闭仍保持耳语，标签密度关闭时不补发声标签。
- `s2-pro`、`s2.1-pro`、`s2.1-pro-free` 在最终发送前把耳语标签转换为一次更明确的自然语言描述，强调贴近麦克风、低声、清楚咬字和持续耳语；转换放在通用清洗之后，避免描述又被压缩成单词标签。REST 与 MCP Studio 共用这项适配，普通未标注的台词和已验证的 Drama 3 成对标签流程保持原有格式。S2 的自然语言控制效果仍需实际试听确认。
- MCP 设置增加共享语速控制，普通对话、持续 ASMR 和通话使用同一保存值。Android 新默认为 `0.90×`；旧 Fish 默认 `1.0×` 只迁移一次，其他已保存的自定义速度保留。Windows 和非 Fish 配置保留原缺省速度。
- 真实工具支持 `speed` / `prosody_speed` 时由服务处理；Studio 或工具未声明语速字段时，对已返回音频进行一次本地保音高节奏处理，不重复提交生成。口型、字幕和时长检查使用处理后的音频。Android 压缩音频复用系统解码；Windows 当前仅支持 WAV 的本地变速，其他编码需维持原速。实际语音听感仍需试听确认。

S2 标签依据：[Emotion Control](https://docs.fish.audio/developer-guide/core-features/emotions.md) 与 [Models Overview](https://docs.fish.audio/developer-guide/models-pricing/models-overview.md)。S2 使用方括号自由描述；圆括号属于旧版 S1。

## 2026-10-15 StateError 修复

旧实现把工具错误、未找到音频、下载失败等多种情况包装为 `StateError`，而回退日志只记录异常类型，导致真实原因丢失。现在保留错误的 `stage`、`code`、`message`、可用的 HTTP status 和 request ID，设置页可以复制脱敏诊断和完整工具 inputSchema。

- 优先选择真正的 `text_to_speech`，排除搜索、余额等说明中提到 TTS 的非生成工具；支持工具分页，重新发现失败时禁用旧工具。
- 语言随角色设置映射，模型与音色可直接配置。按用户要求取消本地必填项及枚举的拒绝校验，保留真实服务返回的错误，不会因 schema 未列模型而自动转入 REST。
- 解析 AudioContent、ResourceLink、EmbeddedResource、Markdown 链接、嵌套 JSON，以及数组或字符串形式的 structuredContent；按实际音频容器保存文件后缀。
- 下载不携带 OAuth 凭据，逐次验证 HTTPS 重定向，限制超时和文件大小。未知外部 CDN 明确报域名错误，不自动信任所有主机。
- 设置页实时反映异步 OAuth / 连接状态，断开后丢弃晚到结果；日志区分选择的 provider 与实际使用的 provider。
- REST 回退默认关闭，保留用户以前明确保存的开关值。开启时，仅在本地准备失败、尚未提交 MCP 生成时允许回退；回退沿用明确选择的 MCP 模型，只有选择“服务默认”时才使用原 API 模型。缺少 Studio 工具、Studio 流程失败、提交后结果未知、工具报错、下载或音频校验失败均不自动回退或再次生成。

已从设备 `a43d2d7a` 的已有日志确认：`MCP StateError → REST 回退 → POST /v1/tts → HTTP 402`。402 的 message 为 `Insufficient API credit. API credit is managed independently from platform credit.`，来自 REST。用户已说明模型设置用于测试回退，当前问题聚焦 MCP StateError。旧日志缺少 MCP 原始错误与实际 schema，不能追溯出那次失败的唯一原因，也不能据此认定 Plus 会员无权益、Team 不一致或 MCP 计费异常。

本地脱敏证据：`build/diagnostics/fish-mcp-readonly-20261015/evidence.redacted.json`。当前 Team、Workspace、余额和套餐权益尚未取得经过鉴权的实际查询结果。官方说明 MCP 使用套餐积分，和 developer API credit 区分；`get_credit_balance` 是免费查询工具，但本轮没有已授权的工具通道执行它，不能把公开文档当作本账号的查询结果。

诊断保存在应用临时目录 `fish_mcp_diagnostics.json`，包含工具 schema、参数名、文本字节数、结果类型及错误，不主动记录台词、Authorization、OAuth token 或签名 URL 的查询参数。`generation_submitted` 表示已提交生成，`outcome_unknown` 表示无法确定服务端执行结果，不能据此自动重试。

最初的源码诊断使用本地模拟 MCP 和 HTTP 客户端，未调用真实生成、未充值或自动重试；随后按用户要求用加密脚本构建 debug，并覆盖安装到测试机。本版 Android / Windows release 的构建、产物与验证结果见 [1.0.4.1 MCP FishAudio 更新说明](CHANGELOG_1.0.4.1_MCP_FishAudio.md)。模拟音频头用于容器校验，不代表真实播放、扣费或听感验证。仍需用户授权的真实生成诊断，才能确认历史 StateError 的具体触发点。

官方依据：[MCP 官方说明](https://docs.fish.audio/overview/mcp.md)、[官方插件工具用法](https://github.com/fishaudio/fish-audio-plugin/blob/71c656a183618db3d3b6dcd4947ed59d4dc30117/plugins/fish-audio/skills/fish-audio/SKILL.md)。完整 schema 以实际账号的 tools/list 为准。

## 首次接入时的公开端点探测

在未授权状态下对官方端点只做了初始化探测，没有注册客户端、调用 `tools/list` 或生成语音：

- `POST https://api.fish.audio/mcp` 返回 `401`，保护资源元数据为 `https://api.fish.audio/.well-known/oauth-protected-resource/mcp`。
- 授权服务器为 `https://api.fish.audio`，scope 为 `mcp`，支持 PKCE S256。
- 授权端点为 `https://fish.audio/oauth/authorize/`，token 端点为 `https://api.fish.audio/oauth/token`，动态注册端点为 `https://api.fish.audio/oauth/register`。
- Fish Audio API 有 `drama-3` 模型。客户端按用户要求允许 MCP 提交所选模型；后续取得的真实 MCP schema 没有模型选择字段，不能因此推定 REST 的模型切换能力同样适用于 MCP。
- 官方文档说明 MCP 语音生成使用账号套餐积分；端点初次探测时未登录账号，未核验当前账号套餐余额或实际扣费。

## 首次使用

1. 打开“设置 → TTS → Fish Audio MCP（OAuth）”。
2. 点击“登录并探测 tools/list”，在浏览器完成 Fish Audio 登录和授权。
3. 浏览器回调回应用后会自动连接，直到显示“工具已探测”。
4. 查看工具列表和生成路径。默认模型使用普通 TTS；明确模型优先使用完整的 Studio MCP 工具。Studio 工具不完整时，只有普通 TTS 真实声明模型字段才可继续使用该路径。
5. 选择模型和音色后，点击“保存并使用 MCP”；返回或取消会丢弃本页草稿。Studio 路径会在 Fish Audio 云端项目保存台词、音色配置及生成音频。缺少 Studio 工具时保留错误，不通过 REST 实现模型切换。

如果授权页面无法自动回到应用，请保留页面中的回调地址并重新打开应用后再次连接；当前 PKCE 状态只在本次进程内有效，进程被系统杀死后需要重新发起登录。

## 2026-10-16 模型选择排查与本轮更新

用户提供的日志显示：00:07 的调用因旧版客户端 schema 校验而回退 REST；00:30 和 00:31 的调用均选择 `drama-3`，`actualProvider` 为 Fish Audio MCP。后两次不能归因于 REST 回退。用户同时反馈 Fish Audio 网页生成记录仍显示 S2.1 Pro。

用户随后提供了实际 `text_to_speech` 的完整 inputSchema，已确认公开输入契约如下：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `text` | 是 | 要生成语音的文本。 |
| `voice_id` | 否 | 指定音色 ID。 |
| `language` | 否 | 仅在未指定 `voice_id` 时，用于选择默认音色。 |

`properties` 只有以上三个字段，`required` 只有 `text`，并明确声明 `additionalProperties: false`。其中没有 `model`、`model_id` 或其他模型切换字段。原先修改本地 `additionalProperties` 并透传模型不能修改服务端契约，已由下述 Studio MCP 路径替代。`language` 不能据此解释为切换已选音色的语言或更换生成模型。

用户随后提供了一条已成功执行的 Studio MCP 调用链及真实响应：将项目的 `default_backend` 设为 `drama-3`，读回项目确认后，再生成指定文本块。当前客户端按这份实际工具协议实现，继续使用同一个官方 MCP 地址和 OAuth 授权。

### 明确模型的 Studio MCP 流程

1. `studio_help` 读取当前工具用法。
2. `studio_create_project` 创建语音项目，写入 `roster`、`default_voice_id` 和空 `chapters`；从响应读取 `project_id` 和章节点 `anchor`。
3. 分两次 `studio_update_project`，先设置 `default_backend` 为所选模型，再将 `scene_preset` 设为 `off`，与用户验证成功的调用流程一致。
4. `studio_project` 读回并核对项目后端。兼容明确返回的 `scene_preset` 和 `scene.preset`；若摘要省略场景字段，则记录场景更新已被接受、查询未回传该值。每次复用项目重新核对；摘要未回传场景时，重新提交关闭场景设置。明确返回的配置冲突仍停止生成。
5. `studio_write_blocks` 使用 `append_to` 写入台词与真实音色 ID，从响应读取文本块 `anchor`。
6. `studio_generate` 先以 `dry_run: true` 查询估算，再生成明确的 `blocks`，从已完成结果读取 `audio_url`，进入现有音频播放链。

以上字段来自用户提供的成功调用证据，并结合当前 `tools/list` 的真实 schema 使用；没有另造 REST 请求或计费来源字段。进入 Studio 前同时检查工具名和所需参数声明，`studio_generate.dry_run` 必须明确为布尔类型，避免未识别的估费参数被忽略。模型枚举值交给服务校验。明确模型优先使用 Studio；工具或参数缺失时显示具体问题，只有普通工具真实声明模型字段才允许直接调用它，不向普通 TTS 填入未知参数。服务默认仍使用 `text_to_speech`，不会创建 Studio 项目。

Studio 会将台词、音色配置及生成结果保存到 Fish Audio 云端项目。普通音色、ASMR 音色及科洛蒂娅固定音色继续使用各自已有的 ID。`default_backend` 读回一致只证明项目配置保存成功；设置页单独显示“Studio 已确认后端配置”，不将其当作后台实际推理模型证明。

网页中的 `TTS 任务（IVC）` 与 `Studio MCP generation` 属于服务端记录来源。两种工具使用同一个 MCP 地址，不代表它们经过同一种生成链；来源显示为 Studio 也不能单独证明实际模型。实际采用模型仍以生成响应中明确的模型元数据和官方生成记录为准。

当前源码修复并增加以下诊断：

- 聊天及持续 ASMR 的授权回退保留明确选择的 MCP 模型，避免使用旧 API 模型；普通 API 模型设置独立保存。
- 设置页区分尚未保存的草稿与最近已提交的请求，展示最近请求模型、云端返回模型及状态。未返回模型标识时明确显示无法确认切换，不把下拉选择或音频生成成功当作模型已生效。
- 脱敏诊断区分 `requested_model`、`reported_model`、`model_selection_status` 和 Studio 已确认的后端配置；仍包含真实工具 inputSchema。云端返回标识只是响应证据，与请求一致也不等于独立验证了后台执行模型；不同标识可能存在别名，需结合官方说明或生成记录判断。
- 返回模型提取先在结构化结果、元数据、附加字段及 JSON 文本中查找明确的 `actual_model`、`used_model`，再查找普通的 `model`、`model_id`、`modelId`、`model_name`、`modelName`。明确的实际模型字段优先于外层普通模型回显；不会从自然语言、音色名称或请求参数对象猜测模型。
- 原始工具 schema 保持不变；普通 TTS 的模型字段缺失时选择 Studio 路径，不再通过本地 schema 扩展绕过服务契约。
- 并发请求按提交顺序归属最近的诊断，较早响应或失败不会覆盖较新的模型记录与日志。本地准备失败不抹掉上次已提交请求的证据；连接取消后的晚到结果也不能作为当前连接的模型结果。

设置页的调用状态包括暂无记录、请求中、请求失败、服务默认、Studio 后端配置已确认、云端未返回、返回一致及返回不一致。“Studio 后端配置已确认”只表示项目配置已读回；“返回一致”只说明响应元数据与请求相同；这些状态都不冒充独立的后台模型验收。

如需留存后续证据，请在 MCP 设置页展开相应工具，点击“复制工具与完整 inputSchema”；也可点击“复制连接 / 错误诊断（已脱敏）”。无需为收集 schema 重新生成语音。生成请求不因结果未知而自动重试。

此前版本完成完整测试 1376 项、跳过 61 项，Fish MCP 焦点测试 97 项及静态检查通过；这些历史结果不代表新增 Studio 流程已经在线验收。真实工具定义保存在 `test/fixtures/fish_mcp_text_to_speech_2026-10-16.json`，当前回归验证会覆盖未声明模型时的路径选择及配置证据展示。Studio 本地测试使用模拟响应，不消耗真实积分，也不代替真账号生成与试听。

本次 Studio 实现的相关测试共 **155 项全部通过**（包含 38 项 Studio 流程测试及聊天音色、持续 ASMR、设置等回归），完整 `flutter analyze --no-pub` 无问题。日志位于 `build/reports/fish-mcp-studio-tests-20261016.log` 和 `build/reports/fish-mcp-studio-analyze-20261016.log`。聊天和 ASMR 将调用方取消状态传入 MCP，预估期间停止后不会继续提交生成；项目、模型及音色按连接隔离，复用项目时重新核对云端配置。应用层不因生成错误或未知结果重新调用付费工具；MCP SDK 对服务端明确拒绝的过期会话可能有内部协议重发，不应将单次工具调用描述为 HTTP 绝对只发送一次。

首次 Studio 修改完成上述本地验证后，已经通过加密脚本构建并覆盖安装到 `a43d2d7a`。随后用户提供的实际错误与只读响应触发了下面的场景字段兼容修复；初次安装不代表该修复已交付。

### 场景字段省略的兼容修复

用户实际 `studio_project` 响应的顶层字段为 `project_id`、`name`、`default_backend`、`roster` 和 `chapters`；`default_backend` 明确为 `drama-3`，但没有 `scene_preset`。此前把场景字段省略当成配置不一致，错误抛出 `studio_backend_not_confirmed`。现在只有模型缺失/冲突、明确的场景冲突或场景更新失败才会阻止生成，不把省略字段解释为 `off`。

官方 Studio 前端也存在 `scene.preset` 的存储形式，参见[官方前端资源](https://fish.audio/assets/studio-next-page-CY05Voro.js)；本地只读摘录位于 `build/reports/fish-studio-scene-schema-evidence-20261016.json`。解析仅兼容有限的项目配置封装，不从角色列表、台词或任意用户内容中寻找确认值。

脱敏诊断新增 `studio_backend_readback`、`studio_scene_readback`、`studio_scene_status` 和响应顶层字段名。`accepted_unreported` 表示场景更新请求成功，但项目摘要未返回场景字段；`confirmed` 才表示返回的场景字段明确为 `off`。这些信息不包含完整项目正文或 OAuth 凭据。

此修复相关测试共 **205 项全部通过**，其中 Studio 流程测试 88 项；完整静态检查无问题。测试保留模型不匹配、场景明确冲突、场景更新失败、预估后取消及未知结果不重复生成的门禁。日志为 `build/reports/fish-mcp-studio-scene-tests-20261016.log` 和 `build/reports/fish-mcp-studio-scene-analyze-20261016.log`。验证使用用户返回结构的本地夹具，未发起真实语音生成。

场景兼容修复已通过 `tool/build_protected.ps1 -Target apk -Mode release -Offline -DeviceId a43d2d7a -Install` 加密构建并覆盖安装。已核对新 APK 中的修复代码、14 个加密资源及设备安装包 SHA-256；结果见 `build/reports/fish-mcp-studio-scene-installed-20261016.json`。版本保持 `1.0.4.1` / `45`，没有自动发起真实合成或试听。

### 生成结果状态兼容与只读补查

用户后续报错为 `stage=studio_result / studio_not_completed`，说明请求已越过项目配置检查并提交生成。原实现强制要求生成结果根级 `status: done`，会拒绝根状态缺失、但本次文本块已返回音频的结果。本轮尚未取得失败那次的原始云端返回，因此不能确定那次是字段省略、等待完成还是其他返回结构。

现在按本次新建文本块解析结果：根状态可省略，明确的失败、取消、运行状态或 `changed/dirty: true` 不会被音频链接掩盖。支持有限的 `result/data/structuredContent` 包裹；筛选准确匹配的目标 `anchor`，拒绝项目冲突、重复目标和冲突音频。初次生成只请求一个块，其唯一结果允许省略 anchor；章节读回必须明确匹配目标 anchor。播放器仅接收已筛选的目标音频，不从原始响应的其他块、根链接或 Markdown 中另选音频。

结果尚未就绪时，仅在本次 `tools/list` 明确提供兼容的 `studio_read_blocks(project_id, chapter)` 时只读补查；最多 10 次，约 45 秒查询期限，支持取消和断连。只读结果兼容 `blocks/results` 列表与目标块 `data.audio_url`。这个查询工具及参数来自用户此前实际调用证据；块数据格式的兼容参考官方前端并以本地夹具验证，仍待该账号真实 MCP 返回确认。缺失工具、超时或结果仍未知时停止，不重调 `studio_generate`、不追加估费调用、不回退 REST。不会为排查而自动发起新的付费语音生成。

脱敏诊断与运行日志现在在结果校验前保存字段名、已知状态、块数、目标是否匹配、有无音频和只读查询次数。不记录台词、完整音频链接、凭据或完整响应；未知状态值只标记为未识别，避免把任意返回正文写入日志。即使解析失败，这些信息也能用于下一步定位。

本轮相关测试 **251 项全部通过**，包括 46 项独立结果解析与只读补查测试，完整 `flutter analyze --no-pub` 无问题。测试日志为 `build/reports/fish-mcp-studio-result-tests-20261016.log`，静态检查日志为 `build/reports/fish-mcp-studio-result-analyze-20261016.log`。这些是本地模拟验证，不代表真实账号已经合成成功或后台实际使用了指定模型。

结果兼容修复已通过受保护脚本构建并覆盖安装到 `a43d2d7a`，版本仍为 `1.0.4.1` / `45`。设备包与本地 APK 的 SHA-256 均为 `561cb0aac377e88327c07899e0a1a13bf5d28bba24602e52e9ca97eca32d10ca`，14 个加密资源头及三种 ABI 的本轮修复标记均通过核验；记录为 `build/reports/fish-mcp-studio-result-installed-20261016.json`。未启动应用、未自动调用真实生成或试听。

## Windows OAuth 回调与打包

Windows 与 Android 使用同一份 MCP 服务、Studio 模型配置、诊断和聊天/ASMR 代码。Windows 启动时为当前用户注册 `fishmcp` 协议，命令中的 EXE 路径和回调参数均带引号，支持包含空格的安装目录。请先把完整 Windows 包解压到固定目录，再运行其中的 `AgentAtelierR.exe`，不要仅复制 EXE 或从压缩包临时目录打开。

浏览器完成授权后，Windows 会用 URL 协议启动应用进程。入口现在先调用 `app_links 7.2.2` 官方的 `SendAppLinkToInstance()`，把链接转交给已运行的同一路径应用并结束临时进程；原应用的 `AppLinks().uriLinkStream` 接收回调，使用原进程内保存的 PKCE state/verifier 完成交换。此前只有协议注册而没有转交逻辑，回调会进入不持有 PKCE 状态的新进程并被拒绝。

此修复已按本地 SDK 的公开头文件、插件实现和 Windows 示例进行静态核对。未启动应用或浏览器、未进行真实 Windows OAuth 授权；原进程退出、不同路径版本同时运行或应用以管理员权限运行时的浏览器回调仍需实际验证。PKCE 状态不跨进程持久化，授权期间应保持原应用运行并使用普通用户权限。

Windows 发布包需要包含完整 Release 目录及生成的插件和 `data` 资源，包括 `app_links`、`url_launcher_windows`、`flutter_secure_storage_windows`、音频和 Spine 运行库。是否成功编译和包含这些文件以对应发布产物检查为准；插件已列入生成的 CMake 注册列表，不代表旧的 Release 目录已经更新。

## 尚未验证

- 已取得用户提供的真实 `text_to_speech` inputSchema 和成功的 Studio 调用证据；新增客户端 Studio 流程仍需真实账号生成、计费来源及试听验收。本地模拟测试不能代替在线验收。
- 本轮开发没有发起真实语音生成，没有新增积分消耗或声线效果结论。后端配置确认和网页来源名不等于实际推理模型证明，各模型的真实权益由服务校验。
- 早先 StateError 修复后的加密 Android debug 已覆盖安装，上一轮也有两端 release；这些旧产物不代表本轮模型诊断修复已交付。新构建状态见发布说明，包体检查也不能代替真实云端模型、Windows OAuth 或试听验收。

## 回滚

本次改动前的本地存档为标签 `backup/pre-fish-audio-mcp-20261015`，对应 bundle：

`build/archives/pre-fish-audio-mcp-20261015/ryza_chat_mvp.git.bundle`

StateError 修复前另有本地标签 `backup/pre-fish-mcp-stateerror-20261015`。

回滚前请先保存当前工作区，并使用该标签或 bundle 恢复。不要删除用户已有的 `docs/user_manual_2026-10-08/` 和 `evidence/` 未跟踪目录。
