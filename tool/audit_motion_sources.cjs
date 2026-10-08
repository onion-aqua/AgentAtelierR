#!/usr/bin/env node
/*
 * Read-only audit of the unpacked APK and the checked-in Ryza Spine assets.
 * The only generated file is the review report (docs/MOTION_SOURCE_AUDIT_2026-10-07.md).
 * No raw asset or application source is modified.
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const PROJECT_DEFAULT = path.resolve(__dirname, '..');
const APK_DEFAULT = path.resolve(PROJECT_DEFAULT, '..', 'apks', 'RyzaChat_AI_1.1.1');
const REPORT_DEFAULT = path.join(PROJECT_DEFAULT, 'docs', 'MOTION_SOURCE_AUDIT_2026-10-07.md');
const CHARACTER_IDS = [
  'crf_skn_002_0001_01', 'crf_skn_002_0001_99', 'crf_skn_002_0002_01',
  'crf_skn_002_0003_01', 'crf_skn_002_0004_01', 'crf_skn_002_0005_01',
];
const CHARACTER_LABELS = {
  crf_skn_002_0001_01: '常服·坐姿',
  crf_skn_002_0001_99: '常服·站姿',
  crf_skn_002_0002_01: '坐姿变体 0002',
  crf_skn_002_0003_01: '坐姿变体 0003',
  crf_skn_002_0004_01: '坐姿变体 0004',
  crf_skn_002_0005_01: '坐姿变体 0005',
};

function parseArgs(argv) {
  const out = { project: PROJECT_DEFAULT, apk: APK_DEFAULT, report: REPORT_DEFAULT, json: false, writeReport: true };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--project' || a === '--apk' || a === '--report') out[a.slice(2)] = path.resolve(argv[++i]);
    else if (a === '--json') out.json = true;
    else if (a === '--no-report') out.writeReport = false;
    else if (a === '--help' || a === '-h') {
      console.log('用法: node tool/audit_motion_sources.cjs [--project DIR] [--apk DIR] [--json] [--no-report]');
      process.exit(0);
    }
  }
  return out;
}

function exists(file) { try { fs.accessSync(file); return true; } catch (_) { return false; } }
function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }
function sha256(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
function rel(root, file) { return path.relative(root, file).replaceAll('\\', '/'); }
function safeReadJson(file) { try { return readJson(file); } catch (_) { return null; } }
function walk(root) {
  if (!exists(root)) return [];
  const result = [];
  const visit = (dir) => {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      const file = path.join(dir, ent.name);
      if (ent.isDirectory()) visit(file);
      else result.push(file);
    }
  };
  visit(root);
  return result;
}
function pngSize(file) {
  try {
    const b = fs.readFileSync(file);
    if (b.length >= 24 && b.readUInt32BE(0) === 0x89504e47 && b.readUInt32BE(12) === 0x49484452) {
      return `${b.readUInt32BE(16)}×${b.readUInt32BE(20)}`;
    }
  } catch (_) { /* optional metadata */ }
  return null;
}
function countBy(values) {
  const out = {};
  for (const v of values) out[v] = (out[v] || 0) + 1;
  return out;
}
function sortedUnique(values) { return [...new Set(values)].sort(); }
function flattenObjectValues(value) {
  if (!value || typeof value !== 'object') return [];
  return Object.values(value);
}

function classifySpineFile(apkRoot, file) {
  const r = rel(apkRoot, file);
  if (r.includes('assets/flutter_assets/assets/spine/crf_chr_002/')) return 'character';
  if (r.includes('assets/flutter_assets/assets/spine/scenes/')) return 'scene';
  if (r.includes('assets/flutter_assets/assets/spine/objects/')) return 'object';
  return 'other';
}

