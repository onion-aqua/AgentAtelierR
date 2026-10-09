# AgentAtelierR 1.0.4 正式版

Android 版本：`1.0.4+38`。GitHub 标签：`v1.0.4`。

## 本次更新

- 修复交换 NPC 联系方式后信息页没有联系人的问题：兼容角色姓名和自然日语同意台词，支持发言及旁白中的显式交友请求；确认不再依赖 TTS 或动作规划成功，联系人立即显示并随存档保存。拒绝、犹豫、旁白和译文中的同意不会被误添加。
- Windows Fish Audio 增加直连预探测和系统 HTTP 代理自动切换；直连不可达时使用已启用的系统代理或 HTTP 代理环境配置，无需开启 TUN。按地址缓存路由并合并并发探测，语音请求超时或可重试网络失败后重新选路；保持 HTTPS 证书校验。
- 动作规划增加按意图、身体区域、语义动作族、姿态和轨道的分层召回；手部、腿部、身体和多区域组合动作会在真实资源范围内检索。
- 未指定具体动作时，规划器只接收当前区域的候选并参考当前人物状态、情绪和最近动作；没有准确动作时保持 `none/unsupported`，不使用相近动作冒充。
- 新增动作目录索引、抱臂回归覆盖和分层检索测试，保留现有动作播放硬校验。
- Android 和 Windows 同步增加内置服装 `crf_skn_002_0006_01`（东方旗袍·紫色）；Spine、预览图和动作数据只在本地参与受保护构建，运行时以加密资源包加载。原始服装、独立加密资源包和密钥均不提交源码仓库。
- 保留近期记忆与长期记忆分层整理、追加式记忆账本、虚拟手机、NPC 信息和 PC Agent 联动能力。
- 版本标识统一为 `1.0.4`，内部 Android versionCode 为 `38`。

## 构建与验证

使用受保护构建脚本生成 release APK，启用人物资源加密、Dart 混淆和分离调试符号：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target apk -Mode release
```

APK：`build/app/outputs/flutter-apk/app-release.apk`。

本次 Android 构建产物大小为 `645,912,388` 字节，SHA-256 为 `14a58642c3c50676906e7c8219ee8e1520117e3de224e0f76fc9e43ccd1b8f98`。APK 元数据已核对为 `versionName=1.0.4`、`versionCode=38`，APK Signature Scheme v2 验证通过。Windows release 运行目录已打包为 `AgentAtelierR-1.0.4-windows-release.zip`，大小 `598,374,210` 字节，SHA-256 为 `152a60c1dcb8b482fc59fd43e78037c54ee37af39bc7e747941d60e905828745`。两端均由本项目受保护脚本重新构建，保留人物资源加密和 Dart 混淆；包内资源核对不替代实际界面与语音验收。Android release 继续使用现有调试签名，以便覆盖安装测试包，不代表应用商店签名。

## PC 版同步与使用

已恢复本项目的 Windows 工程，PC 版由当前 Flutter 共用源码构建，包含最新动作规划、记忆框架、虚拟手机和新服装配置。通过以下命令完成加密 release 构建：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target windows -Mode release
```

解压 Release 附件 `AgentAtelierR-1.0.4-windows-release.zip` 后运行 `AgentAtelierR.exe`，保留同目录 DLL 和 `data` 文件夹。EXE 版本为 `1.0.4+38`，未标记为 Debug；应用 Dart 代码位于 `data/app.so`。Android APK 和 Windows ZIP 均只包含新服装的加密角色包与加密预览，没有新服装的原始文件。

本次联系人与代理修复的 73 项相关测试通过，Flutter 静态分析无问题，Windows 网络通道 C++ 编译检查通过。联系人测试实际经过主聊天输入、NPC 日语姓名回复、添加确认、TTS 缺配置或 HTTP 401 失败及虚拟手机联系人窗口。此前新服装原生 Spine 回归及包内资源校验通过；本轮不声称已做手动换装或真实在线语音验收。dshagalt 是另一个项目，本次未修改其源码或部署。

代理软件仍需运行，并启用 Windows 系统 HTTP 代理或为应用进程配置 HTTP 代理环境变量。目前不解析 PAC/WPAD，不支持 SOCKS 或需要代理账号密码的地址；请使用代理软件提供的 HTTP 混合端口。完整使用及验证说明见 [NPC 联系人与 Fish Audio 代理修复说明](bugfix_npc_fish_proxy.md)。
