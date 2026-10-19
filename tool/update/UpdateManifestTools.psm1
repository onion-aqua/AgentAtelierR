Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Canonicalization = 'aar-cjson-v1'
$script:Sha256Pattern = '^[0-9a-f]{64}$'

function Read-UpdateJsonElement {
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement]$Element,
        [string]$Path = '$'
    )

    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $result = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) {
                if ($result.Contains($property.Name)) {
                    throw "Duplicate JSON property at $Path.$($property.Name)."
                }
                $result[$property.Name] = Read-UpdateJsonElement -Element $property.Value -Path "$Path.$($property.Name)"
            }
            return $result
        }
        ([System.Text.Json.JsonValueKind]::Array) {
            $items = [System.Collections.Generic.List[object]]::new()
            $index = 0
            foreach ($item in $Element.EnumerateArray()) {
                $items.Add((Read-UpdateJsonElement -Element $item -Path "$Path[$index]"))
                $index++
            }
            return ,$items.ToArray()
        }
        ([System.Text.Json.JsonValueKind]::String) {
            return $Element.GetString()
        }
        ([System.Text.Json.JsonValueKind]::Number) {
            [long]$signed = 0
            if ($Element.TryGetInt64([ref]$signed)) {
                return $signed
            }
            [uint64]$unsigned = 0
            if ($Element.TryGetUInt64([ref]$unsigned)) {
                return $unsigned
            }
            throw "Only integer JSON numbers are allowed at $Path."
        }
        ([System.Text.Json.JsonValueKind]::True) { return $true }
        ([System.Text.Json.JsonValueKind]::False) { return $false }
        ([System.Text.Json.JsonValueKind]::Null) { return $null }
        default { throw "Unsupported JSON value at $Path." }
    }
}

function Read-UpdateJson {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $text = [System.IO.File]::ReadAllText($resolved, [System.Text.Encoding]::UTF8)
    $document = $null
    try {
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.AllowTrailingCommas = $false
        $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
        $options.MaxDepth = 64
        $document = [System.Text.Json.JsonDocument]::Parse($text, $options)
        return Read-UpdateJsonElement -Element $document.RootElement
    }
    finally {
        if ($null -ne $document) { $document.Dispose() }
    }
}

function ConvertTo-AarJsonString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return 'null' }
    $builder = [System.Text.StringBuilder]::new($Value.Length + 2)
    [void]$builder.Append('"')
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        $code = [int]$character
        $escaped = $true
        switch ($code) {
            0x22 { [void]$builder.Append('\"') }
            0x5c { [void]$builder.Append('\\') }
            0x08 { [void]$builder.Append('\b') }
            0x09 { [void]$builder.Append('\t') }
            0x0a { [void]$builder.Append('\n') }
            0x0c { [void]$builder.Append('\f') }
            0x0d { [void]$builder.Append('\r') }
            default { $escaped = $false }
        }
        if ($escaped) { continue }
        if ($code -lt 0x20) {
            [void]$builder.Append(('\u{0:x4}' -f $code))
            continue
        }
        if ([char]::IsHighSurrogate($character)) {
            if ($index + 1 -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$index + 1])) {
                throw 'Canonical JSON cannot encode an unpaired high surrogate.'
            }
            [void]$builder.Append($character)
            $index++
            [void]$builder.Append($Value[$index])
            continue
        }
        if ([char]::IsLowSurrogate($character)) {
            throw 'Canonical JSON cannot encode an unpaired low surrogate.'
        }
        [void]$builder.Append($character)
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-AarCanonicalJson {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return ConvertTo-AarJsonString -Value $Value }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }

    if ($Value -is [System.Collections.IDictionary]) {
        [string[]]$keys = @($Value.Keys | ForEach-Object {
            if ($_ -isnot [string]) { throw 'Canonical JSON object keys must be strings.' }
            [string]$_
        })
        [Array]::Sort($keys, [System.StringComparer]::Ordinal)
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($key in $keys) {
            $encodedKey = ConvertTo-AarJsonString -Value $key
            $encodedValue = ConvertTo-AarCanonicalJson -Value $Value[$key]
            $parts.Add("${encodedKey}:${encodedValue}")
        }
        return '{' + [string]::Join(',', $parts) + '}'
    }

    if ($Value -is [pscustomobject]) {
        $object = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $object[$property.Name] = $property.Value
        }
        return ConvertTo-AarCanonicalJson -Value $object
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $Value) {
            $parts.Add((ConvertTo-AarCanonicalJson -Value $item))
        }
        return '[' + [string]::Join(',', $parts) + ']'
    }

    $integerTypes = @(
        [sbyte], [byte], [int16], [uint16], [int32], [uint32], [int64], [uint64]
    )
    foreach ($integerType in $integerTypes) {
        if ($Value -is $integerType) {
            return ([System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
        }
    }
    throw "aar-cjson-v1 does not support values of type $($Value.GetType().FullName)."
}

function Get-AarCanonicalBytes {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Payload)

    $json = ConvertTo-AarCanonicalJson -Value $Payload
    return [System.Text.Encoding]::UTF8.GetBytes($json)
}

