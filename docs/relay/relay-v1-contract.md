# PC / 手机共享联动协议 v1

本文件是两项实施任务共同采用的实现契约，不代表后端已经部署。dshagalt 任务负责云服务与 PC；ryza_chat_mvp 任务负责手机。优先完成扫码、前台问答、任务控制和可靠同步，再使用真实配置接入后台推送。

此公开副本已移除私人部署地址，以 `RELAY_HOST` 占位；协议字段、接口路径、事件名与行为约定保持原样。实际地址由部署任务验证后通过仓库外配置交付。

## 基本约定

- UTF-8 JSON，字段为 snake_case，标识使用 UUID；时间为 UTC ISO 8601。
- `server_base_url` 为实际可验证 TLS 的 HTTPS origin，无路径、无用户名密码、无 query。服务位置在公开副本中脱敏为 `RELAY_HOST`，正式域名或 IP 证书由部署任务验证后交付。
- REST 路径前缀 `/v1`，WebSocket 路径 `/v1/ws`，WSS 地址由 HTTPS origin 转换。
- 已登记的设备使用 `Authorization: Bearer <device_token>`，包括原生客户端的 WSS 握手；不把长期 token 放 URL。
- 每设备 token 使用安全随机 32 字节编码为无填充 base64url。客户端先安全保存，服务端存 `SHA256(UTF8(device_token))` 的小写 hex 摘要；不保存或记录长期 token 明文。
- 服务端根据凭证决定 device_id、角色、绑定与 capability，不能信任请求正文中的身份声明。个人单用户服务使用受保护的 bootstrap 登记，不引入不必要的公开账号系统。
- 第一版鉴权与消息传输使用 TLS，服务器可见正文；鉴权 token 不是端到端加密密钥。

## 配对

二维码为直接编码下列 JSON 的 UTF-8 字符串；示例内容都是占位值：

```json
{
  "type": "agent-relay-pair",
  "v": 1,
  "server_base_url": "https://YOUR_VERIFIED_HOST",
  "pairing_id": "UUID",
  "pairing_secret": "64_LOWERCASE_HEX_CHARACTERS"
}
```

PC 安全随机生成 32 字节 pairing_secret 并编码为 64 个 hex 字符。服务端只存 `SHA256(UTF8(pairing_secret))`。默认 TTL 300 秒，单次 claim 使用数据库原子事务，失败配对不会激活任何设备。

接口如下；device_id/token 均由客户端安全生成，避免确认后发放凭证时丢包导致客户端丢失身份：

| 方法与路径 | 权限及含义 |
| --- | --- |
| `GET /health` | 最小无敏感信息健康检查 |
| `POST /v1/devices/enroll` | 管理员 bootstrap 鉴权；登记 PC，正文 `{device_id, device_name, device_token_hash}` |
| `POST /v1/pairings` | 已登记 PC；正文 `{pairing_secret_hash, ttl_seconds:300}`；返回 `{pairing_id, expires_at}` |
| `POST /v1/pairings/claim` | 一次性配对；正文 `{pairing_id, pairing_secret, device_id, device_name, device_token_hash}`；返回 `{pairing_id, state:"pending_confirmation", expires_at}` |
| `GET /v1/pairings/{pairing_id}/status` | 对应 PC 或该 pending 手机 token；返回 `{state, pc_id, device_id, expires_at, capabilities}`，未确定字段可为 null |
| `POST /v1/pairings/{pairing_id}/confirm` | 对应 PC；正文 `{decision:"approve",capabilities?:["question.answer","approval.respond","task.start","task.cancel"]}` 或 `{decision:"reject"}`；capabilities 可选，省略默认四项，只接受白名单子集 |
| `GET /v1/devices` | 当前凭证能管理/访问的设备及绑定 |
| `DELETE /v1/devices/{device_id}` | 手机仅能撤销自身；PC 能撤销绑定手机；立即拒绝该设备后续请求 |

手机提交 claim 前先在安全存储中保存 server_base_url、pairing_id、device_id/token，支持进程重启后恢复配对状态查询；短期 pairing_secret 不持久保存。claim 创建的 pending 身份仅允许查询自身配对状态；PC 确认后才允许事件连接及业务操作。

