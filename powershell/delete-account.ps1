#!/usr/bin/env pwsh
# delete-account.ps1 — PERMANENT account deletion via the Tenant API.
#
# Usage:
#   ./delete-account.ps1               dry run (no changes, shows the plan)
#   ./delete-account.ps1 -Execute      typed confirmation, then cleanup + deletion
#
# IMPORTANT CONSTRAINTS (see https://developers.cloudflare.com/tenant/how-to/manage-accounts/)
#   * DELETE /accounts/{account_id} is "only available for tenant admins at this time"
#     — it works for accounts owned/created by the tenant behind this credential.
#     A normal customer account typically CANNOT self-delete via API; that is done
#     by the Cloudflare account team/support.
#   * Deletion is PERMANENT and destroys zones and most resources under the account.
#   * NOT auto-deleted: Logpush jobs (keep delivering logs afterwards) and Zero Trust
#     gateway configuration (may keep resolving DNS afterwards). The docs' cleanup
#     sequence also removes the Access organization. This script does all three.
#   * Subscriptions: the Tenant docs do not list them as a manual pre-delete,
#     but in practice leftover paid subscriptions are the most common cause of a
#     failed delete. Phase 0 aborts if any are visible; cancel via billing first.
#   * An unreadable Logpush or member inventory aborts BEFORE the typed account-ID
#     confirmation. The confirmation happens before any change because cleanup
#     destroys Gateway policies and the Access organization.
#   * Cleanup phases (1-3) must return 200/404 AND not report success=false, or
#     the run aborts BEFORE the irreversible account delete. Each phase is then
#     verified by a follow-up read before the account is deleted.
#   * Order of operations (docs): gateway config -> access organization -> account.

param([switch]$Execute)

. (Join-Path $PSScriptRoot "common.ps1")

$TargetName = $env:TARGET_ACCOUNT_NAME
if ([string]::IsNullOrWhiteSpace($TargetName)) {
    Write-Host "ERROR: set TARGET_ACCOUNT_NAME in config.ps1" -ForegroundColor Red
    exit 1
}

# Assert-CleanupOk — every pre-delete mutation must return 200/404. A 404 means
# "already gone" and legitimately carries success=false, so the body is only
# judged on a 200, where success=false would sail past a status-only check.
function Assert-CleanupOk {
    param([Parameter(Mandatory = $true)][string]$Label,
          [Parameter(Mandatory = $true)][hashtable]$Response)
    if ($Response.Status -ne 200 -and $Response.Status -ne 404) {
        Write-Host "ERROR: $Label returned HTTP $($Response.Status) - aborting before the account delete." -ForegroundColor Red
        exit 1
    }
    if ($Response.Status -eq 200 -and $Response.Json -and $null -ne $Response.Json.success -and -not $Response.Json.success) {
        Write-Host "ERROR: $Label returned HTTP 200 with success=false - aborting before the account delete." -ForegroundColor Red
        Write-Host ("  errors: {0}" -f (Get-ErrorSummary $Response.Json))
        exit 1
    }
}

Write-Host "== Locate account by EXACT name: '$TargetName' =="
$r = Invoke-CfApiAll GET "/accounts"
if ($r.Status -ne 200) { Write-Host "ERROR: accounts listing returned HTTP $($r.Status)" -ForegroundColor Red; exit 1 }
$acctMatches = @($r.Json.result | Where-Object { $_.name -ceq $TargetName })
if ($acctMatches.Count -eq 0) {
    Write-Host "ERROR: no account with that exact name. Aborting." -ForegroundColor Red
    exit 1
}
if ($acctMatches.Count -gt 1) {
    # Cloudflare does not enforce unique account names. Picking the first match
    # would be a coin flip over which account gets destroyed.
    Write-Host "ERROR: $($acctMatches.Count) accounts share the exact name '$TargetName':" -ForegroundColor Red
    $acctMatches | ForEach-Object { Write-Host "  $($_.id)" }
    Write-Host "Refusing to guess. Rename the target account so its name is unique, then re-run." -ForegroundColor Red
    exit 1
}
$AccountId = $acctMatches[0].id
Write-Host "ACCOUNT_ID: $AccountId"

# Get-LogpushInventory — fresh paginated logpush inventory.
# Returns @{ Ok; Status; Ids }. An unreadable inventory is NOT an empty one:
# logpush jobs left behind keep delivering logs after the account is gone, so
# callers must abort on Ok=$false rather than skip the cleanup phase.
function Get-LogpushInventory {
    $l = Invoke-CfApiAll GET "/accounts/$AccountId/logpush/jobs"
    if ($l.Status -ne 200) { return @{ Ok = $false; Status = $l.Status; Ids = @() } }
    return @{ Ok = $true; Status = 200; Ids = @($l.Json.result | ForEach-Object { $_.id }) }
}