function Write-UpdateUtf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [switch]$TrailingNewline
    )

    $parent = Split-Path -Parent $Path
    if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    if ($TrailingNewline) { $Content += "`n" }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-UpdateFileMetadata {
    param([Parameter(Mandatory)][string]$Path)

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -le 0) {
        throw "Update artifact is missing or empty: $($file.FullName)"
    }
    return [ordered]@{
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        size = [long]$file.Length
        path = $file.FullName
    }
}

function Resolve-UpdateOpenSsl {
    param([string]$OpenSslPath = '')

    if ($OpenSslPath) {
        $resolved = (Resolve-Path -LiteralPath $OpenSslPath -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "OpenSSL executable is not a file: $resolved"
        }
        return $resolved
    }
    $command = Get-Command openssl -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    foreach ($candidate in @(
        'C:\Program Files\Git\usr\bin\openssl.exe',
        'C:\Program Files\Git\mingw64\bin\openssl.exe',
        'C:\Program Files\OpenSSL-Win64\bin\openssl.exe'
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'OpenSSL 3.x is required for Ed25519 signing. Pass -OpenSslPath explicitly.'
}

function Invoke-UpdateProcess {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$FailureMessage = 'External command failed.'
    )

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
        if (-not $process.Start()) { throw $FailureMessage }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $detail = (($stderr + ' ' + $stdout) -replace '[\r\n]+', ' ').Trim()
            if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) }
            throw "${FailureMessage} Exit code $($process.ExitCode). $detail"
        }
        return $stdout
    }
    finally {
        $process.Dispose()
    }
}

