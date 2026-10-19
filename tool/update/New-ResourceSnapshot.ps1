[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$SnapshotId,
    [Parameter(Mandatory)][string[]]$CompatibleRuntimeIds,
    [Parameter(Mandatory)][string]$AssetKeyId,
    [Parameter(Mandatory)][string[]]$ObjectBaseUrl,
    [long]$ResourceApiVersion = 1,
    [string]$ResourcePathPrefix = '',
    [string]$OutputRoot = 'build/update-resources'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $PSScriptRoot 'UpdateManifestTools.psm1') -Force
$stagingDirectory = $null
$resolvedOutputRoot = $null

function Resolve-ProjectPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $projectRoot $Path))
}

function Assert-NoLink([IO.FileSystemInfo]$Entry) {
    if (($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Resource input and output cannot contain symlinks or junctions: $($Entry.FullName)"
    }
}

function Assert-NoLinkedAncestors([string]$Path) {
    $entry = [IO.DirectoryInfo]::new($Path)
    while ($null -ne $entry) {
        if ($entry.Exists) { Assert-NoLink $entry }
        $entry = $entry.Parent
    }
}

try {
    $source = Get-Item -LiteralPath (Resolve-ProjectPath $SourceDirectory) -Force
    if ($source -isnot [IO.DirectoryInfo]) { throw 'SourceDirectory must be a directory.' }
    Assert-NoLinkedAncestors $source.FullName
    $resolvedOutputRoot = Resolve-ProjectPath $OutputRoot
    Assert-NoLinkedAncestors $resolvedOutputRoot
    $sourcePrefix = $source.FullName.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($resolvedOutputRoot.Equals($source.FullName, [StringComparison]::OrdinalIgnoreCase) -or
        $resolvedOutputRoot.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'OutputRoot must be outside SourceDirectory.'
    }
    foreach ($identifier in @($SnapshotId, $AssetKeyId) + @($CompatibleRuntimeIds)) {
        if ($identifier -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
            throw 'Snapshot, asset key and runtime identifiers must use the v1 identifier format.'
        }
    }
    if ($CompatibleRuntimeIds.Count -lt 1 -or $CompatibleRuntimeIds.Count -gt 32 -or
        @($CompatibleRuntimeIds | Select-Object -Unique).Count -ne $CompatibleRuntimeIds.Count) {
        throw 'CompatibleRuntimeIds must contain 1 to 32 unique identifiers.'
    }
    if ($ResourceApiVersion -lt 1) { throw 'ResourceApiVersion must be positive.' }
    if ($ResourcePathPrefix) { Assert-SafeResourcePath $ResourcePathPrefix 'ResourcePathPrefix' }
    if ($ObjectBaseUrl.Count -lt 1 -or $ObjectBaseUrl.Count -gt 8) {
        throw 'ObjectBaseUrl must contain 1 to 8 HTTPS mirror roots.'
    }
    $baseUrls = [Collections.Generic.List[string]]::new()
    $seenUrls = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in $ObjectBaseUrl) {
        [uri]$uri = $null
        if (-not [uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -cne 'https' -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
            throw 'ObjectBaseUrl must use HTTPS without credentials, query or fragment.'
        }
        $normalized = $uri.AbsoluteUri.TrimEnd('/')
        if (-not $seenUrls.Add($normalized)) { throw 'ObjectBaseUrl contains a duplicate mirror.' }
        $baseUrls.Add($normalized)
    }

    # Enumerate explicitly so a junction cannot silently skip or escape the tree.
    $pending = [Collections.Generic.Queue[IO.DirectoryInfo]]::new()
    $pending.Enqueue($source)
    $filesByPath = [Collections.Generic.Dictionary[string, IO.FileInfo]]::new([StringComparer]::Ordinal)
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        foreach ($entry in $directory.GetFileSystemInfos()) {
            Assert-NoLink $entry
            if ($entry -is [IO.DirectoryInfo]) { $pending.Enqueue($entry); continue }
            if ($entry -isnot [IO.FileInfo]) { throw 'Unsupported resource filesystem entry.' }
            $relative = [IO.Path]::GetRelativePath($source.FullName, $entry.FullName).Replace('\', '/')
            $resourcePath = if ($ResourcePathPrefix) { "$ResourcePathPrefix/$relative" } else { $relative }
            Assert-SafeResourcePath $resourcePath
            if (-not $filesByPath.TryAdd($resourcePath, $entry)) { throw "Duplicate resource path: $resourcePath" }
            if ($filesByPath.Count -gt 100000) { throw 'More than 100000 resource objects.' }
        }
    }
    [string[]]$paths = @($filesByPath.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    [IO.Directory]::CreateDirectory($resolvedOutputRoot) | Out-Null
    $stagingDirectory = Join-Path $resolvedOutputRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
    $stagedObjects = Join-Path $stagingDirectory 'objects/sha256'
    [IO.Directory]::CreateDirectory($stagedObjects) | Out-Null
    $objects = [Collections.Generic.List[object]]::new()
    $stagedByHash = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($path in $paths) {
        $metadata = Get-UpdateFileMetadata -Path $filesByPath[$path].FullName
        if ($metadata.size -gt 2147483648) { throw "Resource exceeds the 2 GiB object limit: $path" }
        if (-not $stagedByHash.ContainsKey($metadata.sha256)) {
            $stagedPath = Join-Path $stagedObjects $metadata.sha256
            [IO.File]::Copy($filesByPath[$path].FullName, $stagedPath, $false)
            $stagedMetadata = Get-UpdateFileMetadata -Path $stagedPath
            if ($metadata.sha256 -cne $stagedMetadata.sha256 -or $metadata.size -ne $stagedMetadata.size) {
                throw "Source changed while staging: $path"
            }
            $stagedByHash.Add($metadata.sha256, $metadata)
        }
        $objects.Add([ordered]@{
            path = $path
            sha256 = $metadata.sha256
            size = $metadata.size
            urls = @($baseUrls | ForEach-Object { "$_/objects/sha256/$($metadata.sha256)" })
        })
    }
    [string[]]$runtimeIds = @($CompatibleRuntimeIds)
    [Array]::Sort($runtimeIds, [StringComparer]::Ordinal)
    $manifest = [ordered]@{
        asset_key_id = $AssetKeyId
        canonicalization = 'aar-cjson-v1'
        compatible_runtime_ids = $runtimeIds
        objects = $objects.ToArray()
        resource_api_version = $ResourceApiVersion
        schema_version = [long]1
        snapshot_id = $SnapshotId
    }
    Assert-ResourceSnapshotManifest $manifest
    [byte[]]$manifestBytes = Get-AarCanonicalBytes $manifest
    if ($manifestBytes.Length -gt 8388608) { throw 'Resource manifest exceeds the client 8 MiB limit.' }
    $snapshotDirectory = Join-Path $resolvedOutputRoot "snapshots/$SnapshotId"
    $manifestPath = Join-Path $snapshotDirectory 'manifest.json'
    if (Test-Path -LiteralPath $snapshotDirectory) {
        Assert-NoLinkedAncestors $snapshotDirectory
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw 'Snapshot directory exists without its immutable manifest.'
        }
        Assert-NoLink (Get-Item -LiteralPath $manifestPath -Force)
        [byte[]]$existingBytes = [IO.File]::ReadAllBytes($manifestPath)
        if (-not [Linq.Enumerable]::SequenceEqual($manifestBytes, $existingBytes)) {
            throw "Snapshot '$SnapshotId' already exists with different content."
        }
    }

    $objectDirectory = Join-Path $resolvedOutputRoot 'objects/sha256'
    Assert-NoLinkedAncestors $objectDirectory
    [IO.Directory]::CreateDirectory($objectDirectory) | Out-Null
    foreach ($entry in $stagedByHash.GetEnumerator()) {
        $destination = Join-Path $objectDirectory $entry.Key
        if (Test-Path -LiteralPath $destination) {
            Assert-NoLink (Get-Item -LiteralPath $destination -Force)
            $existing = Get-UpdateFileMetadata $destination
            if ($existing.sha256 -cne $entry.Key -or $existing.size -ne $entry.Value.size) {
                throw "Content-addressed object already exists with different content: $($entry.Key)"
            }
        }
        else { [IO.File]::Move((Join-Path $stagedObjects $entry.Key), $destination, $false) }
    }
    if (-not (Test-Path -LiteralPath $snapshotDirectory)) {
        $stagedSnapshot = Join-Path $stagingDirectory 'snapshot'
        [IO.Directory]::CreateDirectory($stagedSnapshot) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $stagedSnapshot 'manifest.json'), $manifestBytes)
        $snapshotsRoot = Join-Path $resolvedOutputRoot 'snapshots'
        Assert-NoLinkedAncestors $snapshotsRoot
        [IO.Directory]::CreateDirectory($snapshotsRoot) | Out-Null
        [IO.Directory]::Move($stagedSnapshot, $snapshotDirectory)
    }
    $metadata = Get-UpdateFileMetadata $manifestPath
    Write-Host "Created immutable resource snapshot: $manifestPath"
    Write-Host "Snapshot: $SnapshotId; resources: $($objects.Count); unique objects: $($stagedByHash.Count)"
    Write-Host "Manifest SHA-256: $($metadata.sha256); size: $($metadata.size) bytes"
}
catch {
    Write-Error "Resource snapshot generation failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
finally {
    if ($stagingDirectory -and $resolvedOutputRoot -and (Test-Path -LiteralPath $stagingDirectory)) {
        $root = [IO.Path]::GetFullPath($resolvedOutputRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $staging = [IO.Path]::GetFullPath($stagingDirectory)
        if ($staging.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and
            ([IO.Path]::GetFileName($staging)).StartsWith('.staging-', [StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
