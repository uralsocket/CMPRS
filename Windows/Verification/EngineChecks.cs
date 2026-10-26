using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using Cmprs;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

static class EngineChecks
{
    static readonly List<object> Results = new List<object>();
    static void Check(string name, bool condition, object evidence = null)
    {
        Results.Add(new { name, passed = condition, evidence });
        Console.WriteLine((condition ? "PASS " : "FAIL ") + name);
        if (!condition) throw new Exception(name + ": " + JsonConvert.SerializeObject(evidence));
    }
    static string Hash(string file) { return Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(file))); }
    static int Main(string[] args)
    {
        string bin = args[0], fixtures = args[1];
        try
        {
            var engine = new CompressionEngine(bin);
            foreach (string fixture in new[] { "normal.mov", "120fps.mov", "4k.mov", "portrait.mov", "audio-surround.mov", "rotation.mov" })
            {
                string path = Path.Combine(fixtures, fixture), hash = Hash(path);
                var stages = new HashSet<string>(); engine.Progress = (s, p) => stages.Add(s);
                var r = engine.Compress(path, false, CancellationToken.None);
                Check(fixture, r.Status == "ok" && r.OutputBytes < r.InputBytes && Path.GetFileName(r.Output) == "CMPRS-" + fixture,
                    new { r.Status, r.Message, r.InputBytes, r.OutputBytes });
                Check(fixture + " source intact", Hash(path) == hash);
                Check(fixture + " stages", new[] { "inspecting", "encoding", "verifying" }.All(stages.Contains));
            }
            var duplicate = engine.Compress(Path.Combine(fixtures, "normal.mov"), false, CancellationToken.None);
            Check("exclusive output naming", duplicate.Status == "ok" && Path.GetFileName(duplicate.Output) == "CMPRS-normal (2).mov");
            // This discontinuous VFR fixture exposes a MOV/B-frame duration discrepancy.
            // Match macOS: reject the result rather than silently change frame timing.
            var vfr = engine.Compress(Path.Combine(fixtures, "vfr.mov"), false, CancellationToken.None);
            Check("irregular VFR rejected safely", vfr.Status == "error" && vfr.Message == "timing" && !File.Exists(Path.Combine(fixtures, "CMPRS-vfr.mov")), new { vfr.Status, vfr.Message });
            string high = Path.Combine(fixtures, "10bit.mov");
            var depth = engine.Compress(high, false, CancellationToken.None);
            Check("10-bit needs consent", depth.Status == "needs-consent" && !File.Exists(Path.Combine(fixtures, "CMPRS-10bit.mov")));
            depth = engine.Compress(high, true, CancellationToken.None);
            Check("10-bit approved", depth.Status == "ok", new { depth.Status, depth.Message });
            foreach (string fixture in new[] { "hdr.mov", "alpha.mov", "odd.mkv" })
            {
                var r = engine.Compress(Path.Combine(fixtures, fixture), true, CancellationToken.None);
                Check(fixture + " preserved by skipping", r.Status == "skipped", new { r.Status, r.Message });
            }
            var small = engine.Compress(Path.Combine(fixtures, "small.mp4"), false, CancellationToken.None);
            Check("larger result discarded", small.Status == "skipped" && small.Message == "larger" && !File.Exists(Path.Combine(fixtures, "CMPRS-small.mov")), new { small.Status, small.Message });
            var bad = engine.Compress(Path.Combine(fixtures, "invalid.mov"), false, CancellationToken.None);
            Check("corrupt input fails", bad.Status == "error");
            using (var cts = new CancellationTokenSource())
            {
                engine.Progress = (s, p) => { if (s == "encoding" && p > 0) cts.Cancel(); };
                var r = engine.Compress(Path.Combine(fixtures, "normal.mov"), false, cts.Token);
                Check("cancellation", r.Status == "cancelled");
            }
            var stalled = new CompressionEngine(Path.Combine(fixtures, "stalled"), 300, 300);
            var timeout = stalled.Compress(Path.Combine(fixtures, "normal.mov"), false, CancellationToken.None);
            Check("stalled probe watchdog", timeout.Status == "error" && timeout.Message == "probe-timeout");
            var encodeStalled = new CompressionEngine(Path.Combine(fixtures, "encode-stalled"), 1000, 300);
            timeout = encodeStalled.Compress(Path.Combine(fixtures, "normal.mov"), false, CancellationToken.None);
            Check("stalled encoder watchdog", timeout.Status == "error" && timeout.Message == "encode-timeout", new { timeout.Status, timeout.Message });
            Check("no temporary MOV files", !Directory.GetFiles(fixtures, ".CMPRS-*").Any());
            Check("no log files", !Directory.GetFiles(fixtures, "*.log", SearchOption.AllDirectories).Any());
            var command = CompressionEngine.BuildArguments(JObject.Parse(File.ReadAllText(Path.Combine(fixtures, "source.json"))), "in.mov", "temp.mov", true);
            Check("Ironclad exactly", command.Contains("libx264") && command.Contains("24") && command.Contains("slow") && command.Contains("passthrough") && !command.Contains("-vf") && !command.Contains("-r") && !command.Contains("-fpsmax") && !command.Contains("-ac"));
            return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
        finally { File.WriteAllText(Path.Combine(fixtures, "checks.json"), JsonConvert.SerializeObject(Results, Formatting.Indented)); }
    }
}
