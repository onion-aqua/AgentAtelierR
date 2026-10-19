import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'update_models.dart';

/// Deterministic JSON used by both the offline publisher and the app.
///
/// aar-cjson-v1 intentionally accepts only the JSON subset needed by the
/// manifest. In particular, floating point values are rejected so different
/// runtimes cannot serialize the same apparent number to different bytes.
String canonicalJsonEncode(Object? value) {
  final output = StringBuffer();
  _writeCanonical(value, output);
  return output.toString();
}

Uint8List canonicalJsonBytes(Object? value) =>
    Uint8List.fromList(utf8.encode(canonicalJsonEncode(value)));

void _writeCanonical(Object? value, StringBuffer output) {
  if (value == null) {
    output.write('null');
  } else if (value is bool) {
    output.write(value ? 'true' : 'false');
  } else if (value is int) {
    if (value < -9007199254740991 || value > 9007199254740991) {
      throw const FormatException('canonical JSON 整数超出安全范围');
    }
    output.write(value);
  } else if (value is String) {
    _writeCanonicalString(value, output);
  } else if (value is List) {
    output.write('[');
    for (var index = 0; index < value.length; index++) {
      if (index != 0) output.write(',');
      _writeCanonical(value[index], output);
    }
    output.write(']');
  } else if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw const FormatException('canonical JSON 对象键必须是字符串');
    }
    final keys = value.keys.cast<String>().toList()..sort();
    output.write('{');
    for (var index = 0; index < keys.length; index++) {
      if (index != 0) output.write(',');
      final key = keys[index];
      _writeCanonicalString(key, output);
      output.write(':');
      _writeCanonical(value[key], output);
    }
    output.write('}');
  } else {
    throw FormatException('canonical JSON 不支持 ${value.runtimeType} 类型');
  }
}

void _writeCanonicalString(String value, StringBuffer output) {
  output.write('"');
  for (var index = 0; index < value.length; index++) {
    final code = value.codeUnitAt(index);
    switch (code) {
      case 0x22:
        output.write(r'\"');
      case 0x5c:
        output.write(r'\\');
      case 0x08:
        output.write(r'\b');
      case 0x09:
        output.write(r'\t');
      case 0x0a:
        output.write(r'\n');
      case 0x0c:
        output.write(r'\f');
      case 0x0d:
        output.write(r'\r');
      default:
        if (code < 0x20) {
          output
            ..write(r'\u00')
            ..write(code.toRadixString(16).padLeft(2, '0'));
        } else if (code >= 0xd800 && code <= 0xdbff) {
          if (index + 1 >= value.length) {
            throw const FormatException('canonical JSON 字符串含未配对代理项');
          }
          final low = value.codeUnitAt(index + 1);
          if (low < 0xdc00 || low > 0xdfff) {
            throw const FormatException('canonical JSON 字符串含未配对代理项');
          }
          output.writeCharCode(code);
          output.writeCharCode(low);
          index++;
        } else if (code >= 0xdc00 && code <= 0xdfff) {
          throw const FormatException('canonical JSON 字符串含未配对代理项');
        } else {
          output.writeCharCode(code);
        }
    }
  }
  output.write('"');
}

final class UpdateVerificationException implements Exception {
  const UpdateVerificationException(this.code);

  final String code;

  @override
  String toString() => 'UpdateVerificationException($code)';
}

/// Authenticates signed release manifests against public keys embedded in the
/// application. Private signing material never enters the client or repository.
final class UpdateManifestVerifier {
  UpdateManifestVerifier({
    required Map<String, List<int>> trustedKeys,
    Ed25519? algorithm,
  }) : _trustedKeys = Map.unmodifiable({
         for (final entry in trustedKeys.entries)
           entry.key: Uint8List.fromList(entry.value),
       }),
       _algorithm = algorithm ?? Ed25519() {
    if (_trustedKeys.isEmpty ||
        _trustedKeys.entries.any(
          (entry) =>
              !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
                  .hasMatch(entry.key) ||
              entry.value.length != 32,
        )) {
      throw ArgumentError(
        'Ed25519 trusted keys must have valid ids and 32 bytes',
      );
    }
  }

  final Map<String, Uint8List> _trustedKeys;
  final Ed25519 _algorithm;

  Future<UpdateManifest> verify(UpdateManifestEnvelope envelope) async {
    final metadata = envelope.signature;
    if (metadata.algorithm != 'Ed25519' ||
        metadata.signedObject != 'payload' ||
        metadata.canonicalization != updateCanonicalization ||
        envelope.payload['canonicalization'] != updateCanonicalization) {
      throw const UpdateVerificationException('unsupported_signature_protocol');
    }
    final publicKeyBytes = _trustedKeys[metadata.keyId];
    if (publicKeyBytes == null) {
      throw const UpdateVerificationException('untrusted_key');
    }
    late final Uint8List signatureBytes;
    try {
      signatureBytes = Uint8List.fromList(base64.decode(metadata.valueBase64));
    } on FormatException {
      throw const UpdateVerificationException('invalid_signature_encoding');
    }
    if (signatureBytes.length != 64 ||
        base64.encode(signatureBytes) != metadata.valueBase64) {
      throw const UpdateVerificationException('invalid_signature_encoding');
    }
    final valid = await _algorithm.verify(
      canonicalJsonBytes(envelope.payload),
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) {
      throw const UpdateVerificationException('signature_mismatch');
    }
    return parseUpdateManifestPayload(envelope.payload);
  }
}
