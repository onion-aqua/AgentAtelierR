import 'dart:convert';
import 'dart:io';

import 'package:ryza_chat_mvp/src/update/update_build_config.dart';

Future<void> main(List<String> arguments) async {
  try {
    String? configPath;
    String? outputPath;
    var checkPublicFiles = false;
    for (var index = 0; index < arguments.length; index++) {
      switch (arguments[index]) {
        case '--config-file':
          configPath = arguments[++index];
        case '--output-file':
          outputPath = arguments[++index];
        case '--check-public-files':
          checkPublicFiles = true;
        default:
          throw const FormatException();
      }
    }
    if (configPath == null || outputPath == null) {
      throw const FormatException();
    }
    final source = await File(configPath).readAsString();
    if (source.length > 32768) throw const FormatException();
    final decoded = jsonDecode(source);
    UpdateBuildConfig.fromJson(decoded);
    if (checkPublicFiles) await _checkPublicFiles(decoded as Map);
    final definitions = await protectUpdateBuildConfiguration(decoded);
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsString(jsonEncode(definitions), flush: true);
    stdout.writeln('Protected self-hosted update configuration prepared.');
  } on Object {
    stderr.writeln(
      'Update configuration preparation failed. Check the ignored local JSON, '
      'HTTPS endpoints and Ed25519 public keys. No private value was printed.',
    );
    exitCode = 1;
  }
}

Future<void> _checkPublicFiles(Map<dynamic, dynamic> config) async {
  final privateCandidates = <String>{};
  for (final key in const [
    'gitee_latest_url',
    'cache_latest_url',
    'github_latest_url',
  ]) {
    final value = config[key];
    if (value is String && value.isNotEmpty) privateCandidates.add(value);
  }
  final result = await Process.run('git', [
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
  ], stdoutEncoding: utf8);
  if (result.exitCode != 0) throw const FormatException();
  var leaks = 0;
  for (final path in (result.stdout as String).split('\u0000').toSet()) {
    if (path.isEmpty) continue;
    final file = File(path);
    if (!await file.exists()) continue;
    final text = utf8
        .decode(await file.readAsBytes(), allowMalformed: true)
        .replaceAll('\u0000', '');
    if (privateCandidates.any(text.contains)) leaks++;
  }
  if (leaks != 0) {
    stderr.writeln(
      'Configured update endpoint found in $leaks public candidate file(s).',
    );
    throw const FormatException();
  }
}
