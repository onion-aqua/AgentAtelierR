# 动作与表情资源来源审计
生成时间：2026-10-07T11:53:15.532Z。本报告由 tool/audit_motion_sources.cjs 生成。
报告只读取解包目录和项目资源；未覆盖、重打包或修改任何 raw 资源。

## 1. 扫描范围
项目根：D:\Ryza_chat\ryza_chat_mvp
APK 解包根：D:\Ryza_chat\apks\RyzaChat_AI_1.1.1
人物资源：assets/character/ryza
APK Spine 根：assets/flutter_assets/assets/spine
扫描扩展名：.skel、.atlas、.json。

## 2. 主包人物资源与 SHA-256

| 资源 | 状态 | .skel SHA-256 | .atlas SHA-256 | gesture SHA-256 | 贴图尺寸 |
| --- | --- | --- | --- | --- | --- |
| crf_skn_002_0001_01 | 存在 | bd3228debb5d1868398f4aac903caa18b0c2f366bc841e9ea7d40d1a3d51d42e | 5a96cd52780559b25c54bbe034c7852e11920d49a7ac0cefce9122a2fa957969 | 18d55efdb357302610d77979626cbbc5c91f60808f8df5fe3706865a40a9fb33 | 4096×2660 |
| crf_skn_002_0001_99 | 存在 | 113f48eb086d115e1de9b9ee5e7e749deb3a871aec29dc58ae8f153417dbf027 | 1b8db45d378950ce2864a8c7016ce66d37fe15273a70dbbb070bd4442e021e7a | fe78d6498e90e6ad50728d2ab6e0cf0080fa5398f1c7a0031fa2a79225a7ab4b | 1692×4096 |
| crf_skn_002_0002_01 | 存在 | b76d9d7436d8b7bb25626afa6b6de629345e972948017626b8bd3d8542f33207 | 5edd649ffac53b4a072958e5796f27c39acdbd7c2128cdd8c911c484e09626f3 | a640bedfed750115ef9ff2f951e12f82d0218258c5f8588f30845d0e1770942e | 4096×2736 |
| crf_skn_002_0003_01 | 存在 | 72f973e22229cba8361e89500e68bea4556adff1d33e74a78041c8e10eadc26a | 526d73ff1d65ea6798746c99e8d8ec2940990faa2cae8c51fe1305161af46fcb | 8fea380fcefe6f778f65c2c61b27b213bfb007bb49c045d40abcce78e466425b | 4096×2728 |
| crf_skn_002_0004_01 | 存在 | f323a147ec20774f67a0fa980f1ac16f171b91698c5f94e53b9962a563367b3b | ba00feeec1eb7e31d477b3dbd72b89007afba1e4a4a09f4adf670fe380e4a645 | 17f39318ead4ed0784b9c3a5749bccb05b3ba1f362a12077d4ae559aac0cc086 | 4096×3148 |
| crf_skn_002_0005_01 | 存在 | 13484f5f490dc67d919e4c18f39f21ea2d6f807a2d4373d38aaefbf0533c96b8 | 80331ceef51b52b0b072609ee195623a13116f1bae41ec1b919c539bdc642c51 | 3bbd9beb1b8ba1d4c7bd98cc28fe2e23acb7c9de7c8c565040b6bd6428a4a7e9 | 4096×2648 |

完整 hash 比较结果（与 APK 同名人物包）：

| 资源 | 结论 | 比较 |
| --- | --- | --- |
| crf_skn_002_0001_01 | exact_duplicate | .skel:相同；.atlas:相同；_gesture.json:相同 |
| crf_skn_002_0001_99 | exact_duplicate | .skel:相同；.atlas:相同；_gesture.json:相同 |
| crf_skn_002_0002_01 | main_only_variant | APK 无对应包 |
| crf_skn_002_0003_01 | main_only_variant | APK 无对应包 |
| crf_skn_002_0004_01 | main_only_variant | APK 无对应包 |
| crf_skn_002_0005_01 | main_only_variant | APK 无对应包 |

