param(
    [string]$ProjectRef,
    [switch]$Linked,
    [switch]$IncludeSeed,
    [switch]$RunSmokeTest
)

$ErrorActionPreference = "Stop"

function Ensure-SupabaseCli {
    if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) {
        throw "Supabase CLI not found. Install it first: https://supabase.com/docs/guides/cli"
    }
}

function Ensure-Target {
    if (-not $Linked -and [string]::IsNullOrWhiteSpace($ProjectRef)) {
        throw "Provide -ProjectRef <ref> or use -Linked."
    }
}

function Invoke-Supabase([string[]]$Args) {
    Write-Host "> supabase $($Args -join ' ')" -ForegroundColor DarkCyan
    & supabase @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Supabase command failed with exit code $LASTEXITCODE"
    }
}

Ensure-SupabaseCli
Ensure-Target

$pushArgs = @("db", "push")
if ($Linked) {
    $pushArgs += "--linked"
} else {
    $pushArgs += @("--project-ref", $ProjectRef)
}
if ($IncludeSeed) {
    $pushArgs += "--include-seed"
}

Write-Host "Starting remote deployment..." -ForegroundColor Cyan
Invoke-Supabase $pushArgs
Write-Host "Deployment finished." -ForegroundColor Green

$listArgs = @("migration", "list")
if ($Linked) {
    $listArgs += "--linked"
} else {
    $listArgs += @("--project-ref", $ProjectRef)
}

Write-Host "Verifying migration status..." -ForegroundColor Cyan
Invoke-Supabase $listArgs

if ($RunSmokeTest) {
    $smokeScript = Join-Path $PSScriptRoot "..\supabase\snippets\api_smoke_test.ps1"
    if (-not (Test-Path $smokeScript)) {
        throw "Smoke test script not found at $smokeScript"
    }

    Write-Host "Running API smoke test..." -ForegroundColor Cyan
    & $smokeScript
    if ($LASTEXITCODE -ne 0) {
        throw "Smoke test failed with exit code $LASTEXITCODE"
    }
}

Write-Host "All done." -ForegroundColor Green
