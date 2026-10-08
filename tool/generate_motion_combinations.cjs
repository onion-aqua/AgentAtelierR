#!/usr/bin/env node

// Generate an optional, data-only extension to motion_recipes.json.
//
// The gesture files are the source of truth here.  We never guess an animation
// name from its number: every atom below was found in all resources listed for
// its category.  Stages are checked with the same occupancy rules used by the
// legacy importer (including the B <-> F/G arm hand-off rule).

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const CHARACTER_ROOT = path.join(ROOT, 'assets', 'character', 'ryza');
const BASE_FILE = path.join(ROOT, 'assets', 'data', 'motion_recipes.json');
const EXTRA_FILE = path.join(ROOT, 'assets', 'data', 'motion_recipes_extra.json');
const BASE_POSE = 'motion_A_001_idle';
const ANIMATION_RE = /^motion_(add|oneshot)_([B-J])_\d+_active$/;
const RESOURCE_RE = /^crf_skn_\d+_\d+_(?:01|99)$/;
// The shipped catalogue is generated from these six canonical resources.
// Additional local outfits can reuse the catalogue through baseAppearanceId;
// they must still contain every animation shared by the canonical pool, but
// they must not change the generated IDs or recipe ordering.
const CANONICAL_RESOURCE_NAMES = new Set([
  'crf_skn_002_0001_01', 'crf_skn_002_0001_99',
  'crf_skn_002_0002_01', 'crf_skn_002_0003_01',
  'crf_skn_002_0004_01', 'crf_skn_002_0005_01',
]);

const REGION_LABEL = {
  B: '上身', C: '双腿', D: '瞬间反应', E: '身体', F: '左手',
  G: '右手', H: '身体弹动', I: '左腿', J: '右腿',
};

// CharacterAppearance uses human-facing ids while gesture files use their
// asset names.  Include both forms so an imported skin that declares one of
// these built-in resources as its base can still use the generated recipe.
const APPEARANCE_ID_BY_RESOURCE = {
  crf_skn_002_0001_01: 'seated_01',
  crf_skn_002_0001_99: 'standing_99',
  crf_skn_002_0002_01: 'summer_yellow_01',
  crf_skn_002_0003_01: 'summer_black_01',
  crf_skn_002_0004_01: 'relaxed_shirt_01',
  crf_skn_002_0005_01: 'crf_skn_002_0005_01',
};

// Generate every deterministic, track-safe combination.  The planner still
// retrieves a small semantic shortlist per request, so a large catalogue does
// not become a large prompt.
const SEATED_MAX = Number.MAX_SAFE_INTEGER;
const STANDING_MAX = Number.MAX_SAFE_INTEGER;
const UNIVERSAL_MAX = Number.MAX_SAFE_INTEGER;

function die(message) {
  console.error(`generate_motion_combinations: ${message}`);
  process.exitCode = 1;
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    die(`cannot read ${path.relative(ROOT, file)}: ${error.message}`);
    return null;
  }
}

function collectAnimations(value, result = new Set()) {
  if (typeof value === 'string') {
    const matches = value.match(/motion_(?:add|oneshot)_[B-J]_\d+_active/g);
    if (matches) for (const name of matches) result.add(name);
  } else if (value && typeof value === 'object') {
    for (const child of Object.values(value)) collectAnimations(child, result);
  }
  return result;
}

