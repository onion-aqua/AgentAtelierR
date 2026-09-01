# LLMAtelier 资源接入、版权边界与构建指南

## 1. 发布范围

这个仓库只发布 Flutter/Dart、Android/Windows 工程代码、测试和实现文档。下列内容被 `.gitignore` 强制排除：

- 游戏或应用 APK 解包文件；
- 原版角色图片、头像、服装预览和背景图；
- 原版配音、BGM、环境音、音效和闹钟音频；
- Spine `.skel`、`.atlas`、纹理和动作配置；
- 下载皮肤、付费内容、服务端资源和第三方模型；
- API Key、签名证书、`local.properties` 与本机配置；
- APK/AAB、构建缓存和生成文件。

仓库中的资源文件名和路径只描述代码接口。它们不是资源下载清单，也不表示这些内容可以从原应用提取或重新分发。

## 2. 使用资源前的许可检查

推荐使用自制资源、明确允许再分发的 CC0/CC BY 资源，或你通过书面授权取得的资源。使用前至少确认：

1. 许可覆盖修改、应用内使用和目标发布方式；
2. 商用、署名、同人创作和衍生作品限制；
3. 音频中的表演者、角色声音和声音克隆授权；
4. Spine Runtime 与 Spine Editor 的许可要求；
5. 资源是否允许进入公开 Git 仓库。

不要因为能够从本地 APK、缓存或下载目录中读取文件，就推定拥有再分发权。对许可不确定时，不要上传。

## 3. 当前故意缺失的资源

以下文件是现有代码会查找的接口位置。请用你有权使用的同格式资源替换；文件名可以改，但必须同步修改 `lib/` 中的路径和映射。

### 3.1 角色 Spine 与动作配置

每套可运行角色至少需要 `.skel`、`.atlas`、图集纹理 `.png` 和动作映射 JSON：

```text
assets/character/ryza/crf_skn_002_0001_01.skel
assets/character/ryza/crf_skn_002_0001_01.atlas
assets/character/ryza/crf_skn_002_0001_01.png
assets/character/ryza/crf_skn_002_0001_01/crf_skn_002_0001_01.skel
assets/character/ryza/crf_skn_002_0001_01/crf_skn_002_0001_01.atlas
assets/character/ryza/crf_skn_002_0001_01/crf_skn_002_0001_01.png
assets/character/ryza/crf_skn_002_0001_01/crf_skn_002_0001_01_gesture.json
assets/character/ryza/crf_skn_002_0001_99/crf_skn_002_0001_99.skel
assets/character/ryza/crf_skn_002_0001_99/crf_skn_002_0001_99.atlas
assets/character/ryza/crf_skn_002_0001_99/crf_skn_002_0001_99.png
assets/character/ryza/crf_skn_002_0001_99/crf_skn_002_0001_99_gesture.json
```

服装 `crf_skn_002_0002_01`、`crf_skn_002_0003_01`、`crf_skn_002_0004_01` 在当前代码中只有候选入口，没有完整模型。若要启用，每套也必须提供同名 `.skel/.atlas/.png/_gesture.json` 四件套，并在 `lib/src/character_appearance.dart` 中把 `available` 条件改为真实文件探测结果。

这些历史兼容文件名可能指向第三方 IP。公开发行时，推荐改成自己的角色 ID，例如 `assets/character/custom/default/`，并同步替换角色名称、提示词和 UI 文案。

### 3.2 角色、服装与界面图片

```text
assets/images/dark_radial_background.png
assets/images/talk_background.png
assets/images/skins/crf_skn_002_0001_01.png
assets/images/skins/crf_skn_002_0001_99.png
assets/images/skins/crf_skn_002_0002_01.png
assets/images/skins/crf_skn_002_0003_01.png
assets/images/skins/crf_skn_002_0004_01.png
assets/welcome_mission/bg.jpg
```

头像目录为 `assets/images/chara_icons/`。现有映射会查找以下文件：

```text
agate.png alberta.png ampel.png anna.png boos.png cassandra.png
claudia.png clifford.png deadra.png dennis.png dian.png dort.png
federica.png fee.png fressa.png kala.png karl.png kilo.png korou.png
lent.png lila.png lumber.png mio.png mob_profile.png moritz.png
patrizia.png romy.png ruberto.png ryza.png samuel.png saverio.png
serri.png tao.png user_profile.png volker.png zephine.png
```

不需要全部角色时，应删除相应映射，而不是放入无权使用的占位素材。

### 3.3 场景 Spine

四个时段分别使用 `mor`、`aft`、`eve`、`ngt`：

```text
assets/scenes/stage_00_000_00_mor/stage_00_000_00_mor.json
assets/scenes/stage_00_000_00_mor/spine/stage_00_000_00_mor.skel
assets/scenes/stage_00_000_00_mor/spine/stage_00_000_00_mor.atlas
assets/scenes/stage_00_000_00_mor/spine/stage_00_000_00_mor.png
```

将 `mor` 依次替换为 `aft`、`eve`、`ngt`，即可得到另外 12 个缺失文件名。场景 JSON 是动作/缩放配置，同样不要复制原版文件；请为自己的场景重新编写。

### 3.4 地图

```text
assets/world_map/world_hierarchy.json
assets/world_map/npc_placement.json
assets/world_map/areas/area_01.jpg
assets/world_map/areas/area_02.jpg
assets/world_map/areas/area_03.jpg
assets/world_map/areas/area_04.jpg
assets/world_map/areas/area_05.jpg
```

两个 JSON 的 ID、区域层级、坐标和图片名必须一致。制作新世界观时，应重写数据，不要复制游戏地图和人物配置。

### 3.5 音频