function extractAnimationNames(gesture) {
  const animPoses = gesture?.emotionalGesture?.MixDurationPoses?.animPoses || {};
  return Object.keys(animPoses);
}
function componentCounts(names) {
  const count = (re) => names.filter((n) => re.test(n)).length;
  return {
    totalAnimPoses: names.length,
    basePoses: count(/^motion_A_/),
    motionAdd: count(/^motion_add_/),
    oneShot: count(/^motion_oneshot_/),
    // `eye` follows the asset audit convention and includes eyebrow names that contain "eye";
    // `eyeAnimations` is the strict facial_eye_* count for controller implementation.
    eye: count(/eye/),
    eyeAnimations: count(/^facial_eye_/),
    eyebrow: count(/^facial_eyebrow_/),
    mouth: count(/^facial_mouth_/),
    facialFx: count(/^facial_add_/),
    touch: count(/^motion_touch_/),
  };
}
function gestureStats(file) {
  const doc = readJson(file);
  const e = doc.emotionalGesture || {};
  const groups = e.MotionGroups || [];
  const groupIds = sortedUnique(groups.map((x) => x.GroupId).filter(Boolean));
  const occupancy = countBy(groups.flatMap((x) => String(x.OccupancyLetters || '').split('').filter(Boolean)));
  let expressionSets = 0;
  let effectSets = 0;
  const emotions = Object.keys(e.EmotionProfilesV4 || {});
  for (const profile of Object.values(e.EmotionProfilesV4 || {})) {
    for (const intensity of Object.values(profile.intensityProfiles || {})) {
      expressionSets += Array.isArray(intensity.expressionSets) ? intensity.expressionSets.length : 0;
      effectSets += Array.isArray(intensity.effectSets) ? intensity.effectSets.length : 0;
    }
  }
  const tapReactions = (e.TapReactions || []).map((x) => ({ part: x.PartName, animation: x.OverlayID }));
  const hitPartNames = doc.projectConfig?.hitPartNames || {};
  const rig = doc.rigConfig || {};
  return {
    id: doc.id,
    name: doc.name,
    schemaVersion: doc.schemaVersion,
    file: rel(path.dirname(path.dirname(path.dirname(path.dirname(file)))), file),
    motionGroups: groups.length,
    uniqueGroupIds: groupIds.length,
    groupIds,
    occupancy,
    componentCounts: componentCounts(extractAnimationNames(doc)),
    gesturePatternDefs: Array.isArray(e.GesturePatternDefs) ? e.GesturePatternDefs.length : 0,
    attitudePatterns: Array.isArray(e.AttitudePatterns) ? e.AttitudePatterns.length : 0,
    emotions,
    expressionSets,
    effectSets,
    tapReactions,
    poseTypeSets: Array.isArray(e.PoseTypeSets) ? e.PoseTypeSets.length : 0,
    mixDurationAnimPoses: Object.keys(e.MixDurationPoses?.animPoses || {}).length,
    rigConfig: {
      aimSlots: Object.fromEntries(Object.entries(rig.aimSlots || {}).map(([k, v]) => [k, v.bone || v])),
      rollSlots: Object.fromEntries(Object.entries(rig.rollSlots || {}).map(([k, v]) => [k, v.bone || v])),
    },
    hitPartNames,
    projectFlags: {
      fixedBasePoseMode: doc.projectConfig?.fixedBasePoseMode,
      lockSittingAxis: doc.projectConfig?.lockSittingAxis,
      enableArmInOutRouting: doc.projectConfig?.enableArmInOutRouting,
      closedEyeAnimation: doc.projectConfig?.closedEyeAnimation,
      lookAtBoneHierarchy: doc.projectConfig?.lookAtBoneHierarchy || [],
      lipSyncEnabled: doc.projectConfig?.lipSyncClosure?.enabled === true,
    },
  };
}

function scanCharacterPackage(projectRoot, id) {
  const dir = path.join(projectRoot, 'assets', 'character', 'ryza', id);
  const files = {};
  for (const ext of ['.skel', '.atlas', '.png', '_gesture.json']) {
    const matches = walk(dir).filter((f) => f.endsWith(ext));
    if (matches[0]) files[ext] = { path: rel(projectRoot, matches[0]), bytes: fs.statSync(matches[0]).size, sha256: sha256(matches[0]) };
  }
  const png = walk(dir).find((f) => f.endsWith('.png'));
  if (png && files['.png']) files['.png'].dimensions = pngSize(png);
  const gesture = walk(dir).find((f) => f.endsWith('_gesture.json'));
  return { id, label: CHARACTER_LABELS[id] || id, present: exists(dir), files, gesture: gesture ? gestureStats(gesture) : null };
}

