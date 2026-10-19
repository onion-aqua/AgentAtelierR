# 壁纸资源热更新真机记录：2026-10-19

本轮使用隔离 `device-test` 渠道和 Gitee `codex/update-device-test` 分支验证新增壁纸。正式 `stable` 渠道未发布；没有将测试结果等同于正式分发或全部厂商设备验收。

## 支持 APK 与资源发布

| 项目 | 实际结果 |
| --- | --- |
| 测试设备 | `a43d2d7a`，PJZ110，Android 17 |
| 支持 APK | build 49，受保护 release，通过覆盖安装保留数据 |
| APK 内置发布序号 | 50 |
| 运行时标识 | `android-wallpaper-v1` |
| APK 大小 | `649723108` 字节 |
| APK SHA-256 | `0c609f166880fd2707e335f97d9ca1d325b2bcb8833d884a29c5e1ebe6b1840b` |
| 本次更新发布序号 | 51 |
| Gitee 测试分支提交 | `489c4be` |

固定支持 APK 已核实未内置新增 `png1` 图片，壁纸目录为空。序号 51 同时引用这一份 APK 和完整 19 项资源快照：旧 17 项路径、hash 和大小保持不变，新增完整壁纸目录与 PNG 两项。已安装支持 APK 的设备仅需资源更新，旧运行时仍能取得兼容代码。

新图完整 PNG 解码通过，在线对象 hash 与本地一致。未用占位 APK、空资源快照或假版本进行演示。

## 已观察的真机结果

- 应用通过 Gitee 检查发现更新，完成 19/19 项资源准备，显示下次启动生效。
- 重启应用后，新增图片出现在壁纸页第 4 张卡片；原三张默认壁纸及用户导入壁纸保留。
- 更新前选择的第二张默认壁纸 `builtin-bg2` 保持选中，没有被更新自动替换。
- 手动选择新增壁纸后，虚拟手机主页实际显示新图。
- 选中新图后再次完整重启，主页仍显示新图，壁纸页勾选仍在新图上，确认选择持久化。
- 测试结束已恢复原来的 `builtin-bg2`，新图仍保留供用户选择；资源更新前后系统 versionCode 均为 49，未再次安装 APK。

本地截图位于忽略目录 `build/update-validation/`：`wallpaper49-empty-catalog.png`、`wallpaper51-ready.png`、`wallpaper51-list.png`、`wallpaper51-applied.png`、`wallpaper51-persisted.png`、`wallpaper51-persisted-list.png` 和 `wallpaper51-restored-bg2.png`。截图不提交公开仓库。

## 验证范围

相关测试 38 项通过，全项目静态检查无问题；部署涉及的三个服务容器均健康。图片覆盖加载测试使用 APK 清单中不存在的新路径，验证实际解码和绘制像素，未依赖将新图预先打入支持 APK。

本轮未扩大到全部厂商 ROM、长期后台、下载中断恢复或 Windows 自动更新验证。资源激活需重新启动，Dart 代码变化仍需完整 APK 及 Android 系统安装确认。

操作步骤见 [壁纸热更新说明](WALLPAPER_HOT_UPDATE.md)，先前引导与完整 APK 更新验收见 [更新系统真机记录](DEVICE_TEST_2026-10-19.md)。
