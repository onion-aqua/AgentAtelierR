param(
    [string]$Repository = 'onion-aqua/AgentAtelierR',
    [string]$Tag = 'v1.0.0-dx',
    [string]$ReleaseName = 'AgentAtelierR 1.0.0 DX',
    [string]$NotesPath = 'docs/CHANGELOG_1.0.0-DX.md',
    [string]$ApkPath = 'build/app/outputs/flutter-apk/app-release.apk',
    [string]$AssetName = 'AgentAtelierR-1.0.0-DX-release.apk',
    [switch]$Publish
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$script:githubClient = $null
$accessToken = $null

function Resolve-ProjectPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $projectRoot $Path))
}

function Get-GitHubToken {
    $process = $null
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'git.exe'
        $startInfo.Arguments = 'credential fill'
        $startInfo.WorkingDirectory = $projectRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'Could not start Git Credential Manager.'
        }
        $credentialInput = "protocol=https`nhost=github.com`n`n"
        $process.StandardInput.Write($credentialInput)
        $process.StandardInput.Close()
        $credentialOutput = $process.StandardOutput.ReadToEnd()
        $credentialError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        Write-Verbose "credential helper exit=$($process.ExitCode), outputLength=$($credentialOutput.Length), errorLength=$($credentialError.Length)"
        $credentialLines = @($credentialOutput -split "`r?`n")
        $passwordLine = $credentialLines |
            Where-Object { $_ -is [string] -and $_.StartsWith('password=') } |
            Select-Object -First 1
        if ([string]::IsNullOrEmpty($passwordLine)) {
            $fieldNames = foreach ($fieldLine in $credentialLines) {
                if ($fieldLine -match '^[^=]+=') {
                    ($fieldLine -split '=', 2)[0]
                }
            }
            $fields = $fieldNames -join ','
            throw "Git Credential Manager returned no GitHub access token (exit $($process.ExitCode), fields: $fields)."
        }
        return $passwordLine.Substring('password='.Length)
    }
    finally {
        $credentialInput = $null
        $credentialOutput = $null
        $credentialError = $null
        $credentialLines = $null
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Get-ApiError([int]$Status, [string]$ResponseText) {
    if ($Status -eq 401 -or $Status -eq 403) {
        return "HTTP $Status. Check the stored GitHub account and repository permissions."
    }
    $message = ''
    try {
        $data = ConvertFrom-Json -InputObject $ResponseText -AsHashtable
        $message = [string]$data['message']
    }
    catch {
        $message = ''
    }
    $message = ($message -replace '[\r\n]+', ' ').Trim()
    if ($message.Length -gt 240) { $message = $message.Substring(0, 240) }
    if ($message) { return "HTTP ${Status}: $message" }
    return "HTTP $Status."
}

function Send-GitHubJson {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body = $null,
        [int[]]$AllowedStatus = @(200)
    )
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::new($Method),
        "https://api.github.com$Path"
    )
    $response = $null
    try {
        if ($null -ne $Body) {
            $json = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
            $request.Content = [System.Net.Http.StringContent]::new(
                $json,
                [System.Text.Encoding]::UTF8,
                'application/json'
            )
        }
        $response = $script:githubClient.SendAsync(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($status -notin $AllowedStatus) {
            throw "GitHub API $Method $Path failed: $(Get-ApiError $status $responseText)"
        }
        $data = if ([string]::IsNullOrWhiteSpace($responseText)) {
            $null
        }
        else {
            ConvertFrom-Json -InputObject $responseText -AsHashtable
        }
        return [pscustomobject]@{ Status = $status; Data = $data }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
    }
}

function Get-ReleaseAssets([long]$ReleaseId) {
    $assets = [System.Collections.Generic.List[object]]::new()
    for ($page = 1; $page -le 100; $page++) {
        $result = Send-GitHubJson GET "/repos/$Repository/releases/$ReleaseId/assets?per_page=100&page=$page"
        $batch = @($result.Data)
        foreach ($asset in $batch) { $assets.Add($asset) }
        if ($batch.Count -lt 100) { return $assets.ToArray() }
    }
    throw 'The release has more than 10,000 assets; refusing to choose an incomplete list.'
}

