param(
    [ValidateSet("apk", "appbundle", "windows")]
    [string]$Target = "apk",

    [ValidateSet("debug", "profile", "release")]
    [string]$Mode = "debug",

    [string]$DeviceId = "a43d2d7a",

    [switch]$Install,

    [switch]$Offline,

    [string]$RelayPushConfig = '',

    [string]$RelayServerConfig = '',

    [string]$UpdateConfig = '',

    [string]$EntryPoint = ''
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$keyFile = Join-Path $projectRoot ".asset_protection\character_assets.key"

Push-Location $projectRoot
try {
    # The separately acquired Spine runtime is local-only. Reapply the small
    # checked-in integration patch when building from an unpatched checkout.
    $faceRuntimePath = Join-Path $projectRoot 'packages\spine_flutter\lib\spine_flutter.dart'
    if (Test-Path -LiteralPath $faceRuntimePath) {
        $faceRuntimeSource = Get-Content -LiteralPath $faceRuntimePath -Raw
        $faceApiReady = $faceRuntimeSource.Contains('List<double> getDeform()') -and
            $faceRuntimeSource.Contains('int get runtimeIdentity') -and
            $faceRuntimeSource.Contains('List<PhysicsConstraint> getPhysicsConstraints()')
        foreach ($relativePath in @(
            'lib\spine_flutter_bindings_generated.dart',
            'src\spine-cpp-lite\spine-cpp-lite.h',
            'src\spine-cpp-lite\spine-cpp-lite.cpp'
        )) {
            $faceApiPath = Join-Path $projectRoot "packages\spine_flutter\$relativePath"
            if (-not (Test-Path -LiteralPath $faceApiPath) -or
                -not (Get-Content -LiteralPath $faceApiPath -Raw).Contains('spine_slot_set_deform')) {
                $faceApiReady = $false
            }
        }
        $physicsBindings = Join-Path $projectRoot 'packages\spine_flutter\lib\spine_flutter_bindings_generated.dart'
        if (Test-Path -LiteralPath $physicsBindings) {
            if (-not (Get-Content -LiteralPath $physicsBindings -Raw).Contains("'spine_physics_constraint_reset_fully'")) {
                $faceApiReady = $false
            }
        }
        if (-not $faceApiReady) {
            $facePatchPython = Get-Command python -ErrorAction SilentlyContinue
            if ($null -eq $facePatchPython) {
                throw 'Spine face deformation API is missing. Run tool/apply_spine_face_deform_patch.py with Python, then rebuild.'
            }
            & $facePatchPython.Source (Join-Path $projectRoot 'tool\apply_spine_face_deform_patch.py')
            if ($LASTEXITCODE -ne 0) { throw 'Spine face deformation integration patch failed.' }
        }
    }
    $dependencyArgs = @('pub', 'get')
    if ($Offline) { $dependencyArgs += '--offline' }
    & flutter @dependencyArgs
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed." }

    $privateRelayDefines = ''
    $privateRelaySource = Join-Path $projectRoot '.asset_protection\relay_server.json'
    if ($RelayServerConfig) {
        $privateRelaySource = (Resolve-Path -LiteralPath $RelayServerConfig).Path
    }
    if (Test-Path -LiteralPath $privateRelaySource) {
        $privateRelayDefines = Join-Path $projectRoot '.asset_protection\relay_server.defines.json'
        & dart run tool/protect_relay_server.dart --config-file $privateRelaySource --output-file $privateRelayDefines --check-public-files
        if ($LASTEXITCODE -ne 0) { throw 'Private PC Agent server preparation failed.' }
    }
    else {
        Write-Host 'No private PC Agent configuration found; building the public configurable variant.'
    }

    $privateUpdateDefines = ''
    $privateUpdateSource = Join-Path $projectRoot '.asset_protection\update_server.json'
    if ($UpdateConfig) {
        $privateUpdateSource = (Resolve-Path -LiteralPath $UpdateConfig).Path
    }
    if (Test-Path -LiteralPath $privateUpdateSource) {
        $privateUpdateDefines = Join-Path $projectRoot '.asset_protection\update_server.defines.json'
        & dart run tool/protect_update_config.dart --config-file $privateUpdateSource --output-file $privateUpdateDefines --check-public-files
        if ($LASTEXITCODE -ne 0) { throw 'Private update configuration preparation failed.' }
    }
    else {
        Write-Host 'No private update configuration found; self-hosted update checks will stay disabled.'
    }

    & dart run tool/protect_character_assets.dart --key-file $keyFile
    if ($LASTEXITCODE -ne 0) { throw "Character asset protection failed." }

    $assetKey = (Get-Content -LiteralPath $keyFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($assetKey)) {
        throw "Character asset key is empty: $keyFile"
    }

    if ($Target -eq "appbundle") { $Mode = "release" }
    $flutterArgs = @("build", $Target, "--$Mode", "--no-pub", "--dart-define=AAR_CHARACTER_ASSET_KEY=$assetKey")
    if ($EntryPoint) {
        $flutterArgs += @('--target', (Resolve-Path -LiteralPath $EntryPoint).Path)
    }
    if ($privateRelayDefines) {
        $flutterArgs += "--dart-define-from-file=$privateRelayDefines"
    }
    if ($privateUpdateDefines) {
        $flutterArgs += "--dart-define-from-file=$privateUpdateDefines"
    }
    if ($RelayPushConfig) {
        $resolvedPushConfig = (Resolve-Path -LiteralPath $RelayPushConfig).Path
        $pushConfig = Get-Content -LiteralPath $resolvedPushConfig -Raw | ConvertFrom-Json
        $allowedPushFields = @('RELAY_PUSH_PROVIDER', 'RELAY_FCM_API_KEY', 'RELAY_FCM_APP_ID', 'RELAY_FCM_SENDER_ID', 'RELAY_FCM_PROJECT_ID')
        foreach ($property in $pushConfig.PSObject.Properties) {
            if ($property.Name -notin $allowedPushFields -or $property.Value -isnot [string]) {
                throw 'Relay push config must contain only documented public project identifiers, never device tokens or private keys.'
            }
        }
        $flutterArgs += "--dart-define-from-file=$resolvedPushConfig"
    }
    if ($Mode -eq "release") {
        $symbols = Join-Path $projectRoot "build\symbols"
        $flutterArgs += @("--obfuscate", "--split-debug-info=$symbols")
    }
    & flutter @flutterArgs
    if ($LASTEXITCODE -ne 0) { throw "Protected Flutter build failed." }

    if ($Install) {
        if ($Target -ne "apk") { throw "-Install is supported only for APK builds." }
        $apkName = if ($Mode -eq "debug") { "app-debug.apk" } elseif ($Mode -eq "profile") { "app-profile.apk" } else { "app-release.apk" }
        $apkPath = Join-Path $projectRoot "build\app\outputs\flutter-apk\$apkName"
        if (-not (Test-Path -LiteralPath $apkPath)) { throw "APK was not found: $apkPath" }
        & adb -s $DeviceId install -r $apkPath
        if ($LASTEXITCODE -ne 0) { throw "APK installation failed." }
    }
}
finally {
    Pop-Location
}
