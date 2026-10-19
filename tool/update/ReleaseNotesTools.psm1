Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ValidatedReleaseNotesBody {
    param(
        [Parameter(Mandatory)][object]$Response,
        [Parameter(Mandatory)][string]$ExpectedTag
    )
    if ($Response -isnot [Collections.IDictionary]) { throw 'Release API response must be a JSON object.' }
    if (-not $Response.Contains('tag_name') -or $Response.tag_name -isnot [string] -or
        $Response.tag_name -cne $ExpectedTag) { throw 'Release API returned a different tag.' }
    if ($Response.Contains('draft') -and $Response.draft -ne $false) { throw 'Draft release notes cannot be synchronized.' }
    if (-not $Response.Contains('body') -or $Response.body -isnot [string] -or
        [string]::IsNullOrWhiteSpace($Response.body)) { throw 'Release notes body is empty.' }
    if ([Text.Encoding]::UTF8.GetByteCount($Response.body) -gt 1048576) { throw 'Release notes body exceeds 1 MiB.' }
    return $Response.body
}

function Get-ReleaseNotesFromSources {
    param(
        [Parameter(Mandatory)][object[]]$Sources,
        [Parameter(Mandatory)][string]$ExpectedTag,
        [Parameter(Mandatory)][scriptblock]$FetchResponse
    )
    foreach ($source in $Sources) {
        try {
            $response = & $FetchResponse $source
            $body = Get-ValidatedReleaseNotesBody -Response $response -ExpectedTag $ExpectedTag
            return [ordered]@{ body = $body; source = $source.name }
        }
        catch {
            # Do not surface HTTP details, URLs, headers or token environment values.
            Write-Warning "Release notes source $($source.name) could not provide the expected release; trying the next source."
        }
    }
    throw 'No configured release API provided notes for the expected tag.'
}

Export-ModuleMember -Function @('Get-ValidatedReleaseNotesBody', 'Get-ReleaseNotesFromSources')