结论：APK 只提供 `0001_01` 与 `0001_99` 两个主包人物包的精确副本；`0002_01`～`0005_01` 是主包独有变体，没有发现可直接整合进 Ryza rig 的新人物动作 preset。

## 3. APK Spine 文件清单

APK Spine 扫描到 608 个 `.skel/.atlas/.json` 文件；按目录分类：
| 分类 | 文件数 | 包数量 |
| --- | --- | --- |
| character | 6 | 2 |
| object | 2 | 1 |
| scene | 600 | 200 |

人物包仅是上表两个角色目录；另外约 200 个 `scenes/*` 包和 `objects/obj_001` 属于场景/对象骨骼，纹理、骨骼层级和动画命名不与 Ryza character rig 对齐，不能直接作为人物动作候选。

## 4. 人物 gesture 统计

| 包 | MotionGroups/GroupId | 占用部位 | Mix animPoses | base/add/one-shot | 眼相关/眉/嘴/FX/touch | Gesture/Attitude | 情绪/表达集/效果集 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| crf_skn_002_0001_01 | 140/95 | B=9、C=11、E=11、F=101、G=101、I=4、J=4 | 782 | 34/597/13 | 48/14/70/11/8 | 21/57 | 9/1646/12 |
| crf_skn_002_0001_99 | 53/53 | E=36、H=36、F=17、G=17 | 162 | 7/82/12 | 28/4/19/6/7 | 21/57 | 9/322/11 |
| crf_skn_002_0002_01 | 140/95 | B=9、C=11、E=11、F=101、G=101、I=4、J=4 | 736 | 34/537/13 | 48/14/84/11/8 | 21/57 | 9/1646/12 |
| crf_skn_002_0003_01 | 140/95 | B=9、C=11、E=11、F=101、G=101、I=4、J=4 | 736 | 34/537/13 | 48/14/84/11/8 | 21/57 | 9/1646/12 |
| crf_skn_002_0004_01 | 140/95 | B=9、C=11、E=11、F=101、G=101、I=4、J=4 | 736 | 34/537/13 | 48/14/84/11/8 | 21/57 | 9/1646/12 |
| crf_skn_002_0005_01 | 140/95 | B=9、C=11、E=11、F=101、G=101、I=4、J=4 | 736 | 34/537/13 | 48/14/84/11/8 | 21/57 | 9/1646/12 |

坐姿 0001_01 的占用字母为 B=9、C=11、E=11、FG=202、I=4、J=4；站姿 0001_99 主要为 EH 与 FG。

控制器字段：aim slots = control_aim_center、control_aim_eye、control_aim_head、control_aim_body；roll slots = control_roll_body_lower、control_roll_body_upper、control_roll_neck、control_roll_head。

命中部位映射：BB_head→head、BB_body→body、BB_arm_L→arm_l、BB_arm_R→arm_r、BB_weast→weast、BB_breast→breast。TapReactions 覆盖左臂、右臂、身体、胸部、头部（两项）和腰部。

## 5. 主包 132 个动作配方与轨道

配方文件：assets/data/motion_recipes.json；共 132 个 recipe。按每个 stage 的 region set 统计：

| region set | stage 次数 | 映射轨道 |
| --- | --- | --- |
| FG | 54 | F→6、G→7 |
| EFG | 17 | E→5、F→6、G→7 |
| B | 8 | B→2 |
| FGIJ | 1 | F→6、G→7、I→9、J→10 |
| BE | 3 | B→2、E→5 |
| D | 14 | D→1 |
| E | 17 | E→5 |
| F | 18 | F→6 |
| G | 1 | G→7 |
| EF | 16 | E→5、F→6 |
| CF | 1 | C→3、F→6 |

