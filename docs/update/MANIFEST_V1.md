# AgentAtelierR update manifest v1

This document freezes the signed Android update manifest used by the
self-hosted updater. The machine-readable schema is
`update-manifest.schema.json`.

## Envelope and trust boundary

The document has exactly two top-level fields:

```json
{
  "payload": {},
  "signature": {
    "key_id": "release-key-2026-01",
    "algorithm": "Ed25519",
    "signed_object": "payload",
    "canonicalization": "aar-cjson-v1",
    "value_base64": "..."
  }
}
```

The Ed25519 signature covers only the UTF-8 bytes of the canonical `payload`.
The client maps `key_id` to a public key that was shipped in a trusted app
build. A public key supplied by the same downloaded manifest is never trusted.
`value_base64` is standard padded Base64 and decodes to exactly 64 bytes.

HTTPS protects transport, SHA-256 identifies immutable artifacts, and the
Ed25519 signature authenticates the release publisher. All three checks are
required before an update can be installed or activated.

## `aar-cjson-v1`

The canonicalizer accepts only null, Boolean, string, integer, array, and map
values with string keys. Floating-point and decimal values are rejected.

- Map keys are sorted by ordinal UTF-16 code units. Arrays retain their order.
- No whitespace or trailing newline is emitted.
- `"`, `\`, backspace, tab, LF, form feed, and CR use their short JSON escapes.
- Other U+0000 through U+001F characters use lowercase `\u00xx` escapes.
- Valid non-control Unicode is written directly as UTF-8. Unpaired UTF-16
  surrogates are rejected.
- Integers are base-10 ASCII with no leading zero, plus sign, or exponent.
- Duplicate JSON object keys are rejected before canonicalization.

The committed vector under `test/fixtures/update/` fixes the expected bytes and
SHA-256 for both the PowerShell publisher and the Flutter verifier.

## Payload semantics

`release_id` identifies one immutable publication. `release_seq` is a globally
monotonic positive integer for its channel. Neither may be reused for different
bytes. Changing release notes, assets, or a manifest requires a new sequence and
release ID.

At least one of `target_apk` and `resource_snapshot` is required. A resource-only
release omits `target_apk` and has an empty `apk_deltas` list.

`target_apk`, when present, describes the complete target APK. The publisher computes its
`sha256` and `size`; the certificate digest, package, version code, ABI list,
and HTTPS mirrors are explicit release inputs.

Each `apk_deltas` entry binds one exact `base_sha256` to the target APK hash.
The patch file hash and size are computed by the publisher. A client must use a
delta only when the installed APK bytes match `base_sha256`; version text and
version code are insufficient. If no exact base exists, the client uses the
complete APK. Patch reconstruction is successful only if the result exactly
matches `target_apk.sha256` and the expected Android package, version code, and
certificate.

`resource_snapshot`, when present, points to the complete target resource
snapshot manifest. The snapshot object is optional because an APK-only release
is valid. The snapshot itself has a separate content hash and compatibility
list; its object files follow `resource-snapshot.schema.json` and the client
`ResourceSnapshotManifestParser`. The resource manifest must itself use exact
canonical bytes, with no BOM or trailing newline, and its identity and
compatibility fields must match the signed resource snapshot reference.

`notes` contains presentation URLs. It cannot select executable artifacts. The
`notes.release_id` must equal the signed payload release ID.

Schema v1 rejects unknown fields. Adding fields requires a new schema or
protocol version so an older client never silently changes security semantics.

## Channel pointers

A channel document may either contain the signed envelope directly or contain
exactly `schema_version`, `release_id`, `release_seq`, and `manifest_url`.
Absolute HTTPS `manifest_url` values retain their normal meaning.

Public mirrors may avoid disclosing the private cache host by using the exact
relative value `releases/<release_id>/manifest.json`. The client accepts this
form only when a private cache channel is configured at
`<private-root>/channels/android/<channel>.json`. It derives the manifest URL
from `<private-root>` and does not resolve the relative value against the
public mirror. Absolute-path, network-path, dot-segment, query, fragment, and
release-ID-mismatched variants are rejected. The downloaded envelope must
still match the pointer identity and pass normal signature authentication.

## Publication order

1. For code updates, build and preserve one protected target APK. For resource
   updates, generate the complete current managed resource snapshot.
2. For code updates, create and locally verify any historical-base-to-target patches.
3. Upload immutable APK, patch, resource, and notes objects.
4. Generate and sign the unique release manifest.
5. Upload the immutable `releases/<release_id>/manifest.json`.
6. After every referenced object is reachable and hash-verified, atomically
   replace the channel document with the generated channel candidate.

The scripts in this repository stage files only. They do not upload a release,
change a channel, or contact the private update server.