状态为 pending_confirmation、confirmed、rejected、expired。rejected/expired 的 token 摘要和配对终态记录保留 24 小时，仅允许原手机查询自身终态；之后清理并返回 PAIRING_NOT_FOUND。手机读取拒绝/过期终态后清理该配对本地凭证，不能将此 pending token 用于其他接口。

device_id 不得覆盖：enroll 遇到已有 device_id 返回 DEVICE_EXISTS；claim 仅同一 pairing_id + device_id + device_token_hash 可幂等重试，其他冲突返回 DEVICE_EXISTS。v1 每个 mobile device_id 绑定一个 PC；手机要管理多个 PC 时，为每个绑定维护独立 profile 和安全凭证，不能覆盖之前的绑定。

如果 claim 请求丢失响应，同一 pairing_id + device_id + device_token_hash 重试必须返回同一结果，不能创建第二个身份；其他身份重复兑换返回 PAIRING_USED。同一 pending 设备用自身 token 查状态时不能读取其他人的配对。

PC 明确批准，默认手机 capability 为 `question.answer`、`approval.respond`、`task.start`、`task.cancel`，可在 PC 管理界面收紧权限。审批仍受 PC 原有执行规则约束。 `confirm` 的可选 `capabilities` 在首次确认时指定所授予的白名单子集（可为空）；已 confirmed 的配对可重复发送 `{decision:"approve",capabilities:[...]}`，但只能收紧已有权限，不能重新授予或增加权限。confirmed 配对记录持续保留以支持权限管理；扩权需重新配对。

## 事件与可靠传输

服务器持久化每设备收件队列，并分配该设备队列单调递增的 seq。event_id 在重发、WSS、补拉及推送中保持一致。

```json
{
  "event_id": "UUID",
  "seq": 123,
  "source_event_id": "UUID",
  "type": "question.created",
  "pc_id": "UUID",
  "session_id": "SESSION_ID",
  "request_id": "REQUEST_ID",
  "created_at": "2026-10-04T15:00:00Z",
  "expires_at": "2026-10-04T15:05:00Z",
  "payload": {}
}
```

允许的业务事件为：

- `question.created` / `question.updated`
- `approval.created` / `approval.updated`
- `task.updated`：status 为 queued、running、succeeded、failed、cancelled 或 unknown。
- `pc.state.updated`：PC 发布有权限供手机选择的工作区及会话摘要，更新服务器状态快照。
- `action.request`：服务端转给目标 PC 的已鉴权操作。
- `action.result`：PC 的实际接受/拒绝/冲突/过期结果。
- `pairing.updated`、`device.revoked`。

question.created 的 payload：`{title, body, input:{kind:"text|single_choice|multi_choice", options:[{id,label}], allow_text:boolean}, state:"pending"}`。answer 使用 option ID，不用展示文本作为标识。

approval.created 的 payload：`{title, description, operation_summary, allowed_decisions:["approve","reject"], state:"pending"}`。完整操作详情依据现有审批机制转换，摘要不能代替 PC 实际执行校验。

question/approval updated 的 payload 必须有 state：pending、resolved、cancelled、expired；可带 resolved_by_device_id 和 resolution。手机不自动把过期回答转换为新任务。

| 方法与路径 | 含义 |
| --- | --- |
| `POST /v1/events` | PC 发布允许事件；正文含稳定 source_event_id，服务端按 PC + source_event_id 去重，分配 event_id/seq |
| `GET /v1/events?after_seq=N&limit=100` | 仅当前设备队列；返回 `{events, next_seq, has_more}` |
| `POST /v1/events/ack` | 正文 `{seq:N}`，确认已持久化的连续游标 |
| `GET /v1/events/{event_id}` | 读取有权限访问的单个真实事件，包括推送点击后的正文获取；返回 `{event:EventEnvelope}` |
| `GET /v1/requests?state=pending` | 当前设备有权限访问的待处理提问和审批 |

WSS 连接后客户端发 `{v:1,type:"resume",after_seq:N}`；服务端发 `{v:1,type:"event",event:{...}}`；客户端先持久化再发 `{v:1,type:"ack",seq:N}`。JSON ping/pong 用于心跳，重连带最后连续游标并补拉。处理分页、重复与断档，不能确认超过未落盘事件的游标。