```text
assets/audio/tap_01.m4a
assets/audio/tap_02.m4a
assets/audio/tap_03.m4a
assets/audio/alarm/alarm_ring.m4a
assets/audio/se/se_skin_change.m4a
assets/audio/soundscape/ambient_day.m4a
assets/audio/soundscape/ambient_night.m4a
assets/audio/soundscape/bgm_opening.m4a
```

点击语音目录为 `assets/audio/tap_voice/jp/normal/`。代码会查找 `jp_normal_motion_touch_A_001_01.m4a` 到 `A_007_03.m4a`：组号 `001..007`，每组尾号 `01..03`，共 21 个文件。可以改用自制语音，并同步更新 `lib/src/tap_reaction.dart`。

TTS 生成内容也必须获得声音权利人的授权，不能未经同意模仿特定演员或角色声音。

## 4. 放入合法资源

1. 将资源放到上面的对应目录，保持大小写一致。
2. 检查 `.atlas` 内引用的纹理文件名与实际 PNG 一致。
3. 确认 Spine 导出版本与 `spine_flutter 4.2.36` 兼容；当前接口按 Spine 4.2 设计。
4. 动作映射 JSON 必须引用骨骼文件中真实存在的动画、皮肤和轨道。
5. 图片建议使用 PNG/JPG；音频按当前实现使用 M4A。若改格式，同步修改代码路径。
6. 不要修改 `.gitignore` 来上传受限资源。合法但不允许公开的资源应只保存在本地。
7. 使用 `git status --ignored` 确认资源处于 ignored 状态，再提交代码。

## 5. API 配置

OpenAI 兼容接口和 Fish Audio Key 通过应用设置页填写，由平台安全存储保存，不写入仓库，也不会进入本地备份 JSON。不要把 Key 写入 Dart 常量、测试快照、截图或 Issue。

高级推理参数只对模型名以 `gpt-5` 开头的模型开放。兼容服务需要支持 `reasoning_effort`、`max_completion_tokens` 和标准 Chat Completions `tools/tool_calls`；否则应关闭对应选项。

## 6. 构建

环境要求：Flutter 3.47 或兼容版本、Dart 3.13、JDK 17、Android SDK 37（或与 `android/app/build.gradle.kts` 中 `compileSdk` 一致的版本）以及已接受的 Android SDK 许可。

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Debug APK 默认输出到 `build/app/outputs/flutter-apk/app-debug.apk`。

发布版签名未配置。若将来发布，必须先完成资源许可、隐私政策、商店合规、安全审计和独立签名配置，且不得把签名文件提交到 Git。

## 7. 资源接入验收

- `flutter analyze` 无错误；
- `flutter test` 全部通过；
- 启动页、聊天背景、头像和地图没有 `Unable to load asset`；
- 每套 Spine 的默认 idle、说话、表情、点击与组合动作均能播放；
- 组合动作没有手部扭曲、轨道残留或材质错位；
- 切换服装后纹理、骨骼和动作映射来自同一套资源；
- TTS、BGM、环境音、点击语音和闹钟分别测试；
- 断网、空 Key、接口错误和资源缺失时应用能显示可理解的降级状态；
- `git status` 中不存在图片、音频、模型、密钥、APK 或解包文件。

## 8. 可复制的 Skill 提示词

以下提示词可交给 Codex 或其他编码 Agent。它要求 Agent 只接入用户明确有权使用的本地资源，并保持这些资源不进入 Git。

```text
你是一个负责 LLMAtelier Flutter 项目资源接入和构建的编码 Agent。

目标：把用户提供且用户确认有权使用的图片、音频、Spine 模型和配置接入本地工程，验证功能并构建 APK。不得下载、提取、补全、猜测或上传任何游戏原版、付费、泄露、缓存或版权状态不明的资源。

执行规则：
1. 先阅读 README.md、docs/RESOURCE_SETUP_AND_BUILD.md、pubspec.yaml、.gitignore 和相关 lib/src 文件。
2. 在复制任何资源前，要求用户明确确认资源来源及其使用许可。许可不清楚时停止资源复制，只提供路径和格式建议。
3. 资源只放到文档规定的 assets 路径；若使用自定义文件名，同步更新集中映射，避免在多个页面散落硬编码。
4. 不把 API Key、local.properties、签名文件、资源文件、APK/AAB 或构建缓存加入 Git。执行 git status --ignored 检查。
5. Spine 套装必须保持 skel、atlas、纹理、gesture JSON 同源且版本兼容。先解析 atlas 和动作名，再接入动作、表情、点击区域与服装切换。不得混用不同套装的骨骼或纹理。
6. 音频逐类验证：TTS、点击语音、BGM、环境音、音效、闹钟。不得未经授权克隆角色或演员声音。
7. 资源缺失时保留明确的降级 UI，不伪造成功，不使用网络上的相似素材代替。
8. 完成后依次运行 flutter pub get、flutter analyze、flutter test、flutter build apk --debug。
9. 检查 APK 路径和大小，启动模拟器验证主界面、聊天、动作、换装、音频、附件、设置和闹钟。
10. 最终报告必须列出：接入文件、许可确认依据、修改代码、测试结果、APK 路径、仍缺失资源和未验证风险。不得在报告中泄露密钥。

优先做最小、安全、可维护的修改，沿用项目现有结构；不要引入无必要依赖，不要修改远端历史，不要删除用户本地原始资源。
```

## 9. 上传前检查命令

```powershell
git status --short --ignored
git ls-files assets
git grep -n -I -E "(sk-[A-Za-z0-9]|Bearer +[A-Za-z0-9]|api[_-]?key)"
```

`git ls-files assets` 的正常结果只能包含 `assets/README.md` 与各目录的 `.gitkeep`。如出现 PNG、JPG、M4A、SKEL、ATLAS、模型或动作 JSON，立即取消暂存并调查来源。
