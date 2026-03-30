# =============================================================================
# Pogo Raid Premium - Live API smoke test (PowerShell)
# Run from YOUR OWN terminal (Windows Terminal / PowerShell ISE / pwsh):
#   .\supabase\snippets\api_smoke_test.ps1
# NOTE: Must not be run from VS Code Copilot terminal (HTTP calls are blocked).
# =============================================================================

$SMOKE_ENV_FILE = Join-Path $PSScriptRoot ".env.smoke.local"
$LOADED_ENV_KEYS = New-Object System.Collections.Generic.List[string]
$ORIGINAL_ENV = @{}

function Section($title) {
    Write-Host "`n===== $title =====" -ForegroundColor Cyan
}

function Load-SmokeEnvFile($path) {
    if (-not (Test-Path $path)) {
        return
    }

    Section "Loading smoke env file"
    Write-Host "Found: $path"

    foreach ($line in Get-Content $path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) {
            continue
        }

        $eq = $trimmed.IndexOf("=")
        if ($eq -lt 1) {
            continue
        }

        $key = $trimmed.Substring(0, $eq).Trim()
        $value = $trimmed.Substring($eq + 1).Trim().Trim('"')

        if (-not $ORIGINAL_ENV.ContainsKey($key)) {
            $ORIGINAL_ENV[$key] = [System.Environment]::GetEnvironmentVariable($key, "Process")
        }

        [System.Environment]::SetEnvironmentVariable($key, $value, "Process")
        if (-not $LOADED_ENV_KEYS.Contains($key)) {
            $LOADED_ENV_KEYS.Add($key)
        }
    }
}

function Cleanup-SmokeEnvFileValues() {
    if ($LOADED_ENV_KEYS.Count -eq 0) {
        return
    }

    Section "Cleaning smoke env values"
    foreach ($key in $LOADED_ENV_KEYS) {
        $previous = $ORIGINAL_ENV[$key]
        if ($null -eq $previous) {
            Remove-Item "Env:$key" -ErrorAction SilentlyContinue
        } else {
            [System.Environment]::SetEnvironmentVariable($key, $previous, "Process")
        }
    }

    Write-Host "Restored/cleared variables loaded from file."
}

Load-SmokeEnvFile $SMOKE_ENV_FILE

$SUPABASE_URL = "https://jkzbruimweyolcgjmram.supabase.co"
$ANON_KEY     = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpremJydWltd2V5b2xjZ2ptcmFtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMyMjA0MjMsImV4cCI6MjA4ODc5NjQyM30.cV39soOyyuy0NDRP6cw9jlEWIQ8raclS-WMEnmdp8-g"
$SERVICE_ROLE_KEY = $env:SUPABASE_SERVICE_ROLE_KEY

$ErrorActionPreference = "Stop"

function Http($method, $uri, $authToken = $null, $body = $null) {
    $headers = @{ "apikey" = $ANON_KEY; "Content-Type" = "application/json" }
    if ($authToken) { $headers["Authorization"] = "Bearer $authToken" }
    $params = @{ Method = $method; Uri = $uri; Headers = $headers; UseBasicParsing = $true }
    if ($body) { $params["Body"] = ($body | ConvertTo-Json -Depth 10) }
    try {
        $r = Invoke-WebRequest @params
        return ($r.Content | ConvertFrom-Json)
    } catch {
        $raw = $_.ErrorDetails.Message
        try   { return ($raw | ConvertFrom-Json) }
        catch { return @{ error = $raw } }
    }
}

function AdminHttp($method, $uri, $body = $null) {
    $headers = @{ "apikey" = $SERVICE_ROLE_KEY; "Authorization" = "Bearer $SERVICE_ROLE_KEY"; "Content-Type" = "application/json" }
    $params = @{ Method = $method; Uri = $uri; Headers = $headers; UseBasicParsing = $true }
    if ($body) { $params["Body"] = ($body | ConvertTo-Json -Depth 10) }
    try {
        $r = Invoke-WebRequest @params
        return ($r.Content | ConvertFrom-Json)
    } catch {
        $raw = $_.ErrorDetails.Message
        try   { return ($raw | ConvertFrom-Json) }
        catch { return @{ error = $raw } }
    }
}

function Print-Json($obj, $title) {
    Write-Host $title -ForegroundColor DarkGray
    Write-Host ($obj | ConvertTo-Json -Depth 10)
}

