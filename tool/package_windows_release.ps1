#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [string]$InputDirectory = 'build/windows/x64/runner/Release',
    [string]$OutputPath = '',
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:\.\d+)?$')]
    [string]$Version,
    [Parameter(Mandatory)]
    [ValidateRange(1, 2147483647)]
    [int]$BuildNumber,
    [string]$VcRuntimeDirectory = '',
    [string[]]$AdditionalRuntimeDirectories = @()
)

# Package an already completed protected build. This script never builds,
# encrypts, launches, removes files, or overwrites a previous package/stage.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

function Resolve-ProjectPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $projectRoot $Path))
}

function Assert-NoLink([IO.FileSystemInfo]$Entry) {
    if (($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Input, runtime, and output paths must not contain symbolic links or junctions.'
    }
}

function Assert-NoLinkedAncestors([string]$Path) {
    $directory = [IO.DirectoryInfo]::new($Path)
    while ($null -ne $directory) {
        if ($directory.Exists) { Assert-NoLink $directory }
        $directory = $directory.Parent
    }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RuntimeFiles([IO.DirectoryInfo]$Directory) {
    $pending = [Collections.Generic.Queue[IO.DirectoryInfo]]::new()
    $pending.Enqueue($Directory)
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    while ($pending.Count -gt 0) {
        foreach ($entry in $pending.Dequeue().GetFileSystemInfos()) {
            Assert-NoLink $entry
            if ($entry -is [IO.DirectoryInfo]) {
                if ($entry.Name -ieq '.asset_protection') { throw 'Private configuration directory found in runtime output.' }
                $pending.Enqueue($entry)
            }
            elseif ($entry -is [IO.FileInfo] -and $entry.Extension -notin @('.lib', '.exp', '.pdb', '.ilk')) {
                # path_provider_android brings JNI transitively into Flutter's FFI
                # bundle list. Windows uses path_provider_windows, registers no JNI
                # plugin, and does not provide a JVM. Do not ship this unused DLL.
                if ($entry.Name -ieq 'dartjni.dll') { continue }
                if ($entry.Extension -in @('.key', '.pem', '.p12', '.pfx') -or
                    $entry.Name -like '*.defines.json' -or
                    $entry.Name -in @('relay_server.json', 'update_server.json', 'gitee_access_token.txt', 'generated_config.cmake')) {
                    throw 'Private configuration or key file found in runtime output.'
                }
                $files.Add($entry)
            }
        }
    }
    return $files.ToArray()
}

$inputRoot = Get-Item -LiteralPath (Resolve-ProjectPath $InputDirectory)
if ($inputRoot -isnot [IO.DirectoryInfo]) { throw 'InputDirectory must be the completed Windows runtime directory.' }
Assert-NoLinkedAncestors $inputRoot.FullName
if (-not $OutputPath) {
    $OutputPath = "build/releases/AgentAtelierR-$Version-build$BuildNumber-windows-x64-release.zip"
}
$output = Resolve-ProjectPath $OutputPath
if ([IO.Path]::GetExtension($output) -ine '.zip') { throw 'OutputPath must end with .zip.' }
$stage = $output + '.stage'
$inputPrefix = $inputRoot.FullName.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if ($output.StartsWith($inputPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'OutputPath must be outside InputDirectory.' }
Assert-NoLinkedAncestors ([IO.Path]::GetDirectoryName($output))
if ((Test-Path -LiteralPath $output) -or (Test-Path -LiteralPath $stage)) {
    throw 'Output ZIP or stage already exists; select a new output path. Existing files are never overwritten.'
}

$exe = Get-Item -LiteralPath (Join-Path $inputRoot.FullName 'AgentAtelierR.exe')
$versionInfo = $exe.VersionInfo
$numericVersion = @($Version.Split('.') | Select-Object -First 3 | ForEach-Object { [int]$_ })
if ($versionInfo.FileVersion -cne $Version -or $versionInfo.ProductVersion -cne $Version -or
    $versionInfo.FileMajorPart -ne $numericVersion[0] -or
    $versionInfo.FileMinorPart -ne $numericVersion[1] -or
    $versionInfo.FileBuildPart -ne $numericVersion[2] -or
    $versionInfo.FilePrivatePart -ne $BuildNumber -or $versionInfo.IsDebug) {
    throw 'Executable version/build does not match the requested public release, or executable is a debug build.'
}
foreach ($relative in @('flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin')) {
    if (-not (Test-Path -LiteralPath (Join-Path $inputRoot.FullName $relative) -PathType Leaf)) {
        throw "Required Flutter runtime file is missing: $relative"
    }
}
$nativeManifest = Join-Path $inputRoot.FullName 'data/flutter_assets/NativeAssetsManifest.json'
if ((Test-Path -LiteralPath $nativeManifest -PathType Leaf) -and
    (Get-Content -LiteralPath $nativeManifest -Raw) -match '(?i)dartjni|package:jni[/"\s]') {
    throw 'Native assets declare JNI. Review Windows JNI support before applying the unused-DLL packaging exclusion.'
}
# Validate the existing tree before copying any explicitly supplied runtime DLLs.
$null = @(Get-RuntimeFiles $inputRoot)
$runtimeSources = [Collections.Generic.Dictionary[string, IO.FileInfo]]::new([StringComparer]::OrdinalIgnoreCase)
$runtimeDirectories = @($AdditionalRuntimeDirectories)
if ($VcRuntimeDirectory) { $runtimeDirectories = @($VcRuntimeDirectory) + $runtimeDirectories }
foreach ($directoryPath in $runtimeDirectories) {
    $directory = Get-Item -LiteralPath (Resolve-ProjectPath $directoryPath)
    if ($directory -isnot [IO.DirectoryInfo]) { throw 'Runtime directory must be a directory containing redistributable DLLs.' }
    Assert-NoLinkedAncestors $directory.FullName
    $dlls = @($directory.GetFiles('*.dll', [IO.SearchOption]::TopDirectoryOnly))
    if ($dlls.Count -eq 0) { throw 'An explicitly supplied runtime directory contains no DLLs.' }
    foreach ($dll in $dlls) {
        Assert-NoLink $dll
        if ($runtimeSources.ContainsKey($dll.Name)) {
            if ((Get-Sha256 $runtimeSources[$dll.Name].FullName) -cne (Get-Sha256 $dll.FullName)) {
                throw 'Explicit runtime directories contain conflicting DLLs with the same filename.'
            }
            continue
        }
        $existing = Join-Path $inputRoot.FullName $dll.Name
        if (Test-Path -LiteralPath $existing) {
            $existingFile = Get-Item -LiteralPath $existing
            Assert-NoLink $existingFile
            if ($existingFile -isnot [IO.FileInfo] -or (Get-Sha256 $existing) -cne (Get-Sha256 $dll.FullName)) {
                throw 'Runtime DLL conflicts with an existing input file; no file was overwritten.'
            }
        }
        $runtimeSources.Add($dll.Name, $dll)
    }
}

if (-not $PSCmdlet.ShouldProcess($output, 'Copy optional runtime DLLs, preserve a complete stage, and create Windows release ZIP')) {
    [ordered]@{ planned_output = $output; planned_stage = $stage; version = $Version; build = $BuildNumber; optional_runtime_dlls = $runtimeSources.Count; packaged = $false } | ConvertTo-Json
    return
}

# Add only missing, explicitly selected redistributable DLLs. Never overwrite.
foreach ($dll in $runtimeSources.Values) {
    $destination = Join-Path $inputRoot.FullName $dll.Name
    if (-not (Test-Path -LiteralPath $destination)) { [IO.File]::Copy($dll.FullName, $destination, $false) }
}
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output)) | Out-Null
[IO.Directory]::CreateDirectory($stage) | Out-Null
$runtimeFiles = @(Get-RuntimeFiles $inputRoot | Sort-Object FullName)
$records = [Collections.Generic.List[object]]::new()
foreach ($file in $runtimeFiles) {
    $relative = [IO.Path]::GetRelativePath($inputRoot.FullName, $file.FullName).Replace('\', '/')
    $destination = Join-Path $stage $relative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    $hash = Get-Sha256 $file.FullName
    [IO.File]::Copy($file.FullName, $destination, $false)
    if ((Get-Item -LiteralPath $destination).Length -ne $file.Length -or (Get-Sha256 $destination) -cne $hash) {
        throw 'A runtime file changed during staging. Incomplete artifacts are preserved for inspection.'
    }
    $records.Add([ordered]@{ path = $relative; size = $file.Length; sha256 = $hash })
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [IO.File]::Open($output, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
$archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($record in $records) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $stage $record.path), $record.path, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
}
finally {
    $archive.Dispose()
    $stream.Dispose()
}
# A concurrently changed build is not a valid package of the current tree.
$currentFiles = @(Get-RuntimeFiles $inputRoot)
if ($currentFiles.Count -ne $records.Count) { throw 'Runtime file set changed during packaging.' }
foreach ($record in $records) {
    $source = Join-Path $inputRoot.FullName $record.path
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-Item -LiteralPath $source).Length -ne $record.size -or (Get-Sha256 $source) -cne $record.sha256) {
        throw 'Runtime contents changed during packaging. Review the preserved ZIP/stage before publishing.'
    }
}
$zip = Get-Item -LiteralPath $output
[ordered]@{
    output_path = $zip.FullName
    stage_path = $stage
    version = $Version
    build = $BuildNumber
    files = $records.Count
    bytes = $zip.Length
    sha256 = Get-Sha256 $zip.FullName
    optional_runtime_dlls = $runtimeSources.Count
    packaged = $true
} | ConvertTo-Json
