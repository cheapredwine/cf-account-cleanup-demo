foreach ($f in @("common.ps1", "config.example.ps1", "precheck.ps1", "leave-account.ps1", "delete-account.ps1")) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $f), [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) {
        "FAIL $f"
        $errors | ForEach-Object { "     $($_.Extent.StartLineNumber): $($_.Message)" }
    } else {
        "OK   $f"
    }
}
