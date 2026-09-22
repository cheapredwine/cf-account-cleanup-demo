#!/usr/bin/env pwsh
# leave-account.ps1 — OPTION A: remove the account from YOUR dashboard only.
#
# This does NOT delete the account. It removes your user's membership
# (DELETE /memberships/{membership_id}). The account, its zones, and its data
# remain intact for any other members/owner. Reversible: the owner can
# re-invite your user at any time.
#
# Use this when the goal is "stop seeing it in the dashboard".
# Use delete-account.ps1 only when the goal is "destroy the account entirely".

. (Join-Path $PSScriptRoot "common.ps1")

$TargetName = $env:TARGET_ACCOUNT_NAME
if ([string]::IsNullOrWhiteSpace($TargetName)) {
    Write-Host "ERROR: set TARGET_ACCOUNT_NAME in config.ps1" -ForegroundColor Red
    exit 1
}

Write-Host "== Find membership for account '$TargetName' =="
$mem = Invoke-CfApi GET "/memberships?per_page=50"
$entry = $mem.Json.result | Where-Object { $_.account.name -ceq $TargetName } | Select-Object -First 1
if (-not $entry) {
    Write-Host "No membership found for that name. Nothing to do."
    exit 1
}

$roles = ($entry.roles | ForEach-Object { $_.name }) -join ","
Write-Host ("account={0}  id={1}  status={2}  roles={3}" -f $entry.account.name, $entry.account.id, $entry.status, $roles)
Write-Host "membership_id: $($entry.id)"

Write-Host ""
Write-Host "Removing this membership hides the account from this user's dashboard."
Write-Host "The account itself is NOT deleted."
Confirm-OrAbort -Prompt "Type 'LEAVE' to confirm: " -Expected "LEAVE"

$d = Invoke-CfApi DELETE "/memberships/$($entry.id)"
Write-Host ("success={0}  errors={1}" -f $d.Json.success, (Get-ErrorSummary $d.Json))

Write-Host ""
Write-Host "== Verification: membership should be gone =="
$v = Invoke-CfApi GET "/memberships?per_page=50"
$still = $v.Json.result | Where-Object { $_.account.name -ceq $TargetName }
if (-not $still) {
    Write-Host "membership removed - account no longer listed for this user"
} else {
    Write-Host "still present"
}