function New-UpdateTemporaryDirectory {
    $root = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $path = Join-Path $root ('aar-update-' + [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}

function Remove-UpdateTemporaryDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $root = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not ([System.IO.Path]::GetFileName($resolved)).StartsWith('aar-update-', [System.StringComparison]::Ordinal)) {
        throw "Refusing to remove unexpected temporary directory: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

function New-Ed25519UpdateSignature {
    param(
        [Parameter(Mandatory)][byte[]]$PayloadBytes,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [string]$OpenSslPath = ''
    )

    $privateKey = (Resolve-Path -LiteralPath $PrivateKeyPath -ErrorAction Stop).Path
    $openssl = Resolve-UpdateOpenSsl -OpenSslPath $OpenSslPath
    $temporary = New-UpdateTemporaryDirectory
    try {
        $payloadPath = Join-Path $temporary 'payload.bin'
        $signaturePath = Join-Path $temporary 'signature.bin'
        $publicKeyPath = Join-Path $temporary 'public.pem'
        [System.IO.File]::WriteAllBytes($payloadPath, $PayloadBytes)
        Invoke-UpdateProcess -Executable $openssl -Arguments @(
            'pkeyutl', '-sign', '-rawin', '-inkey', $privateKey,
            '-in', $payloadPath, '-out', $signaturePath
        ) -FailureMessage 'Ed25519 signing failed.' | Out-Null
        Invoke-UpdateProcess -Executable $openssl -Arguments @(
            'pkey', '-in', $privateKey, '-pubout', '-out', $publicKeyPath
        ) -FailureMessage 'Could not derive the Ed25519 public key.' | Out-Null
        Invoke-UpdateProcess -Executable $openssl -Arguments @(
            'pkeyutl', '-verify', '-rawin', '-pubin', '-inkey', $publicKeyPath,
            '-in', $payloadPath, '-sigfile', $signaturePath
        ) -FailureMessage 'Ed25519 signature round-trip verification failed.' | Out-Null
        [byte[]]$signature = [System.IO.File]::ReadAllBytes($signaturePath)
        if ($signature.Length -ne 64) {
            throw "Unexpected Ed25519 signature length: $($signature.Length) bytes."
        }
        return [System.Convert]::ToBase64String($signature)
    }
    finally {
        Remove-UpdateTemporaryDirectory -Path $temporary
    }
}

function Test-Ed25519UpdateSignature {
    param(
        [Parameter(Mandatory)][byte[]]$PayloadBytes,
        [Parameter(Mandatory)][string]$SignatureBase64,
        [Parameter(Mandatory)][string]$PublicKeyPath,
        [string]$OpenSslPath = ''
    )

    try { [byte[]]$signature = [System.Convert]::FromBase64String($SignatureBase64) }
    catch { return $false }
    if ($signature.Length -ne 64) { return $false }
    $publicKey = (Resolve-Path -LiteralPath $PublicKeyPath -ErrorAction Stop).Path
    $openssl = Resolve-UpdateOpenSsl -OpenSslPath $OpenSslPath
    $temporary = New-UpdateTemporaryDirectory
    try {
        $payloadPath = Join-Path $temporary 'payload.bin'
        $signaturePath = Join-Path $temporary 'signature.bin'
        [System.IO.File]::WriteAllBytes($payloadPath, $PayloadBytes)
        [System.IO.File]::WriteAllBytes($signaturePath, $signature)
        try {
            Invoke-UpdateProcess -Executable $openssl -Arguments @(
                'pkeyutl', '-verify', '-rawin', '-pubin', '-inkey', $publicKey,
                '-in', $payloadPath, '-sigfile', $signaturePath
            ) -FailureMessage 'Ed25519 verification failed.' | Out-Null
            return $true
        }
        catch { return $false }
    }
    finally {
        Remove-UpdateTemporaryDirectory -Path $temporary
    }
}

function Assert-UpdateObjectShape {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Required,
        [string[]]$Optional = @()
    )

    foreach ($key in $Required) {
        if (-not $Value.Contains($key)) { throw "$Name is missing required field '$key'." }
    }
    $allowed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in @($Required) + @($Optional)) { [void]$allowed.Add($key) }
    foreach ($key in $Value.Keys) {
        if ($key -isnot [string] -or -not $allowed.Contains([string]$key)) {
            throw "$Name contains unknown schema v1 field '$key'."
        }
    }
}

function Assert-UpdateString {
    param([object]$Value, [string]$Name, [string]$Pattern = '', [switch]$AllowEmpty)
    if ($Value -isnot [string]) { throw "$Name must be a string." }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value)) { throw "$Name cannot be empty." }
    if ($Pattern -and $Value -notmatch $Pattern) { throw "$Name has an invalid value." }
}

function Assert-UpdateInteger {
    param(
        [object]$Value,
        [string]$Name,
        [long]$Minimum = 0,
        [decimal]$Maximum = [long]::MaxValue
    )
    if ($Value -isnot [sbyte] -and $Value -isnot [byte] -and
        $Value -isnot [int16] -and $Value -isnot [uint16] -and
        $Value -isnot [int32] -and $Value -isnot [uint32] -and
        $Value -isnot [int64] -and $Value -isnot [uint64]) {
        throw "$Name must be an integer."
    }
    if ([decimal]$Value -lt $Minimum) { throw "$Name must be at least $Minimum." }
    if ([decimal]$Value -gt $Maximum) { throw "$Name must be at most $Maximum." }
}