ACK 只说明收到事件，不表示 Agent 已执行。实现至少一次传输和稳定 ID 去重，保留消息至明确的保留期限；游标超出保留期时返回 CURSOR_EXPIRED，并提供待办/任务状态快照重新同步。

`GET /v1/state` 返回当前设备权限范围内的一致性快照：`{snapshot_seq, devices, workspaces, sessions, requests, tasks, actions}`。snapshot_seq 与这些集合在同一数据库读事务中取得。客户端发生 CURSOR_EXPIRED 时，获取快照、持久化状态及 snapshot_seq，再从 after_seq=snapshot_seq 恢复，不能仅清空游标漏掉当前待办。

列表和快照采用以下稳定结构：

- `GET /v1/devices` 返回 `{devices:[DeviceSummary]}`。DeviceSummary 为 `{device_id, role:"pc|mobile", device_name, pc_id, connection_state:"online|offline", capabilities}`；PC 自身 pc_id=其 device_id。
- WorkspaceSummary 为 `{workspace_id, pc_id, label}`，不向手机提供任意本地路径。由 PC 映射真实、已授权工作区。
- SessionSummary 为 `{session_id, pc_id, workspace_id, title, status:"idle|running|unknown", updated_at}`。
- `GET /v1/requests` 返回 `{requests:[RequestSummary]}`。RequestSummary 为 `{request_id, pc_id, session_id, kind:"question|approval", state, created_at, expires_at, payload}`；payload 与 created/updated 事件同义。
- TaskSummary 及 task.updated.payload 为 `{task_id, status, summary, error, updated_at}`；事件 envelope 带 pc_id/session_id。task_id 为稳定任务/turn 标识，不能只把会话 ID 当成每一次任务 ID。
- `pc.state.updated.payload` 为 `{workspaces:[WorkspaceSummary], sessions:[SessionSummary]}`，PC 初始化及变更后发布。服务器从真实 task/request 事件维护相应快照，不凭空造状态。

列表只返回有权限的内容；状态快照不得夹带其他设备的 token、配置或完整本地路径。

## 手机动作

`POST /v1/actions`：

```json
{
  "action_id": "UUID_GENERATED_ONCE_PER_USER_ACTION",
  "type": "question.answer",
  "target_pc_id": "UUID",
  "session_id": "SESSION_ID",
  "request_id": "REQUEST_ID",
  "expires_at": "2026-10-04T15:05:00Z",
  "payload": {"selected_option_ids": [], "text": "用户回答"}
}
```

- `question.answer`：payload 为 `{selected_option_ids, text}`，必须关联原问题。
- `approval.respond`：payload 为 `{decision:"approve|reject"}`，必须关联原审批。
- `task.start`：payload 为 `{prompt, workspace_id}`；session_id 可为空表示新建，此时 workspace_id 必填且来自已授权 WorkspaceSummary。已有会话的 workspace_id 可省略，若提供则必须与会话匹配。request_id=null。
- `task.cancel`：session_id 必填，payload 为 `{task_id}`，目标任务必须属于该会话且当前凭证有取消权限。request_id=null。

客户端重试必须使用同一 action_id 和同一内容。服务端对当前设备 + action_id 原子去重；同键不同内容返回 IDEMPOTENCY_CONFLICT。服务端自行验证期限，客户端不能延长 PC 原请求期限。

HTTP 202 返回 `{action_id,status:"queued"}`，只表示已接收。`GET /v1/actions/{action_id}` 与 action.result 返回当前状态，状态为 queued、delivered、accepted、rejected、expired、conflict 或 unknown。

`action.request.payload` 固定为 `{action_id, origin_device_id, action_type, target_pc_id, session_id, request_id, expires_at, args}`：action_type 为手机动作 type，args 为原 payload；origin_device_id 由服务器从真实认证结果填写，不能从手机正文照抄。envelope 的 pc_id 为目标 PC。

