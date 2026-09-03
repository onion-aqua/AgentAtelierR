> **Disclaimer**
>
> This is an unofficial research and reimplementation project. The repository
> contains independently written source code, implementation notes, tests, and
> documentation only. Original images, audio, Spine models, animation data,
> fonts, videos, APKs, extracted application files, and secrets are not included.
>
> Third-party copyrights and intellectual-property rights remain with their
> respective owners. The repository license applies only to material the project
> contributors have the right to license.

# LLMAtelier

一个 Flutter 编写的本地优先 AI 角色交互应用原型。公开仓库仅提供代码和实现方式，不提供游戏或应用原版资源。

## 当前实现

- OpenAI 兼容接口流式聊天、图片与文档输入、长期记忆和原始输出查看
- Fish Audio S2 Pro、DashScope Qwen-TTS 与 OpenAI 风格通用 TTS 接口
- TTS、间歇口型、微表情、头部动作和角色演出的同步控制
- LLM 情绪、表情和动作指令解析，以及动作混合与情绪权重选择
- 液态玻璃或半透明聊天 UI、自动高度、历史记录、撤回和语音重播
- 本地用户画像、称呼、关系、互动偏好、语言和主题设置
- 只读联网搜索与工具调用 Agent，以及 GPT 系列高级推理参数
- 双指缩放和纵向镜头调整
- 本地 JSON 存档导入导出，不包含 API 密钥
- Android 系统闹钟和锁屏响铃接口
- Spine 角色、换装、点击互动、场景、BGM 和环境音的资源接入接口

角色动作数量、服装、表情和语言语音取决于使用者自行提供的合法资源。缺少资源时，代码仍可进行依赖解析、静态检查和不依赖资源的测试，但无法完整展示角色与场景。

## 资源与构建

请先阅读 [资源接入、版权边界与构建指南](docs/RESOURCE_SETUP_AND_BUILD.md)。文档列出了故意缺失的文件名和放置位置、合法资源接入步骤、构建命令和可交给编码 Agent 使用的 Skill 提示词。

```powershell
flutter pub get
flutter analyze
flutter test
```

如已准备好拥有合法使用权的完整资源，可运行 `flutter run` 或 `flutter build apk --debug`。

## 版权边界

本项目不是相关游戏、应用或角色的官方版本，也未声称获得其开发者、发行商或权利人的授权、赞助或认可。

请只使用自制资源、明确允许相应使用和分发的资源，或已获得书面授权的资源。能够从本地 APK、缓存或下载目录读取文件，不代表拥有重新分发权。对许可不确定时，不要上传或发布。

声音合成同样需要尊重配音演员、声音权利人和模型许可证。不得未经授权克隆或模仿特定人物的声音。

发布应用前，使用者应自行完成资源许可、商标与角色名称、隐私政策、模型与 API 条款、Spine Runtime、应用商店和当地法律要求的审查。

本项目按现状提供，不对完整性、稳定性、适销性或特定用途适用性作保证。