try {
    # ----------------------------------------------------------
    # 1. Anon key explained
    # ----------------------------------------------------------
    Section "Anon key - decoded JWT payload"
    $payload = $ANON_KEY.Split(".")[1]
    # Pad base64 to multiple of 4
    $padded  = $payload + ("=" * ((4 - $payload.Length % 4) % 4))
    $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($padded)) | ConvertFrom-Json
    $decoded | Format-List
    Write-Host "Key: role=$($decoded.role)  ref=$($decoded.ref)  exp=$(([DateTimeOffset]::FromUnixTimeSeconds($decoded.exp)).ToString('yyyy-MM-dd'))"
    Write-Host "Retrieve any time: supabase projects api-keys --project-ref $($decoded.ref)"

    # ----------------------------------------------------------
    # 2. Raid bosses - unauthenticated read
    # ----------------------------------------------------------
    Section "GET /rest/v1/raid_bosses"
    $bosses = Http "GET" "$SUPABASE_URL/rest/v1/raid_bosses?select=id,name,tier,pokemon_id&order=tier.desc"
    $bosses | Format-Table -AutoSize

    # ----------------------------------------------------------
    # 3. Authenticate test user
    # ----------------------------------------------------------
    Section "Auth flow"
    $TEST_EMAIL = if ($env:SMOKE_TEST_EMAIL) { $env:SMOKE_TEST_EMAIL } else { "smoketest@pogo-test.dev" }
    $TEST_PASS  = if ($env:SMOKE_TEST_PASSWORD) { $env:SMOKE_TEST_PASSWORD } else { "TestPass123!" }

    # First try password sign-in. This works for already confirmed users.
    Section "POST /auth/v1/token (sign in)"
    $signinResult = Http "POST" "$SUPABASE_URL/auth/v1/token?grant_type=password" -body @{
        email    = $TEST_EMAIL
        password = $TEST_PASS
    }
    $ACCESS_TOKEN = $signinResult.access_token
    $USER_ID      = $signinResult.user.id

    if (-not $ACCESS_TOKEN) {
        Print-Json $signinResult "Sign-in response:"

        # If service role is available, bootstrap a confirmed user without email sending.
        if ($SERVICE_ROLE_KEY) {
            Section "Admin bootstrap confirmed user (service role)"
            if (-not $env:SMOKE_TEST_EMAIL) {
                $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $TEST_EMAIL = "smoketest+$stamp@pogo-test.dev"
            }

            $adminCreate = AdminHttp "POST" "$SUPABASE_URL/auth/v1/admin/users" @{
                email         = $TEST_EMAIL
                password      = $TEST_PASS
                email_confirm = $true
            }
            Print-Json $adminCreate "Admin create user response:"

            Section "POST /auth/v1/token (sign in after admin bootstrap)"
            $signinResult = Http "POST" "$SUPABASE_URL/auth/v1/token?grant_type=password" -body @{
                email    = $TEST_EMAIL
                password = $TEST_PASS
            }
            Print-Json $signinResult "Sign-in response (after admin bootstrap):"
            $ACCESS_TOKEN = $signinResult.access_token
            $USER_ID      = $signinResult.user.id
        }

        if ($ACCESS_TOKEN) {
            Write-Host "Using test email: $TEST_EMAIL"
        }

        # If user does not exist, attempt signup.
        if (-not $ACCESS_TOKEN) {
            Section "POST /auth/v1/signup"
            $signupResult = Http "POST" "$SUPABASE_URL/auth/v1/signup" -body @{
                email    = $TEST_EMAIL
                password = $TEST_PASS
            }
            Print-Json $signupResult "Signup response:"

            $ACCESS_TOKEN = $signupResult.session.access_token
            $USER_ID      = $signupResult.user.id

            # Email confirmation enabled => signup may return user but no session.
            if (-not $ACCESS_TOKEN) {
                Section "Re-try sign-in after signup"
                $signinResult = Http "POST" "$SUPABASE_URL/auth/v1/token?grant_type=password" -body @{
                    email    = $TEST_EMAIL
                    password = $TEST_PASS
                }
                Print-Json $signinResult "Sign-in response (after signup):"
                $ACCESS_TOKEN = $signinResult.access_token
                $USER_ID      = $signinResult.user.id
            }
        }
    }

    Write-Host "User ID      : $USER_ID"
    if ($ACCESS_TOKEN) {
        Write-Host "Access token : $($ACCESS_TOKEN.Substring(0,[Math]::Min(40,$ACCESS_TOKEN.Length)))..."
    } else {
        Write-Error "Authentication failed. Use a confirmed account via SMOKE_TEST_EMAIL/SMOKE_TEST_PASSWORD, or set SUPABASE_SERVICE_ROLE_KEY to allow admin bootstrap."
        exit 1
    }

    # ----------------------------------------------------------
    # 4. Create own profile
    # ----------------------------------------------------------
    Section "POST /rest/v1/user_profiles"
    $profileResult = Http "POST" "$SUPABASE_URL/rest/v1/user_profiles?Prefer=return%3Drepresentation" $ACCESS_TOKEN @{
        auth_id      = $USER_ID
        display_name = "Smoke Tester"
    }
    Write-Host ($profileResult | ConvertTo-Json -Depth 5)

    # ----------------------------------------------------------
    # 5. Read own profile
    # ----------------------------------------------------------
    Section "GET /rest/v1/user_profiles (own)"
    $profileUrl = "$SUPABASE_URL/rest/v1/user_profiles?auth_id=eq.$USER_ID" + "&select=*"
    $profile = Http "GET" $profileUrl $ACCESS_TOKEN
    $profile | Format-List

    # ----------------------------------------------------------
    # 6. List active raids
    # ----------------------------------------------------------
    Section "GET /rest/v1/raids (active)"
    $raidsUrl = "$SUPABASE_URL/rest/v1/raids?is_active=eq.true" + "&select=id,location_name,start_time,capacity" + "&order=start_time.asc"
    $raids = Http "GET" $raidsUrl $ACCESS_TOKEN
    if ($raids.Count -gt 0) { $raids | Format-Table -AutoSize } else { Write-Host "(no active raids - expected if seed raid host != test user)" }

    # ----------------------------------------------------------
    # 7. Join queue via RPC
    # ----------------------------------------------------------
    Section "POST /rest/v1/rpc/join_raid_queue"
    $SEED_RAID_ID = "00000000-0000-0000-0000-00000000aa06"
    $queueRow = Http "POST" "$SUPABASE_URL/rest/v1/rpc/join_raid_queue" $ACCESS_TOKEN @{
        p_raid_id = $SEED_RAID_ID
        p_note    = "smoke test join"
    }
    Write-Host ($queueRow | ConvertTo-Json -Depth 5)

    if ($queueRow.status -ne "invited") {
        throw "Expected auto-filled join to return invited, got $($queueRow.status)"
    }

    Write-Host "`n===== Smoke test complete =====" -ForegroundColor Green
} finally {
    Cleanup-SmokeEnvFileValues
}