PC 通过 `POST /v1/events` 发布 action.result，payload 固定为 `{action_id, status, session_id, task_id, request_id, error, updated_at}`；error 为 null 或 `{code,message,retryable}`，尚无值的 ID 为 null。status 由 PC 返回 accepted/rejected/expired/conflict/unknown。accepted 表示 Agent 已接受该操作，任务后续完成由 task.updated 表达。

服务器仅接受该动作 target_pc_id 对应 PC 的回执，在同一事务中持久化 action 状态并投递给原手机；重复 source_event_id 不重复结算。新任务 accepted 必须给出真实 session_id/task_id，供手机后续定位和取消。PC 本地问题已处理时同步对应 question/approval.updated，再对晚到手机动作返回 conflict 或 expired。

ActionSummary 为 `{action_id, action_type, target_pc_id, session_id, task_id, request_id, status, error, updated_at}`。`GET /v1/actions/{action_id}` 返回 `{action:ActionSummary}`，快照 actions 使用同一结构；只允许发起设备及目标 PC 读取。

目标 PC 的 ActionSummary 可含向后兼容的可选 `request`，其结构与 `action.request.payload` 完全相同：`{action_id,origin_device_id,action_type,target_pc_id,session_id,request_id,expires_at,args}`。该字段只在对应 target PC 的鉴权快照及动作查询中返回；原手机及其他设备不获得 `request`。PC 游标过期后可据此恢复未执行动作，并重新核对设备权限、原请求及期限，使用持久 action_id 对账，不能盲目重跑已经执行或 unknown 的任务。

服务端负责权限与排队；PC 的统一请求结算器决定本地请求是否仍可接受。PC 与手机并发时只能处理一次。PC 也要持久化动作去重和实际会话映射，发生执行不确定时先对账，不保证任意底层工具副作用能严格执行一次，也不盲目重跑。

## 后台推送

`POST /v1/push/subscriptions`：手机鉴权，正文 `{provider, registration_token}`；`DELETE /v1/push/subscriptions/{subscription_id}` 注销。

推送至少提供 `{event_id, pc_id, kind}`，可含通用提示，但不携带设备 token、二维码密钥或完整敏感问题。手机鉴权读取对应事件/待办，通知点击定位，再与 WSS 和补拉去重。

provider 为可替换适配器，双方必须使用同一实际渠道配置。推送平台参数尚未提供，不能把 mock provider 或本地通知标记为真实后台推送成功。

## 错误与部署交付

统一错误体 `{error:{code,message,retryable}}`。至少包括 UNAUTHORIZED、DEVICE_REVOKED、FORBIDDEN、DEVICE_EXISTS、PAIRING_EXPIRED、PAIRING_USED、PAIRING_NOT_FOUND、PC_OFFLINE、REQUEST_EXPIRED、REQUEST_RESOLVED、IDEMPOTENCY_CONFLICT、CURSOR_EXPIRED、RATE_LIMITED。message 不能包含密钥或完整内部堆栈。

部署任务交付 server_base_url、协议版本 v1、启用 capability、真实 push provider 状态及客户端配置说明。token、Authorization、配对 secret、推送 token 从日志中脱敏；待机服务进程重启后仍能恢复设备和消息状态。

## 真实会话历史扩展（session_history v1）

本扩展保持协议 v1、四项操作白名单及原有路径不变。缺少本节的可选字段表示旧实现不支持历史，不得使用任务摘要生成聊天正文。手机先查询能力，再获取真实正文；新建与续聊仍使用 `task.start`，HTTP 202 仍不是 Agent 接受或生成回复。

### 授权与能力发现

`DeviceSummary` 和配对状态增加可选 `history_read:boolean`，缺省为 false。`confirm` 增加可选 `history_read:boolean`，首次确认省略时不授予；已 confirmed 的配对可以由该 PC 显式设置此独立读取权限，原四项操作 capability 仍只能收紧。历史读取不成为第五项远程动作，也不授予任何内部 RPC。PC 管理界面提供独立历史权限开关；服务器在每次历史读取、事件补拉及订阅发送时重新检查当前绑定和读取权限。