function parseResource(directory) {
  const gesture = fs.readdirSync(directory).find((entry) => entry.endsWith('_gesture.json'));
  if (!gesture) return null;
  const file = path.join(directory, gesture);
  const json = readJson(file);
  if (!json) return null;
  const animations = collectAnimations(json);
  // This is deliberately based on the authored MotionGroups as well as the
  // nested one-shot/attitude definitions.  D reactions are usually absent
  // from MotionGroups but are still real skeleton animations.
  const groups = (((json || {}).emotionalGesture || {}).MotionGroups || [])
    .filter((group) => group && typeof group === 'object');
  const groupByAnimation = new Map();
  for (const group of groups) {
    for (const key of ['AnimName_1', 'AnimName_2']) {
      const name = typeof group[key] === 'string' ? group[key] : '';
      if (!ANIMATION_RE.test(name)) continue;
      const record = {
        occupancy: typeof group.OccupancyLetters === 'string' ? group.OccupancyLetters : '',
        poseIds: typeof group.ApplicablePoseIds === 'string' ? group.ApplicablePoseIds : '',
        sittingIds: typeof group.ApplicableSittingIDs === 'string' ? group.ApplicableSittingIDs : '',
      };
      if (!groupByAnimation.has(name)) groupByAnimation.set(name, []);
      groupByAnimation.get(name).push(record);
    }
  }
  return {
    name: path.basename(directory),
    file: path.relative(ROOT, file).replaceAll(path.sep, '/'),
    standing: path.basename(directory).endsWith('_99'),
    animations,
    groupByAnimation,
    source: json,
  };
}

function loadResources() {
  const entries = fs.readdirSync(CHARACTER_ROOT)
    .filter((entry) => RESOURCE_RE.test(entry))
    .map((entry) => parseResource(path.join(CHARACTER_ROOT, entry)))
    .filter(Boolean)
    .sort((a, b) => a.name.localeCompare(b.name));
  const resources = entries.filter((resource) => CANONICAL_RESOURCE_NAMES.has(resource.name));
  if (resources.length !== CANONICAL_RESOURCE_NAMES.size) {
    throw new Error(`expected six canonical readable gesture resources, found ${resources.length}`);
  }
  const canonicalAnimations = [...resources[0].animations].filter((name) =>
    resources.every((resource) => resource.animations.has(name)));
  for (const supplemental of entries.filter((resource) => !CANONICAL_RESOURCE_NAMES.has(resource.name))) {
    const missing = canonicalAnimations.filter((name) => !supplemental.animations.has(name));
    if (missing.length) {
      throw new Error(`${supplemental.name} is missing ${missing.length} canonical animations`);
    }
  }
  return resources;
}

function intersection(resources) {
  if (!resources.length) return new Set();
  return new Set([...resources[0].animations].filter((name) =>
    resources.every((resource) => resource.animations.has(name))));
}

function regionOf(name) {
  const match = ANIMATION_RE.exec(name);
  return match ? match[2] : null;
}

function layerConflict(left, right) {
  if (!left || !right) return true;
  if (left.region === right.region) return true;
  if (left.region === 'D' || right.region === 'D') return true;
  // B is the authored upper-body handoff.  It cannot share the arm tracks
  // with F/G even though those letters map to different numerical tracks.
  if (left.region === 'B' && (right.region === 'F' || right.region === 'G')) return true;
  if (right.region === 'B' && (left.region === 'F' || left.region === 'G')) return true;
  return false;
}

function stageSafe(stage) {
  if (!Array.isArray(stage) || !stage.length) return false;
  for (let i = 0; i < stage.length; i += 1) {
    for (let j = i + 1; j < stage.length; j += 1) {
      if (layerConflict(stage[i], stage[j])) return false;
    }
  }
  return stage.every((layer) =>
    typeof layer.name === 'string' && ANIMATION_RE.test(layer.name) &&
    typeof layer.region === 'string' && layer.region === regionOf(layer.name) &&
    Number.isFinite(layer.alpha) && layer.alpha > 0 && layer.alpha <= 1 &&
    Number.isFinite(layer.speed) && layer.speed > 0);
}

function layerFor(name, multi) {
  const region = regionOf(name);
  // E is a torso sway and leg channels are subtle overlays.  Keeping them
  // below one when they share a stage avoids visually drowning the hand move.
  const alpha = multi && region === 'E' ? 0.35 :
    multi && (region === 'C' || region === 'I' || region === 'J') ? 0.45 : 1;
  return { name, region, alpha, speed: 1 };
}

function stageSignature(stage) {
  return stage
    .map((layer) => `${layer.name}@${layer.alpha.toFixed(2)}@${layer.speed.toFixed(2)}`)
    .sort()
    .join('|');
}

function recipeSignature(stages) {
  return stages.map(stageSignature).join('>');
}

