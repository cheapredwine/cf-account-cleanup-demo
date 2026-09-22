#!/usr/bin/env pwsh
# common.ps1 — shared helpers. Dot-source this file; do not execute it directly:
#   . (Join-Path $PSScriptRoot "common.ps1")
# Provides: config loading, Invoke-CfApi wrapper, typed confirmation.
# Requires PowerShell 7+ (SkipHttpErrorCheck, ?? operator).

$ErrorActionPreference = "Stop"

if (Test-Path (Join-Path $PSScriptRoot "config.ps1")) {
    . (Join-Path $PSScriptRoot "config.ps1")
} else {
    Write-Host "ERROR: config.ps1 not found." -ForegroundColor Red
    Write-Host "       Copy config.example.ps1 to config.ps1 and fill in credentials."
    exit 1
}

$script:CfApi = "https://api.cloudflare.com/client/v4"

function Assert-CfConfig {
    if (-not $env:CF_API_TOKEN -and -not ($env:CF_AUTH_EMAIL -and $env:CF_AUTH_KEY)) {
        Write-Host "ERROR: set CF_API_TOKEN or CF_AUTH_EMAIL + CF_AUTH_KEY in config.ps1" -ForegroundColor Red
        exit 1
    }
}

# Invoke-CfApi METHOD PATH [BODY]
# Returns @{ Status = <int http code>; Json = <parsed body> }.
# Never throws on HTTP errors (SkipHttpErrorCheck) — callers branch on Status,
# mirroring the bash version's body+HTTP_STATUS output.
function Invoke-CfApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][object]$Body = $null
    )
    Assert-CfConfig
    $headers = @{ "Content-Type" = "application/json" }
    if ($env:CF_API_TOKEN) {
        $headers["Authorization"] = "Bearer $($env:CF_API_TOKEN)"
    } else {
        $headers["X-Auth-Email"] = $env:CF_AUTH_EMAIL
        $headers["X-Auth-Key"] = $env:CF_AUTH_KEY
    }
    $params = @{
        Method             = $Method
        Uri                = "$script:CfApi$Path"
        Headers            = $headers
        SkipHttpErrorCheck = $true
    }
    if ($null -ne $Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10)
    }
    $resp = Invoke-WebRequest @params
    $json = $null
    if ($resp.Content) { $json = $resp.Content | ConvertFrom-Json }
    return @{ Status = [int]$resp.StatusCode; Json = $json }
}

# Invoke-CfApiAll METHOD PATH — fetch ALL pages (50/page) of a list endpoint.
# Returns @{ Status; Json = @{ result = merged; result_info = last page's } }.
# PATH must not embed page/per_page (this helper owns paging).
# Any non-200 page: Status = that code, Json = $null, error to host. Never throws.
function Invoke-CfApiAll {
    param([Parameter(Mandatory = $true)][string]$Method,
          [Parameter(Mandatory = $true)][string]$Path)
    # .Contains, not -like "*?*": in -like patterns "?" is a WILDCARD, so every
    # path would match and the helper would append "&" instead of "?".
    $sep = if ($Path.Contains("?")) { "&" } else { "?" }
    $page = 1
    $all = @()
    $info = $null
    while ($true) {
        $r = Invoke-CfApi $Method "$Path${sep}page=$page&per_page=50"
        if ($r.Status -ne 200) {
            Write-Host "ERROR: $Path page $page returned HTTP $($r.Status)" -ForegroundColor Red
            return @{ Status = $r.Status; Json = $null }
        }
        $all += @($r.Json.result)
        $info = $r.Json.result_info
        $totalPages = if ($info -and $info.total_pages) { [int]$info.total_pages } else { 1 }
        if ($page -ge $totalPages) { break }
        $page++
    }
    return @{ Status = 200; Json = [pscustomobject]@{ result = $all; result_info = $info } }
}

# Get-ErrorSummary -Json <parsed cloudflare body> — "msg1; msg2" or "".
function Get-ErrorSummary {
    param([AllowNull()][object]$Json)
    if ($Json -and $Json.errors) { ($Json.errors | ForEach-Object { $_.message }) -join "; " } else { "" }
}

# Confirm-OrAbort -Prompt "..." -Expected "TEXT"
# Requires the operator to type EXPECTED_TEXT exactly (case-sensitive, like bash ==).
# Rejects piped/redirected stdin and non-interactive sessions.
function Confirm-OrAbort {
    param([Parameter(Mandatory = $true)][string]$Prompt,
          [Parameter(Mandatory = $true)][string]$Expected)
    if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) {
        Write-Host "Aborted: confirmation must come from an interactive terminal - piped stdin is rejected. Nothing was done." -ForegroundColor Red
        exit 1
    }
    $answer = Read-Host $Prompt
    if ($answer -cne $Expected) {
        Write-Host "Aborted: confirmation text did not match. Nothing was done."
        exit 1
    }
}
