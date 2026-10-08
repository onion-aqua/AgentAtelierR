# AgentAtelierR 1.0.4 正式版

Android 版本：`1.0.4+38`。GitHub 标签：`v1.0.4`。

## 本次更新

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

本次 Android 构建产物大小为 `645,910,684` 字节，SHA-256 为 `f87419cc07f2355331023d4412c0858c0695ceab03aac27a28680c3506690182`。APK 元数据已核对为 `versionName=1.0.4`、`versionCode=38`，APK Signature Scheme v2 验证通过。Windows release 运行目录已打包为 `AgentAtelierR-1.0.4-windows-release.zip`，大小 `598,946,157` 字节，SHA-256 为 `abb7a8797f08be1941b99276145819f34ba8489b518aa394eaa272ac433cefb1`。本版本的动作、索引、规划器和新服装兼容性测试在发布前运行；涉及原生 Spine 的测试仍以本机实际运行时资源为准。Android release 继续使用现有调试签名，以便覆盖安装测试包，不代表应用商店签名。

## PC 版同步与使用

已恢复本项目的 Windows 工程，PC 版由当前 Flutter 共用源码构建，包含最新动作规划、记忆框架、虚拟手机和新服装配置。通过以下命令完成加密 release 构建：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tool\build_protected.ps1 -Target windows -Mode release
```

解压 Release 附件 `AgentAtelierR-1.0.4-windows-release.zip` 后运行 `AgentAtelierR.exe`，保留同目录 DLL 和 `data` 文件夹。EXE 版本为 `1.0.4+38`，未标记为 Debug；应用 Dart 代码位于 `data/app.so`。Android APK 和 Windows ZIP 均只包含新服装的加密角色包与加密预览，没有新服装的原始文件。

静态分析通过；本轮目标测试 122 项通过、2 项跳过，另外新服装的原生 Spine 动作混合、24/60/120 fps 骨骼状态与风动回归测试通过。两个平台的 release 构建及包内资源校验均通过。本轮未进行手机或 PC 界面的手动换装验收；dshagalt 是另一个项目，本次未修改其源码或部署。
