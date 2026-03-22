param(
    [string]$ProjectRef,
    [switch]$Linked
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) {
    throw "Supabase CLI not found. Install it first: https://supabase.com/docs/guides/cli"
}

if (-not $Linked -and [string]::IsNullOrWhiteSpace($ProjectRef)) {
    throw "Provide -ProjectRef <ref> or use -Linked."
}

$args = @("migration", "list")
if ($Linked) {
    $args += "--linked"
} else {
    $args += @("--project-ref", $ProjectRef)
}

Write-Host "> supabase $($args -join ' ')" -ForegroundColor DarkCyan
& supabase @args
if ($LASTEXITCODE -ne 0) {
    throw "Supabase command failed with exit code $LASTEXITCODE"
}
