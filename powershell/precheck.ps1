#!/usr/bin/env pwsh
# precheck.ps1 — READ-ONLY preflight before deleting an account.
# Performs zero mutations. Run this first and share the output before any delete.
#
# What it inspects, per https://developers.cloudflare.com/tenant/how-to/manage-accounts/
#   1. Locate the account by exact name match -> account ID
#   2. Account details (id, name, created date)
#   3. Zones under the account (destroyed by account deletion)
#   4. Subscriptions/entitlements — cancel before deletion; active subs are
#      the most common cause of a failed delete (billing-linked)
#   5. Logpush jobs          — NOT auto-deleted; must be removed manually first
#   6. Zero Trust gateway configuration — NOT auto-deleted; remove manually
#   7. Access organization   — NOT auto-deleted; remove manually
#   8. Members with access   — confirm nobody else relies on this account
#   9. Your membership view  — how this account is attached to your user
#
# Exit status: 0 if every section was readable, 1 if any section could not be
# read. An unreadable section is never reported as "none" — the whole point of
# the preflight is to distinguish "nothing there" from "cannot see".
#
# Usage:
#   ./precheck.ps1                            (uses TARGET_ACCOUNT_NAME from config.ps1)
#   ./precheck.ps1 -TargetAccountName "X"     (exact account name as parameter)

param([string]$TargetAccountName)

. (Join-Path $PSScriptRoot "common.ps1")

# Env fallback here, not in the param default: param defaults evaluate before
# the config.ps1 dot-source runs, so they would read an empty env var.
if ([string]::IsNullOrWhiteSpace($TargetAccountName)) {
    $TargetAccountName = $env:TARGET_ACCOUNT_NAME
}
if ([string]::IsNullOrWhiteSpace($TargetAccountName)) {
    Write-Host "ERROR: set TARGET_ACCOUNT_NAME in config.ps1 or pass -TargetAccountName" -ForegroundColor Red
    exit 1
}