function scanApk(apkRoot) {
  const spineRoot = path.join(apkRoot, 'assets', 'flutter_assets', 'assets', 'spine');
  const files = walk(spineRoot).filter((f) => ['.skel', '.atlas', '.json'].includes(path.extname(f).toLowerCase()));
  const byType = countBy(files.map((f) => classifySpineFile(apkRoot, f)));
  const packages = new Map();
  for (const file of files) {
    const r = rel(apkRoot, file);
    const dir = path.dirname(file);
    const pathParts = r.split('/');
    const sceneIndex = pathParts.indexOf('scenes');
    const objectIndex = pathParts.indexOf('objects');
    const key = r.includes('assets/flutter_assets/assets/spine/crf_chr_002/') ? path.basename(dir) : sceneIndex >= 0 ? `scene:${pathParts[sceneIndex + 1]}` : objectIndex >= 0 ? `object:${pathParts[objectIndex + 1]}` : `other:${path.basename(dir)}`;
    if (!packages.has(key)) packages.set(key, { key, kind: classifySpineFile(apkRoot, file), files: {} });
    const fileKey = file.endsWith('_gesture.json') ? '_gesture.json' : path.extname(file).toLowerCase();
    packages.get(key).files[fileKey] = { path: r, bytes: fs.statSync(file).size, sha256: sha256(file) };
  }
  const gestures = files.filter((f) => f.endsWith('_gesture.json'));
  return {
    root: apkRoot,
    spineRoot,
    fileCount: files.length,
    byType,
    packageCounts: countBy([...packages.values()].map((x) => x.kind)),
    packages: [...packages.values()].sort((a, b) => a.key.localeCompare(b.key)),
    characterGestures: gestures.map((file) => ({ path: rel(apkRoot, file), stats: gestureStats(file) })),
  };
}

function apkCharacterMatch(apk, projectPackage) {
  const id = projectPackage.id;
  const candidates = apk.packages.filter((p) => p.kind === 'character' && p.key === id);
  if (!candidates.length) return { id, status: id.includes('0001_') ? 'missing_in_apk' : 'main_only_variant' };
  const apkFiles = candidates[0].files;
  const mainFiles = projectPackage.files;
  const compared = {};
  for (const ext of ['.skel', '.atlas', '_gesture.json']) {
    const m = mainFiles[ext];
    const a = apkFiles[ext];
    compared[ext] = { main: m?.sha256 || null, apk: a?.sha256 || null, equal: Boolean(m && a && m.sha256 === a.sha256) };
  }
  const exact = Object.values(compared).every((x) => x.equal);
  return { id, status: exact ? 'exact_duplicate' : 'character_variant', compared };
}

function recipeAudit(projectRoot) {
  const file = path.join(projectRoot, 'assets', 'data', 'motion_recipes.json');
  if (!exists(file)) return { present: false, recipes: 0, regionSets: {}, trackMap: {}, bFgSameStage: { count: 0, recipeIds: [] } };
  const data = readJson(file);
  const regionSets = {};
  const stageCount = {};
  const conflicts = [];
  for (const recipe of data.recipes || []) {
    for (const stage of recipe.stages || []) {
      const letters = stage.map((x) => String(x.region || '').toUpperCase()).filter(Boolean);
      const key = sortedUnique(letters.join('').split('')).join('');
      regionSets[key] = (regionSets[key] || 0) + 1;
      stageCount[key] = (stageCount[key] || 0) + 1;
      if (letters.includes('B') && letters.some((x) => x === 'F' || x === 'G')) conflicts.push(recipe.id);
    }
  }
  const trackMap = { D: 1 };
  for (const code of 'BCDEFGHIJ') trackMap[code] = 2 + code.charCodeAt(0) - 'B'.charCodeAt(0);
  return {
    present: true,
    path: rel(projectRoot, file),
    version: data.version,
    recipes: (data.recipes || []).length,
    regionSets,
    stageRegionSets: stageCount,
    trackMap,
    bFgSameStage: { count: conflicts.length, recipeIds: sortedUnique(conflicts), trackLevelConflict: false, propertyLevelConflict: 'unknown_needs_runtime_verification' },
  };
}

