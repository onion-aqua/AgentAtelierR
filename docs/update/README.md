# Self-hosted update publication tools

The publisher creates a signed, immutable Android manifest for a complete APK,
a complete resource snapshot, or both. It does not build the app, make an
HDiffPatch file, upload assets, or publish a GitHub/Gitee release.

## Bootstrap client configuration

Copy `update-build-config.example.json` to the ignored local path
`.asset_protection/update_server.json` and replace every example value. The
three release endpoints and Ed25519 public keys are encrypted into protected
build defines by `tool/build_protected.ps1`. A build without that local file
keeps all update networking disabled.

For server installation and bootstrap sequencing, see
[the server deployment guide](SERVER_DEPLOYMENT.md). Before a genuine signed
baseline exists, keep the private configuration as
`.asset_protection/update_server.pending.json`; do not activate it or publish
placeholder manifests. The pending `release_seq` must match the actual first
bootstrap publication, and is not a reservation or a published release.

The isolated `device-test` channel now has a genuine bootstrap and device
observations; see [the 2026-10-19 device test record](DEVICE_TEST_2026-10-19.md).
Production `stable` is published. Version 1.0.4.3 uses release sequence 59 and
Android build 55. Gitee and GitHub Git mirrors carry relative channel pointers
and notes; signed manifests and immutable artifacts are published at the
configured self-hosted origin. Gitee Git publication does not imply Gitee
Release API or attachment publication.

`resource_asset_key_ids` is a non-empty allowlist embedded in the client. A
signed release may select only one of these already-trusted resource encryption
key identifiers. Never populate this list from a downloaded release or resource
manifest: doing so would let downloaded metadata authorize its own key.

## Inputs

Copy `update-publish-config.example.json` outside the repository and replace all
example values. Keep private endpoints and local artifact paths in that local
file. The checked-in example intentionally uses `example.invalid`; it contains
no production IP, token, or private key.

Required release facts include:

- A never-before-used, monotonically increasing `release_seq`.
- For APK releases: Android `version_code`, application ID, supported ABIs, the
  SHA-256 of the APK signing certificate, and HTTPS locations for the APK.
- For each delta, the exact base APK SHA-256, an existing local patch file, its
  patch protocol version, and its HTTPS locations.
- For resource releases: a complete generated snapshot and its compatibility
  metadata. At least one of `target_apk` and `resource_snapshot` is required.
- Optional presentation-only Gitee/GitHub notes links.

If `release_id` is omitted, the tool generates one from platform, channel,
sequence, UTC publication time, and the target APK hash (or resource-manifest
hash for a resource-only release). If `published_at` is
omitted, current UTC time at second precision is used.

The Ed25519 private key must be a PEM file passed with `-PrivateKeyPath`. Store
it outside source control, restrict filesystem access, and back it up securely.
The tool reads it only to sign and perform a local round-trip verification. It
does not copy or print the private key. The corresponding public key and
`key_id` must be embedded into a trusted bootstrap app before manifests signed
with that key can be accepted. To prevent accidental commits, the generator
rejects a private-key path inside the repository unless it is under the ignored
`.asset_protection` directory.

OpenSSL 3.x is required. The scripts search `PATH` and common Git for Windows
locations, or accept an explicit `-OpenSslPath`.

## Generate a staged manifest

Use the protected build workflow separately; never substitute a direct Flutter
release build. Then run:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File tool/update/New-UpdateManifest.ps1 `
  -ConfigPath C:/secure-release/update-config.json `
  -ApkPath build/app/outputs/flutter-apk/app-release.apk `
  -PrivateKeyPath C:/secure-release/keys/update-ed25519.pem `
  -KeyId release-key-2026-01
```

The default staging root is ignored build output:

```text
build/update-publish/
  releases/<release_id>/
    manifest.json
    manifest.sha256
    payload.canonical.json
  channel-candidates/android/<channel>.json
```

Release directories are immutable. The generator scans the selected output root
and refuses a duplicate `release_id` or `release_seq`. CI or the release operator
must also enforce sequence uniqueness across machines; deleting local staging
does not make a sequence reusable.

`channel-candidates/...` is a staged copy of the signed manifest. Upload all
immutable objects first, then promote this candidate atomically. Do not expose a
candidate whose APK, patch, resource, or notes object is missing.

## Generate a complete resource snapshot

Stage a directory containing only the complete current set of managed assets.
Paths in the directory map to Flutter asset keys; use `-ResourcePathPrefix` if
the source is a subtree. Include existing encrypted `.bin` asset packs and
metadata unchanged. This tool does not encrypt raw character assets. Keep raw
protected assets outside public staging and upload only encrypted packs.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File tool/update/New-ResourceSnapshot.ps1 `
  -SourceDirectory C:/secure-release/managed-assets `
  -SnapshotId resources-000048 `
  -CompatibleRuntimeIds android-runtime-v1 `
  -AssetKeyId character-assets-v1 `
  -ResourceApiVersion 1 `
  -ObjectBaseUrl https://updates.example.invalid/agentatelier/resources `
  -OutputRoot C:/secure-release/resources
