# AgentAtelierR 1.0.4.2 Windows 版

## 更新内容

- 同步安卓主线的聊天、长期记忆、NPC 信息、生图、壁纸和语音设置。
- 同步东方旗袍 r3、万圣节女巫服装及预览，角色资源采用加密打包。
- PC Agent 联动改用粘贴配对二维码数据，保留前台问答、任务和断线补拉。
- PC 版更新入口改为下载 Windows 完整包。
- 移除 Windows 尚不支持的实时电话、语音闹钟、相机拍照、本地 CosyVoice 和手机推送入口。

## 使用方法

下载 `AgentAtelierR-1.0.4.2-build53-windows-x64-release.zip`，完整解压到新目录。退出旧版本，运行新目录中的 `AgentAtelierR.exe`。请将 EXE、所有 DLL 和 `data` 文件夹保留在一起。

存档、聊天和接口设置继续使用当前 Windows 用户的数据目录。聊天和语音沿用已有 LLM、Fish Audio REST/MCP、Qwen 等配置；在“声音与语音”中选择可用服务。

PC Agent 联动：从桌面 Agent 取得有效的配对二维码 JSON，打开虚拟手机中的 PC Agent 设置，粘贴并确认，再等待 Agent 同意。

后续更新可打开“设置 → 关于 → PC 版下载与更新”，下载新的 Windows 完整包。

## 注意事项

- 适用于 Windows x64；请完整解压后运行。
- Windows 使用完整包更新，安卓 stable 下载器和 APK 安装流程不用于 PC。
- 实时电话、定时语音闹钟、手机厂商推送和本地 CosyVoice 当前仅在相应移动平台提供；PC 保留云端语音与持续 ASMR。
- 从 Android 导入的通话记录和闹钟数据仍保留，PC 不会启动录音或恢复手机定时闹钟。
- AI 与云端语音服务需要各自的接口配置，正常产生服务用量。
