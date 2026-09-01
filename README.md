> **⚠️ Disclaimer**
>
> This is an unofficial research and reimplementation project.
>
> This repository contains only independently written code, implementation methods, tools, and technical documentation. **Original images, audio, models, fonts, videos, APKs, and other original assets are not included.**
>
> All third-party copyrights and intellectual property rights remain with their respective owners.
>
> The license of this repository applies only to content created and owned by this project.



# LLMAtelier

一个 Flutter 编写的本地优先 AI 角色交互应用原型。仓库公开的是功能代码与实现方式，不包含任何游戏原版图片、音频、Spine 模型、动作配置或其他受版权保护的资源。

主要实现：

- OpenAI 兼容接口的流式聊天、长期记忆、原始输出查看与结构化演出指令
- Fish Audio S2 Pro TTS，以及语音、口型、表情和动作的同步播放
- 140 项组合动作、53 项闲置动作的候选池与情绪权重自动演出
- 可选的只读联网搜索与工具调用 Agent，以及 GPT 系列高级推理参数
- 可拖动液态玻璃聊天 UI、图片/文档附件输入与本地存档导入导出
- Spine 动作、微表情、换装、点击互动、场景与声音控制接口
- 双指缩放和纵向镜头调整，以及适合角色展示的默认近景构图
- 本地用户设定：称呼、自画像、关系定位、互动偏好和边界提示词注入
- Android 系统闹钟与锁屏响铃

完整的缺失资源清单、放置路径、合规要求、构建步骤以及可交给编码 Agent 使用的 Skill 提示词见：[资源接入与构建指南](docs/RESOURCE_SETUP_AND_BUILD.md)。

没有资源时仍可执行依赖解析、静态检查和单元测试；涉及角色、场景、音频的页面需要先放入合法资源才能完整运行。

# 免责声明 / Disclaimer

本项目为一个**非官方的技术研究、学习与软件重构项目**，旨在通过对相关软件进行技术分析和研究，探索其程序设计、运行机制、接口行为及实现方式，并在此基础上进行独立的软件实现与开发。

## 1. 项目性质

本项目与相关原软件的开发者、发行商、版权所有者或其他权利人不存在官方合作、授权、赞助或隶属关系。

本项目不代表原软件官方，也不声称获得原软件版权所有者的认可或授权。

## 2. 关于项目代码

本项目公开的内容主要为项目贡献者自行编写的：

* 源代码
* 程序实现
* 技术方案
* 工具及脚本
* 接口实现
* 技术研究文档

除特别注明外，上述内容均为本项目贡献者独立编写或在合法许可范围内使用。

本项目不提供原软件的完整源代码，也不以复制、重新发布原软件为目的。

## 3. 关于原软件资源

为了避免未经授权传播第三方受版权或其他知识产权保护的内容，**本项目不会在公开仓库中提供原软件的原版资源文件**。

包括但不限于：

* 原版图片
* 原版音频、音乐及语音
* 原版模型及模型数据
* 原版字体
* 原版动画及视频
* 原版游戏/应用资源包
* 原版 APK、安装包或其他完整发行文件
* 其他属于第三方的受版权保护资源

因此，本项目的公开仓库原则上仅包含代码、程序实现方式以及相关技术研究资料。

## 4. 第三方内容

相关原软件及其图片、音频、模型、角色、美术资源、商标、名称以及其他第三方内容的知识产权，均归其各自合法权利人所有。

本项目不对上述第三方内容主张所有权。

本项目中的代码许可证仅适用于本项目贡献者拥有相应权利的原创代码及其他原创内容，**不意味着获得任何第三方软件或资源的授权**。

## 5. 非官方研究项目

本项目仅用于软件开发研究、技术学习、兼容性研究、程序分析及社区技术交流。

本项目不是原软件的官方版本，也不是原软件的替代发行渠道。

未经相关权利人授权，任何人不得将本项目理解为获得原软件或其相关第三方内容的复制、分发、商业使用或其他授权。

## 6. 使用者责任

使用本项目时，使用者应自行遵守所在地适用的法律法规，以及相关软件的许可协议、最终用户许可协议和其他适用条款。

如使用者自行获取、处理或使用原软件及其第三方资源，应自行确认其具有相应的合法权利。

因使用者违反适用法律、软件许可协议或第三方知识产权而产生的责任，由使用者自行承担。

## 7. 无担保声明

本项目按“**AS IS（现状）**”提供。

项目维护者不对本项目的准确性、完整性、稳定性、可用性或特定用途适用性作任何明示或默示保证。

使用本项目产生的风险由使用者自行承担。

## 8. 权利人联系

如果任何权利人认为本项目中的代码、文档或其他内容侵犯其合法权益，请通过 GitHub Issue 或项目公开联系方式与维护者联系。

项目维护者将在收到合理的权利证明及具体说明后，对相关内容进行核查，并在必要情况下及时进行修改、删除或采取其他适当措施。

---

### Copyright Notice

Original software, trademarks, characters, images, audio, models and other third-party materials remain the property of their respective rights holders.

This repository contains independently written code and implementation research only and does not intentionally distribute the original software or its original asset files.

This project is unofficial and is not affiliated with, endorsed by, or sponsored by the original software's copyright holders.
****
