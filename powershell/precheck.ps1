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

Write-Host ""
Write-Host "== 1. Locate account by EXACT name: '$TargetAccountName' =="
$r = Invoke-CfApiAll GET "/accounts"
if ($r.Status -ne 200) { Write-Host "ERROR: accounts listing returned HTTP $($r.Status)" -ForegroundColor Red; exit 1 }
$r.Json.result | ForEach-Object { Write-Host ("{0}  {1}" -f $_.id, $_.name) }

$acct = $r.Json.result | Where-Object { $_.name -ceq $TargetAccountName } | Select-Object -First 1
if (-not $acct) {
    Write-Host "No account with that exact name visible to this credential."
    Write-Host "If the name is right but invisible, the credential's user may only be a member, not the owner."
    exit 1
}
$AccountId = $acct.id
Write-Host "MATCHED ACCOUNT_ID: $AccountId"

Write-Host ""
Write-Host "== 2. Account details =="
$d = Invoke-CfApi GET "/accounts/$AccountId"
$created = $d.Json.result.created_on
if (-not $created) { $created = "n/a" }
Write-Host ("  id: {0}`n  name: {1}`n  created_on: {2}" -f $d.Json.result.id, $d.Json.result.name, $created)

Write-Host ""
Write-Host "== 3. Zones under this account (these get destroyed with the account) =="
$z = Invoke-CfApiAll GET "/zones?account.id=$AccountId"
if ($z.Status -ne 200) { Write-Host "ERROR: zones listing returned HTTP $($z.Status)" -ForegroundColor Red; exit 1 }
if ($z.Json.result.Count -eq 0) {
    Write-Host "none"
} else {
    $z.Json.result | ForEach-Object { Write-Host ("{0}  {1}  status={2}" -f $_.id, $_.name, $_.status) }
}

Write-Host ""
Write-Host "== 4. Subscriptions/entitlements (cancel BEFORE deletion; active subs are the most common cause of a failed delete) =="
$s = Invoke-CfApi GET "/accounts/$AccountId/subscriptions"
if ($s.Status -eq 200) {
    if ($s.Json.result.Count -eq 0) {
        Write-Host "none"
    } else {
        $s.Json.result | ForEach-Object {
            Write-Host ("{0}  product={1}  state={2}" -f $_.id, ($_.product.name ?? "?"), ($_.state ?? "?"))
        }
    }
} else {
    Write-Host "subscriptions list not visible to this credential (HTTP $($s.Status)) - verify billing manually before deleting"
}

Write-Host ""
Write-Host "== 5. Logpush jobs (delete manually BEFORE account deletion) =="
$l = Invoke-CfApiAll GET "/accounts/$AccountId/logpush/jobs"
if ($l.Status -eq 200 -and $l.Json.result.Count -gt 0) {
    $l.Json.result | ForEach-Object { Write-Host ("{0}  destination={1}" -f $_.id, $_.destination_conf) }
} elseif ($l.Status -eq 200) {
    Write-Host "none"
} else {
    Write-Host "endpoint not available for this credential (HTTP $($l.Status))"
}

Write-Host ""
Write-Host "== 6. Zero Trust gateway configuration (delete manually BEFORE account deletion) =="
$g = Invoke-CfApi GET "/accounts/$AccountId/gateway"
if ($g.Status -eq 200) {
    Write-Host ("{0}  {1}" -f $g.Json.result.id, $g.Json.result.name)
} else {
    Write-Host "no gateway configuration (HTTP $($g.Status))"
}

Write-Host ""
Write-Host "== 7. Access organization (delete manually BEFORE account deletion) =="
$a = Invoke-CfApi GET "/accounts/$AccountId/access/organizations"
if ($a.Status -eq 200) {
    Write-Host ("{0}  {1}" -f $a.Json.result.id, $a.Json.result.name)
} else {
    Write-Host "no access organization (HTTP $($a.Status))"
}

Write-Host ""
Write-Host "== 8. Members with access to this account =="
$m = Invoke-CfApiAll GET "/accounts/$AccountId/members"
if ($m.Status -eq 200) {
    $m.Json.result | ForEach-Object {
        Write-Host ("{0}  role={1}  status={2}" -f $_.user.email, ($_.roles | Select-Object -First 1).name, $_.status)
    }
} else {
    Write-Host "members list not available for this credential (HTTP $($m.Status))"
}

Write-Host ""
Write-Host "== 9. Your membership entry for this account =="
$mem = Invoke-CfApiAll GET "/memberships"
if ($mem.Status -ne 200) { Write-Host "ERROR: memberships listing returned HTTP $($mem.Status)" -ForegroundColor Red; exit 1 }
$mem.Json.result | Where-Object { $_.account.name -ceq $TargetAccountName } |
    ForEach-Object {
        # Roles shape varies by auth: strings (OAuth) or objects (API key).
        $roles = ($_.roles | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name } }) -join ","
        Write-Host ("membership_id={0}  status={1}  roles={2}" -f $_.id, $_.status, $roles)
    }

Write-Host ""
Write-Host "Precheck complete. No changes were made."