function Assert-UpdateHttpsUrl {
    param([object]$Value, [string]$Name)
    Assert-UpdateString -Value $Value -Name $Name
    [uri]$uri = $null
    if (-not [uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.UserInfo -or $uri.Fragment) {
        throw "$Name must be an absolute HTTPS URL without embedded credentials or a fragment."
    }
}

function Assert-SafeResourcePath {
    param([object]$Value, [string]$Name = 'resource path')

    Assert-UpdateString -Value $Value -Name $Name
    if ($Value.Trim() -cne $Value -or $Value.Length -gt 512 -or $Value.StartsWith('/') -or $Value.EndsWith('/') -or
        $Value.Contains('\') -or $Value.Contains('//') -or $Value.Contains(':') -or
        $Value -match '[\x00-\x1f\x7f]') {
        throw "$Name is not a safe managed relative path."
    }
    foreach ($segment in $Value.Split('/')) {
        if (-not $segment -or $segment -ceq '.' -or $segment -ceq '..') {
            throw "$Name cannot leave the managed resource directory."
        }
    }
}

function Assert-UpdateArray {
    param([object]$Value, [string]$Name, [switch]$AllowEmpty)
    if ($Value -is [string] -or $Value -isnot [System.Collections.IEnumerable] -or
        $Value -is [System.Collections.IDictionary]) {
        throw "$Name must be an array."
    }
    $items = @($Value)
    if (-not $AllowEmpty -and $items.Count -eq 0) { throw "$Name cannot be empty." }
    return $items
}

function Assert-UpdateStringArray {
    param([object]$Value, [string]$Name, [switch]$HttpsUrls)
    $items = @(Assert-UpdateArray -Value $Value -Name $Name)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    for ($index = 0; $index -lt $items.Count; $index++) {
        if ($HttpsUrls) {
            Assert-UpdateHttpsUrl -Value $items[$index] -Name "$Name[$index]"
        }
        else {
            Assert-UpdateString -Value $items[$index] -Name "$Name[$index]" -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        }
        if (-not $seen.Add([string]$items[$index])) { throw "$Name contains a duplicate value." }
    }
}

function Assert-ResourceSnapshotManifest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Manifest)

    Assert-UpdateObjectShape -Value $Manifest -Name 'resource manifest' -Required @(
        'asset_key_id', 'canonicalization', 'compatible_runtime_ids', 'objects',
        'resource_api_version', 'schema_version', 'snapshot_id'
    )
    if ($Manifest.schema_version -ne 1) { throw 'resource manifest.schema_version must be 1.' }
    if ($Manifest.canonicalization -cne $script:Canonicalization) {
        throw "resource manifest.canonicalization must be $script:Canonicalization."
    }
    Assert-UpdateString $Manifest.snapshot_id 'resource manifest.snapshot_id' '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
    Assert-UpdateInteger $Manifest.resource_api_version 'resource manifest.resource_api_version' 1
    Assert-UpdateStringArray $Manifest.compatible_runtime_ids 'resource manifest.compatible_runtime_ids'
    $runtimeIds = @(Assert-UpdateArray $Manifest.compatible_runtime_ids 'resource manifest.compatible_runtime_ids')
    if ($runtimeIds.Count -gt 32) { throw 'resource manifest.compatible_runtime_ids has more than 32 entries.' }
    Assert-UpdateString $Manifest.asset_key_id 'resource manifest.asset_key_id' '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'

    $objects = @(Assert-UpdateArray $Manifest.objects 'resource manifest.objects' -AllowEmpty)
    if ($objects.Count -gt 100000) { throw 'resource manifest.objects has more than 100000 entries.' }
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $hashSizes = [System.Collections.Generic.Dictionary[string, long]]::new([System.StringComparer]::Ordinal)
    $previousPath = $null
    for ($index = 0; $index -lt $objects.Count; $index++) {
        if ($objects[$index] -isnot [System.Collections.IDictionary]) {
            throw "resource manifest.objects[$index] must be an object."
        }
        $object = $objects[$index]
        $name = "resource manifest.objects[$index]"
        Assert-UpdateObjectShape -Value $object -Name $name -Required @('path', 'sha256', 'size', 'urls')
        Assert-SafeResourcePath -Value $object.path -Name "$name.path"
        if (-not $seenPaths.Add([string]$object.path)) { throw 'resource manifest contains a duplicate path.' }
        if ($null -ne $previousPath -and [StringComparer]::Ordinal.Compare($previousPath, [string]$object.path) -ge 0) {
            throw 'resource manifest.objects must be sorted by ordinal resource path.'
        }
        $previousPath = [string]$object.path
        Assert-UpdateString $object.sha256 "$name.sha256" $script:Sha256Pattern
        Assert-UpdateInteger $object.size "$name.size" 1 2147483648
        if ($hashSizes.ContainsKey($object.sha256) -and $hashSizes[$object.sha256] -ne $object.size) {
            throw 'The same resource hash cannot declare different sizes.'
        }
        $hashSizes[$object.sha256] = $object.size
        Assert-UpdateStringArray $object.urls "$name.urls" -HttpsUrls
        $urls = @(Assert-UpdateArray $object.urls "$name.urls")
        if ($urls.Count -gt 8) { throw "$name.urls has more than 8 entries." }
    }
}

