# 虚拟手机壁纸资源热更新

本说明记录本轮壁纸交付步骤和验收要求，不表示构建、设备安装或发布已经完成。操作使用隔离的 `device-test` 渠道；不发布正式 `stable` 渠道。服务器地址和本地签名配置使用占位值。

## 支持版本与兼容性

build 49 增加动态壁纸目录读取能力，内置发布基线序号为 50，运行时标识为 `android-wallpaper-v1`。支持 APK 中的 `assets/data/virtual_phone_wallpapers.json` 保持空目录，新增 PNG 不打入该 APK；`wallpapers/.gitkeep` 仅保证干净检出后 pubspec 引用的目录存在。

本轮通过一次保留数据的完整覆盖安装升级支持 APK，不单独发布序号 50 的渠道。之后的序号 51 清单同时引用这一份固定字节的 build 49 APK 和完整资源快照：已安装 build 49 的设备只下载所缺资源，旧运行时则先取得支持 APK，并在兼容运行时启动时激活资源。不能把序号 51 做成只有新运行时资源、没有支持 APK 的最新版，否则跳过中间版本的旧客户端无法从唯一最新渠道取得所需代码更新。

资源快照和外层发布均使用 `android-wallpaper-v1`、资源 API 1 和现有可信资源密钥标识。不要沿用旧的 `android-bootstrap-v1` 来声明尚不支持动态目录的客户端兼容，也不要因 PNG 未加密而更换角色包密钥或上传角色明文。

## 目录格式

热更新目录路径固定为 `assets/data/virtual_phone_wallpapers.json`，内容示例：

```json
{
  "schema_version": 1,
  "wallpapers": [
    {
      "id": "catalog-purple-sky",
      "name": "紫色夜空",
      "asset_path": "assets/images/virtual_phone/wallpapers/purple_sky.png"
    }
  ]
}
```

仅接受 `schema_version`、`wallpapers`，条目仅接受 `id`、`name`、`asset_path`。ID 以 `catalog-` 开头，使用小写字母、数字、点、下划线或连字符；相同壁纸长期保持相同 ID。名称为非空、无控制字符的最多 80 个 Unicode 字符，前后不能有空白。资源路径仅允许上述 wallpapers 目录内的单层 `.png` 文件名，不使用 URL、相对上级目录或任意本地路径。ID 和图片路径各自唯一，最多 64 项。

单图最多 24 MiB、边长最多 8192、像素数最多 3200 万。当前客户端预检 PNG 头与尺寸，发布前还需用实际解码器验证完整 PNG。缺失图片会跳过对应目录项，错误目录退回默认三张壁纸。

目录在启动时、资源快照激活之后读取。下载完成后需重新启动应用才显示新增壁纸。新增图片不必存在于原 APK 的 AssetManifest；`DefaultAssetBundle` 的资源覆盖会为 `Image.asset`、`AssetImage` 提供实际图片。

默认三张保持不可删除。热推目录壁纸允许本地删除，实际保存为该 ID 的隐藏记录，不删除共享资源对象；再次推送同 ID 不会强制恢复已隐藏的壁纸。导入壁纸继续使用独立的用户文件目录。正在使用的壁纸被删除时回到第一张默认壁纸。

## 生成完整快照

本轮快照必须有 **19 个资源路径**：前次序号 48 的 17 项受管理资源，加上完整壁纸目录和新 PNG。保留原 17 项的路径、大小和 hash，不能只提交新增两项，因为完整快照中省略的路径表示移除旧覆盖。后续新增其他资源时应调整预期总数，不能永久把 19 写成通用限制。

准备一个私有的完整受管理资源树，根目录下具有 `assets/`，不得混入日志、用户存档、API 配置、私钥或未经保护的角色资源。构建输出目录必须位于该输入树之外。以下命令生成本地快照，不上传、不切换渠道：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File tool/update/New-ResourceSnapshot.ps1 `
  -SourceDirectory '<COMPLETE_MANAGED_RESOURCE_TREE>' `
  -SnapshotId resources-000051 `
  -CompatibleRuntimeIds android-wallpaper-v1 `
  -AssetKeyId '<EXISTING_TRUSTED_ASSET_KEY_ID>' `
  -ObjectBaseUrl 'https://updates.example.invalid/updates/agentatelier/resources' `
  -ResourceApiVersion 1 `
  -OutputRoot '<RESOURCE_OUTPUT_ROOT>'
```

此命令不指定 `ResourcePathPrefix`，因为输入树已经包含 `assets/`。输出为 `snapshots/resources-000051/manifest.json` 和 `objects/sha256/<hash>`。对象 URL 自动追加 `/objects/sha256/<hash>`，不要再把 `objects/sha256` 放进 `ObjectBaseUrl`。

发布前比较新旧清单：旧 17 项必须全部存在，逐项 hash/size 不变；新清单目录的图片引用必须有相同路径的对象。校验支持 APK ZIP 内目录为空且无该 PNG，才能证明后续观察到的是资源热更新。

## 签名、上传与测试

外层本地发布配置应明确填写：`release_seq: 51`、`channel: device-test`、`runtime_compat_id: android-wallpaper-v1`、`resource_api_version: 1`、`apk_deltas: []`，以及真实 `target_apk` 与 `resource_snapshot`。APK 的 `version_code` 为 49，资源 `id` 为 `resources-000051`，`compatible_runtime_ids` 为 `['android-wallpaper-v1']`；`manifest_path` 指向生成的 canonical 快照，`manifest_url` 指向其 HTTPS 公开路径。发布序号与 Android versionCode 是不同字段，不互相覆盖。

使用 [发布工具说明](README.md) 中的 `New-UpdateManifest.ps1`，传入固定支持 APK 的 `-ApkPath`，在本地离线签名；再用 `Test-UpdateManifest.ps1`、`-ResourceManifestPath`、`-ResourceObjectsRoot` 和 `-RequireAllLocalArtifacts` 完整校验。APK、资源 manifest 的大小和 hash 由工具计算，不手填假值，不重新构建已签名身份对应的 APK。

通过授权 SSH 上传所有不可变制品后，按照 [服务器说明](SERVER_DEPLOYMENT.md#隔离测试渠道发布命令) 使用 `--required-channel device-test` 发布。Gitee 测试分支的相对渠道指针必须指向同一发布身份；公开 Git 元数据不写入私有服务器地址或任何凭据。

真机验收应分别记录支持 APK 安装、版本号和数据保留、资源下载及重启激活、壁纸列表新增项、选中后主页实际显示、重启后选择保留，以及删除新增壁纸后默认三张和用户导入壁纸仍在。已装支持 APK 的资源更新过程中 versionCode 应保持 49，新增 PNG 字节应与签名对象 hash 一致。未实际完成的项目保留为待验证，不以模拟测试代替。
