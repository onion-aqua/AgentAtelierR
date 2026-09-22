import 'dart:convert';
import 'dart:io';

// Mechanical conversion of local Motion Lab manifests; no textures are copied.
void main(List<String> args) {
  final recipes = <Map<String, dynamic>>[];
  for (final folder in args) {
    final manifest = jsonDecode(
      File('$folder/action_groups_manifest.json').readAsStringSync(),
    );
    for (final group in manifest['groups'] as List) {
      final file = group['file'] as String;
      final source = jsonDecode(File('$folder/$file').readAsStringSync());
      final stages = <List<Map<String, dynamic>>>[];
      var stage = <Map<String, dynamic>>[];
      for (final layer in source['layers'] as List) {
        final name = layer['name'] as String;
        final match = RegExp(r'^motion_(add|oneshot)_([B-J])_')
            .firstMatch(name);
        if (match == null || layer['enabled'] == false) continue;
        final region = match[2]!;
        // D is a whole-body reaction. B and F/G share arm bones.
        bool conflict(Map<String, dynamic> other) =>
            other['region'] == region ||
            region == 'D' ||
            other['region'] == 'D' ||
            (region == 'B' && ['F', 'G'].contains(other['region'])) ||
            (other['region'] == 'B' && ['F', 'G'].contains(region));
        if (stage.any(conflict)) {
          stages.add(stage);
          stage = [];
        }
        stage.add({
          'name': name,
          'region': region,
          'alpha': layer['alpha'] ?? 1,
          'speed': layer['speed'] ?? 1,
        });
      }
      if (stage.isNotEmpty) stages.add(stage);
      if (stages.isEmpty) continue;
      recipes.add({
        'id': 'grp_recipe_${file.split('_').first}',
        'name': group['name'],
        'description': group['description'] ?? group['name'],
        'base': source['base'],
        'stages': stages,
        'validation': 'structural_only',
        'source': file,
      });
    }
  }
  File('assets/data/motion_recipes.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ')
        .convert({'version': 1, 'recipes': recipes}),
  );
  stdout.writeln('Imported ${recipes.length} recipes');
}
