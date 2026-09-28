# CosyVoice 3 本地语音

入口：设置 → 语音合成 → CosyVoice 3（本地）。Android arm64 设备首次需要联网安装模型；之后语音合成和音色创建都在设备内运行，不使用 TTS API Key。AI 对话和翻译仍按各自的服务配置联网。

## 安装与使用

1. 安装合成模型包后，选择内置基准音色或已创建的音色，试听并启用本地语音。合成模型包约 1.4 GB（17 个文件）。
2. 若要在手机上创建音色，另安装约 1.0 GB 的音色创建扩展。选择一段清晰的单人参考音频，截取 **3–5 秒**，填写与片段内容完全一致的文字，然后创建音色。底层解码允许 3–15 秒，但较长片段容易超过实时合成的 125 Token 提示上限，因此推荐 3–5 秒。
3. 为莱莎与苏菲分别选取本地音色。普通对话和持续 ASMR 均使用当前人物选中的音色；本地模型不识别 Fish Audio 的情绪、耳语或停顿标签。音色是参考音频的零样本复刻，效果取决于录音质量和转写准确度，并不保证每次都完全相同。

模型和参考音频保存在应用私有目录，不包含在聊天 JSON 备份中。音色选择 ID 会随人物设置保存；在另一台设备恢复备份后，需重新安装模型和对应音色。下载、校验和解压时需要额外空闲存储空间。

## 模型来源与校验

[Nian27/CosyVoice3-MNN](https://github.com/Nian27/CosyVoice3-MNN) 的 [发布清单](https://github.com/Nian27/CosyVoice3-MNN/blob/main/release-manifest.json) 指向 [VicenTrent/Cosy-Voice-MNN](https://huggingface.co/VicenTrent/Cosy-Voice-MNN)：

| 文件 | 用途 | 字节 | SHA-256 |
| --- | --- | ---: | --- |
| [cosyvoice3-mnn-mobile-fp16-complete.zip](https://huggingface.co/VicenTrent/Cosy-Voice-MNN/resolve/main/cosyvoice3-mnn-mobile-fp16-complete.zip?download=true) | 合成必需 | 1,399,083,563 | `B1C74DFC90972D82D8166813620A882FE37A0DC02964E19C4F33DAAFEFEB1C84` |
| [cosyvoice3-mnn-enrollment-extension.zip](https://huggingface.co/VicenTrent/Cosy-Voice-MNN/resolve/main/cosyvoice3-mnn-enrollment-extension.zip?download=true) | 手机创建音色 | 997,807,778 | `59EF5C8810D3CEAD01FF21A64379CF0A819F0A72651A6BA2B2343E9DA5A72231` |

两包下载量合计约 2.4 GB。模型不会打包进 APK。安装器应先核对包的字节数和 SHA-256，再校验内部模型文件；校验失败时重新下载或导入。

合成包的 `manifest.json` 将 `flow.cfg-student-2step.batch1.fp16.mnn` 的 SHA-256 写为 `C7008468…`，但上述完整 ZIP 内该文件的实际 SHA-256 为 `B74ECE0A1A2E165EEF53DBC8D628310A1B464323D4729959069744BAECF418D7`。本应用按已核对的完整 ZIP 和实际文件哈希校验该文件；其他文件与包内清单一致。

导入时必须保留 `llm_config.json`（456 B）；MNN 会读取其中的模型结构参数。缺少它会让模型状态误判为就绪并在朗读时发生 Reshape 错误。应用对原始文件做固定哈希校验，采样参数写入派生的运行时配置。

## 设备与许可

移植版使用 MNN 3.6.1，只提供 Android arm64 原生库。其作者报告仅在荣耀 Magic8 Pro（SM8850）真机验证，全链路常驻内存约 2.25 GB PSS，建议 8 GB 以上 RAM；冷启动、长文本和其他芯片上的速度与稳定性尚需实测。桌面与 iOS 不在当前本地推理范围内。

[CosyVoice 官方源码](https://github.com/FunAudioLLM/CosyVoice)及[移植项目源码](https://github.com/Nian27/CosyVoice3-MNN/blob/main/LICENSE)使用 Apache-2.0；[移植模型仓库说明](https://github.com/Nian27/CosyVoice3-MNN/blob/main/docs/HUGGINGFACE_README.md)将模型包标为 Apache-2.0。预编译原生库来自 MNN、CrispASR 等组件，发布时还需保留各组件的许可证与归属说明。人物素材的使用权与语音模型许可分别处理。
