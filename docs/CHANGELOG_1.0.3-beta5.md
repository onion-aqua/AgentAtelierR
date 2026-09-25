# AgentAtelierR 1.0.3 beta5

Android 版本号：`1.0.3-beta5+28`。使用加密构建脚本生成 release APK；当前 Android 工程仍使用调试密钥签名，不能作为商店发布包。

## 本次更新

- 服装切换页改为可左右滑动的堆叠卡片，保留液态玻璃边框和左下角的皮肤 ZIP、贴图导入入口。
- 移除服装卡片的整卡背景色与配色渐变，仅在底部文字区域保留较短的暗色渐变以保证可读性。
- 右侧下一张卡片先停在屏幕外，再以缓起步动画滑入，避免切换层级时突然闪现；卡片移动使用绘制平移，减少布局计算。
- 全屏页面可暂停主界面人物动画；新存档会重置人物表情和动作状态。
- 语音、表情与动作规划参考已结算的人物状态；歌唱规划的文本使用歌唱语音输出。
- 减少动画及界面设置时的重复持久化与规划日志开销。

## 构建与验证

使用 `tool/build_protected.ps1 -Target apk -Mode release` 构建。APK 输出到 `build/app/outputs/flutter-apk/app-release.apk`。本地人物资源及解密密钥不提交到 GitHub。

静态分析无问题；完整测试 467 项通过、10 项跳过。release APK 已安装到 `dc4a3f49`，设备报告 `versionName=1.0.3-beta5`、`versionCode=28`。APK 的 SHA-256 为 `5B70FE7E2BFB849C9814EFE28EB0215057D85F70039D7E57B024BF95CD245862`。