PC 的 `pc.state.updated.payload` 可增加 `features:{session_history:{version:1}}`。授权范围仍是该 PC 发布的完整 `workspaces` / `sessions`，只能包含 PC 本地明确授权的真实工作区和会话。`SessionSummary` 可增加 `history_state:"syncing|ready|unavailable"`、`history_revision:number`；缺省字段不承诺正文已就绪。标题来自真实会话标题或用户正文的首行，不包含机器生成的本地路径。

`GET /v1/features` 要求 active 设备鉴权，返回 `{protocol_version:1,pc_id,connection_state,features:{session_history:{version:1,supported:boolean,permission:boolean,state:"unsupported|forbidden|syncing|ready"}}}`。`permission` 对手机要求 confirmed 绑定的 `history_read=true`；PC 可以查询自身。`supported` 取决于 PC 是否发布上述 feature。离线不等于不支持，`connection_state` 明确为 online/offline。所有字段均由认证及真实同步状态得出，不信任手机提供的 pc_id。

### 手机读取

| 方法与路径 | 响应及语义 |
| --- | --- |
| `GET /v1/sessions?limit=50&cursor=...&workspace_id=...&pc_id=...` | 返回 `{pc_id,connection_state,snapshot_seq,sessions,next_cursor,has_more}`；按 updated_at 降序、session_id 升序，最多 100 条；workspace_id/pc_id 可省略，提供时必须属于当前绑定及授权范围 |
| `GET /v1/sessions/{session_id}/messages?limit=50&cursor=...&revision=...&pc_id=...` | 返回 `{pc_id,session_id,workspace_id,connection_state,snapshot_seq,history_revision,sync_state:"ready|syncing",messages,next_cursor,has_more}`；消息按 ordinal 升序、part_index 升序，最多 100 条传输片段；revision 可省略，存在时必须等于当前可读 revision |

`next_cursor` 为不透明字符串或 null，绑定设备、PC、筛选条件及版本，客户端不得自行计算。历史分页发生版本变化返回 `HISTORY_CHANGED`（409，retryable=true），手机清理该次分页结果后重取第一页，不能拼接不同版本。`snapshot_seq` 是当前设备事件队列水位；读取历史不会确认 ACK 或代替 `/v1/state` 的一致性快照。列表未同步可以合法为空；正文尚无已完成快照时返回 `HISTORY_NOT_READY`（409，retryable=true），不返回假正文。不支持返回 `HISTORY_UNSUPPORTED`（409，retryable=false）；无读取权限或跨 PC/工作区/会话返回 FORBIDDEN，已撤销设备仍使用 DEVICE_REVOKED。

每条 `messages` 记录为 `{message_id,role:"user|assistant",body,created_at,updated_at,ordinal,status:"queued|streaming|completed|cancelled|failed",part_index,part_count}`。message_id 使用桌面真实消息 ID，跨重连、同步及编辑稳定；ordinal 是该会话的稳定显示顺序整数。body 是真实可见文本，不含思考、system/developer 指令、工具调用及结果、配置、凭证字段或附件本地路径元数据。用户自己输入的正文按原文保留，不能声称自动识别正文中的所有秘密。每个 body 片段最多 8192 个 UTF-16 code units，不能切断代理对；part_index 从 0 开始，part_count 至少为 1。手机按同一 revision + message_id 收齐所有片段后拼接完整正文，不能将片段显示为多条消息或把未收齐内容声称为完整历史。

queued 仅表示真实尚未进入模型请求的用户队列项；streaming 是真实 assistant 可见文本的临时投影，完成后由持久日志正文覆盖；不得将隐藏推理转为正文。取消和失败可以保留真实已显示的部分文本，分别标 cancelled/failed；没有正文的失败/取消不生成虚构消息，任务状态由原 task.updated 负责。PC 编辑队列正文时沿用消息 ID 并改变 revision，移除队列项、删除会话或失去授权时移除对应消息或整个会话。快照替换表示完整当前可见聊天，不能只追加造成已删除消息复活。仅模型上下文压缩不应删除用户看过的历史正文。

