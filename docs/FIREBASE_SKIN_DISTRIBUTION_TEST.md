# Firebase 皮肤资源分发测试流程

## 目的

验证 Firebase Storage 中的 Spine 皮肤资源是否可以正常枚举、下载、校验和解压，并确认资源结构能够被当前 Spine 4.2 运行时使用。

本流程只验证资源分发链路，不等同于验证 App 内的购买、订阅、所有权同步和皮肤切换流程。

## 当前资源结构

扫描前缀：`spine/`

```text
spine/
└── crf_chr_002/
    ├── crf_skn_002_0001_01/
    │   ├── r1.zip
    │   └── r2.zip
    ├── crf_skn_002_0001_99/
    │   ├── r1.zip
    │   └── r2.zip
    ├── crf_skn_002_0002_01/
    │   ├── r2.zip
    │   └── r3.zip
    ├── crf_skn_002_0003_01/
    │   ├── r2.zip
    │   └── r3.zip
    ├── crf_skn_002_0004_01/
    │   ├── r2.zip
    │   └── r4.zip
    └── crf_skn_002_0005_01/
        ├── card_r1.png
        ├── card_r3.png
        ├── r1.zip
        └── r3.zip
```

截至 2026-09-23：

- Firebase 对象总数：14
- ZIP：12
- PNG 卡面：2
- 皮肤目录：6
- `spine/` 下只有 `crf_chr_002/` 一个角色目录

12 个 ZIP 并不代表 12 套皮肤。当前是 6 套皮肤各保留两个 revision。

## 最新版本规则

同一皮肤目录中的 `rN.zip` 表示资源修订版本。选择数字最大的 revision：

| 皮肤 ID | 当前最新资源 |
| --- | --- |
| `crf_skn_002_0001_01` | `r2.zip` |
| `crf_skn_002_0001_99` | `r2.zip` |
| `crf_skn_002_0002_01` | `r3.zip` |
| `crf_skn_002_0003_01` | `r3.zip` |
| `crf_skn_002_0004_01` | `r4.zip` |
| `crf_skn_002_0005_01` | `r3.zip` |

不要仅凭 Storage 中存在新 revision 就认为 App 会自动使用它。App 最终下载哪个文件由主数据中的 `asset.archive.path`、`bytes` 和 `sha256` 决定。

## 执行流程

### 1. 扫描对象

使用 Firebase Storage JSON API，并设置 `prefix=spine/`：

```text
GET https://firebasestorage.googleapis.com/v0/b/{bucket}/o
    ?prefix=spine%2F
    &maxResults=1000
```

要求：

1. 处理 `nextPageToken`，不能假定所有对象都在第一页。
2. 记录对象名，不输出 `downloadTokens`。
3. 按角色目录、皮肤目录和文件扩展名统计。
4. 对每套皮肤解析 `rN.zip`，选取最大的 `N`。

整个 bucket 的无前缀枚举可能返回 `403 Permission denied`。这不影响使用允许访问的 `spine/` 前缀进行测试。

### 2. 获取单个对象元数据

对目标对象请求元数据：

```text
GET https://firebasestorage.googleapis.com/v0/b/{bucket}/o/{encoded-object-path}
```

至少读取：

- `name`
- `size`
- `md5Hash`
- `contentType`
- `generation`
- `updated`

如果下载依赖 `downloadTokens`，只在进程内存中使用，不打印、不保存到报告、不提交 Git。

### 3. 下载最新资源

每次测试使用独立目录：

```text
firebase_distribution_test_YYYY-MM-DD/
```

下载要求：

1. 不复用上一次测试的 ZIP。
2. 只下载需要验证的最新 revision，避免重复下载旧版本。
3. 记录 HTTP 状态码和耗时。
4. 下载完成后立即比较实际字节数与 Firebase `size`。
5. 计算本地 MD5，与 Firebase `md5Hash` 比较。
6. 额外计算 SHA-256，供 App 主数据发布使用。

下载成功的最低条件：

```text
HTTP = 200
实际字节数 = Firebase size
本地 MD5 = Firebase md5Hash
```

### 4. 安全解压

解压前逐个检查 ZIP entry 的规范化绝对路径。所有 entry 必须位于目标解压目录内，避免 `../` 路径穿越。

