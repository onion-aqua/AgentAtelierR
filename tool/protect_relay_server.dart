import 'dart:convert';
import 'dart:io';

import 'package:ryza_chat_mvp/src/relay/relay_server_config.dart';

Future<void> main(List<String> arguments) async {
  try {
    String? configPath;
    String? outputPath;
    var checkPublicFiles = false;
    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--config-file':
          configPath = arguments[++i];
        case '--output-file':
          outputPath = arguments[++i];
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
    if (source.length > 8192) throw const FormatException();
    final config = jsonDecode(source);
    RelayServerConfig.fromJson(config);
    if (checkPublicFiles) {
      await _checkPublicFiles(
        Uri.parse(config['server_base_url'] as String).host,
      );
    }
    final definitions = await protectRelayServerConfiguration(config);
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsString(jsonEncode(definitions), flush: true);
    stdout.writeln(
      'Protected PC Agent server configuration; address hidden and fixed.',
    );
  } on Object {
    stderr.writeln(
      'PC Agent private build preparation failed. Check the ignored local configuration, '
      'HTTPS origin, and public-source address scan. No private values were printed.',
    );
    exitCode = 1;
  }
}

Future<void> _checkPublicFiles(String host) async {
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
    // Scan bytes as well as text so ASCII or UTF-16 address copies cannot
    // bypass the check through a different extension or encoding.
    final bytes = await file.readAsBytes();
    final text = utf8
        .decode(bytes, allowMalformed: true)
        .replaceAll('\u0000', '')
        .toLowerCase();
    if (text.contains(host.toLowerCase())) leaks++;
  }
  if (leaks != 0) {
    stderr.writeln(
      'Private server address found in $leaks public candidate file(s).',
    );
    throw const FormatException();
  }
}
