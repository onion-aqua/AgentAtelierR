import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/relay/relay_server_config.dart';

void main() {
  test('private build encrypts ignored configuration and rejects public address copies', () async {
    final project = Directory.current.path;
    final packagesFile = File('$project/.dart_tool/package_config.json');
    final packages =
        (jsonDecode(await packagesFile.readAsString()) as Map)['packages']
            as List;
    final flutter = packages.cast<Map>().firstWhere(
      (entry) => entry['name'] == 'flutter',
    );
    final flutterPackage = Directory.fromUri(
      packagesFile.uri.resolve(flutter['rootUri'] as String),
    );
    final sdkRoot = flutterPackage.parent.parent.path;
    final dartExecutable =
        '$sdkRoot/bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}';
    final fixture = await Directory.systemTemp.createTemp(
      'relay_build_config_',
    );
    addTearDown(() => fixture.delete(recursive: true));
    Future<ProcessResult> run(String command, List<String> args) =>
        Process.run(command, args, workingDirectory: fixture.path);
    expect((await run('git', ['init', '--quiet'])).exitCode, 0);
    await File('${fixture.path}/.gitignore').writeAsString('private/\n');
    final local = Directory('${fixture.path}/private');
    await local.create();
    const origin = 'https://fixed-private.example.test';
    final config = File('${local.path}/relay_server.json');
    final definitions = File('${local.path}/relay_server.defines.json');
    await config.writeAsString(jsonEncode({'v': 1, 'server_base_url': origin}));
    final command = [
      '--packages=$project/.dart_tool/package_config.json',
      '$project/tool/protect_relay_server.dart',
      '--config-file',
      config.path,
      '--output-file',
      definitions.path,
      '--check-public-files',
    ];
    final success = await run(dartExecutable, command);
    expect(success.exitCode, 0, reason: success.stderr.toString());
    expect(
      '${success.stdout}${success.stderr}',
      isNot(contains('fixed-private.example.test')),
    );
    final encrypted = jsonDecode(await definitions.readAsString()) as Map;
    expect(
      jsonEncode(encrypted),
      isNot(contains('fixed-private.example.test')),
    );
    final policy = await RelayServerConfig.fromProtectedDefines(
      encrypted: encrypted[relayServerBlobDefine] as String,
      key: encrypted[relayServerKeyDefine] as String,
    );
    expect(policy.requireAllowed(Uri.parse(origin)), Uri.parse(origin));

    final leak = File('${fixture.path}/README.md');
    await leak.writeAsString('https://FIXED-PRIVATE.EXAMPLE.TEST');
    final rejected = await run(dartExecutable, command);
    expect(rejected.exitCode, isNot(0));
    expect(rejected.stderr, contains('public candidate file'));
    expect(
      '${rejected.stdout}${rejected.stderr}',
      isNot(contains('FIXED-PRIVATE.EXAMPLE.TEST')),
    );
    expect(
      '${rejected.stdout}${rejected.stderr}',
      isNot(contains('fixed-private.example.test')),
    );

    // An address-bearing private config itself must also be ignored.
    await leak.delete();
    await File('${fixture.path}/.gitignore').writeAsString('');
    final unignored = await run(dartExecutable, command);
    expect(unignored.exitCode, isNot(0));
  });
}
