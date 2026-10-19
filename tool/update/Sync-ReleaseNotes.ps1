[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$OutputPath = 'build/update-publish/notes.md'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $PSScriptRoot 'UpdateManifestTools.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReleaseNotesTools.psm1') -Force

function Resolve-ProjectPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $projectRoot $Path))
}

try {
    $config = Read-UpdateJson (Resolve-ProjectPath $ConfigPath)
    if ($config -isnot [Collections.IDictionary]) { throw 'Config must be a JSON object.' }
    $allowed = @('expected_tag', 'gitee_release_api_url', 'github_release_api_url',
        'gitee_token_environment', 'github_token_environment')
    foreach ($key in $config.Keys) { if ($key -cnotin $allowed) { throw 'Config contains an unsupported field.' } }
    if (-not $config.Contains('expected_tag') -or $config.expected_tag -isnot [string] -or
        [string]::IsNullOrWhiteSpace($config.expected_tag)) { throw 'Config must contain expected_tag.' }
    $sources = [Collections.Generic.List[object]]::new()
    foreach ($name in @('gitee', 'github')) {
        $urlField = "${name}_release_api_url"
        $tokenField = "${name}_token_environment"
        if (-not $config.Contains($urlField)) {
            if ($config.Contains($tokenField)) { throw 'A token environment name requires its corresponding API URL.' }
            continue
        }
        [uri]$uri = $null
        if ($config[$urlField] -isnot [string] -or
            -not [uri]::TryCreate($config[$urlField], [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -cne 'https' -or -not $uri.Host -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
            throw 'Release API URLs must use HTTPS without credentials, query or fragment.'
        }
        $tokenEnvironment = ''
        if ($config.Contains($tokenField)) {
            if ($config[$tokenField] -isnot [string] -or $config[$tokenField] -cnotmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$') {
                throw 'Token environment variable names are invalid.'
            }
            $tokenEnvironment = $config[$tokenField]
        }
        $sources.Add([ordered]@{ name = $name; uri = $uri; token_environment = $tokenEnvironment })
    }
    if ($sources.Count -eq 0) { throw 'At least one public release API URL is required.' }
    $fetch = {
        param($source)
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        $client.MaxResponseContentBufferSize = 2097152
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $source.uri)
        $response = $null
        try {
            $request.Headers.UserAgent.ParseAdd('AgentAtelierR-ReleaseNotes/1')
            $request.Headers.Accept.ParseAdd('application/json')
            if ($source.token_environment) {
                $token = [Environment]::GetEnvironmentVariable($source.token_environment)
                if (-not $token) { throw 'Configured token environment variable is empty.' }
                $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
            }
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) { throw 'Release API returned a non-success status.' }
            $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            return ConvertFrom-Json -InputObject $json -AsHashtable -Depth 32
        }
        finally {
            if ($null -ne $response) { $response.Dispose() }
            $request.Dispose()
            $client.Dispose()
        }
    }
    $result = Get-ReleaseNotesFromSources -Sources $sources.ToArray() -ExpectedTag $config.expected_tag -FetchResponse $fetch
    $output = Resolve-ProjectPath $OutputPath
    $directory = Split-Path -Parent $output
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.notes-' + [guid]::NewGuid().ToString('N'))
    try {
        Write-UpdateUtf8File $temporary $result.body
        [IO.File]::Move($temporary, $output, $true)
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    Write-Host "Synchronized release notes from $($result.source): $output"
}
catch {
    Write-Error 'Release notes synchronization failed. Check the expected tag and HTTPS API configuration; existing notes were preserved.' -ErrorAction Continue
    exit 1
}
