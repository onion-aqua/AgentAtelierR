[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$ApkPath = '',
    [Parameter(Mandatory)][string]$PrivateKeyPath,
    [Parameter(Mandatory)][string]$KeyId,
    [string]$OutputRoot = 'build/update-publish',
    [string]$OpenSslPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $PSScriptRoot 'UpdateManifestTools.psm1') -Force
$stagingDirectory = $null
$releasesRootForCleanup = $null

function Resolve-ProjectPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $projectRoot $Path))
}

function Resolve-ConfigPath([string]$Path, [string]$ConfigDirectory) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $ConfigDirectory $Path))
}

function Assert-ConfigShape {
    param(
        [System.Collections.IDictionary]$Value,
        [string]$Name,
        [string[]]$Required,
        [string[]]$Optional = @()
    )
    foreach ($key in $Required) {
        if (-not $Value.Contains($key)) { throw "$Name is missing required field '$key'." }
    }
    $allowed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in @($Required) + @($Optional)) { [void]$allowed.Add($key) }
    foreach ($key in $Value.Keys) {
        if (-not $allowed.Contains([string]$key)) { throw "$Name contains unknown field '$key'." }
    }
}

function Get-ConfigArray([object]$Value, [string]$Name, [switch]$AllowEmpty) {
    if ($Value -is [string] -or $Value -isnot [System.Collections.IEnumerable] -or
        $Value -is [System.Collections.IDictionary]) {
        throw "$Name must be an array."
    }
    $items = @($Value)
    if (-not $AllowEmpty -and $items.Count -eq 0) { throw "$Name cannot be empty." }
    return $items
}

function Get-ConfigStringArray([object]$Value, [string]$Name) {
    $items = @(Get-ConfigArray $Value $Name)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $items) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) {
            throw "$Name must contain only non-empty strings."
        }
        $result.Add($item)
    }
    return $result.ToArray()
}