$script:Incomplete = 0
function Write-Unreadable {
    param([Parameter(Mandatory = $true)][string]$Label,
          [Parameter(Mandatory = $true)][int]$Status)
    $script:Incomplete++
    Write-Host "UNREADABLE: $Label (HTTP $Status) - this credential cannot see it; do NOT read this as 'none'" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "== 1. Locate account by EXACT name: '$TargetAccountName' =="
$r = Invoke-CfApiAll GET "/accounts"
if ($r.Status -ne 200) { Write-Host "ERROR: accounts listing returned HTTP $($r.Status)" -ForegroundColor Red; exit 1 }
$r.Json.result | ForEach-Object { Write-Host ("{0}  {1}" -f $_.id, $_.name) }

$acctMatches = @($r.Json.result | Where-Object { $_.name -ceq $TargetAccountName })
if ($acctMatches.Count -eq 0) {
    Write-Host "No account with that exact name visible to this credential."
    Write-Host "If the name is right but invisible, the credential's user may only be a member, not the owner."
    exit 1
}
if ($acctMatches.Count -gt 1) {
    # Cloudflare does not enforce unique account names.
    Write-Host "ERROR: $($acctMatches.Count) accounts share the exact name '$TargetAccountName':" -ForegroundColor Red
    $acctMatches | ForEach-Object { Write-Host "  $($_.id)" }
    Write-Host "Refusing to guess which one you mean. Rename the target account so its name is unique." -ForegroundColor Red
    exit 1
}
$AccountId = $acctMatches[0].id
Write-Host "MATCHED ACCOUNT_ID: $AccountId"

Write-Host ""
Write-Host "== 2. Account details =="
$d = Invoke-CfApi GET "/accounts/$AccountId"
if ($d.Status -eq 200) {
    $created = $d.Json.result.created_on
    if (-not $created) { $created = "n/a" }
    Write-Host ("  id: {0}`n  name: {1}`n  created_on: {2}" -f $d.Json.result.id, $d.Json.result.name, $created)
} else {
    Write-Unreadable -Label "account details" -Status $d.Status
}

Write-Host ""
Write-Host "== 3. Zones under this account (these get destroyed with the account) =="
$z = Invoke-CfApiAll GET "/zones?account.id=$AccountId"
if ($z.Status -ne 200) {
    Write-Unreadable -Label "zone list" -Status $z.Status
} elseif ($z.Json.result.Count -eq 0) {
    Write-Host "none"
} else {
    $z.Json.result | ForEach-Object { Write-Host ("{0}  {1}  status={2}" -f $_.id, $_.name, $_.status) }
}

Write-Host ""
Write-Host "== 4. Subscriptions/entitlements (cancel BEFORE deletion; active subs are the most common cause of a failed delete) =="
$s = Invoke-CfApiAll GET "/accounts/$AccountId/subscriptions"
if ($s.Status -ne 200) {
    Write-Unreadable -Label "subscription list" -Status $s.Status
} else {
    $subs = @($s.Json.result | Where-Object { $null -ne $_ })
    if ($subs.Count -eq 0) {
        Write-Host "none"
    } else {
        $subs | ForEach-Object {
            Write-Host ("{0}  product={1}  state={2}" -f $_.id, ($_.product.name ?? "?"), ($_.state ?? "?"))
        }
    }
}

Write-Host ""
Write-Host "== 5. Logpush jobs (delete manually BEFORE account deletion) =="
$l = Invoke-CfApiAll GET "/accounts/$AccountId/logpush/jobs"
if ($l.Status -ne 200) {
    Write-Unreadable -Label "logpush jobs" -Status $l.Status
} elseif ($l.Json.result.Count -eq 0) {
    Write-Host "none"
} else {
    $l.Json.result | ForEach-Object { Write-Host ("{0}  destination={1}" -f $_.id, $_.destination_conf) }
}

Write-Host ""
Write-Host "== 6. Zero Trust gateway configuration (delete manually BEFORE account deletion) =="
$g = Invoke-CfApi GET "/accounts/$AccountId/gateway"
if ($g.Status -eq 200) {
    Write-Host ("{0}  {1}" -f $g.Json.result.id, $g.Json.result.name)
} elseif ($g.Status -eq 404) {
    Write-Host "none"
} else {
    # 403 means "cannot see", not "not there" — reporting it as absent would hide
    # a gateway configuration that keeps resolving DNS after the account is gone.
    Write-Unreadable -Label "gateway configuration" -Status $g.Status
}

Write-Host ""
Write-Host "== 7. Access organization (delete manually BEFORE account deletion) =="
$a = Invoke-CfApi GET "/accounts/$AccountId/access/organizations"
if ($a.Status -eq 200) {
    Write-Host ("{0}  {1}" -f $a.Json.result.id, $a.Json.result.name)
} elseif ($a.Status -eq 404) {
    Write-Host "none"
} else {
    Write-Unreadable -Label "Access organization" -Status $a.Status
}

Write-Host ""
Write-Host "== 8. Members with access to this account =="
$m = Invoke-CfApiAll GET "/accounts/$AccountId/members"
if ($m.Status -ne 200) {
    Write-Unreadable -Label "member list" -Status $m.Status
} elseif ($m.Json.result.Count -eq 0) {
    Write-Host "none"
} else {
    $m.Json.result | ForEach-Object {
        # Roles come back as objects or as plain strings depending on the auth used.
        $first = $_.roles | Select-Object -First 1
        $role = if ($null -eq $first) { "?" } elseif ($first -is [string]) { $first } else { ($first.name ?? "?") }
        Write-Host ("{0}  role={1}  status={2}" -f $_.user.email, $role, $_.status)
    }
}

Write-Host ""
Write-Host "== 9. Your membership entry for this account =="
$mem = Invoke-CfApiAll GET "/memberships"
if ($mem.Status -ne 200) {
    Write-Unreadable -Label "membership list" -Status $mem.Status
} else {
    $entries = @($mem.Json.result | Where-Object { $_.account.name -ceq $TargetAccountName })
    if ($entries.Count -eq 0) {
        Write-Host "no membership entry for this account name"
    } else {
        $entries | ForEach-Object {
            # Roles shape varies by auth: strings (OAuth) or objects (API key).
            $roles = ($_.roles | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name } }) -join ","
            Write-Host ("membership_id={0}  status={1}  roles={2}" -f $_.id, $_.status, $roles)
        }
    }
}

Write-Host ""
if ($script:Incomplete -gt 0) {
    Write-Host "Precheck INCOMPLETE. No changes were made, but $($script:Incomplete) section(s) could not be read."
    Write-Host "Do not treat an unreadable section as empty - fix the credential's permissions and re-run"
    Write-Host "before deciding anything. delete-account.ps1 -Execute will abort on the same gaps."
    exit 1
}
Write-Host "Precheck complete. No changes were made."