# Assert-Absent — accept an absent endpoint as 404 or 200 with no ID.
function Assert-Absent {
    param([Parameter(Mandatory = $true)][string]$Label,
          [Parameter(Mandatory = $true)][string]$Path)
    $verify = Invoke-CfApi GET $Path
    if ($verify.Status -eq 404) {
        Write-Host "  verified: $Label is gone"
        return
    }
    if ($verify.Status -eq 200) {
        $id = if ($verify.Json -and $verify.Json.result) { $verify.Json.result.id } else { $null }
        if ($null -eq $id -or [string]::IsNullOrWhiteSpace([string]$id)) {
            Write-Host "  verified: $Label is gone"
            return
        }
        Write-Host "ERROR: $Label is still present after its DELETE - aborting before the account delete." -ForegroundColor Red
        exit 1
    }
    Write-Host "ERROR: could not verify $Label is gone (GET $Path returned HTTP $($verify.Status))." -ForegroundColor Red
    Write-Host "       Grant read access to this path and re-run; aborting before the account delete." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "== Pre-deletion inventory =="
$z = Invoke-CfApiAll GET "/zones?account.id=$AccountId"
if ($z.Status -ne 200) {
    Write-Host "ERROR: could not list zones (HTTP $($z.Status)) - refusing to delete an account" -ForegroundColor Red
    Write-Host "       whose contents cannot be shown. Aborting." -ForegroundColor Red
    exit 1
}
$zones = ($z.Json.result | ForEach-Object { $_.name }) -join ","
$logpush = Get-LogpushInventory
$m = Invoke-CfApiAll GET "/accounts/$AccountId/members"
$membersReadable = $m.Status -eq 200
$memberCount = if ($membersReadable) { $m.Json.result.Count } else { "?" }
Write-Host "  zones that will be destroyed : $(if ($zones) { $zones } else { 'none' })"
if ($logpush.Ok) {
    Write-Host "  logpush jobs to remove       : $(if ($logpush.Ids.Count) { $logpush.Ids -join ',' } else { '(none found)' })"
} else {
    Write-Host "  logpush jobs to remove       : UNREADABLE (HTTP $($logpush.Status)) - not the same as none"
}
if ($membersReadable) {
    Write-Host "  member count                 : $memberCount"
} else {
    Write-Host "  member count                 : UNREADABLE (HTTP $($m.Status)) - not the same as zero"
}

$unreadableInventories = @()
if (-not $logpush.Ok) { $unreadableInventories += "logpush jobs (HTTP $($logpush.Status))" }
if (-not $membersReadable) { $unreadableInventories += "account members (HTTP $($m.Status))" }

if (-not $Execute) {
    Write-Host ""
    Write-Host "DRY RUN - nothing was changed."
    Write-Host "Plan if executed:"
    Write-Host "  gate 1. require complete logpush and member inventories before confirmation"
    Write-Host "  gate 2. type the full account ID to confirm - asked BEFORE any change is made"
    Write-Host "  0. subscriptions: abort if any active subscriptions exist (cancel them"
    Write-Host "     via billing first - list every page before deciding)"
    Write-Host "  1. DELETE logpush jobs: $(if ($logpush.Ids.Count) { $logpush.Ids -join ',' } else { '(none)' }); then re-list them and require that none remain"
    Write-Host "  2. DELETE /accounts/$AccountId/gateway            (Zero Trust gateway config); then read it back and require it to be gone"
    Write-Host "  3. DELETE /accounts/$AccountId/access/organizations; then read it back and require it to be gone"
    Write-Host "  4. DELETE /accounts/$AccountId                    (permanent)"
    if ($unreadableInventories.Count -gt 0) {
        Write-Host ""
        Write-Host "NOTE: unreadable inventory:"
        $unreadableInventories | ForEach-Object { Write-Host "      $_" }
        Write-Host "      An execute run would abort before the confirmation prompt."
    }
    exit 0
}

if ($unreadableInventories.Count -gt 0) {
    Write-Host "ERROR: pre-deletion inventory incomplete - aborting before the confirmation prompt." -ForegroundColor Red
    $unreadableInventories | ForEach-Object { Write-Host "       UNREADABLE: $_" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "== Confirmation (nothing has changed yet) =="
Write-Host "This run will, in order: remove every logpush job, the Zero Trust gateway"
Write-Host "configuration and the Access organization, then PERMANENTLY delete the account."
Write-Host "Zones: $(if ($zones) { $zones } else { 'none' }) will be destroyed and cannot be recovered."
Write-Host "The cleanup steps also destroy Gateway policies and all Access apps/policies."
Confirm-OrAbort -Prompt "Type the full 32-character account ID to confirm: " -Expected $AccountId

Write-Host ""
Write-Host "== Phase 0: subscription check (abort if active subscriptions exist) =="
# The Tenant docs require Logpush/gateway/Access cleanup before deletion; paid
# subscriptions are not listed there, but in practice a leftover subscription is
# the most common cause of a failed delete. Cancel those via billing first.
$s = Invoke-CfApiAll GET "/accounts/$AccountId/subscriptions"
if ($s.Status -eq 200) {
    $subs = @($s.Json.result | Where-Object { $null -ne $_ })
    if ($subs.Count -gt 0) {
        Write-Host "ERROR: $($subs.Count) active subscription(s) found. Cancel them via billing first, then re-run." -ForegroundColor Red
        $subs | ForEach-Object { Write-Host ("  sub {0}  product={1}  state={2}" -f $_.id, ($_.product.name ?? "?"), ($_.state ?? "?")) }
        exit 1
    }
    Write-Host "  no active subscriptions"
} else {
    # An unreadable subscription list is not a pass. Require the operator to say
    # explicitly that billing was checked out of band.
    Write-Host "ERROR: subscription list not visible to this credential (HTTP $($s.Status))." -ForegroundColor Red
    Write-Host "       This gate cannot confirm the account is unbilled." -ForegroundColor Red
    Write-Host "       Check billing in the dashboard, then re-run with BILLING_VERIFIED=1 to proceed." -ForegroundColor Red
    if ($env:BILLING_VERIFIED -ne "1") { exit 1 }
    Write-Host "  BILLING_VERIFIED=1 set by the operator - continuing without the subscription check"
}

Write-Host ""
Write-Host "== Phase 1: remove logpush jobs (fresh inventory) =="
$logpush = Get-LogpushInventory
if (-not $logpush.Ok) {
    Write-Host "ERROR: could not list logpush jobs (HTTP $($logpush.Status)) - aborting before the account delete." -ForegroundColor Red
    Write-Host "       Logpush jobs left behind keep delivering logs after the account is gone," -ForegroundColor Red
    Write-Host "       so an unreadable inventory must not be treated as an empty one." -ForegroundColor Red
    Write-Host "       Grant Logpush:Read + Logpush:Edit to this credential and re-run." -ForegroundColor Red
    exit 1
}
if ($logpush.Ids.Count -eq 0) { Write-Host "  none" }
foreach ($jobId in $logpush.Ids) {
    Write-Host "  deleting logpush job $jobId"
    $d = Invoke-CfApi DELETE "/accounts/$AccountId/logpush/jobs/$jobId"
    Write-Host ("    {0}" -f (Get-CfSummary -Response $d))
    Assert-CleanupOk -Label "logpush job $jobId DELETE" -Response $d
}
$logpush = Get-LogpushInventory
if (-not $logpush.Ok) {
    Write-Host "ERROR: could not verify logpush cleanup (HTTP $($logpush.Status)) - aborting before the account delete." -ForegroundColor Red
    exit 1
}
if ($logpush.Ids.Count -gt 0) {
    Write-Host "ERROR: logpush jobs remain after cleanup - aborting before the account delete:" -ForegroundColor Red
    $logpush.Ids | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
Write-Host "  verified: no logpush jobs remain"

Write-Host ""
Write-Host "== Phase 2: remove Zero Trust gateway configuration =="
$g = Invoke-CfApi DELETE "/accounts/$AccountId/gateway"
Write-Host ("  gateway DELETE: {0}" -f (Get-CfSummary -Response $g))
Assert-CleanupOk -Label "gateway DELETE" -Response $g
Assert-Absent -Label "gateway configuration" -Path "/accounts/$AccountId/gateway"

Write-Host ""
Write-Host "== Phase 3: remove Access organization =="
$a = Invoke-CfApi DELETE "/accounts/$AccountId/access/organizations"
Write-Host ("  Access organization DELETE: {0}" -f (Get-CfSummary -Response $a))
Assert-CleanupOk -Label "Access organization DELETE" -Response $a
Assert-Absent -Label "Access organization" -Path "/accounts/$AccountId/access/organizations"

Write-Host ""
Write-Host "== Phase 4: delete the account (point of no return) =="
$x = Invoke-CfApi DELETE "/accounts/$AccountId"
Write-Host ("  account DELETE: {0}  result={1}" -f (Get-CfSummary -Response $x), $x.Json.result.id)
if ($x.Status -ne 200) {
    Write-Host "ERROR: account DELETE returned HTTP $($x.Status) - the account was NOT deleted." -ForegroundColor Red
    Write-Host "       Prerequisite cleanup has already run; review the account before retrying." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "== Verification: account should now be gone =="
$v = Invoke-CfApi GET "/accounts/$AccountId"
Write-Host "GET /accounts/$AccountId returned HTTP $($v.Status) (expect 403/404)"
if ($v.Status -ne 403 -and $v.Status -ne 404) {
    Write-Host "ERROR: the account is still readable - deletion did not take effect." -ForegroundColor Red
    exit 1
}
Write-Host "Account deleted."