try {
    $resolvedConfig = (Resolve-Path -LiteralPath (Resolve-ProjectPath $ConfigPath) -ErrorAction Stop).Path
    $resolvedApk = if ($ApkPath) { (Resolve-Path -LiteralPath (Resolve-ProjectPath $ApkPath) -ErrorAction Stop).Path } else { $null }
    $resolvedPrivateKey = (Resolve-Path -LiteralPath (Resolve-ProjectPath $PrivateKeyPath) -ErrorAction Stop).Path
    $resolvedOutputRoot = Resolve-ProjectPath $OutputRoot
    $configDirectory = Split-Path -Parent $resolvedConfig
    $projectRootPrefix = [System.IO.Path]::GetFullPath($projectRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $assetProtectionPrefix = [System.IO.Path]::GetFullPath((Join-Path $projectRoot '.asset_protection')).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedPrivateKey.StartsWith($projectRootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $resolvedPrivateKey.StartsWith($assetProtectionPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'PrivateKeyPath must be outside the repository or under the ignored .asset_protection directory.'
    }
    if ($resolvedApk -and [System.IO.Path]::GetExtension($resolvedApk) -cne '.apk') {
        throw 'ApkPath must point to a complete .apk file.'
    }
    if ($KeyId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
        throw 'KeyId must contain only letters, digits, dot, underscore, or hyphen.'
    }

    $config = Read-UpdateJson -Path $resolvedConfig
    if ($config -isnot [System.Collections.IDictionary]) { throw 'The generation config must be a JSON object.' }
    Assert-ConfigShape $config 'config' @(
        'release_seq', 'display_version', 'channel', 'platform',
        'updater_protocol_version', 'runtime_compat_id', 'resource_api_version',
        'apk_deltas', 'notes'
    ) @('release_id', 'published_at', 'target_apk', 'resource_snapshot')
    if ($config.platform -cne 'android') { throw 'This schema v1 generator supports platform=android only.' }
    if ($config.release_seq -isnot [int64] -and $config.release_seq -isnot [uint64]) {
        throw 'config.release_seq must be an integer.'
    }
    if ([decimal]$config.release_seq -lt 1) { throw 'config.release_seq must be at least 1.' }
    if ([decimal]$config.release_seq -gt [long]::MaxValue) { throw 'config.release_seq exceeds signed 64-bit range.' }

    $hasTargetApk = $config.Contains('target_apk')
    if (-not $hasTargetApk -and -not $config.Contains('resource_snapshot')) {
        throw 'config must contain target_apk or resource_snapshot.'
    }
    if ($hasTargetApk -and -not $resolvedApk) { throw 'config.target_apk requires -ApkPath.' }
    if (-not $hasTargetApk -and $resolvedApk) { throw '-ApkPath requires config.target_apk.' }
    $apkMetadata = $null
    $targetApk = $null
    if ($hasTargetApk) {
        if ($config.target_apk -isnot [System.Collections.IDictionary]) { throw 'config.target_apk must be an object.' }
        Assert-ConfigShape $config.target_apk 'config.target_apk' @(
            'version_code', 'package_name', 'abis', 'certificate_sha256', 'urls'
        )
        $apkMetadata = Get-UpdateFileMetadata -Path $resolvedApk
        $targetAbis = @(Get-ConfigStringArray $config.target_apk.abis 'config.target_apk.abis')
        [Array]::Sort($targetAbis, [System.StringComparer]::Ordinal)
        $targetApk = [ordered]@{
            version_code = $config.target_apk.version_code
            package_name = $config.target_apk.package_name
            abis = $targetAbis
            sha256 = $apkMetadata.sha256
            certificate_sha256 = ([string]$config.target_apk.certificate_sha256).ToLowerInvariant()
            urls = @(Get-ConfigStringArray $config.target_apk.urls 'config.target_apk.urls')
            size = $apkMetadata.size
        }
    }

    $resourceMetadata = $null
    $resourceSnapshot = $null
    if ($config.Contains('resource_snapshot')) {
        $snapshotConfig = $config.resource_snapshot
        if ($snapshotConfig -isnot [System.Collections.IDictionary]) { throw 'config.resource_snapshot must be an object.' }
        Assert-ConfigShape $snapshotConfig 'config.resource_snapshot' @(
            'id', 'schema_version', 'compatible_runtime_ids', 'asset_key_id',
            'manifest_path', 'manifest_url'
        )
        $resourceManifestPath = Resolve-ConfigPath ([string]$snapshotConfig.manifest_path) $configDirectory
        $resourceMetadata = Get-UpdateFileMetadata -Path $resourceManifestPath
        $resourceManifest = Read-UpdateJson $resourceManifestPath
        Assert-ResourceSnapshotManifest $resourceManifest
        [byte[]]$resourceCanonical = Get-AarCanonicalBytes $resourceManifest
        [byte[]]$resourceBytes = [IO.File]::ReadAllBytes($resourceManifestPath)
        if (-not [Linq.Enumerable]::SequenceEqual($resourceCanonical, $resourceBytes)) {
            throw 'The resource manifest must contain exact aar-cjson-v1 bytes (without BOM or trailing newline).'
        }
        if ($resourceBytes.Length -gt 8388608) { throw 'The resource manifest exceeds the client 8 MiB limit.' }
        $runtimeIds = @(Get-ConfigStringArray $snapshotConfig.compatible_runtime_ids 'config.resource_snapshot.compatible_runtime_ids')
        [Array]::Sort($runtimeIds, [System.StringComparer]::Ordinal)
        [string[]]$manifestRuntimeIds = @($resourceManifest.compatible_runtime_ids)
        [Array]::Sort($manifestRuntimeIds, [System.StringComparer]::Ordinal)
        if ($snapshotConfig.id -cne $resourceManifest.snapshot_id -or
            $snapshotConfig.schema_version -ne $resourceManifest.schema_version -or
            $snapshotConfig.asset_key_id -cne $resourceManifest.asset_key_id -or
            $config.resource_api_version -ne $resourceManifest.resource_api_version -or
            (ConvertTo-AarCanonicalJson $runtimeIds) -cne (ConvertTo-AarCanonicalJson $manifestRuntimeIds)) {
            throw 'Resource snapshot identity or compatibility differs from the resource manifest.'
        }
        $resourceSnapshot = [ordered]@{
            id = $snapshotConfig.id
            schema_version = $snapshotConfig.schema_version
            compatible_runtime_ids = $runtimeIds
            asset_key_id = $snapshotConfig.asset_key_id
            manifest_sha256 = $resourceMetadata.sha256
            manifest_url = $snapshotConfig.manifest_url
            size = $resourceMetadata.size
        }
    }

    $publishedAt = if ($config.Contains('published_at')) {
        [string]$config.published_at
    }
    else {
        [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    }
    $releaseId = if ($config.Contains('release_id')) {
        [string]$config.release_id
    }
    else {
        $stamp = $publishedAt -replace '[-:]', '' -replace 'Z$', 'z'
        '{0}-{1}-{2:d10}-{3}-{4}' -f @(
            $config.platform, $config.channel, [long]$config.release_seq,
            $stamp.ToLowerInvariant(), $(if ($hasTargetApk) { $apkMetadata.sha256.Substring(0, 12) } else { $resourceMetadata.sha256.Substring(0, 12) })
        )
    }

    $deltaConfigs = @(Get-ConfigArray $config.apk_deltas 'config.apk_deltas' -AllowEmpty)
    if (-not $hasTargetApk -and $deltaConfigs.Count -gt 0) {
        throw 'A resource-only release must have an empty apk_deltas array.'
    }
    $deltas = [System.Collections.Generic.List[object]]::new()
    $seenBaseHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    for ($index = 0; $index -lt $deltaConfigs.Count; $index++) {
        $deltaConfig = $deltaConfigs[$index]
        if ($deltaConfig -isnot [System.Collections.IDictionary]) { throw "config.apk_deltas[$index] must be an object." }
        Assert-ConfigShape $deltaConfig "config.apk_deltas[$index]" @(
            'base_sha256', 'patch_path', 'format', 'patch_protocol_version', 'urls'
        )
        $baseHash = ([string]$deltaConfig.base_sha256).ToLowerInvariant()
        if (-not $seenBaseHashes.Add($baseHash)) {
            throw "Duplicate APK delta base SHA-256: $baseHash"
        }
        if ($baseHash -ceq $apkMetadata.sha256) {
            throw 'An APK delta base SHA-256 cannot equal the target APK SHA-256.'
        }
        $patchPath = Resolve-ConfigPath ([string]$deltaConfig.patch_path) $configDirectory
        $patchMetadata = Get-UpdateFileMetadata -Path $patchPath
        if ($patchMetadata.size -ge $apkMetadata.size) {
            Write-Warning "Delta $index is not smaller than the complete APK; clients may prefer the complete APK."
        }
        $deltas.Add([ordered]@{
            base_sha256 = $baseHash
            target_sha256 = $apkMetadata.sha256
            format = $deltaConfig.format
            patch_protocol_version = $deltaConfig.patch_protocol_version
            patch_sha256 = $patchMetadata.sha256
            urls = @(Get-ConfigStringArray $deltaConfig.urls "config.apk_deltas[$index].urls")
            size = $patchMetadata.size
        })
    }
    $sortedDeltas = @($deltas.ToArray() | Sort-Object { $_.base_sha256 })

    if ($config.notes -isnot [System.Collections.IDictionary]) { throw 'config.notes must be an object.' }
    Assert-ConfigShape $config.notes 'config.notes' @() @('gitee_url', 'github_url', 'cached_markdown_url')
    $notes = [ordered]@{ release_id = $releaseId }
    foreach ($name in @('gitee_url', 'github_url', 'cached_markdown_url')) {
        if ($config.notes.Contains($name)) { $notes[$name] = $config.notes[$name] }
    }

    $payload = [ordered]@{
        schema_version = 1
        canonicalization = 'aar-cjson-v1'
        release_id = $releaseId
        release_seq = $config.release_seq
        display_version = $config.display_version
        channel = $config.channel
        platform = $config.platform
        updater_protocol_version = $config.updater_protocol_version
        published_at = $publishedAt
        runtime_compat_id = $config.runtime_compat_id
        resource_api_version = $config.resource_api_version
        apk_deltas = $sortedDeltas
    }
    if ($hasTargetApk) { $payload.target_apk = $targetApk }
    if ($null -ne $resourceSnapshot) { $payload.resource_snapshot = $resourceSnapshot }
    $payload.notes = $notes

    [byte[]]$canonicalBytes = Get-AarCanonicalBytes -Payload $payload
    $signatureValue = New-Ed25519UpdateSignature `
        -PayloadBytes $canonicalBytes `
        -PrivateKeyPath $resolvedPrivateKey `
        -OpenSslPath $OpenSslPath
    $manifest = [ordered]@{
        payload = $payload
        signature = [ordered]@{
            key_id = $KeyId
            algorithm = 'Ed25519'
            signed_object = 'payload'
            canonicalization = 'aar-cjson-v1'
            value_base64 = $signatureValue
        }
    }
    Assert-UpdateManifest -Manifest $manifest

    $releasesRoot = Join-Path $resolvedOutputRoot 'releases'
    $releasesRootForCleanup = $releasesRoot
    if (Test-Path -LiteralPath $releasesRoot) {
        foreach ($existingPath in Get-ChildItem -LiteralPath $releasesRoot -Filter manifest.json -File -Recurse -ErrorAction SilentlyContinue) {
            $existing = Read-UpdateJson -Path $existingPath.FullName
            if ($existing.payload.release_id -ceq $releaseId) {
                throw "release_id '$releaseId' already exists at $($existingPath.FullName); immutable releases cannot be overwritten."
            }
            if ([decimal]$existing.payload.release_seq -eq [decimal]$config.release_seq) {
                throw "release_seq '$($config.release_seq)' is already used by $($existing.payload.release_id)."
            }
        }
    }

    $releaseDirectory = Join-Path $releasesRoot $releaseId
    if (Test-Path -LiteralPath $releaseDirectory) {
        throw "Release output already exists and will not be overwritten: $releaseDirectory"
    }
    [System.IO.Directory]::CreateDirectory($releasesRoot) | Out-Null
    $stagingDirectory = Join-Path $releasesRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($stagingDirectory) | Out-Null
    $stagedManifestPath = Join-Path $stagingDirectory 'manifest.json'
    $stagedCanonicalPath = Join-Path $stagingDirectory 'payload.canonical.json'
    $manifestJson = ConvertTo-Json -InputObject $manifest -Depth 20
    Write-UpdateUtf8File -Path $stagedManifestPath -Content $manifestJson -TrailingNewline
    Write-UpdateUtf8File -Path $stagedCanonicalPath -Content ([System.Text.Encoding]::UTF8.GetString($canonicalBytes))
    $manifestHash = (Get-FileHash -LiteralPath $stagedManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-UpdateUtf8File -Path (Join-Path $stagingDirectory 'manifest.sha256') -Content "$manifestHash  manifest.json" -TrailingNewline
    Move-Item -LiteralPath $stagingDirectory -Destination $releaseDirectory
    $stagingDirectory = $null
    $manifestPath = Join-Path $releaseDirectory 'manifest.json'

    $candidateDirectory = Join-Path $resolvedOutputRoot "channel-candidates\$($config.platform)"
    [System.IO.Directory]::CreateDirectory($candidateDirectory) | Out-Null
    $candidatePath = Join-Path $candidateDirectory "$($config.channel).json"
    $candidateTemporary = Join-Path $candidateDirectory ('.candidate-' + [guid]::NewGuid().ToString('N') + '.json')
    Copy-Item -LiteralPath $manifestPath -Destination $candidateTemporary
    [System.IO.File]::Move($candidateTemporary, $candidatePath, $true)

    Write-Host "Created immutable release manifest: $manifestPath"
    Write-Host "Created channel candidate: $candidatePath"
    Write-Host "Release: $releaseId (sequence $($config.release_seq))"
    if ($hasTargetApk) {
        Write-Host "Target APK SHA-256: $($apkMetadata.sha256)"
        Write-Host "Target APK size: $($apkMetadata.size) bytes"
    }
    else { Write-Host "Resource-only release: $($resourceSnapshot.id)" }
    Write-Host "APK deltas: $($sortedDeltas.Count)"
    Write-Host "Manifest SHA-256: $manifestHash"
}
catch {
    Write-Error "Update manifest generation failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
finally {
    if ($stagingDirectory -and $releasesRootForCleanup -and (Test-Path -LiteralPath $stagingDirectory)) {
        $root = [System.IO.Path]::GetFullPath($releasesRootForCleanup)
        $staging = [System.IO.Path]::GetFullPath($stagingDirectory)
        if ($staging.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and
            ([System.IO.Path]::GetFileName($staging)).StartsWith('.staging-', [System.StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
