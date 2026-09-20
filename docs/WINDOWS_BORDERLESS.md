# Windows 无边框窗口（2026-09-20）

打开左上角折叠菜单，选择“切换无边框窗口”。默认保留系统边框，每次启动恢复默认模式。

无边框模式上方保留应用控制条：拖动标题移动窗口，调整大小按钮进入右下角缩放，另有恢复边框、最小化、关闭按钮。隐藏聊天 UI 后控制条仍然可用。置顶功能可与无边框组合使用。保持现有竖屏比例。

Android 与 Windows 共用聊天逻辑：撤回后旁白与发言分别恢复，存在旁白时展开双输入框；普通消息列表使用独立旁白条，原始输出视图保留完整内容。

## 构建

准备 Flutter、Visual Studio 的 C++ 桌面开发工具以及已获授权的本地资源，参照 RESOURCE_SETUP_AND_BUILD.md。Windows 应用图标 `windows/runner/resources/app_icon.ico` 不在此源码上传范围内：请使用自己的图标放入该位置。Spine 本地依赖按现有资源说明准备。

```powershell
./tool/build_protected.ps1 -Target windows -Mode release
```

发布目录为 `build/windows/x64/runner/Release`。分发必须包含 EXE、同目录 DLL 及整个 data 目录，不要单独复制 EXE。原始资源、加密密钥、签名和本地配置不得提交到 Git。
