import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Public interoperability key: conceals QR contents from ordinary scanners.
/// It is not a credential and does not provide end-to-end encryption or protect
/// against a QR holder who knows this open-source format.
const relayQrEnvelopePrefix = 'ryzasync:v2:';
const relayQrCompatibilitySeed = 'ryzasync/qr-envelope/v2/public-compat-key';
const maxRelayQrPlaintextBytes = 4096;
const maxRelayQrEnvelopeLength =
    relayQrEnvelopePrefix.length +
    ((maxRelayQrPlaintextBytes + 12 + 16) * 4 + 2) ~/ 3;

const invalidRelayQrMessage = '配对二维码无效或不受支持，请重新获取 PC 生成的配对数据。';

SecretKey? _compatibilityKey;

Future<SecretKey> _key() async => _compatibilityKey ??= SecretKey(
  (await Sha256().hash(utf8.encode(relayQrCompatibilitySeed))).bytes,
);

/// Unwraps v2 and preserves legacy v1 JSON. A recognized envelope never falls
/// back to JSON after any failure; callers must validate the returned JSON with
/// the existing pairing protocol before asking for consent or using the network.
Future<String> decodeRelayQrEnvelope(String source) async {
  try {
    if (source.isEmpty || source.length > maxRelayQrEnvelopeLength) {
      throw const FormatException();
    }
    if (!source.startsWith('ryzasync:')) {
      if (source.length > maxRelayQrPlaintextBytes ||
          utf8.encode(source).length > maxRelayQrPlaintextBytes) {
        throw const FormatException();
      }
      return source;
    }
    if (!source.startsWith(relayQrEnvelopePrefix)) {
      throw const FormatException();
    }
    final encoded = source.substring(relayQrEnvelopePrefix.length);
    if (encoded.isEmpty ||
        encoded.length % 4 == 1 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) {
      throw const FormatException();
    }
    final envelope = base64Url.decode(base64Url.normalize(encoded));
    // The round trip rejects noncanonical trailing bits as well as padding.
    if (envelope.length <= 28 ||
        envelope.length > maxRelayQrPlaintextBytes + 28 ||
        base64Url.encode(envelope).replaceAll('=', '') != encoded) {
      throw const FormatException();
    }
    final tagOffset = envelope.length - 16;
    final plaintext = await AesGcm.with256bits().decrypt(
      SecretBox(
        Uint8List.sublistView(envelope, 12, tagOffset),
        nonce: Uint8List.sublistView(envelope, 0, 12),
        mac: Mac(Uint8List.sublistView(envelope, tagOffset)),
      ),
      secretKey: await _key(),
      aad: utf8.encode(relayQrEnvelopePrefix),
    );
    if (plaintext.isEmpty || plaintext.length > maxRelayQrPlaintextBytes) {
      throw const FormatException();
    }
    return utf8.decode(plaintext, allowMalformed: false);
  } on Object {
    // Never attach source, plaintext, key material or cryptographic diagnostics.
    throw const FormatException(invalidRelayQrMessage);
  }
}
