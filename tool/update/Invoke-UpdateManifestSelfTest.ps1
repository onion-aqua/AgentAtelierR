[CmdletBinding()]
param([string]$OpenSslPath = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $PSScriptRoot 'UpdateManifestTools.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReleaseNotesTools.psm1') -Force

function Invoke-ExpectedFailure {
    param([string]$Executable, [string[]]$Arguments, [string]$Name)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Could not start negative test: $Name" }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $null = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -eq 0) { throw "Negative test unexpectedly succeeded: $Name" }
        Write-Host "Expected rejection passed: $Name"
    }
    finally { $process.Dispose() }
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('aar-update-selftest-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
try {
    $openssl = Resolve-UpdateOpenSsl -OpenSslPath $OpenSslPath
    $pwsh = (Get-Process -Id $PID).Path

    $notesCalls = [Collections.Generic.List[string]]::new()
    $notesSources = @([ordered]@{ name = 'gitee' }, [ordered]@{ name = 'github' })
    $notes = Get-ReleaseNotesFromSources -Sources $notesSources -ExpectedTag 'v-selftest' -FetchResponse {
        param($source)
        $notesCalls.Add($source.name)
        if ($source.name -ceq 'gitee') { return @{ tag_name = 'different-tag'; body = 'wrong release' } }
        return @{ tag_name = 'v-selftest'; body = "更新信息`n使用方法"; draft = $false }
    }
    if ($notes.source -cne 'github' -or $notes.body -cne "更新信息`n使用方法" -or
        [string]::Join(',', $notesCalls) -cne 'gitee,github') {
        throw 'Release notes did not reject a mismatched tag and fall back in the expected order.'
    }
    $notesCalls.Clear()
    $notes = Get-ReleaseNotesFromSources -Sources $notesSources -ExpectedTag 'v-selftest' -FetchResponse {
        param($source)
        $notesCalls.Add($source.name)
        return @{ tag_name = 'v-selftest'; body = 'Gitee release notes' }
    }
    if ($notes.source -cne 'gitee' -or [string]::Join(',', $notesCalls) -cne 'gitee') {
        throw 'Release notes did not prefer the first successful Gitee source.'
    }
    $rejectedDraft = $false
    try { Get-ValidatedReleaseNotesBody @{ tag_name = 'v-selftest'; body = 'draft'; draft = $true } 'v-selftest' | Out-Null }
    catch { $rejectedDraft = $true }
    if (-not $rejectedDraft) { throw 'Draft release notes were not rejected.' }
    Write-Host 'Release notes source ordering, tag matching and draft rejection passed (local responses only).'

    $fixtureInput = Join-Path $projectRoot 'test\fixtures\update\canonical-input.json'
    $fixtureExpected = Join-Path $projectRoot 'test\fixtures\update\canonical-payload.json'
    $fixtureHash = Join-Path $projectRoot 'test\fixtures\update\canonical-payload.sha256'
    $fixture = Read-UpdateJson -Path $fixtureInput
    $canonical = ConvertTo-AarCanonicalJson -Value $fixture
    $expected = [System.IO.File]::ReadAllText($fixtureExpected, [Text.Encoding]::UTF8).TrimEnd("`r", "`n")
    if ($canonical -cne $expected) { throw 'Canonical JSON fixture bytes changed.' }
    $actualHash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))
    ).ToLowerInvariant()
    $expectedHash = [System.IO.File]::ReadAllText($fixtureHash, [Text.Encoding]::UTF8).Trim()
    if ($actualHash -cne $expectedHash) { throw 'Canonical JSON fixture SHA-256 changed.' }
    Write-Host "Canonical JSON fixture passed: $actualHash"
    $emptyArrayPath = Join-Path $temporaryRoot 'empty-array.json'
    Write-UpdateUtf8File -Path $emptyArrayPath -Content '{"items":[]}'
    $emptyArrayFixture = Read-UpdateJson -Path $emptyArrayPath
    if ((ConvertTo-AarCanonicalJson $emptyArrayFixture) -cne '{"items":[]}') {
        throw 'Canonical JSON did not preserve an empty array.'
    }

    $privateKey = Join-Path $temporaryRoot 'private.pem'
    $publicKey = Join-Path $temporaryRoot 'public.pem'
    Invoke-UpdateProcess -Executable $openssl -Arguments @(
        'genpkey', '-algorithm', 'ED25519', '-out', $privateKey
    ) -FailureMessage 'Could not create temporary Ed25519 self-test key.' | Out-Null
    Invoke-UpdateProcess -Executable $openssl -Arguments @(
        'pkey', '-in', $privateKey, '-pubout', '-out', $publicKey
    ) -FailureMessage 'Could not derive temporary Ed25519 self-test public key.' | Out-Null

    $apk = Join-Path $temporaryRoot 'target.apk'
    $patch = Join-Path $temporaryRoot 'base-to-target.patch'
    [System.IO.File]::WriteAllBytes($apk, [Text.Encoding]::UTF8.GetBytes('self-test target apk bytes'))
    [System.IO.File]::WriteAllBytes($patch, [Text.Encoding]::UTF8.GetBytes('self-test delta bytes'))
    $resourceSource = Join-Path $temporaryRoot 'resource-input'
    [IO.Directory]::CreateDirectory((Join-Path $resourceSource 'nested')) | Out-Null
    Write-UpdateUtf8File (Join-Path $resourceSource 'nested/日本語.txt') 'resource test bytes'
    Write-UpdateUtf8File (Join-Path $resourceSource 'duplicate.txt') 'resource test bytes'
    $resourceOutput = Join-Path $temporaryRoot 'resource-output'
    $resourceScript = Join-Path $PSScriptRoot 'New-ResourceSnapshot.ps1'
    $resourceArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $resourceScript,
        '-SourceDirectory', $resourceSource, '-SnapshotId', 'resources-selftest-000001',
        '-CompatibleRuntimeIds', 'android-runtime-selftest', '-AssetKeyId', 'asset-key-selftest',
        '-ObjectBaseUrl', 'https://updates.example.invalid/resources',
        '-ResourcePathPrefix', 'assets/protected', '-OutputRoot', $resourceOutput
    )
    Invoke-UpdateProcess -Executable $pwsh -Arguments $resourceArgs -FailureMessage 'Resource snapshot generation failed.' | Write-Host
    # Re-running identical inputs is safe; the snapshot and objects stay immutable.
    Invoke-UpdateProcess -Executable $pwsh -Arguments $resourceArgs -FailureMessage 'Identical snapshot reuse failed.' | Out-Null
    $resource = Join-Path $resourceOutput 'snapshots/resources-selftest-000001/manifest.json'
    $resourceObjects = Join-Path $resourceOutput 'objects/sha256'
    $resourceSnapshot = Read-UpdateJson $resource
    Assert-ResourceSnapshotManifest $resourceSnapshot
    if (@($resourceSnapshot.objects).Count -ne 2 -or @(Get-ChildItem -LiteralPath $resourceObjects -File).Count -ne 1) {
        throw 'Resource staging did not preserve paths or deduplicate identical bytes.'
    }
    $resourceSchema = Join-Path $projectRoot 'docs/update/resource-snapshot.schema.json'
    if (-not (Get-Content -LiteralPath $resource -Raw -Encoding UTF8 | Test-Json -SchemaFile $resourceSchema)) {
        throw 'Generated resource manifest did not satisfy resource-snapshot.schema.json.'
    }
    Write-UpdateUtf8File (Join-Path $resourceSource 'nested/日本語.txt') 'changed resource test bytes'
    Invoke-ExpectedFailure -Executable $pwsh -Arguments $resourceArgs -Name 'resource snapshot ID with different content'
    Write-UpdateUtf8File (Join-Path $resourceSource 'nested/日本語.txt') 'resource test bytes'
    $unsafeResourceArgs = @($resourceArgs)
    $unsafeResourceArgs[[Array]::IndexOf($unsafeResourceArgs, 'assets/protected')] = '../escape'
    Invoke-ExpectedFailure -Executable $pwsh -Arguments $unsafeResourceArgs -Name 'unsafe resource path prefix'

    $config = [ordered]@{
        release_id = 'android-stable-selftest-000001'
        release_seq = [long]900000001
        display_version = '9.9.9-test'
        channel = 'stable'
        platform = 'android'
        updater_protocol_version = [long]1
        published_at = '2030-01-02T03:04:05Z'
        runtime_compat_id = 'android-runtime-selftest'
        resource_api_version = [long]1
        target_apk = [ordered]@{
            version_code = [long]900000001
            package_name = 'com.example.agentatelier'
            abis = @('armeabi-v7a', 'arm64-v8a')
            certificate_sha256 = ('11' * 32)
            urls = @('https://updates.example.invalid/apk/selftest.apk')
        }
        apk_deltas = @([ordered]@{
            base_sha256 = ('22' * 32)
            patch_path = $patch
            format = 'hdiffpatch'
            patch_protocol_version = [long]1
            urls = @('https://updates.example.invalid/delta/selftest.patch')
        })
        resource_snapshot = [ordered]@{
            id = 'resources-selftest-000001'
            schema_version = [long]1
            compatible_runtime_ids = @('android-runtime-selftest')
            asset_key_id = 'asset-key-selftest'
            manifest_path = $resource
            manifest_url = 'https://updates.example.invalid/resources/selftest.json'
        }
        notes = [ordered]@{
            gitee_url = 'https://gitee.example.invalid/agentatelier/releases/tag/selftest'
            github_url = 'https://github.example.invalid/agentatelier/releases/tag/selftest'
            cached_markdown_url = 'https://updates.example.invalid/notes/selftest.md'
        }
    }
    $configPath = Join-Path $temporaryRoot 'config.json'
    Write-UpdateUtf8File -Path $configPath -Content (ConvertTo-Json $config -Depth 20) -TrailingNewline
    $outputRoot = Join-Path $temporaryRoot 'output'
    $newScript = Join-Path $PSScriptRoot 'New-UpdateManifest.ps1'
    $testScript = Join-Path $PSScriptRoot 'Test-UpdateManifest.ps1'
    Invoke-UpdateProcess -Executable $pwsh -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $newScript,
        '-ConfigPath', $configPath, '-ApkPath', $apk,
        '-PrivateKeyPath', $privateKey, '-KeyId', 'selftest-key-1',
        '-OutputRoot', $outputRoot, '-OpenSslPath', $openssl
    ) -FailureMessage 'Manifest generation self-test failed.' | Write-Host

    $manifestPath = Join-Path $outputRoot 'releases\android-stable-selftest-000001\manifest.json'
    $manifestSchema = Join-Path $projectRoot 'docs\update\update-manifest.schema.json'
    $schemaValid = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
        Test-Json -SchemaFile $manifestSchema
    if (-not $schemaValid) { throw 'Generated manifest did not satisfy update-manifest.schema.json.' }
    Invoke-UpdateProcess -Executable $pwsh -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $testScript,
        '-ManifestPath', $manifestPath, '-PublicKeyPath', $publicKey,
        '-ApkPath', $apk, '-DeltaPatchPath', $patch,
        '-ResourceManifestPath', $resource, '-ResourceObjectsRoot', $resourceObjects, '-RequireAllLocalArtifacts',
        '-OpenSslPath', $openssl
    ) -FailureMessage 'Manifest verification self-test failed.' | Write-Host

    $tamperedPath = Join-Path $temporaryRoot 'tampered.json'
    $tampered = Read-UpdateJson -Path $manifestPath
    $tampered.payload.display_version = '9.9.9-tampered'
    Write-UpdateUtf8File -Path $tamperedPath -Content (ConvertTo-Json $tampered -Depth 20) -TrailingNewline
    Invoke-ExpectedFailure -Executable $pwsh -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $testScript,
        '-ManifestPath', $tamperedPath, '-PublicKeyPath', $publicKey,
        '-OpenSslPath', $openssl
    ) -Name 'tampered signed payload'

    $collision = [ordered]@{}
    foreach ($entry in $config.GetEnumerator()) { $collision[$entry.Key] = $entry.Value }
    $collision.release_id = 'android-stable-selftest-collision'
    $collisionPath = Join-Path $temporaryRoot 'collision.json'
    Write-UpdateUtf8File -Path $collisionPath -Content (ConvertTo-Json $collision -Depth 20) -TrailingNewline
    Invoke-ExpectedFailure -Executable $pwsh -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $newScript,
        '-ConfigPath', $collisionPath, '-ApkPath', $apk,
        '-PrivateKeyPath', $privateKey, '-KeyId', 'selftest-key-1',
        '-OutputRoot', $outputRoot, '-OpenSslPath', $openssl
    ) -Name 'duplicate release_seq'

    $resourceOnly = [ordered]@{}
    foreach ($entry in $config.GetEnumerator()) {
        if ($entry.Key -cne 'target_apk') { $resourceOnly[$entry.Key] = $entry.Value }
    }
    $resourceOnly.Remove('release_id')
    $resourceOnly.release_seq = [long]900000002
    $resourceOnly.apk_deltas = @()
    $resourceOnlyPath = Join-Path $temporaryRoot 'resource-only-config.json'
    Write-UpdateUtf8File $resourceOnlyPath (ConvertTo-Json $resourceOnly -Depth 20)
    $publishSchema = Join-Path $projectRoot 'docs/update/update-publish-config.schema.json'
    if (-not (Get-Content $resourceOnlyPath -Raw -Encoding UTF8 | Test-Json -SchemaFile $publishSchema)) {
        throw 'Resource-only publication config did not satisfy its schema.'
    }
    Invoke-UpdateProcess -Executable $pwsh -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $newScript,
        '-ConfigPath', $resourceOnlyPath, '-PrivateKeyPath', $privateKey,
        '-KeyId', 'selftest-key-1', '-OutputRoot', $outputRoot, '-OpenSslPath', $openssl
    ) -FailureMessage 'Resource-only manifest generation failed.' | Write-Host
    $resourceOnlyManifest = @(Get-ChildItem (Join-Path $outputRoot 'releases') -Filter manifest.json -Recurse -File |
        Where-Object { (Read-UpdateJson $_.FullName).payload.release_seq -eq 900000002 })
    if ($resourceOnlyManifest.Count -ne 1) { throw 'Resource-only manifest was not generated exactly once.' }
    $resourceOnlyPayload = (Read-UpdateJson $resourceOnlyManifest[0].FullName).payload
    if ($resourceOnlyPayload.Contains('target_apk') -or @($resourceOnlyPayload.apk_deltas).Count -ne 0) {
        throw 'Resource-only payload unexpectedly included APK fields.'
    }
    if (-not (Get-Content $resourceOnlyManifest[0].FullName -Raw -Encoding UTF8 | Test-Json -SchemaFile $manifestSchema)) {
        throw 'Resource-only manifest did not satisfy update-manifest.schema.json.'
    }
    Invoke-UpdateProcess -Executable $pwsh -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $testScript,
        '-ManifestPath', $resourceOnlyManifest[0].FullName, '-PublicKeyPath', $publicKey,
        '-ResourceManifestPath', $resource, '-ResourceObjectsRoot', $resourceObjects,
        '-RequireAllLocalArtifacts', '-OpenSslPath', $openssl
    ) -FailureMessage 'Resource-only manifest verification failed.' | Write-Host

    $resourceOnly.apk_deltas = $config.apk_deltas
    Write-UpdateUtf8File $resourceOnlyPath (ConvertTo-Json $resourceOnly -Depth 20)
    Invoke-ExpectedFailure -Executable $pwsh -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $newScript,
        '-ConfigPath', $resourceOnlyPath, '-PrivateKeyPath', $privateKey,
        '-KeyId', 'selftest-key-1', '-OutputRoot', $outputRoot, '-OpenSslPath', $openssl
    ) -Name 'resource-only manifest with APK deltas'
    $resourceOnly.apk_deltas = @()
    $resourceOnly.Remove('resource_snapshot')
    Write-UpdateUtf8File $resourceOnlyPath (ConvertTo-Json $resourceOnly -Depth 20)
    Invoke-ExpectedFailure -Executable $pwsh -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $newScript,
        '-ConfigPath', $resourceOnlyPath, '-PrivateKeyPath', $privateKey,
        '-KeyId', 'selftest-key-1', '-OutputRoot', $outputRoot, '-OpenSslPath', $openssl
    ) -Name 'manifest without APK or resource target'

    Write-UpdateUtf8File (Join-Path $resourceObjects $resourceSnapshot.objects[0].sha256) 'corrupt staged object'
    Invoke-ExpectedFailure -Executable $pwsh -Arguments $resourceArgs -Name 'corrupt content-addressed staged object'

    Write-Host 'All update manifest self-tests passed.'
}
finally {
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolved = [System.IO.Path]::GetFullPath($temporaryRoot)
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        ([System.IO.Path]::GetFileName($resolved)).StartsWith('aar-update-selftest-', [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
