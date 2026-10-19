[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$PublicKeyPath,
    [string]$ApkPath = '',
    [string[]]$DeltaPatchPath = @(),
    [string]$ResourceManifestPath = '',
    [string]$ResourceObjectsRoot = '',
    [switch]$RequireAllLocalArtifacts,
    [string]$OpenSslPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $PSScriptRoot 'UpdateManifestTools.psm1') -Force

function Resolve-ProjectPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $projectRoot $Path))
}

try {
    $resolvedManifest = (Resolve-Path -LiteralPath (Resolve-ProjectPath $ManifestPath) -ErrorAction Stop).Path
    $resolvedPublicKey = (Resolve-Path -LiteralPath (Resolve-ProjectPath $PublicKeyPath) -ErrorAction Stop).Path
    $manifest = Read-UpdateJson -Path $resolvedManifest
    if ($manifest -isnot [System.Collections.IDictionary]) { throw 'Manifest root must be an object.' }
    Assert-UpdateManifest -Manifest $manifest

    [byte[]]$canonicalBytes = Get-AarCanonicalBytes -Payload $manifest.payload
    $canonicalSibling = Join-Path (Split-Path -Parent $resolvedManifest) 'payload.canonical.json'
    if (Test-Path -LiteralPath $canonicalSibling -PathType Leaf) {
        [byte[]]$committedBytes = [System.IO.File]::ReadAllBytes($canonicalSibling)
        if (-not [System.Linq.Enumerable]::SequenceEqual($canonicalBytes, $committedBytes)) {
            throw 'payload.canonical.json does not match the manifest payload.'
        }
    }
    $signatureValid = Test-Ed25519UpdateSignature `
        -PayloadBytes $canonicalBytes `
        -SignatureBase64 $manifest.signature.value_base64 `
        -PublicKeyPath $resolvedPublicKey `
        -OpenSslPath $OpenSslPath
    if (-not $signatureValid) { throw 'Ed25519 signature verification failed.' }

    $verifiedHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($ApkPath) {
        $apk = Get-UpdateFileMetadata -Path (Resolve-ProjectPath $ApkPath)
        if (-not $manifest.payload.Contains('target_apk')) { throw 'A local APK was supplied, but the manifest has no target_apk.' }
        if ($apk.sha256 -cne $manifest.payload.target_apk.sha256 -or $apk.size -ne $manifest.payload.target_apk.size) {
            throw 'The local APK hash or size does not match payload.target_apk.'
        }
        [void]$verifiedHashes.Add($apk.sha256)
    }

    foreach ($patchPath in $DeltaPatchPath) {
        $patch = Get-UpdateFileMetadata -Path (Resolve-ProjectPath $patchPath)
        $matching = @($manifest.payload.apk_deltas | Where-Object {
            $_.patch_sha256 -ceq $patch.sha256 -and $_.size -eq $patch.size
        })
        if ($matching.Count -ne 1) {
            throw "Local delta patch does not match exactly one manifest entry: $patchPath"
        }
        [void]$verifiedHashes.Add($patch.sha256)
    }

    if ($ResourceManifestPath) {
        $resource = Get-UpdateFileMetadata -Path (Resolve-ProjectPath $ResourceManifestPath)
        if (-not $manifest.payload.Contains('resource_snapshot')) {
            throw 'A local resource manifest was supplied, but the update manifest has no resource_snapshot.'
        }
        $snapshot = $manifest.payload.resource_snapshot
        if ($resource.sha256 -cne $snapshot.manifest_sha256 -or $resource.size -ne $snapshot.size) {
            throw 'The local resource manifest hash or size does not match payload.resource_snapshot.'
        }
        $resourceManifest = Read-UpdateJson (Resolve-ProjectPath $ResourceManifestPath)
        Assert-ResourceSnapshotManifest $resourceManifest
        [byte[]]$resourceBytes = [IO.File]::ReadAllBytes((Resolve-ProjectPath $ResourceManifestPath))
        [byte[]]$resourceCanonical = Get-AarCanonicalBytes $resourceManifest
        if ($resourceBytes.Length -gt 8388608 -or -not [Linq.Enumerable]::SequenceEqual($resourceBytes, $resourceCanonical)) {
            throw 'Resource manifest must contain exact aar-cjson-v1 bytes within the client size limit.'
        }
        [string[]]$manifestRuntimeIds = @($resourceManifest.compatible_runtime_ids)
        [string[]]$signedRuntimeIds = @($snapshot.compatible_runtime_ids)
        [Array]::Sort($manifestRuntimeIds, [StringComparer]::Ordinal)
        [Array]::Sort($signedRuntimeIds, [StringComparer]::Ordinal)
        if ($resourceManifest.snapshot_id -cne $snapshot.id -or
            $resourceManifest.schema_version -ne $snapshot.schema_version -or
            $resourceManifest.asset_key_id -cne $snapshot.asset_key_id -or
            $resourceManifest.resource_api_version -ne $manifest.payload.resource_api_version -or
            (ConvertTo-AarCanonicalJson $manifestRuntimeIds) -cne (ConvertTo-AarCanonicalJson $signedRuntimeIds)) {
            throw 'Resource manifest identity or compatibility differs from the signed update payload.'
        }
        if ($ResourceObjectsRoot) {
            $objectRoot = Resolve-ProjectPath $ResourceObjectsRoot
            foreach ($object in $resourceManifest.objects) {
                $objectPath = Join-Path $objectRoot $object.sha256
                $objectMetadata = Get-UpdateFileMetadata $objectPath
                if ($objectMetadata.sha256 -cne $object.sha256 -or $objectMetadata.size -ne $object.size) {
                    throw "Local resource object does not match snapshot: $($object.path)"
                }
            }
        }
        elseif ($RequireAllLocalArtifacts -and @($resourceManifest.objects).Count -gt 0) {
            throw '-RequireAllLocalArtifacts requires -ResourceObjectsRoot for non-empty snapshots.'
        }
        [void]$verifiedHashes.Add($resource.sha256)
    }
    elseif ($ResourceObjectsRoot) { throw '-ResourceObjectsRoot requires -ResourceManifestPath.' }

    if ($RequireAllLocalArtifacts) {
        if ($manifest.payload.Contains('target_apk') -and
            -not $verifiedHashes.Contains($manifest.payload.target_apk.sha256)) {
            throw '-RequireAllLocalArtifacts requires the matching -ApkPath.'
        }
        foreach ($delta in $manifest.payload.apk_deltas) {
            if (-not $verifiedHashes.Contains($delta.patch_sha256)) {
                throw "Missing local delta patch for base $($delta.base_sha256)."
            }
        }
        if ($manifest.payload.Contains('resource_snapshot') -and
            -not $verifiedHashes.Contains($manifest.payload.resource_snapshot.manifest_sha256)) {
            throw '-RequireAllLocalArtifacts requires the matching -ResourceManifestPath.'
        }
    }

    $payloadHash = [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($canonicalBytes)
    ).ToLowerInvariant()
    Write-Host 'Update manifest validation passed.'
    Write-Host "Release: $($manifest.payload.release_id) (sequence $($manifest.payload.release_seq))"
    Write-Host "Signing key: $($manifest.signature.key_id)"
    Write-Host "Canonical payload SHA-256: $payloadHash"
    Write-Host "Locally verified artifacts: $($verifiedHashes.Count)"
}
catch {
    Write-Error "Update manifest validation failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