function stageLabel(stage) {
  return stage.map((layer) => `${REGION_LABEL[layer.region] || layer.region} ${layer.name.match(/_(\d+)_/)?.[1] || ''}`).join('＋');
}

function recipeCategory(resources, universal, seated, standing) {
  const all = resources.every((resource) => resource.animations.has(universal));
  if (all) return 'universal';
  if (seated.every((resource) => resource.animations.has(universal))) return 'seated';
  if (standing.every((resource) => resource.animations.has(universal))) return 'standing';
  return null;
}

function sortedNames(names) {
  return [...names].sort((a, b) => {
    const ra = regionOf(a);
    const rb = regionOf(b);
    if (ra !== rb) return ra.localeCompare(rb);
    return a.localeCompare(b, 'en', { numeric: true });
  });
}

function skinTokens(resources) {
  return [...new Set(resources.flatMap((resource) => [
    resource.name,
    APPEARANCE_ID_BY_RESOURCE[resource.name],
  ].filter(Boolean)))];
}

function generate(resources, base) {
  const seatedResources = resources.filter((resource) => !resource.standing);
  const standingResources = resources.filter((resource) => resource.standing);
  const sets = {
    universal: intersection(resources),
    seated: intersection(seatedResources),
    standing: intersection(standingResources),
  };
  const order = ['universal', 'standing', 'seated'];
  const limits = { universal: UNIVERSAL_MAX, standing: STANDING_MAX, seated: SEATED_MAX };
  const supported = {
    universal: resources,
    standing: standingResources,
    seated: seatedResources,
  };
  const generated = [];
  const seen = new Set(base.recipes.map((recipe) => recipeSignature(recipe.stages)));
  const perCategory = { universal: 0, standing: 0, seated: 0 };
  const skippedDuplicate = { base: seen.size, generated: 0 };
  let nextId = 145;

  function add(category, stages, reason) {
    if (perCategory[category] >= limits[category]) return false;
    if (!stages.every(stageSafe)) return false;
    const signature = recipeSignature(stages);
    if (seen.has(signature)) {
      skippedDuplicate.generated += 1;
      return false;
    }
    const names = stages.flat().map((layer) => layer.name);
    if (!names.every((name) => sets[category].has(name))) return false;
    seen.add(signature);
    const stageNames = stages.map(stageLabel);
    const posture = category === 'universal' ? 'both' : category;
    const multi = stages.length > 1;
    const tags = ['generated', `posture:${posture}`];
    if (multi) tags.push('multi_stage');
    tags.push(...new Set(stages.flat().map((layer) => `track:${layer.region}`)));
    generated.push({
      id: `grp_recipe_${String(nextId).padStart(3, '0')}`,
      name: `${String(nextId).padStart(3, '0')}_${stageNames.join(' → ')}`,
      description: `${posture === 'both' ? '坐姿与站姿' : posture === 'seated' ? '坐姿' : '站姿'}安全动作组合：${stageNames.join('，')}。由真实 gesture 资源生成，阶段间保留不冲突轨道。`,
      base: BASE_POSE,
      category,
      posture,
      tags,
      // `skins` is understood by MotionRecipe.supportsAppearance.  Keeping
      // this list on every generated recipe prevents a standing composition
      // from appearing on one of the five seated skins (and vice versa).
      skins: skinTokens(supported[category]),
      stages,
      validation: 'resource_scan+track_conflict',
      source: 'tool/generate_motion_combinations.cjs',
      generationReason: reason,
    });
    nextId += 1;
    perCategory[category] += 1;
    return true;
  }

  function addSingles(category, names) {
    for (const name of sortedNames(names)) add(category, [[layerFor(name, false)]], 'single');
  }

  function addPairs(category, names) {
    const byRegion = {};
    for (const name of sortedNames(names)) {
      const region = regionOf(name);
      if (region !== 'D') (byRegion[region] ||= []).push(name);
    }
    const regions = Object.keys(byRegion).sort();
    for (let i = 0; i < regions.length; i += 1) {
      for (let j = i + 1; j < regions.length; j += 1) {
        const leftRegion = regions[i];
        const rightRegion = regions[j];
        for (const left of byRegion[leftRegion]) {
          for (const right of byRegion[rightRegion]) {
            const stage = [layerFor(left, true), layerFor(right, true)].sort((a, b) => a.name.localeCompare(b.name));
            add(category, [stage], 'compatible_pair');
          }
        }
      }
    }
  }

  function addTriples(category, names) {
    const byRegion = {};
    for (const name of sortedNames(names)) {
      const region = regionOf(name);
      if (region !== 'D') (byRegion[region] ||= []).push(name);
    }
    // Preferred triples cover the useful torso + two-hand composition first.
    const preferred = [
      ['B', 'C', 'E'], ['B', 'C', 'I'], ['B', 'C', 'J'], ['C', 'E', 'F'],
      ['C', 'E', 'G'], ['E', 'F', 'G'], ['E', 'F', 'H'], ['E', 'G', 'H'],
      ['F', 'G', 'I'], ['F', 'G', 'J'], ['B', 'E', 'I'], ['B', 'E', 'J'],
    ];
    for (const tuple of preferred) {
      if (tuple.some((region) => !byRegion[region])) continue;
      for (const a of byRegion[tuple[0]]) {
        for (const b of byRegion[tuple[1]]) {
          for (const c of byRegion[tuple[2]]) {
            const stage = [layerFor(a, true), layerFor(b, true), layerFor(c, true)].sort((x, y) => x.name.localeCompare(y.name));
            add(category, [stage], 'compatible_triple');
          }
        }
      }
    }
  }

  function addOneShotTransitions(category, names) {
    const reactions = sortedNames(names).filter((name) => regionOf(name) === 'D');
    const actions = sortedNames(names).filter((name) => regionOf(name) !== 'D');
    // Keep a transition for every authored D reaction, then fan out to the
    // first layer of each region.  The category limit makes this deterministic
    // while still preserving broad coverage for the seated resource.
    for (const reaction of reactions) {
      for (const action of actions) {
        if (!add(category, [[layerFor(reaction, false)], [layerFor(action, false)]], 'one_shot_then_action')) {
          if (perCategory[category] >= limits[category]) return;
        }
      }
    }
  }

  for (const category of order) {
    addSingles(category, sets[category]);
    addPairs(category, sets[category]);
    addTriples(category, sets[category]);
    addOneShotTransitions(category, sets[category]);
  }

  const recipes = generated.map((recipe) => {
    // generationReason helps audits, but is intentionally not used by the app.
    delete recipe.generationReason;
    return recipe;
  });
  const stats = {
    resources: resources.length,
    resourceFiles: resources.map((resource) => resource.file),
    baseRecipes: base.recipes.length,
    generatedRecipes: recipes.length,
    firstId: recipes[0]?.id || null,
    lastId: recipes.at(-1)?.id || null,
    categories: Object.fromEntries(order.map((category) => [category, recipes.filter((recipe) => recipe.category === category).length])),
    multiStageRecipes: recipes.filter((recipe) => recipe.stages.length > 1).length,
    stages: recipes.reduce((sum, recipe) => sum + recipe.stages.length, 0),
    duplicateSignaturesSkipped: skippedDuplicate.generated,
    occupancyRule: 'same region or D exclusive; B conflicts with F/G',
    generator: 'tool/generate_motion_combinations.cjs',
  };
  return { recipes, stats, sets, supported };
}