轨道映射：D→1（动作配方对瞬时反应强制使用 1 轨）、B→2、C→3、E→5、F→6、G→7、H→8、I→9、J→10。B 与 F/G 同 stage 冲突数为 0。轨道租约层因此判定为不冲突，但当前 Spine 播放使用 MixBlend.replace，不同轨道仍可能写相同骨骼属性；属性级覆盖结论必须在 Flutter/native runtime 中逐动画检查。

## 6. 工作台控制器建议

| 控制器 | 资源来源与颗粒度 |
| --- | --- |
| 基础姿态/坐姿轴 | motion_A_*_idle、PoseTypeSets、SittingSets |
| 肩部与双臂整体 B | OccupancyLetters=B、grp_b_* |
| 腿部 C/I/J | OccupancyLetters=C/I/J、grp_c_*、grp_i_*、grp_j_* |
| 躯干倾斜与身体 EH | OccupancyLetters=E/H、grp_eh_* |
| 左手 F | OccupancyLetters=F、grp_fg_f_*、grp_fg_1** |
| 右手 G | OccupancyLetters=G、grp_fg_g_*、grp_fg_2** |
| 眼睛/眨眼/注视 | facial_eye_*、GesturePatternDefs、ambientGaze |
| 眉毛 | facial_eyebrow_*、expressionSets |
| 嘴型/口型与唇形同步 | facial_mouth_*、lipSyncClosure |
| 脸部 FX | facial_add_*、blush/tear/sweat/pale |
| Aim/Roll 控制器 | rigConfig.aimSlots、rigConfig.rollSlots |
| 命中部位/触摸反馈 | projectConfig.hitPartNames、TapReactions |

建议预览器以基础姿态为底座，独立租约 B/C/E/FG/I/J（站姿增加 EH），再把左右手 F/G、眼睛、眉毛、嘴型、FX、aim/roll 和 hit parts 作为可叠加控制器。每个控制器应显示当前 GroupId、VariantIndex、动画片段、alpha、speed、mix 和占用轨道；提交前同时做轨道冲突与骨骼属性覆盖检查。

## 7. 扩展动作配方

`assets/data/motion_recipes_extra.json` 由 `tool/generate_motion_combinations.cjs` 从六套本地 gesture 文件确定性生成，共 **38,058** 条新配方，编号 `grp_recipe_145` 至 `grp_recipe_38202`。其中通用资源 478 条、站姿资源 778 条、坐姿资源 36,802 条，多阶段配方 980 条；与原 132 条合计 38,190 条唯一配方。

生成器只使用真实 gesture 中出现的 `motion_add_*`/`motion_oneshot_*` 动画名，按同部位、D 独占以及 B 与 F/G 的手臂交接规则过滤，并写入 `posture`、`category`、`tags` 和 `skins`。运行时先加载原目录，再 best-effort 合并扩展目录；皮肤、姿态、当前 Spine 动画存在性和轨道冲突会在播放前再次检查。规划器首轮仍只检索少量语义候选，完整配方留在本地目录，避免把数万条描述一次性放进 LLM 上下文。

## 8. Spine runtime 与验证边界

项目和 APK 均带有 `spine_flutter` 的 JS/WASM runtime（Spine 4.2 系列），可在 Flutter 工作台继续复用。解包内容没有 standalone Node Spine JS `SkeletonBinary` parser；当前 Node inspector 不能代替 CPU 级 skeleton 验证。实时预览应直接用 Flutter/native `spine_flutter` 加载 `.skel` + `.atlas`，并把动画、混合和控制器参数回显到工作台。

## 9. 审计结论

本次全量解包扫描没有找到比主包更丰富的 Ryza 人物动作来源：APK 的两个人物包是主包的逐文件精确副本；场景包和对象包不能直接接入人物 rig。可整合工作的重点是把已有 B/C/E/FG/I/J、EH、表情组件、触摸命中、aim/roll 和 132 个 recipe 做成可实时预览、可校验轨道与属性覆盖的细粒度工作台。