```

When called from PowerShell, `-CompatibleRuntimeIds` and `-ObjectBaseUrl` accept
arrays for multiple compatible runtimes or HTTPS mirrors. The output is:

```text
resources/
  objects/sha256/<64-character content hash>
  snapshots/<snapshot_id>/manifest.json
```

Each object URL is `<ObjectBaseUrl>/objects/sha256/<hash>`. Upload that tree
without renaming objects. Identical bytes are copied once, unchanged objects
can be reused, and existing objects or snapshot IDs with different bytes are
rejected. Paths are sorted ordinally and the manifest contains exact
`aar-cjson-v1` UTF-8 bytes without a BOM or trailing newline. The tool rejects
path traversal, symlinks/junctions, empty or oversized objects, and output paths
inside the source tree. See `resource-snapshot.schema.json` and the runtime
parser for the protocol limits.

Snapshots describe the entire managed replacement set, including unchanged
assets. Omitting a path removes its hot override in the next snapshot and lets
the app use its bundled fallback; it never deletes user saves. The outer signed
release authenticates the resource manifest hash, identity and compatibility.

For a resource-only release, copy `update-publish-resources.example.json` to a
private config, set its `manifest_path` to the generated file, and use matching
snapshot identity/compatibility fields. Omit `target_apk`, set `apk_deltas` to
`[]`, and omit `-ApkPath`:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File tool/update/New-UpdateManifest.ps1 `
  -ConfigPath C:/secure-release/resource-update-config.json `
  -PrivateKeyPath C:/secure-release/keys/update-ed25519.pem `
  -KeyId release-key-2026-01
```

The generator validates the canonical resource file and rejects mismatched
snapshot ID, schema, key ID, runtime list or resource API version before signing.

## Synchronize release notes

The app reads notes from the signed manifest's `notes.cached_markdown_url`.
`Sync-ReleaseNotes.ps1` can populate the file served at that URL from public
release APIs. Copy `release-notes-sync.example.json` to a private config and
replace the placeholder URLs with the actual Gitee/GitHub API endpoints for
one expected release tag. These are JSON API URLs, not release HTML pages.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File tool/update/Sync-ReleaseNotes.ps1 `
  -ConfigPath C:/secure-release/release-notes-sync.json `
  -OutputPath C:/secure-release/notes/release-48.md
```

Gitee is tried first. An unavailable, empty, draft or mismatched-tag response
falls back to GitHub. Only an exact `tag_name` match supplies its `body`; other
API fields are discarded. Existing notes are preserved if both fail. The file
is replaced atomically after a successful fetch; publishing it remains an
explicit release/deployment step.

Public endpoints need no token. If required, optional
`gitee_token_environment` / `github_token_environment` config fields name an
environment variable read at runtime and sent in an HTTPS Bearer header. Never
put its value in JSON, a URL, Git or script arguments. Redirects are disabled so
credentials are not forwarded. No request/response headers or tokens are logged.

## Verify before upload

Signature and schema only:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File tool/update/Test-UpdateManifest.ps1 `
  -ManifestPath build/update-publish/releases/<release_id>/manifest.json `
  -PublicKeyPath C:/secure-release/keys/update-ed25519-public.pem
```

Signature, schema, and every local artifact:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File tool/update/Test-UpdateManifest.ps1 `
  -ManifestPath build/update-publish/releases/<release_id>/manifest.json `
  -PublicKeyPath C:/secure-release/keys/update-ed25519-public.pem `
  -ApkPath build/app/outputs/flutter-apk/app-release.apk `
  -DeltaPatchPath C:/secure-release/delta/base-a.patch,C:/secure-release/delta/base-b.patch `
  -ResourceManifestPath C:/secure-release/resources/snapshot.json `
  -ResourceObjectsRoot C:/secure-release/resources/objects/sha256 `
  -RequireAllLocalArtifacts
```

PowerShell array syntax can also be used for multiple delta paths when invoking
the script from another script.

For resource-only verification, omit `-ApkPath` and `-DeltaPatchPath`.
`-ResourceObjectsRoot` points to the directory of hash-named files, not its
parent. `-RequireAllLocalArtifacts` validates every object in non-empty resource
snapshots as well as the signed manifest and any supplied APK/deltas.

## Self-test

The self-test creates a temporary key and tiny fake artifacts outside the
repository, signs and verifies a manifest, validates the committed canonical
JSON vector, generates both APK and resource-only releases, and verifies
resource deduplication, canonical snapshots and immutable content. It confirms
that payload tampering, duplicate release sequence reuse, unsafe paths and
invalid resource-only targets are rejected. Release-note source ordering and
tag matching use local test responses. The temporary private key is deleted at
the end.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File tool/update/Invoke-UpdateManifestSelfTest.ps1
```

Passing this test proves local manifest and signature round trips. It is not a
real APK patch reconstruction test, upload test, Gitee/GitHub synchronization
test, or production server integration test.
