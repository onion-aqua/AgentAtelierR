# 自托管更新真机测试记录：2026-10-19

本轮在隔离的 `device-test` 渠道验证 Gitee 更新发现、自托管资源下载、资源激活和 Android 安装流程。正式 `stable` 渠道没有发布，继续返回 404；正式渠道发布操作曾被自动审批检查拒绝，本轮改用独立测试渠道完成用户授权的真机测试。

## 环境与发布身份

| 项目 | 本轮状态 |
| --- | --- |
| 测试设备 | `a43d2d7a`，PJZ110，Android 17 |
| 原安装版本 | `1.0.4.1`，build 46 |
| 引导测试版本 | `1.0.4.1`，build 47，受保护 release |
| 后续完整安装包 | `1.0.4.1`，build 48，受保护 release |
| 应用更新渠道 | `device-test` |
| Gitee 分支 | `codex/update-device-test`，独立于默认分支 |
| 正式 `stable` 渠道 | 未发布 |

引导 APK 使用覆盖安装保留应用数据，没有执行卸载或清除数据。设备从 build 46 更新至 build 47 后继续使用原有数据。

测试发布按不可变身份递进，`release_seq` 与 Android versionCode 分别记录：

| 发布序号 | 内容 | 对应安装版本 |
| --- | --- | --- |
| 47 | 真实引导 APK 基线 | build 47 |
| 48 | 完整资源快照 | 保持 build 47 |
| 49 | 完整 APK 更新 | 目标 build 48 |

发布说明和签名渠道在 Gitee 测试分支提交，通过 Git raw 读取。公开指针使用相对路径，不包含私有服务器地址；解析后的清单继续校验签名、渠道和发布身份，制品地址由签名清单确定。

## 已完成的真机操作

| 操作 | 实际观察 |
| --- | --- |
| Gitee 认证与写入 | Git 认证写入独立测试分支成功 |
| 更新发现 | 应用显示来源为 Gitee 的新版本提示 |
| 关闭提示 | 点击右上角 `×` 后关闭，设置内版本中心仍可打开 |
| 资源下载 | 17 个真实资源对象，共 `122318510` 字节，约 `116.7 MiB`，已下载和校验 |
| 资源激活 | 重启后角色正常加载，版本中心通过 Gitee 检查显示已是最新，资源更新已生效 |
| 完整 APK 下载 | build 48 的完整 release APK 已下载，约 `620 MiB` |
| 安装权限 | 到达 Android 安装来源授权流程，授权后可继续安装 |
| 系统安装器 | 点击继续安装后到达真实 Android 系统安装器，完成覆盖安装 |
| 最终安装核验 | 系统 versionCode=48、versionName=1.0.4.1；读取实际已安装 base.apk，其 SHA-256 与签名清单的目标 APK 完全一致 |
| 更新后启动 | 角色正常加载；版本中心显示 device-test、内部构建48、内置资源和来源 Gitee，再次检查为最新版本 |

build 48 已于设备时间 2026-10-19 19:49 完成覆盖安装。初次引导由 ADB `install -r` 安装 build47，后续 build48 通过应用下载并调用 Android 系统安装器完成，未使用 ADB 安装 build48。已安装 APK 的逐字节摘要一致，排除了仅下载或仅打开安装器的情况。

未执行卸载或清除数据；既有角色、场景和第3天的存档显示保留。此处没有导出并逐字段比对全部用户数据，不能将界面观察扩大为所有存档字段完整性校验。

本轮截图保存在忽略目录 `build/update-validation/`：`device47-return-for-prompt.png`、`device47-prompt-dismissed.png`、`device47-resource-status.png`、`device47-resource-active-up-to-date.png`、`device48-final-center.png` 和 `device48-final-up-to-date.png`。截图只作为本地验收证据，不提交用户界面内容到公开仓库。

本地构建产物：

- [build 47 引导测试 APK](../../build/releases/AgentAtelierR-1.0.4.1-build47-device-test-release.apk)
- [build 48 更新测试 APK](../../build/releases/AgentAtelierR-1.0.4.1-build48-device-test-release.apk)

这些路径为本地构建输出，不代表已上传 GitHub Release 资产。

## 自动验证

本轮新增或受影响的相关测试 21 项通过，全项目 `flutter analyze --no-pub` 未发现问题。此前静态源 HTTPS、Range、If-Range、ETag、缓存和路径隔离的验收见 [服务器部署说明](SERVER_DEPLOYMENT.md)。

本地自动测试验证协议和状态机，以上真机记录验证实际网络、资源下载、重启激活及系统安装器衔接；两类结果不能相互替代。

## 尚未完成与使用限制

- 未观察到实际大文件下载取消再恢复的真机过程，本记录不宣称该场景已通过。
- 引导版本之前的旧客户端没有更新器，不能直接热更新至本次版本；必须完整安装一次引导 APK。本轮没有验证“早于引导版本的客户端直接跨版本更新”。
- Android 未集成二进制差分重建引擎，本轮代码更新下载完整 APK，由用户在系统安装器确认。
- Gitee Git 登录成功不等于 Release API 已授权。当前 Release API 的认证调用返回 401，没有可用的 Release API 发布凭据；本轮只写入 Git raw 渠道及说明，没有更新 Gitee Release 页面或 GitHub Release 资产。
- 本次只覆盖上述一台真机，不代表全部厂商 ROM、全部 Android 版本或后台下载策略已经验收。
- 正式 `stable` 发布、正式用户分发及 Windows 自动更新均不在本次测试完成范围内。

正式启用前仍需核实 Release API 发布凭据和目标渠道，并单独验证正式发布。测试分支与 `device-test` 渠道不能作为已经发布正式版本的依据。现有 APK 沿用原安装的调试签名以维持覆盖兼容；签名迁移必须单独安排，不能替换密钥后要求用户卸载旧版。