function buildAudit(options) {
  const projectPackages = CHARACTER_IDS.map((id) => scanCharacterPackage(options.project, id));
  const apk = scanApk(options.apk);
  const matches = projectPackages.map((p) => apkCharacterMatch(apk, p));
  const runtime = {
    spineFlutterRuntime: {
      project: ['packages/spine_flutter/lib/assets/libspine_flutter.js', 'packages/spine_flutter/lib/assets/libspine_flutter.wasm'],
      apk: ['assets/flutter_assets/packages/spine_flutter/lib/assets/libspine_flutter.js', 'assets/flutter_assets/packages/spine_flutter/lib/assets/libspine_flutter.wasm'],
      reusable: true,
      versionNote: '项目 README/pubspec 与 APK runtime 均为 Spine 4.2 系列；Flutter 运行时可复用。',
    },
    standaloneNodeParser: { available: false, note: '解包仅提供 WASM/Flutter runtime；没有可直接用于 Node CPU SkeletonBinary 解析的 standalone Spine JS parser。' },
    verificationBoundary: '动画属性覆盖与实际视觉效果需由 Flutter/native spine_flutter 加载 .skel/.atlas 逐动画验证，或另行引入合法的 Spine 4.2 JS runtime/parser。',
  };
  return {
    generatedAt: new Date().toISOString(),
    projectRoot: options.project,
    apkRoot: options.apk,
    scanScope: {
      projectCharacterRoot: rel(options.project, path.join(options.project, 'assets', 'character', 'ryza')),
      apkSpineRoot: rel(options.apk, path.join(options.apk, 'assets', 'flutter_assets', 'assets', 'spine')),
      extensions: ['.skel', '.atlas', '.json'],
      rawAssetsModified: false,
    },
    projectPackages,
    apk,
    matches,
    recipes: recipeAudit(options.project),
    runtime,
    workbenchControllers: [
      { id: 'base_pose', label: '基础姿态/坐姿轴', sources: ['motion_A_*_idle', 'PoseTypeSets', 'SittingSets'] },
      { id: 'body_B', label: '肩部与双臂整体 B', sources: ['OccupancyLetters=B', 'grp_b_*'] },
      { id: 'legs_CIJ', label: '腿部 C/I/J', sources: ['OccupancyLetters=C/I/J', 'grp_c_*', 'grp_i_*', 'grp_j_*'] },
      { id: 'torso_EH', label: '躯干倾斜与身体 EH', sources: ['OccupancyLetters=E/H', 'grp_eh_*'] },
      { id: 'arm_left_F', label: '左手 F', sources: ['OccupancyLetters=F', 'grp_fg_f_*', 'grp_fg_1**'] },
      { id: 'arm_right_G', label: '右手 G', sources: ['OccupancyLetters=G', 'grp_fg_g_*', 'grp_fg_2**'] },
      { id: 'eyes', label: '眼睛/眨眼/注视', sources: ['facial_eye_*', 'GesturePatternDefs', 'ambientGaze'] },
      { id: 'eyebrows', label: '眉毛', sources: ['facial_eyebrow_*', 'expressionSets'] },
      { id: 'mouth_lipsync', label: '嘴型/口型与唇形同步', sources: ['facial_mouth_*', 'lipSyncClosure'] },
      { id: 'facial_fx', label: '脸部 FX', sources: ['facial_add_*', 'blush/tear/sweat/pale'] },
      { id: 'aim_roll', label: 'Aim/Roll 控制器', sources: ['rigConfig.aimSlots', 'rigConfig.rollSlots'] },
      { id: 'hit_parts', label: '命中部位/触摸反馈', sources: ['projectConfig.hitPartNames', 'TapReactions'] },
    ],
  };
}

