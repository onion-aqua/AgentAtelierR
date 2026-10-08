param(
    [ValidateSet("apk", "appbundle", "windows")]
    [string]$Target = "apk",

    [ValidateSet("debug", "profile", "release")]
    [string]$Mode = "debug",

    [string]$DeviceId = "a43d2d7a",

    [switch]$Install,

    [string]$RelayPushConfig = '',

    [string]$RelayServerConfig = '',

    [string]$EntryPoint = ''
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$keyFile = Join-Path $projectRoot ".asset_protection\character_assets.key"

Push-Location $projectRoot
try {
    & flutter pub get
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
