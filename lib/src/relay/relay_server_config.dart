import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../protected_asset_format.dart';
import 'relay_protocol.dart';

const relayServerBlobDefine = 'AAR_RELAY_SERVER_BLOB';
const relayServerKeyDefine = 'AAR_RELAY_SERVER_KEY';
const _packId = 'pc-agent-server-config-v1';
const _entryName = 'relay.json';

/// The private endpoint is supplied by ignored, encrypted build definitions.
/// Public checkouts without definitions retain QR-based server selection.
class RelayServerConfig {
  const RelayServerConfig.unrestricted() : _origin = null;

  RelayServerConfig.pinned(String origin) : _origin = secureOrigin(origin);

  final Uri? _origin;

  bool get isPinned => _origin != null;

  bool allows(Uri origin) => _origin == null || origin == _origin;

  Uri requireAllowed(Uri requested) {
    final valid = secureOrigin(requested.toString());
    if (!allows(valid)) {
      throw const FormatException('此版本只支持内置联动服务，请使用该服务生成的配对二维码。');
    }
    return _origin ?? valid;
  }

  factory RelayServerConfig.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 2 ||
        value['v'] != 1 ||
        value['v'] is! int ||
        value['server_base_url'] is! String) {
      throw const FormatException('联动服务器构建配置格式无效');
    }
    return RelayServerConfig.pinned(value['server_base_url'] as String);
  }

  static Future<RelayServerConfig> fromEnvironment() => fromProtectedDefines(
    encrypted: const String.fromEnvironment(relayServerBlobDefine),
    key: const String.fromEnvironment(relayServerKeyDefine),
  );

  static Future<RelayServerConfig> fromProtectedDefines({
    required String encrypted,
    required String key,
  }) async {
    if (encrypted.isEmpty && key.isEmpty) {
      return const RelayServerConfig.unrestricted();
    }
    try {
      if (encrypted.isEmpty || key.isEmpty || encrypted.length > 32768) {
        throw const FormatException();
      }
      final files = await decryptProtectedAssetFiles(
        encrypted: Uint8List.fromList(base64Url.decode(encrypted)),
        key: decodeProtectedAssetKey(key),
        packId: _packId,
      );
      if (files.length != 1 || !files.containsKey(_entryName)) {
        throw const FormatException();
      }
      return RelayServerConfig.fromJson(
        jsonDecode(utf8.decode(files[_entryName]!)),
      );
    } on Object {
      // Do not include plaintext, ciphertext, keys or URLs in diagnostics.
      throw const FormatException('内置联动服务配置无法验证，已停止连接，请重新使用加密脚本构建。');
    }
  }

  @override
  String toString() => isPinned
      ? 'RelayServerConfig(pinned, redacted)'
      : 'RelayServerConfig(unrestricted)';
}

/// Shared by the build tool and format tests; never prints private values.
Future<Map<String, String>> protectRelayServerConfiguration(
  Object? config, {
  Uint8List? key,
}) async {
  RelayServerConfig.fromJson(config);
  final secret =
      key ??
      Uint8List.fromList(
        await (await AesGcm.with256bits().newSecretKey()).extractBytes(),
      );
  final encrypted = await encryptProtectedAssetFiles(
    files: {_entryName: Uint8List.fromList(utf8.encode(jsonEncode(config)))},
    key: secret,
    packId: _packId,
  );
  return {
    relayServerBlobDefine: base64UrlEncode(encrypted),
    relayServerKeyDefine: base64UrlEncode(secret),
  };
}