function Assert-UpdateManifest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Manifest)

    Assert-UpdateObjectShape -Value $Manifest -Name 'manifest' -Required @('payload', 'signature')
    if ($Manifest.payload -isnot [System.Collections.IDictionary]) { throw 'payload must be an object.' }
    if ($Manifest.signature -isnot [System.Collections.IDictionary]) { throw 'signature must be an object.' }
    $payload = $Manifest.payload
    Assert-UpdateObjectShape -Value $payload -Name 'payload' -Required @(
        'schema_version', 'canonicalization', 'release_id', 'release_seq',
        'display_version', 'channel', 'platform', 'updater_protocol_version',
        'published_at', 'runtime_compat_id', 'resource_api_version',
        'apk_deltas', 'notes'
    ) -Optional @('target_apk', 'resource_snapshot')

    if ($payload.schema_version -ne 1) { throw 'payload.schema_version must be 1.' }
    if ($payload.canonicalization -cne $script:Canonicalization) { throw "payload.canonicalization must be $script:Canonicalization." }
    Assert-UpdateString $payload.release_id 'payload.release_id' '^[a-z0-9][a-z0-9._-]{7,127}$'
    Assert-UpdateInteger $payload.release_seq 'payload.release_seq' 1
    Assert-UpdateString $payload.display_version 'payload.display_version' '^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:[ _.-][0-9A-Za-z._ -]+)?$'
    Assert-UpdateString $payload.channel 'payload.channel' '^[a-z0-9][a-z0-9._-]{0,31}$'
    if ($payload.platform -cne 'android') { throw 'payload.platform must be android for schema v1.' }
    Assert-UpdateInteger $payload.updater_protocol_version 'payload.updater_protocol_version' 1
    Assert-UpdateString $payload.published_at 'payload.published_at' '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    try { [void][DateTimeOffset]::ParseExact($payload.published_at, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal) }
    catch { throw 'payload.published_at must be a valid UTC timestamp with second precision.' }
    Assert-UpdateString $payload.runtime_compat_id 'payload.runtime_compat_id' '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
    Assert-UpdateInteger $payload.resource_api_version 'payload.resource_api_version' 1

    $hasTargetApk = $payload.Contains('target_apk')
    $hasResourceSnapshot = $payload.Contains('resource_snapshot')
    if (-not $hasTargetApk -and -not $hasResourceSnapshot) {
        throw 'payload must contain target_apk or resource_snapshot.'
    }

    $targetHash = $null
    if ($payload.Contains('target_apk')) {
        if ($payload.target_apk -isnot [System.Collections.IDictionary]) { throw 'payload.target_apk must be an object.' }
        $target = $payload.target_apk
        Assert-UpdateObjectShape $target 'payload.target_apk' @(
            'version_code', 'package_name', 'abis', 'sha256',
            'certificate_sha256', 'urls', 'size'
        )
        Assert-UpdateInteger $target.version_code 'payload.target_apk.version_code' 1 2100000000
        Assert-UpdateString $target.package_name 'payload.target_apk.package_name' '^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$'
        Assert-UpdateStringArray $target.abis 'payload.target_apk.abis'
        Assert-UpdateString $target.sha256 'payload.target_apk.sha256' $script:Sha256Pattern
        Assert-UpdateString $target.certificate_sha256 'payload.target_apk.certificate_sha256' $script:Sha256Pattern
        Assert-UpdateStringArray $target.urls 'payload.target_apk.urls' -HttpsUrls
        Assert-UpdateInteger $target.size 'payload.target_apk.size' 1
        $targetHash = $target.sha256
    }

    $deltas = @(Assert-UpdateArray $payload.apk_deltas 'payload.apk_deltas' -AllowEmpty)
    if (-not $hasTargetApk -and $deltas.Count -ne 0) {
        throw 'A resource-only payload must have an empty apk_deltas array.'
    }
    $baseHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    for ($index = 0; $index -lt $deltas.Count; $index++) {
        if ($deltas[$index] -isnot [System.Collections.IDictionary]) { throw "payload.apk_deltas[$index] must be an object." }
        $delta = $deltas[$index]
        $name = "payload.apk_deltas[$index]"
        Assert-UpdateObjectShape $delta $name @(
            'base_sha256', 'target_sha256', 'format', 'patch_protocol_version',
            'patch_sha256', 'urls', 'size'
        )
        Assert-UpdateString $delta.base_sha256 "$name.base_sha256" $script:Sha256Pattern
        Assert-UpdateString $delta.target_sha256 "$name.target_sha256" $script:Sha256Pattern
        Assert-UpdateString $delta.format "$name.format" '^[a-z0-9][a-z0-9._-]{0,31}$'
        Assert-UpdateInteger $delta.patch_protocol_version "$name.patch_protocol_version" 1
        Assert-UpdateString $delta.patch_sha256 "$name.patch_sha256" $script:Sha256Pattern
        Assert-UpdateStringArray $delta.urls "$name.urls" -HttpsUrls
        Assert-UpdateInteger $delta.size "$name.size" 1
        if ($null -eq $targetHash -or $delta.target_sha256 -cne $targetHash) {
            throw "$name.target_sha256 must match payload.target_apk.sha256."
        }
        if (-not $baseHashes.Add($delta.base_sha256)) { throw 'Only one APK delta per exact base SHA-256 is allowed.' }
    }

    if ($payload.Contains('resource_snapshot')) {
        if ($payload.resource_snapshot -isnot [System.Collections.IDictionary]) { throw 'payload.resource_snapshot must be an object.' }
        $snapshot = $payload.resource_snapshot
        Assert-UpdateObjectShape $snapshot 'payload.resource_snapshot' @(
            'id', 'schema_version', 'compatible_runtime_ids', 'asset_key_id',
            'manifest_sha256', 'manifest_url', 'size'
        )
        Assert-UpdateString $snapshot.id 'payload.resource_snapshot.id' '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        Assert-UpdateInteger $snapshot.schema_version 'payload.resource_snapshot.schema_version' 1
        Assert-UpdateStringArray $snapshot.compatible_runtime_ids 'payload.resource_snapshot.compatible_runtime_ids'
        Assert-UpdateString $snapshot.asset_key_id 'payload.resource_snapshot.asset_key_id' '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        Assert-UpdateString $snapshot.manifest_sha256 'payload.resource_snapshot.manifest_sha256' $script:Sha256Pattern
        Assert-UpdateHttpsUrl $snapshot.manifest_url 'payload.resource_snapshot.manifest_url'
        Assert-UpdateInteger $snapshot.size 'payload.resource_snapshot.size' 1
    }

    if ($payload.notes -isnot [System.Collections.IDictionary]) { throw 'payload.notes must be an object.' }
    Assert-UpdateObjectShape $payload.notes 'payload.notes' @('release_id') @('gitee_url', 'github_url', 'cached_markdown_url')
    if ($payload.notes.release_id -cne $payload.release_id) { throw 'payload.notes.release_id must match payload.release_id.' }
    foreach ($name in @('gitee_url', 'github_url', 'cached_markdown_url')) {
        if ($payload.notes.Contains($name)) { Assert-UpdateHttpsUrl $payload.notes[$name] "payload.notes.$name" }
    }

    $signature = $Manifest.signature
    Assert-UpdateObjectShape $signature 'signature' @(
        'key_id', 'algorithm', 'signed_object', 'canonicalization', 'value_base64'
    )
    Assert-UpdateString $signature.key_id 'signature.key_id' '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
    if ($signature.algorithm -cne 'Ed25519') { throw 'signature.algorithm must be Ed25519.' }
    if ($signature.signed_object -cne 'payload') { throw 'signature.signed_object must be payload.' }
    if ($signature.canonicalization -cne $script:Canonicalization) { throw "signature.canonicalization must be $script:Canonicalization." }
    Assert-UpdateString $signature.value_base64 'signature.value_base64'
    try { [byte[]]$signatureBytes = [Convert]::FromBase64String($signature.value_base64) }
    catch { throw 'signature.value_base64 is not valid padded base64.' }
    if ($signatureBytes.Length -ne 64 -or [Convert]::ToBase64String($signatureBytes) -cne $signature.value_base64) {
        throw 'signature.value_base64 must be canonical padded base64 for a 64-byte Ed25519 signature.'
    }
}

Export-ModuleMember -Function @(
    'Read-UpdateJson', 'ConvertTo-AarCanonicalJson', 'Get-AarCanonicalBytes',
    'Write-UpdateUtf8File', 'Get-UpdateFileMetadata', 'Resolve-UpdateOpenSsl',
    'Invoke-UpdateProcess', 'New-Ed25519UpdateSignature',
    'Test-Ed25519UpdateSignature', 'Assert-UpdateManifest',
    'Assert-SafeResourcePath', 'Assert-ResourceSnapshotManifest'
)
