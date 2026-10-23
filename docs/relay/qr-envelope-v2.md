# 云同步配对二维码封装 v2

新生成的配对二维码默认使用本文的 v2 封装。手机在本地解密、验证并解析原有配对 JSON，再继续原有 HTTPS 校验、用户确认和配对请求。中继接口仍为 relay v1，不需要修改线上后端。

## 字节约定

二维码字符串为 `ryzasync:v2:` 加无 `=` 填充的 Base64URL。Base64URL 只使用 `A-Z`、`a-z`、`0-9`、`-`、`_`，不得包含空白、URL 转义、标准 Base64 的 `+` 或 `/`。

| 项目 | 固定约定 |
| --- | --- |
| 算法 | AES-256-GCM |
| 兼容密钥 | `SHA-256(UTF8("ryzasync/qr-envelope/v2/public-compat-key"))` 得到的原始 32 字节；不得把摘要的十六进制文本当成密钥 |
| nonce | 每次生成从系统安全随机源取得 12 字节 |
| AAD | `UTF8("ryzasync:v2:")`；必须包含最后一个冒号 |
| tag | 16 字节认证标签 |
| 二进制顺序 | `nonce || ciphertext || tag` |
| 明文 | 现有完整配对 JSON 的 UTF-8 字节，不修改内部 `type`、`v` 或后端字段 |

原 JSON 内部仍使用 `type: "agent-relay-pair"`、`v: 1`，完整包含原有 `server_base_url`、`pairing_id`、`pairing_secret`、`expires_at` 等字段。封装版本与中继协议版本分别管理；不能把内部 `v` 改成 `2`。服务器地址和一次性 secret 不得作为明文附加到二维码、URL、复制内容或二维码旁的展示文本。

固定 nonce 仅用于测试向量。正式生成即使明文相同，也必须重新取得安全随机 nonce，不能复用固定值、时间戳或计数器作为 nonce。

App 接受的明文上限为 4096 个 UTF-8 字节；v2 二进制总长上限为 4124 字节，包含前缀的二维码字符串上限为 5511 个字符。密文不能为空；解码后仅有 nonce 和 tag 的输入直接拒绝。Base64URL 必须是规范编码，不能用非零尾部填充位产生同字节的另一种写法。

## 解析和失败处理

手机扫码和粘贴配对数据使用同一解析入口：

1. `ryzasync:v2:` 输入先检查长度和严格 Base64URL 编码，再解码并检查 nonce、tag 和密文长度。
2. 使用上述固定 AAD 和兼容密钥完成 AES-GCM 验证；只有认证成功，才把明文按严格 UTF-8 解码并交给原 JSON 解析器。
3. 原解析器继续校验 `type`、`v`、UUID、64 位小写十六进制 secret、HTTPS origin 及所选中继地址；原有用户确认流程继续生效。
4. JSON 带 `expires_at` 时，本地拒绝格式无效或已过期时间。原有不带该字段的 v1 JSON 仍兼容，其二维码有效期由服务端 claim 校验；本地时钟检查不替代服务端期限和单次使用检查。
5. 带 v2 前缀但解密失败的输入直接拒绝，不能回退为明文。未知 `ryzasync:` 版本、畸形编码、过短/过大数据或错误 tag 同样直接拒绝。

旧的明文 relay v1 JSON 可继续扫码或粘贴。新封装失败时不请求网络、不生成或保存绑定，不把输入、解密内容或 secret 带入异常提示和日志；用户只收到二维码无效或不受支持的提示。

## 授权和开源限制

兼容密钥是明确公开的跨客户端常量。此功能仅让普通扫码或二维码解码软件直接读到密文，不能阻止知道约定的人解密；开源代码或客户端中提取密钥后即可还原二维码。不能将此功能描述为端到端加密、防逆向、真实服务凭证保护或阻止持码人攻击。

不要使用真实设备 token、服务器秘密或管理员 bootstrap 作为兼容密钥。今后需要更换兼容密钥时，新增封装版本，不能静默改变 v2 的派生规则。

二维码仍是短期单次配对凭证，不应截图外传或写入日志。二维码 TTL、1/3/7 天绑定期限、普通确认或直接绑定、能力授权、历史读取、撤销和公开 PC 登记均沿用 [relay v1 协议](relay-v1-contract.md)。云端继续接收解密后的原有 claim 正文，不接收或解密二维码封装。

## 互通验证边界

互通测试应使用虚构 HTTPS origin、固定 UUID/secret、明确的未来 `expires_at` 与仅测试使用的固定 nonce，跨 Node/Harness 与 Dart 比较完整明文及封装结果；另测试随机 nonce、篡改拒绝、编码/长度错误、未知版本和旧 v1 兼容。测试文件不能含真实配对凭证。

本地密码学与协议测试证明封装兼容及错误输入处理。真实双端验收还需升级后的 Harness 显示新二维码、App 扫码并取得现有服务的配对结果；二维码测试向量不能代替这一运行验证。

### 2026-10-23 源码验证

- `test/relay/fixtures/harness-qr-envelope-v2.json` 是 Harness 共享向量的原样副本，包含 ASCII、Unicode、旧 v1 和 9 类错误输入。
- `harness-random-qr-v2.json` 来自直接执行当前 Harness `encodePairingQrV2` TypeScript/WebCrypto 编码器：相同完整 JSON 连续生成 16 个不同 nonce 的封装，均通过 Dart 解码和字段验证。此测试不调用云端。
- `qr-envelope-v2.json` 由独立 Node `node:crypto` 实现生成；`node tool/relay/generate_qr_envelope_vectors.mjs --verify` 可复核固定向量与随机 nonce 生成。
- `flutter test --no-pub test/relay` 共 204 项通过，包含 75 项封装测试，以及 Android 扫码、Windows 粘贴、原授权与绑定流程回归。失败输入在 UI 测试中没有网络请求或绑定写入。

本次未重新打包、安装到设备、发布或修改线上服务器，未执行真实双端相机扫码和云端绑定验收。
