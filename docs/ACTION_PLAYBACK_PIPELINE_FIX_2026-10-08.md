# 动作已规划但角色不动：执行流程修复与模拟器验证

日期：2026-10-08。版本保持 `1.0.4-beta1-horae.26106+37`。

## 确认的问题

此前的动作标签修复只证明模型选中了可用资源，尚未验证完整的画面播放。本轮检查了主回复、语音规划、动作规划、段落分发、队列和真实 Spine 轨道。

1. 短句 TTS 播完后才返回的动作规划，没有进入执行入口。段落切换也可能丢掉已经读完的段落。
2. `grp_fg_024` 和 `grp_recipe_4673` 的真实 F050/G050 资源仅 200 ms，原入口混合分别约 600 ms / 340 ms，却在首次 `complete` 时就清除轨道，动作还没有充分显示。
3. 无 TTS、语音配置不齐和语言不匹配的路径可能提前返回，没有把独立规划的动作应用到角色。
4. 批量补派时，下一段表情会清空上一段等待中的动作；异步恢复还缺少取消/存档代际守卫。
5. 晚到回调提前更新缓存，遇到相同正文的重复回复时可能删除本轮语音缓存。

## 实现

- `SpeechPerformanceDispatch` 使用原始主角段落序号，记录已开始/已分发段落。规划在语音期间、句间或语音结束后到达，都可以补派符合条件的段落；同一段不会重复分发。
- 关闭 TTS、没有可播语音或语言校验拒绝合成时，仍应用当前有效回复的演出。角色、存档、回复和播放代际变化会阻止旧结果执行。
- 主音频无需等待动作规划才开始。音频结束后，等待本轮规划分发再结束回复；取消可以解除等待。规划沿用原有 30 秒超时。
- `MotionPlaybackTiming` 将极短动作的一次运动减速至至少 600 ms，缩短入口混合并增加保持时间。拍手入口混合为 150 ms，可见窗口为 900 ms；保持一个周期，不自动变成连续拍手。普通长动作维持作者速度；零时长姿态在混合后保留 600 ms。
- 标准组与组合阶段按完整窗口释放，不由首次 Spine `complete` 提前结束。Timer 沿用资源代际、轨道租约和统一取消。未处理的释放 Timer 仍视为忙碌，避免界面卡顿时下一动作抢先启动。
- 段落表情不再清空已有动作队列；语音缓存与来源统一提交。

## 验证结果

`flutter analyze --no-pub`：全项目无问题。

相关自动测试：71 项通过，首次运行跳过 1 项需要本地 DLL 的 native 测试。配置 DLL 路径后，动作 timing 与六套真实骨架 native 测试共 17 项全部通过，其中包含拍手峰值、一次完整周期、保持、清除及骨骼数值稳定性。最终分发/队列/动作规划回归 41 项再次通过。

本地模拟器：`Pixel_10_Pro`，Android 16 / API 36，设备 `emulator-5554`。调试入口复用生产 `ChatScreen`、实际发送回调、真实规划器、TTS 客户端和加密 Spine 资源。LLM 响应与 1 秒提示音来自进程内模拟 HTTP 服务，动作规划刻意延迟 6 秒；没有接入用户在线服务或读取真实凭证。

| 场景 | 结果 | 证据 |
| --- | --- | --- |
| 1 秒语音结束后返回标准拍手 | `语音已结束=true` 后分发 `grp_fg_024`，轨道 6/7 开始并完成；录屏看见双手抬起、合拢、恢复 | `evidence/pipeline-short-tts.json`、`pipeline-short-tts.mp4`、`pipeline-visible-clap.png` |
| 晚到组合拍手 | `grp_recipe_4673` 阶段开始、结束、释放；录屏确认动作可见 | `evidence/pipeline-recipe.json`、`pipeline-recipe.mp4`、`pipeline-recipe-motion.png` |
| 关闭 TTS | 没有 TTS 请求，标准拍手仍进入轨道，随后恢复正常待机调度；完成日志受限频影响没有单独输出 | `evidence/pipeline-no-tts.json` |
| 英语回复纠正为日语 | 真实语言纠正器完成后合成，晚到动作仍执行 | `evidence/pipeline-language-correction.json` |
| 规划等待期间取消回复 | 规划虽返回，旧拍手没有分发/执行 | `evidence/pipeline-cancel.json` |
| 规划等待期间清空测试存档 | 旧规划返回后，没有进入新存档的拍手执行 | `evidence/pipeline-new-save.json` |

日志中的总动作开始/完成计数包含正常待机动作，验收按目标 `grp_fg_024` / `grp_recipe_4673` 的具体记录和录屏判断，不用总数冒充结果。

## 构建与调试

正式包通过现有加密脚本、默认 `lib/main.dart` 入口构建：

```powershell
.\tool\build_protected.ps1 -Target apk -Mode release
```

产物：`D:\Ryza_chat\ryza_chat_mvp\build\app\outputs\flutter-apk\app-release.apk`。

大小：631257368 字节。SHA-256：`830924890968BD9C8E37BC867E23023CFF5A1EE12457AA6DB796C65F3BCAD096`。

正式包已覆盖安装到 `emulator-5554`，正常入口启动成功，版本码 37，角色和主界面显示正常。截图：`evidence/pipeline-release.png`。模拟服务仅存在于独立 debug 入口，正式包没有启动模拟 HTTP 服务。

复现用独立入口只在 debug 模式运行，生产入口不导入该文件。设置与 SecretStore 使用内存模拟，不修改真实存档或服务配置：

```powershell
.\tool\build_protected.ps1 -Target apk -Mode debug -EntryPoint tool/debug_animation_pipeline.dart -Install -DeviceId emulator-5554
adb -s emulator-5554 shell am start -n com.example.ryza_chat_mvp/.MainActivity
```

界面提供无 TTS、短 TTS、组合动作和语言纠正测试。需等待骨架及动作目录全部加载后提交。可从 `PIPELINE_SIMULATOR` 日志取得本地随机端口，用 `adb forward tcp:18111 tcp:<端口>` 后调用 `/debug/run`、`/debug/state`、`/debug/cancel`、`/debug/new-save`；只用于本地模拟验证。

## 验证边界

本轮没有进行真实在线 LLM/Fish Audio 联调。标准与组合拍手已通过 Android 模拟器实际渲染验证，不代表三万多种组合均逐一完成视觉审核。静态立绘角色不具备 Spine 动作能力，不能以拍手标签生成动画。全屏暂停设置仍按原规则暂停人物；隐藏期间播放窗口按墙钟消耗，这种预览不属于本轮正常前台动作验收。

测试机 `a43d2d7a` 本轮未出现在 ADB，正式包交付并在本地模拟器安装；未向 GitHub 推送。