兼容现有 Desktop 的 assistant 消息 ID 在持久结算时才产生，streaming 记录可以增加可选 `provisional:true`，message_id 为该真实流 attempt 在当前生命周期唯一且固定的临时 ID。持久结算后记录改用真实 message_id，并可增加 `replaces_message_id` 指向该临时 ID，手机据此保留显示位置；完整新快照中临时项必须消失。provisional 缺省为 false，临时 ID 不用于编辑、续聊或取消动作，也不能跨 PC 重启认为仍在生成。流 end 的已提交 seq 关联真实持久消息；重启只恢复真实日志记录及明确标记的未完成状态，不能将临时输出改为 completed。

已就绪缓存可以在 PC 离线时读取，connection_state=offline；不得暗示缓存实时。完成快照及其 revision 在中继重启后保留，半成品快照不会替代完整缓存。PC 重启根据真实持久日志重新对账，不能把已丢失的临时 streaming 状态当作已完成回答。

### PC 上传与增量通知

PC 通过原 `POST /v1/events` 的持久 outbox 发布新增 `session.history.page`，该事件只作为鉴权上传，不向手机转发正文。envelope.session_id 必填，request_id/expires_at 为 null，payload 为 `{workspace_id,history_revision,snapshot_id,page_index,is_last,messages}`。snapshot_id 为稳定 UUID，同一次快照重试使用相同 snapshot_id、revision、source_event_id 和内容；page_index 从 0 连续递增，messages 使用上述传输片段结构，单次完整 UTF-8 JSON 请求不超过 128 KiB。revision 是 PC 针对该会话持久单调递增的正整数，正文、状态、编辑或删除发生变化才分配新版本。messages 可为空，空会话仍通过最后一页提交。

服务端只接受真实认证 PC 自己当前授权的 session/workspace，严格验证片段完整性、顺序、页连续性及版本。所有页暂存，最后一页在事务中激活完整快照并替换该会话全部旧消息；半成品不对手机可见。更旧 revision 不可覆盖新版本，同 revision 不同内容返回 IDEMPOTENCY_CONFLICT。ACK/HTTP 成功仅代表相应页持久化，不声称整段历史已可读；只有最后一页原子提交成功才算快照完成。

完整快照提交后，服务端向有 history_read 权限的绑定设备发布 `session.history.updated`，envelope 带 pc_id/session_id，payload 为 `{workspace_id,history_revision,history_state:"ready",updated_at}`，不携带正文。实时回复按同一稳定消息 ID 的新 revision 发布更新；手机收到通知后分页重取。首次授权、离线恢复、事件游标过期时手机通过能力发现及上述列表/正文 API 获取当前状态，不能只依赖通知。

PC state 移除会话/工作区时，中继同事务清理该范围的正文及未完成上传并阻止迟到页恢复；手机收到 pc.state.updated 后删除失去授权的本地历史缓存。撤销读取权限时 DeviceSummary.history_read=false，手机立即清理历史缓存并停止读取。服务端不会让旧事件、快照、请求或任务接口绕过当前会话授权范围。

撤权仍保留该会话版本高水位，重新授权同会话时 PC 分配更高 revision 并重新观察真实日志，旧快照或已确认上传页不能恢复正文。新快照上传中如果存在旧完整缓存，messages 返回旧缓存的 history_revision 和 sync_state=syncing；如果没有完整缓存则 HISTORY_NOT_READY。分页版本比较始终使用实际可读快照。旧 PC 从未发布 scope 时，原 v1 问题/任务读取保持原绑定语义，但历史必须有明确授权的 pc.state，空 scope 表示已撤销全部会话。

为了维持原每设备连续 seq，已入队事件在读取/订阅时失去权限，则用同 event_id/seq 的 `scope.redacted` 替代，保留 source_event_id、pc_id、created_at，session_id/request_id/expires_at 为 null，payload 仅 `{reason:"scope_removed"}`。正文、标题和原事件类型不返回；客户端按普通无业务内容事件持久化及 ACK。这个兼容事件也用于隐藏已撤销 history_read 权限的历史通知，不能因过滤跳过 seq 而令旧 v1 客户端永久断档。

scope.redacted 是当前读取权限下的投影，允许同一 event_id/seq 之前已缓存的正文被删除替换；手机不得当作重复事件内容冲突而保留旧正文，应优先执行 scope 与 history_read 撤销清理。已声明 scope 的快照及补拉只能返回仍授权的内容，不能靠此前接收的事件保留失权正文。