每个皮肤包预期恰好包含：

```text
{skin_id}.atlas
{skin_id}.png
{skin_id}.skel
{skin_id}_gesture.json
```

### 5. 内容校验

对每个解压后的资源包检查：

1. `.atlas`、`.png`、`.skel` 和 `_gesture.json` 各一个。
2. Atlas 引用的纹理文件名与实际 PNG 文件名一致。
3. `.skel` 中的 Spine 导出版本为 `4.2.43`。
4. Gesture JSON 能够解析。
5. `emotionalGesture.MotionGroups` 当前应为 140 组。
6. 不存在额外文件或缺失文件。

Gesture JSON 中可能存在空字符串属性名。PowerShell 应使用：

```powershell
ConvertFrom-Json -Depth 100 -AsHashTable
```

否则会出现解析器错误，但这不表示 JSON 文件损坏。

### 6. 检查 App 主数据

已安装的正式版 App 包名：

```text
ai.gospiral.atelierryza
```

主数据缓存位置：

```text
/data/user/0/ai.gospiral.atelierryza/files/masters_bundle.json
```

正式版不可使用普通 `run-as`。在允许 root 的测试模拟器上，可临时运行：

```powershell
adb root
adb wait-for-device
adb exec-out cat /data/user/0/ai.gospiral.atelierryza/files/masters_bundle.json
adb unroot
```

只读取以下字段：

```text
bundle.skins[].id
bundle.skins[].asset.archive.path
bundle.skins[].asset.archive.bytes
bundle.skins[].asset.archive.sha256
bundle.skins[].asset.files
```

测试结束必须执行 `adb unroot`，不要修改 App 账号、购买状态、配置或缓存。

## 2026-09-23 验证结果

测试目录：

```text
C:\Users\cheny\Desktop\RyzaChat_AI_1.0.3_\firebase_distribution_test_2026-09-23
```

| Firebase 对象 | HTTP | 字节数 | MD5 | SHA-256 |
| --- | ---: | ---: | --- | --- |
| `crf_skn_002_0002_01/r3.zip` | 200 | 9,856,551 | 通过 | `7747d79dbe8746cacb74357199a51fc83fe5b27613bc417a899263055ce1ae33` |
| `crf_skn_002_0003_01/r3.zip` | 200 | 9,507,657 | 通过 | `5c29e9387c535788e9985208273a28426446e3e03a9d01cc405c0497c1ca54c0` |
| `crf_skn_002_0004_01/r4.zip` | 200 | 10,546,263 | 通过 | `49c3e5aeba438b7a0c22eb5d03732a6be023000923b7edcd09e787e60925a0f7` |
| `crf_skn_002_0005_01/r3.zip` | 200 | 9,726,319 | 通过 | `3ab66ba12656ae0a472a6062f4b3e68c82e9f3683be13e7693a550355d1cf6de` |

四个包均通过以下检查：

- 文件大小与 Firebase 元数据一致
- Firebase MD5 一致
- ZIP 可完整解压
- 每包恰好四个 Spine 资源文件
- Spine 版本为 4.2.43
- Gesture JSON 可解析，含 140 个动作组
- Atlas 与纹理文件匹配
- 无 ZIP 路径穿越

## 发布前检查清单

- [ ] 新 ZIP 已上传到新的 revision 路径，未覆盖正在使用的旧对象
- [ ] Firebase 元数据请求返回 200
- [ ] 实际下载返回 200
- [ ] 大小和 MD5 校验通过
- [ ] ZIP 路径安全检查通过
- [ ] 四个必需文件齐全
- [ ] Spine 版本与运行时兼容
- [ ] Gesture JSON 可解析
- [ ] Atlas 引用正确
- [ ] 主数据已更新为新 `path`、`bytes` 和 `sha256`
- [ ] 主数据版本或 ETag 已变化
- [ ] App 清除或刷新旧主数据缓存后能获取新 revision
- [ ] App 内完成一次“主数据同步 -> 下载 -> 校验 -> 解压 -> 加载 -> 切换”端到端验证

## 判断标准

资源文件下载和内容检查全部通过，只能得出“Firebase Storage 分发正常”。

只有 App 主数据已经指向新 revision，并在真实客户端完成下载和加载，才能得出“App 热更新资源链路正常”。
