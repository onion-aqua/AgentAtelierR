param(
    [string]$Device = "emulator-5554",

    [string]$RelayServerConfig = ''
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
        Write-Host 'No private PC Agent configuration found; running the public configurable variant.'
    }
    & dart run tool/protect_character_assets.dart --key-file $keyFile
    if ($LASTEXITCODE -ne 0) { throw "Character asset protection failed." }
    $assetKey = (Get-Content -LiteralPath $keyFile -Raw).Trim()
    $runArgs = @('run', '-d', $Device, '--no-pub', "--dart-define=AAR_CHARACTER_ASSET_KEY=$assetKey")
    if ($privateRelayDefines) {
        $runArgs += "--dart-define-from-file=$privateRelayDefines"
    }
    & flutter @runArgs
    if ($LASTEXITCODE -ne 0) { throw "Protected Flutter run failed." }
}
finally {
    Pop-Location
}