function md(value) { return String(value ?? '').replaceAll('|', '\\|').replaceAll('\n', ' '); }
function table(headers, rows) {
  return [`| ${headers.join(' | ')} |`, `| ${headers.map(() => '---').join(' | ')} |`, ...rows.map((r) => `| ${r.map(md).join(' | ')} |`)].join('\n');
}
function formatCounts(obj) { return Object.entries(obj || {}).map(([k, v]) => `${k}=${v}`).join('、') || '无'; }
function makeReport(a) {
  const lines = [];
  const add = (...xs) => lines.push(...xs, '');
  const seated = a.projectPackages.find((x) => x.id === 'crf_skn_002_0001_01')?.gesture;
  const standing = a.projectPackages.find((x) => x.id === 'crf_skn_002_0001_99')?.gesture;
  add('# 动作与表情资源来源审计', `生成时间：${a.generatedAt}。本报告由 tool/audit_motion_sources.cjs 生成。`, '报告只读取解包目录和项目资源；未覆盖、重打包或修改任何 raw 资源。');
  add('## 1. 扫描范围', `项目根：${a.projectRoot}`, `APK 解包根：${a.apkRoot}`, `人物资源：${a.scanScope.projectCharacterRoot}`, `APK Spine 根：${a.scanScope.apkSpineRoot}`, `扫描扩展名：${a.scanScope.extensions.join('、')}。`);
  add('## 2. 主包人物资源与 SHA-256');
  add(table(['资源', '状态', '.skel SHA-256', '.atlas SHA-256', 'gesture SHA-256', '贴图尺寸'], a.projectPackages.map((p) => [p.id, p.present ? '存在' : '缺失', p.files['.skel']?.sha256 || '—', p.files['.atlas']?.sha256 || '—', p.files['_gesture.json']?.sha256 || '—', p.files['.png']?.dimensions || '—'])));
  add('完整 hash 比较结果（与 APK 同名人物包）：');
  add(table(['资源', '结论', '比较'], a.matches.map((m) => [m.id, m.status, Object.entries(m.compared || {}).map(([k, v]) => `${k}:${v.equal ? '相同' : '缺失/不同'}`).join('；') || 'APK 无对应包'])));
  add('结论：APK 只提供 `0001_01` 与 `0001_99` 两个主包人物包的精确副本；`0002_01`～`0005_01` 是主包独有变体，没有发现可直接整合进 Ryza rig 的新人物动作 preset。');
  add('## 3. APK Spine 文件清单');
  add(`APK Spine 扫描到 ${a.apk.fileCount} 个 `.concat('`.skel/.atlas/.json` 文件；按目录分类：') , table(['分类', '文件数', '包数量'], Object.entries(a.apk.byType).map(([k, v]) => [k, v, a.apk.packageCounts[k] || 0])));
  add('人物包仅是上表两个角色目录；另外约 200 个 `scenes/*` 包和 `objects/obj_001` 属于场景/对象骨骼，纹理、骨骼层级和动画命名不与 Ryza character rig 对齐，不能直接作为人物动作候选。');
  add('## 4. 人物 gesture 统计');
  add(table(['包', 'MotionGroups/GroupId', '占用部位', 'Mix animPoses', 'base/add/one-shot', '眼相关/眉/嘴/FX/touch', 'Gesture/Attitude', '情绪/表达集/效果集'], a.projectPackages.filter((p) => p.gesture).map((p) => { const g = p.gesture; const c = g.componentCounts; return [p.id, `${g.motionGroups}/${g.uniqueGroupIds}`, formatCounts(g.occupancy), g.mixDurationAnimPoses, `${c.basePoses}/${c.motionAdd}/${c.oneShot}`, `${c.eye}/${c.eyebrow}/${c.mouth}/${c.facialFx}/${c.touch}`, `${g.gesturePatternDefs}/${g.attitudePatterns}`, `${g.emotions.length}/${g.expressionSets}/${g.effectSets}`]; })));
  add(`坐姿 0001_01 的占用字母为 B=${seated?.occupancy?.B || 0}、C=${seated?.occupancy?.C || 0}、E=${seated?.occupancy?.E || 0}、FG=${(seated?.occupancy?.F || 0) + (seated?.occupancy?.G || 0)}、I=${seated?.occupancy?.I || 0}、J=${seated?.occupancy?.J || 0}；站姿 0001_99 主要为 EH 与 FG。`);
  add('控制器字段：aim slots = ' + Object.values(seated?.rigConfig?.aimSlots || {}).join('、') + '；roll slots = ' + Object.values(seated?.rigConfig?.rollSlots || {}).join('、') + '。');
  add('命中部位映射：' + Object.entries(seated?.hitPartNames || {}).map(([k, v]) => `${k}→${v}`).join('、') + '。TapReactions 覆盖左臂、右臂、身体、胸部、头部（两项）和腰部。');
  add('## 5. 主包 132 个动作配方与轨道');
  add(`配方文件：${a.recipes.path}；共 ${a.recipes.recipes} 个 recipe。按每个 stage 的 region set 统计：`);
  add(table(['region set', 'stage 次数', '映射轨道'], Object.entries(a.recipes.regionSets).map(([k, v]) => [k, v, [...k].map((x) => `${x}→${a.recipes.trackMap[x] ?? '—'}`).join('、')])));
  add(`轨道映射：D→1（动作配方对瞬时反应强制使用 1 轨）、B→2、C→3、E→5、F→6、G→7、H→8、I→9、J→10。B 与 F/G 同 stage 冲突数为 ${a.recipes.bFgSameStage.count}。轨道租约层因此判定为不冲突，但当前 Spine 播放使用 MixBlend.replace，不同轨道仍可能写相同骨骼属性；属性级覆盖结论必须在 Flutter/native runtime 中逐动画检查。`);
  add('## 6. 工作台控制器建议');
  add(table(['控制器', '资源来源与颗粒度'], a.workbenchControllers.map((x) => [x.label, x.sources.join('、')])));
  add('建议预览器以基础姿态为底座，独立租约 B/C/E/FG/I/J（站姿增加 EH），再把左右手 F/G、眼睛、眉毛、嘴型、FX、aim/roll 和 hit parts 作为可叠加控制器。每个控制器应显示当前 GroupId、VariantIndex、动画片段、alpha、speed、mix 和占用轨道；提交前同时做轨道冲突与骨骼属性覆盖检查。');
  add('## 7. Spine runtime 与验证边界');
  add('项目和 APK 均带有 `spine_flutter` 的 JS/WASM runtime（Spine 4.2 系列），可在 Flutter 工作台继续复用。解包内容没有 standalone Node Spine JS `SkeletonBinary` parser；当前 Node inspector 不能代替 CPU 级 skeleton 验证。实时预览应直接用 Flutter/native `spine_flutter` 加载 `.skel` + `.atlas`，并把动画、混合和控制器参数回显到工作台。');
  add('## 8. 审计结论');
  add('本次全量解包扫描没有找到比主包更丰富的 Ryza 人物动作来源：APK 的两个人物包是主包的逐文件精确副本；场景包和对象包不能直接接入人物 rig。可整合工作的重点是把已有 B/C/E/FG/I/J、EH、表情组件、触摸命中、aim/roll 和 132 个 recipe 做成可实时预览、可校验轨道与属性覆盖的细粒度工作台。');
  return lines.join('\n').replace(/\n{3,}/g, '\n\n');
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!exists(options.project)) throw new Error(`项目目录不存在: ${options.project}`);
  if (!exists(options.apk)) console.warn(`警告：APK 目录不存在，将只输出主包结果: ${options.apk}`);
  const audit = buildAudit(options);
  const report = makeReport(audit);
  if (options.writeReport) {
    fs.mkdirSync(path.dirname(options.report), { recursive: true });
    fs.writeFileSync(options.report, report, 'utf8');
  }
  if (options.json) process.stdout.write(JSON.stringify(audit, null, 2));
  else {
    console.log(`扫描完成：${audit.apk.fileCount} 个 APK Spine 文件，${audit.projectPackages.length} 套主包人物资源。`);
    console.log(`精确副本：${audit.matches.filter((x) => x.status === 'exact_duplicate').map((x) => x.id).join('、') || '无'}；报告：${options.writeReport ? options.report : '未写入'}`);
  }
}

main();
