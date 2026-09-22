#!/usr/bin/env pwsh
# delete-account.ps1 — PERMANENT account deletion via the Tenant API.
#
# Usage:
#   ./delete-account.ps1               dry run (no changes, shows the plan)
#   ./delete-account.ps1 -Execute      perform prerequisite cleanup + deletion
#                                      (still requires typing the account ID)
#
# IMPORTANT CONSTRAINTS (see https://developers.cloudflare.com/tenant/how-to/manage-accounts/)
#   * DELETE /accounts/{account_id} is "only available for tenant admins at this time"
#     — it works for accounts owned/created by the tenant behind this credential.
#     A normal customer account typically CANNOT self-delete via API; that is done
#     by the Cloudflare account team/support.
#   * Deletion is PERMANENT and destroys zones and most resources under the account.
#   * NOT auto-deleted: Logpush jobs, Zero Trust gateway configuration, Access
#     organization. This script removes those first in -Execute mode.
#   * Subscriptions: the Tenant docs do not list them as a manual pre-delete,
#     but in practice leftover paid subscriptions are the most common cause of a
#     failed delete. Phase 0 aborts if any are visible; cancel via billing first.
#   * Order of operations (docs): gateway config -> access organization -> account.

param([switch]$Execute)

. (Join-Path $PSScriptRoot "common.ps1")

$TargetName = $env:TARGET_ACCOUNT_NAME
if ([string]::IsNullOrWhiteSpace($TargetName)) {
    Write-Host "ERROR: set TARGET_ACCOUNT_NAME in config.ps1" -ForegroundColor Red
    exit 1
}

Write-Host "== Locate account by EXACT name: '$TargetName' =="
$r = Invoke-CfApi GET "/accounts?per_page=50"
$acct = $r.Json.result | Where-Object { $_.name -ceq $TargetName } | Select-Object -First 1
if (-not $acct) {
    Write-Host "ERROR: no account with that exact name. Aborting." -ForegroundColor Red
    exit 1
}
$AccountId = $acct.id
Write-Host "ACCOUNT_ID: $AccountId"

Write-Host ""
Write-Host "== Pre-deletion inventory =="
$z = Invoke-CfApi GET "/zones?account.id=$AccountId&per_page=50"
$zones = ($z.Json.result | ForEach-Object { $_.name }) -join ","
$l = Invoke-CfApi GET "/accounts/$AccountId/logpush/jobs"
$logpushIds = @()
if ($l.Status -eq 200) { $logpushIds = @($l.Json.result | ForEach-Object { $_.id }) }
Write-Host "  zones that will be destroyed : $(if ($zones) { $zones } else { 'none' })"
Write-Host "  logpush jobs to remove       : $(if ($logpushIds.Count) { $logpushIds -join ',' } else { '(none found)' })"
$m = Invoke-CfApi GET "/accounts/$AccountId/members?per_page=50"
$memberCount = if ($m.Status -eq 200) { $m.Json.result.Count } else { "?" }
Write-Host "  member count                 : $memberCount"

if (-not $Execute) {
    Write-Host ""
    Write-Host "DRY RUN - nothing was changed."
    Write-Host "Plan if run with -Execute:"
    Write-Host "  0. subscriptions: abort if any active subscriptions exist (cancel them"
    Write-Host "     via billing first - leftover subs are the most common cause of a failed delete)"
    Write-Host "  1. DELETE logpush jobs: $(if ($logpushIds.Count) { $logpushIds -join ',' } else { '(none)' })"
    Write-Host "  2. DELETE /accounts/$AccountId/gateway            (Zero Trust gateway config)"
    Write-Host "  3. DELETE /accounts/$AccountId/access/organizations"
    Write-Host "  4. DELETE /accounts/$AccountId                    (permanent)"
    exit 0
}

Write-Host ""
Write-Host "== Phase 0: subscription check (abort if active subscriptions exist) =="
# The Tenant docs require Logpush/gateway/Access cleanup before deletion; paid
# subscriptions are not listed there, but in practice a leftover subscription is
# the most common cause of a failed delete. Cancel those via billing first.
$s = Invoke-CfApi GET "/accounts/$AccountId/subscriptions"
if ($s.Status -eq 200) {
    $subs = @($s.Json.result)
    if ($subs.Count -gt 0) {
        Write-Host "ERROR: $($subs.Count) active subscription(s) found. Cancel them via billing first, then re-run." -ForegroundColor Red
        $subs | ForEach-Object { Write-Host ("  sub {0}  product={1}  state={2}" -f $_.id, ($_.product.name ?? "?"), ($_.state ?? "?")) }
        exit 1
    }
    Write-Host "  no active subscriptions"
} else {
    Write-Host "  subscription list not visible to this credential (HTTP $($s.Status)) - verify billing manually before proceeding"
}

Write-Host ""
Write-Host "== Phase 1: remove logpush jobs =="
foreach ($jobId in $logpushIds) {
    Write-Host "  deleting logpush job $jobId"
    $d = Invoke-CfApi DELETE "/accounts/$AccountId/logpush/jobs/$jobId"
    Write-Host ("    success={0}  errors={1}" -f $d.Json.success, (Get-ErrorSummary $d.Json))
}

Write-Host ""
Write-Host "== Phase 2: remove Zero Trust gateway configuration =="
$g = Invoke-CfApi DELETE "/accounts/$AccountId/gateway"
Write-Host ("  success={0}  errors={1}" -f $g.Json.success, (Get-ErrorSummary $g.Json))

Write-Host ""
Write-Host "== Phase 3: remove Access organization =="
$a = Invoke-CfApi DELETE "/accounts/$AccountId/access/organizations"
Write-Host ("  success={0}  errors={1}" -f $a.Json.success, (Get-ErrorSummary $a.Json))

Write-Host ""
Write-Host "== Phase 4: delete the account =="
Write-Host "This is PERMANENT. Zones: $(if ($zones) { $zones } else { 'none' }) will be destroyed and cannot be recovered."
Confirm-OrAbort -Prompt "Type the full 32-character account ID to confirm: " -Expected $AccountId
$x = Invoke-CfApi DELETE "/accounts/$AccountId"
Write-Host ("  success={0}  result={1}  errors={2}" -f $x.Json.success, $x.Json.result.id, (Get-ErrorSummary $x.Json))

Write-Host ""
Write-Host "== Verification: account should now be gone =="
$v = Invoke-CfApi GET "/accounts/$AccountId"
Write-Host "GET /accounts/$AccountId returned HTTP $($v.Status) (expect 403/404)"