function validate(catalogue, resources, base, expected = null) {
  const errors = [];
  const recipes = catalogue.recipes;
  const ids = new Set();
  const signatures = new Set(base.recipes.map((recipe) => recipeSignature(recipe.stages)));
  const resourcesByCategory = {
    universal: resources,
    seated: resources.filter((resource) => !resource.standing),
    standing: resources.filter((resource) => resource.standing),
  };
  for (let index = 0; index < recipes.length; index += 1) {
    const recipe = recipes[index];
    if (!/^grp_recipe_\d{3,}$/.test(recipe.id)) errors.push(`${recipe.id}: invalid id`);
    if (ids.has(recipe.id)) errors.push(`${recipe.id}: duplicate id`);
    ids.add(recipe.id);
    if (recipe.base !== BASE_POSE) errors.push(`${recipe.id}: wrong base`);
    if (!Array.isArray(recipe.stages) || !recipe.stages.length) errors.push(`${recipe.id}: no stages`);
    const signature = recipeSignature(recipe.stages || []);
    if (signatures.has(signature)) errors.push(`${recipe.id}: duplicate base/catalogue signature`);
    signatures.add(signature);
    const categoryResources = resourcesByCategory[recipe.category];
    if (!categoryResources || !categoryResources.length) errors.push(`${recipe.id}: unknown category`);
    for (const stage of recipe.stages || []) {
      if (!stageSafe(stage)) errors.push(`${recipe.id}: unsafe stage`);
      for (const layer of stage || []) {
        if (categoryResources && !categoryResources.every((resource) => resource.animations.has(layer.name))) {
          errors.push(`${recipe.id}: ${layer.name} missing from supported resources`);
        }
      }
    }
  }
  const numericIds = recipes.map((recipe) => Number(recipe.id.replace(/^grp_recipe_/, ''))).sort((a, b) => a - b);
  for (let i = 0; i < numericIds.length; i += 1) {
    if (numericIds[i] !== 145 + i) errors.push(`ids are not contiguous at ${numericIds[i]}`);
  }
  if (expected && JSON.stringify(catalogue.stats) !== JSON.stringify(expected)) errors.push('stats differ from generated result');
  return errors;
}

