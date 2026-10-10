# AgentAtelierR 1.0.4 正式版

Android / Windows 版本：`1.0.4+40`。GitHub 标签：`v1.0.4`。2026-10-11 覆盖更新同一正式版 Release 的 Android APK 与 Windows ZIP。

## 本次更新

- 修复场景 NPC 明确同意交换联系方式后，虚拟手机信息页仍没有联系人的问题。兼容赛莉的“ええ、交換しましょう”“SMSでも構わないわ”及卡菈的“よいぞ、交換してやろう”等日语表达。
- 紧接上一轮完整回复的联系请求时，可用“或者 SMS 也行”“那换成 QQ 吧”沿用同一 NPC 目标。仍需本人在新回复中同意，并由用户点击“加入信息”确认；取消、失败、撤回、不相关话题、关闭确认及换档不会延续邀请，旧历史不会自动补加联系人。
- Android 与 Windows 共用上述修复，保持版本名 `1.0.4`，内部构建号递增为 `40`。

## 保留的近期更新

- 普通语音、持续 ASMR 与 TTS 试音增加可选立体声及居中／偏左／偏右的固定声音位置。声音不会随台词随机移动，一段回复或一次 ASMR 会话采用开始合成时的设置；原生立体声保留原有声场。设置可持久化并随设置备份。
- 持续 ASMR 在音频入队前检查有效包络和正时长，损坏、截断或零帧音频删除后重新合成同一文本一次，仍失败时明确提示重试。
- Android 本地音源准备失败时，使用相同音频字节备用加载一次；不会因此再次请求 TTS。补齐原生错误广播及开始播放瞬间的错误处理，避免未处理异常或一直等待；自动播放和重播均适用。
- 快速重播增加准备阶段防重入与取消检查，避免同时准备多个音源或过期操作重新启动播放。

- 修复交换 NPC 联系方式后信息页没有联系人的问题：兼容角色姓名和自然日语同意台词，支持发言及旁白中的显式交友请求；确认不再依赖 TTS 或动作规划成功，联系人立即显示并随存档保存。拒绝、犹豫、旁白和译文中的同意不会被误添加。
- Windows Fish Audio 增加直连预探测和系统 HTTP 代理自动切换；直连不可达时使用已启用的系统代理或 HTTP 代理环境配置，无需开启 TUN。按地址缓存路由并合并并发探测，语音请求超时或可重试网络失败后重新选路；保持 HTTPS 证书校验。
- 动作规划增加按意图、身体区域、语义动作族、姿态和轨道的分层召回；手部、腿部、身体和多区域组合动作会在真实资源范围内检索。
- 未指定具体动作时，规划器只接收当前区域的候选并参考当前人物状态、情绪和最近动作；没有准确动作时保持 `none/unsupported`，不使用相近动作冒充。
- 新增动作目录索引、抱臂回归覆盖和分层检索测试，保留现有动作播放硬校验。
- Android 和 Windows 同步增加内置服装 `crf_skn_002_0006_01`（东方旗袍·紫色）；Spine、预览图和动作数据只在本地参与受保护构建，运行时以加密资源包加载。原始服装、独立加密资源包和密钥均不提交源码仓库。
- 保留近期记忆与长期记忆分层整理、追加式记忆账本、虚拟手机、NPC 信息和 PC Agent 联动能力。

## 构建与验证

使用受保护构建脚本生成 release APK，启用人物资源加密、Dart 混淆和分离调试符号：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target apk -Mode release
```

APK：`build/app/outputs/flutter-apk/app-release.apk`。

Android release 产物大小为 `645,953,392` 字节，SHA-256 为 `30e88c618738ffa01e65fcdea300886efc768c358bed5b78ca2e54f61afb1342`；元数据为 `versionName=1.0.4`、`versionCode=40`，APK Signature Scheme v2 验证通过。Windows release 运行目录已打包为 `AgentAtelierR-1.0.4-windows-release.zip`，大小 `598,508,508` 字节，SHA-256 为 `2c92844516176660c05f4df5d1fad50cd47f28bdc1f98f428e0b4b1dec46aba7`，ZIP 内含 `AgentAtelierR.exe` 与 `data` 目录。两端均使用正常 main 入口，由本项目受保护脚本重新构建，启用人物资源加密和 Dart 混淆。Android release 继续使用现有调试签名，以便覆盖安装测试包，不代表应用商店签名。

本次 83 项 NPC 联系人相关测试通过，Flutter 静态分析无问题。回归使用实际设备已有台词，运行主聊天、用户确认及虚拟手机联系人窗口；另覆盖中止 SSE 后保留的半截回复、网络失败、不相关话题、拒绝确认、新档、角色隔离及存档往返。设备仅用于读取问题证据，本次不声称已经完成新版真机在线聊天验收。详情见 [场景 NPC 联系请求修复](https://github.com/onion-aqua/AgentAtelierR/blob/v1.0.4/docs/bugfix_npc_contact_followup.md)。

此前音频修复的 Flutter 静态分析、58 项音频／ASMR 回归与 7 项立体声设置测试通过。Android 模拟器使用真实 MediaPlayer 完成 59 项原生音频检查，包含 40 段单声道音频自然播放完成后的连续切换，0 项失败；该检查使用 debug 诊断入口，之后已安装正常 debug 应用并确认主界面启动。诊断入口不在本次 release 的正常入口中。

用户手机实际 Fish Audio 场景的 `what:13`、真机耳机听感及 Windows 在线语音尚未完成验收，不能由模拟器或构建成功推断通过。立体声操作见[立体声与固定位置说明](https://github.com/onion-aqua/AgentAtelierR/blob/v1.0.4/docs/tts_stereo.md)，修复与诊断范围见[ASMR 音频可靠性说明](https://github.com/onion-aqua/AgentAtelierR/blob/v1.0.4/docs/asmr_audio_reliability.md)。

## PC 版同步与使用

已恢复本项目的 Windows 工程，PC 版由当前 Flutter 共用源码构建，包含最新动作规划、记忆框架、虚拟手机和新服装配置。通过以下命令完成加密 release 构建：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target windows -Mode release
```

解压 Release 附件 `AgentAtelierR-1.0.4-windows-release.zip` 后运行 `AgentAtelierR.exe`，保留同目录 DLL 和 `data` 文件夹。EXE 版本为 `1.0.4+40`，未标记为 Debug；应用 Dart 代码位于 `data/app.so`。Android APK 和 Windows ZIP 均只包含新服装的加密角色包与加密预览，没有新服装的原始文件。

此前联系人与代理修复的 73 项相关测试通过，Flutter 静态分析无问题，Windows 网络通道 C++ 编译检查通过。联系人测试实际经过主聊天输入、NPC 日语姓名回复、添加确认、TTS 缺配置或 HTTP 401 失败及虚拟手机联系人窗口。此前新服装原生 Spine 回归及包内资源校验通过；本轮不声称已做手动换装或真实在线语音验收。dshagalt 是另一个项目，本次未修改其源码或部署。

代理软件仍需运行，并启用 Windows 系统 HTTP 代理或为应用进程配置 HTTP 代理环境变量。目前不解析 PAC/WPAD，不支持 SOCKS 或需要代理账号密码的地址；请使用代理软件提供的 HTTP 混合端口。完整使用及验证说明见 [NPC 联系人与 Fish Audio 代理修复说明](https://github.com/onion-aqua/AgentAtelierR/blob/v1.0.4/docs/bugfix_npc_fish_proxy.md)。