function Upload-ReleaseAsset {
    param(
        [long]$ReleaseId,
        [string]$Name,
        [System.IO.FileInfo]$File
    )
    $encodedName = [System.Uri]::EscapeDataString($Name)
    $uri = "https://uploads.github.com/repos/$Repository/releases/$ReleaseId/assets?name=$encodedName"
    $fileStream = [System.IO.File]::OpenRead($File.FullName)
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post,
        $uri
    )
    $response = $null
    try {
        $request.Content = [System.Net.Http.StreamContent]::new($fileStream, 1048576)
        $request.Content.Headers.ContentType =
            [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/vnd.android.package-archive')
        $request.Content.Headers.ContentLength = $File.Length
        $response = $script:githubClient.SendAsync(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($status -ne 201) {
            throw "APK upload failed: $(Get-ApiError $status $responseText)"
        }
        $asset = ConvertFrom-Json -InputObject $responseText -AsHashtable
        if ($asset['state'] -ne 'uploaded' -or [long]$asset['size'] -ne $File.Length) {
            throw "Uploaded asset $($asset['id']) did not pass state/size verification."
        }
        return $asset
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        $fileStream.Dispose()
    }
}

try {
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'Repository must have the form owner/name.'
    }
    if ($Tag -notmatch '^v[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw 'Tag must be a GitHub release tag such as v1.0.0-dx.'
    }
    if ($AssetName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.apk$') {
        throw 'AssetName must be a plain .apk filename.'
    }

    $resolvedApk = Resolve-ProjectPath $ApkPath
    $resolvedNotes = Resolve-ProjectPath $NotesPath
    $apk = Get-Item -LiteralPath $resolvedApk -ErrorAction SilentlyContinue
    $notes = Get-Item -LiteralPath $resolvedNotes -ErrorAction SilentlyContinue
    if ($Publish -and ($null -eq $apk -or $apk.Length -le 0)) {
        throw "APK is missing or empty: $resolvedApk"
    }
    if ($Publish -and $null -eq $notes) {
        throw "Release notes are missing: $resolvedNotes"
    }

    $accessToken = Get-GitHubToken
    $script:githubClient = [System.Net.Http.HttpClient]::new()
    $script:githubClient.Timeout = [TimeSpan]::FromHours(2)
    $script:githubClient.DefaultRequestHeaders.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $accessToken)
    $script:githubClient.DefaultRequestHeaders.UserAgent.ParseAdd('AgentAtelierR-release-script/1.0')
    $script:githubClient.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
    $script:githubClient.DefaultRequestHeaders.Add('X-GitHub-Api-Version', '2022-11-28')

    $repositoryResult = Send-GitHubJson GET "/repos/$Repository"
    $canPush = $repositoryResult.Data['permissions'] -and
        $repositoryResult.Data['permissions']['push'] -eq $true
    $encodedTag = [System.Uri]::EscapeDataString($Tag)
    $tagResult = Send-GitHubJson GET "/repos/$Repository/git/ref/tags/$encodedTag" -AllowedStatus @(200, 404)
    $releaseResult = Send-GitHubJson GET "/repos/$Repository/releases/tags/$encodedTag" -AllowedStatus @(200, 404)

    Write-Host "GitHub API authentication: available; repository push permission: $canPush"
    Write-Host "Remote tag $Tag`: $(if ($tagResult.Status -eq 200) { 'present' } else { 'missing' })"
    Write-Host "Release $Tag`: $(if ($releaseResult.Status -eq 200) { 'present' } else { 'missing' })"
    Write-Host "APK: $(if ($null -ne $apk) { "$($apk.Length) bytes" } else { 'missing' })"
    Write-Host "Notes: $(if ($null -ne $notes) { 'present' } else { 'missing' })"

    if ($Publish) {
        if (-not $canPush) {
            throw 'The stored GitHub account has no push permission on this repository.'
        }
        if ($tagResult.Status -ne 200) {
            throw "Push the $Tag tag before creating its release."
        }
        $notesText = Get-Content -LiteralPath $resolvedNotes -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($notesText)) {
            throw "Release notes are empty: $resolvedNotes"
        }
        $sha256 = (Get-FileHash -LiteralPath $resolvedApk -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($releaseResult.Status -eq 200) {
            $release = $releaseResult.Data
        }
        else {
            $create = Send-GitHubJson POST "/repos/$Repository/releases" -AllowedStatus @(201) -Body @{
                tag_name = $Tag
                name = $ReleaseName
                body = $notesText
                draft = $true
                prerelease = $false
                generate_release_notes = $false
            }
            $release = $create.Data
            Write-Host "Created draft release $Tag."
        }

        $releaseId = [long]$release['id']
        $assets = @(Get-ReleaseAssets $releaseId)
        $existing = $assets | Where-Object { $_['name'] -eq $AssetName } | Select-Object -First 1
        if ($null -ne $existing -and $existing['digest'] -eq "sha256:$sha256") {
            Write-Host 'The release APK already matches the local SHA-256; upload skipped.'
        }
        elseif ($null -ne $existing) {
            $temporaryName = "$AssetName.uploading-$($sha256.Substring(0, 12))"
            $temporary = $assets | Where-Object { $_['name'] -eq $temporaryName } | Select-Object -First 1
            if ($null -ne $temporary -and
                ($temporary['state'] -ne 'uploaded' -or [long]$temporary['size'] -ne $apk.Length)) {
                Send-GitHubJson DELETE "/repos/$Repository/releases/assets/$($temporary['id'])" -AllowedStatus @(204) | Out-Null
                $temporary = $null
            }
            if ($null -eq $temporary) {
                $temporary = Upload-ReleaseAsset $releaseId $temporaryName $apk
            }
            Send-GitHubJson DELETE "/repos/$Repository/releases/assets/$($existing['id'])" -AllowedStatus @(204) | Out-Null
            try {
                Send-GitHubJson PATCH "/repos/$Repository/releases/assets/$($temporary['id'])" -Body @{
                    name = $AssetName
                } | Out-Null
            }
            catch {
                throw "Replacement APK is uploaded as asset $($temporary['id']) but could not be renamed. Rerun to recover. $($_.Exception.Message)"
            }
        }
        else {
            Upload-ReleaseAsset $releaseId $AssetName $apk | Out-Null
        }

        $published = Send-GitHubJson PATCH "/repos/$Repository/releases/$releaseId" -Body @{
            name = $ReleaseName
            body = $notesText
            draft = $false
            prerelease = $false
        }
        Write-Host "Published release: $($published.Data['html_url'])"
        Write-Host "APK SHA-256: $sha256"
    }
    else {
        Write-Host 'Read-only validation complete. Add -Publish after pushing the tag and building the APK.'
    }
}
catch {
    Write-Error "GitHub release operation failed: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
finally {
    $accessToken = $null
    if ($null -ne $script:githubClient) { $script:githubClient.Dispose() }
}