function main() {
  const checkOnly = process.argv.includes('--check');
  const resources = loadResources();
  const base = readJson(BASE_FILE);
  if (!base || !Array.isArray(base.recipes)) throw new Error('base motion_recipes.json has no recipes array');
  const generated = generate(resources, base);
  const output = { version: 1, generatedFrom: 'assets/data/motion_recipes.json', stats: generated.stats, recipes: generated.recipes };
  const errors = validate(output, resources, base);
  if (errors.length) {
    for (const error of errors.slice(0, 30)) console.error(`  - ${error}`);
    throw new Error(`validation failed (${errors.length} errors)`);
  }
  if (checkOnly) {
    const onDisk = readJson(EXTRA_FILE);
    if (!onDisk || !Array.isArray(onDisk.recipes)) {
      throw new Error(`--check requires ${path.relative(ROOT, EXTRA_FILE)}; run without --check to generate it`);
    }
    const diskErrors = validate(onDisk, resources, base, generated.stats);
    if (diskErrors.length) {
      for (const error of diskErrors.slice(0, 30)) console.error(`  - ${error}`);
      throw new Error(`on-disk validation failed (${diskErrors.length} errors)`);
    }
    // The generator is deterministic.  Comparing the canonical JSON catches
    // hand-edited layers and stale output while keeping --check read-only.
    if (JSON.stringify(onDisk.recipes) !== JSON.stringify(output.recipes)) {
      throw new Error('on-disk recipes differ from the deterministic generator output');
    }
  } else {
    fs.mkdirSync(path.dirname(EXTRA_FILE), { recursive: true });
    // Keep the shipped catalogue compact; the generator remains the readable
    // source and this file is loaded as a runtime asset.
    fs.writeFileSync(EXTRA_FILE, `${JSON.stringify(output)}\n`);
  }
  console.log(`${checkOnly ? 'Validated' : 'Generated'} ${generated.stats.generatedRecipes} recipes (${generated.stats.multiStageRecipes} multi-stage).`);
  console.log(`Categories: ${Object.entries(generated.stats.categories).map(([key, value]) => `${key}=${value}`).join(', ')}.`);
  console.log(`Resources: ${resources.map((resource) => resource.name).join(', ')}.`);
  console.log(`IDs: ${generated.stats.firstId || 'none'} .. ${generated.stats.lastId || 'none'}; duplicate signatures skipped=${generated.stats.duplicateSignaturesSkipped}.`);
}

try {
  main();
} catch (error) {
  die(error.message);
}
