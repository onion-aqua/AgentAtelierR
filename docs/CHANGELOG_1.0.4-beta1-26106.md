# AgentAtelierR 1.0.4 beta1 26106

Android 版本：`1.0.4-beta1.26106+36`。`26106` 为本次展示版本标识，内部版本代码由 35 升至 36，支持覆盖已有 RC4 安装。GitHub 标签为 `v1.0.4-beta1.26106`，按测试版（Prerelease）发布。

## 本次更新

- 增加虚拟手机，角色状态、商店、服装、组合动作、存档及菜单功能统一在手机内显示完整页面，支持图标展开/缩回、分层返回、边缘手势和顶部下拉关闭。
- 手机桌面增加大时钟、地图位置与天气、信号/饱食度电量、灵动岛、存档运营商及三张内置壁纸。壁纸支持三列选择、导入和删除自定义图片；液态玻璃与明暗主题实时同步。
- 增加 NPC 信息与联系人：主聊天交换联系方式、NPC 同意后由用户确认添加；私信和记忆按 NPC、人物和存档隔离，主聊天可检索对应 NPC 的交流记录。
- 信息右上角增加语言设置，默认跟随莱莎或苏菲，也可单独指定回复与翻译语言。修复私信翻译依赖主聊天独立翻译开关的问题。
- 主聊天、NPC 回复和译文增加保守的语言检查，明确错语最多定向纠正一次；通过后再进入 TTS/表演规划，保留人名、旁白、角色和表演标签。辅助请求整体超时有界，旧存档的迟到结果不会串入新档。
- NPC 原始上下文增加完整回合的字符预算，避免仅限制 24 条时长回复使请求过大。主聊天延续历史裁剪与每 4 轮/累计 8 条的两层记忆整理，目前没有独立滚动摘要压缩。
- PC Agent 增加扫码配对、前台问题与审批、任务下发/取消、回执、事件去重与断线补拉；聊天 UI 支持历史侧栏、续聊和新建会话，并遵循共享协议扩展。
- 修复 PC 任务过期正文反复重试、UTC 时间精度与服务端格式校验不一致等问题；发送结果未明时保留同一个 action_id，收到 PC 回执后才显示接受结果。
- 修复近期 Tooltip/浮层语义、运行日志同步重入及重复错误刷屏问题，改进日志列表状态和持久化队列。
- 发送按钮长按切换普通输入与旁白/发言分栏，点按发送；调整商店商品价格并增加手机道具，商品图改为保留胶囊形灵动岛的动漫插画。

## 使用与限制

- NPC 信息使用已配置的主 LLM；未启用服务或网络失败时不会生成演示回复。语言校验不是完整的语义识别，短句及中日共用词可能无法确定。
- 角色聊天、私信和 PC 历史是分别管理的数据；私信不会自动执行背包、地图、任务或 PC 控制。
- PC 完整历史需桌面端支持 `session_history v1`，并由用户对绑定启用 `history_read`；自动测试不能代替真实桌面历史验收。
- 当前中继推送未启用。FCM 与推送 provider 接入结构已提供，实际项目配置、厂商 SDK 与后台/锁屏远程通知尚未完成真机验收。
- 苏菲完整立绘、原作媒体、人物加密资源、私有服务器地址与密钥继续留在本地；仅提交用户明确允许公开的手机 UI、壁纸和生成商品图。

## 构建与验证

使用资源加密脚本构建 release APK，启用 Dart 混淆与分离调试符号：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target apk -Mode release -Install -DeviceId a43d2d7a
```

附件名：`AgentAtelierR-1.0.4-beta1-26106-release.apk`。这是 release 运行模式的测试版，沿用现有 Android 调试签名以兼容覆盖安装，并非应用商店签名包。

本次验证结果：

- `flutter analyze --no-pub`：无问题。
- `flutter test --no-pub --reporter expanded`：879 项通过，10 项按现有资源/测试环境条件跳过，无失败。
- 通过 `tool/build_protected.ps1` 完成资源加密、release 构建、Dart 混淆与符号分离；APK 为 630,463,487 字节（约 601 MiB）。
- APK 的 `versionName=1.0.4-beta1.26106`、`versionCode=36`，签名验证通过；新版商店图、手机图标/壁纸与加密人物包存在。
- 已覆盖安装到 `a43d2d7a` 并成功启动；启动后进程存活，当前进程日志未发现致命异常、ANR 或未处理异常标记。
- 公开源码地址/凭证检查、相对代码依赖及 Android 安全存储备份排除规则复核通过。

APK SHA-256：`1cd4b804ac60b9dc242849afcca8c44965f736098a13560052f4b3f1cdbd0c86`。

在线模型语义、完整 PC 历史链路和远程推送不作为自动测试通过的结论；当前缺少的推送平台配置与实际验收范围见上述使用与限制。

相关说明：[虚拟手机](https://github.com/onion-aqua/AgentAtelierR/blob/v1.0.4-beta1.26106/docs/virtual_phone.md)、[NPC 信息](https://github.com/onion-aqua/AgentAtelierR/blob/v1.0.4-beta1.26106/docs/npc_messages.md)、[语言与上下文](https://github.com/onion-aqua/AgentAtelierR/blob/v1.0.4-beta1.26106/docs/chat_language_and_context.md)、[近期问题修复](https://github.com/onion-aqua/AgentAtelierR/blob/v1.0.4-beta1.26106/docs/bugfix_review_2026-10-06.md)、[PC 聊天与历史](https://github.com/onion-aqua/AgentAtelierR/blob/v1.0.4-beta1.26106/docs/relay/PC-Agent聊天与历史.md)。
