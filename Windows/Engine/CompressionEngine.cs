using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using Newtonsoft.Json.Linq;

namespace Cmprs
{
    public sealed class CompressionResult
    {
        public string Status, Message, Output;
        public long InputBytes, OutputBytes;
    }

    public sealed class MediaFailure : Exception
    {
        public readonly string Code;
        public MediaFailure(string code) : base(code) { Code = code; }
    }

    // No logs, disk queue or shell command execution. Only temporary MOV output is written.
    public sealed class CompressionEngine
    {
        readonly string ffmpeg, ffprobe;
        readonly int probeTimeout, encodeIdleTimeout;
        public Action<string, double> Progress = delegate { };

        public CompressionEngine(string bin, int probeTimeout = 60000, int encodeIdleTimeout = 300000)
        {
            ffmpeg = Path.Combine(bin, "ffmpeg" + (Environment.OSVersion.Platform == PlatformID.Win32NT ? ".exe" : ""));
            ffprobe = Path.Combine(bin, "ffprobe" + (Environment.OSVersion.Platform == PlatformID.Win32NT ? ".exe" : ""));
            this.probeTimeout = probeTimeout; this.encodeIdleTimeout = encodeIdleTimeout;
        }

        // CommandLineToArgvW/CRT quoting, including trailing backslashes. No cmd.exe involved.
        public static string Quote(string value)
        {
            var b = new StringBuilder("\""); int slash = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slash++; continue; }
                b.Append('\\', c == '"' ? slash * 2 + 1 : slash); b.Append(c); slash = 0;
            }
            return b.Append('\\', slash * 2).Append('"').ToString();
        }

        string Run(string binary, IList<string> args, CancellationToken token, bool probe, double duration = 0, double frames = 0)
        {
            token.ThrowIfCancellationRequested();
            var psi = new ProcessStartInfo(binary, string.Join(" ", args.Select(Quote))) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
                RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            var output = new StringBuilder();
            long activity = Stopwatch.GetTimestamp();
            double bestTime = -1, bestFrames = -1, bestBytes = -1;
            Exception readError = null;
            using (var process = new Process { StartInfo = psi })
            {
                process.Start();
                try { process.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
                var stdout = new Thread(() => {
                    try
                    {
                        if (probe)
                        {
                            var chars = new char[4096]; int n;
                            while ((n = process.StandardOutput.Read(chars, 0, chars.Length)) > 0)
                            {
                                if (output.Length + n > 8 * 1024 * 1024) throw new MediaFailure("probe-large");
                                output.Append(chars, 0, n);
                            }
                        }
                        else
                        {
                            string line;
                            while ((line = process.StandardOutput.ReadLine()) != null)
                            {
                                int eq = line.IndexOf('='); if (eq < 0) continue;
                                string key = line.Substring(0, eq); double v;
                                if (!double.TryParse(line.Substring(eq + 1), NumberStyles.Float, CultureInfo.InvariantCulture, out v)) continue;
                                bool advanced = false; double pct = -1;
                                if (key == "out_time_us" && v > bestTime) { bestTime = v; advanced = true; if (duration > 0) pct = v / 1e6 / duration; }
                                if (key == "frame" && v > bestFrames) { bestFrames = v; advanced = true; if (frames > 0) pct = v / frames; }
                                if (key == "total_size" && v > bestBytes) { bestBytes = v; advanced = true; }
                                if (advanced) Interlocked.Exchange(ref activity, Stopwatch.GetTimestamp());
                                if (pct >= 0) Progress("encoding", Math.Min(.97, Math.Max(0, pct) * .97));
                            }
                        }
                    }
                    catch (Exception e) { readError = e; }
                }) { IsBackground = true };
                var stderr = new Thread(() => {
                    try { var discard = new char[4096]; while (process.StandardError.Read(discard, 0, discard.Length) > 0) { } }
                    catch (IOException) { } catch (ObjectDisposedException) { }
                }) { IsBackground = true };
                stdout.Start(); stderr.Start();
                string failure = null;
                try
                {
                    while (!process.WaitForExit(100))
                    {
                        if (token.IsCancellationRequested) { failure = "cancelled"; break; }
                        if (readError != null) { failure = "read"; break; }
                        double elapsed = (Stopwatch.GetTimestamp() - Interlocked.Read(ref activity)) * 1000.0 / Stopwatch.Frequency;
                        if (elapsed > (probe ? probeTimeout : encodeIdleTimeout)) { failure = probe ? "probe-timeout" : "encode-timeout"; break; }
                    }
                }
                finally
                {
                    if (failure != null) { try { if (!process.HasExited) process.Kill(); } catch { } }
                    if (!process.WaitForExit(10000)) { try { process.Kill(); } catch { } }
                    stdout.Join(5000); stderr.Join(5000);
                }
                token.ThrowIfCancellationRequested();
                if (failure != null) throw new MediaFailure(failure);
                if (readError != null) throw new MediaFailure("read");
                if (process.ExitCode != 0) throw new MediaFailure(probe ? "probe" : "encode");
                return output.ToString();
            }
        }

        JObject Probe(string path, CancellationToken token)
        {
            return JObject.Parse(Run(ffprobe, new[] { "-v", "error", "-protocol_whitelist", "file,pipe", "-show_streams", "-show_format", "-show_chapters", "-of", "json", path }, token, true));
        }
        static string Text(JToken t, string key) { return (string)t[key] ?? ""; }
        static double Number(JToken t, string key) { double n; return double.TryParse(Text(t, key), NumberStyles.Float, CultureInfo.InvariantCulture, out n) ? n : 0; }
        static List<JToken> Streams(JObject info, string type) { return (info["streams"] ?? new JArray()).Where(s => Text(s, "codec_type") == type).ToList(); }
        static bool Cover(JToken s) { return (int?)s["disposition"]?["attached_pic"] == 1; }
        static bool Known(string s) { return s != "" && s != "unknown" && s != "N/A"; }
        static double Rotation(JToken s) { return (s["side_data_list"] ?? new JArray()).Select(d => (double?)d["rotation"]).FirstOrDefault(v => v.HasValue) ?? 0; }

        static string PixelFormat(JToken stream, bool allow8Bit)
        {
            string p = Text(stream, "pix_fmt"), transfer = Text(stream, "color_transfer");
            bool hdrSide = (stream["side_data_list"] ?? new JArray()).Any(s => {
                string t = Text(s, "side_data_type").ToLowerInvariant();
                return t.Contains("dovi") || t.Contains("mastering") || t.Contains("content light") || t.Contains("hdr");
            });
            if (transfer == "smpte2084" || transfer == "arib-std-b67" || hdrSide) throw new MediaFailure("hdr");
            if (p.StartsWith("yuva") || p.StartsWith("gbrap") || new[] { "rgba", "bgra", "argb", "abgr", "ya8", "ya16le" }.Contains(p) || stream["tags"]?["alpha_mode"] != null) throw new MediaFailure("alpha");
            string[] supported = { "yuv420p", "yuvj420p", "yuv422p", "yuvj422p", "yuv444p", "yuvj444p", "yuv420p10le", "yuv422p10le", "yuv444p10le", "yuv444p12le", "yuv422p12le", "gray", "gray10le", "nv12", "nv16", "p010le", "p012le", "rgb24", "bgr24", "gbrp", "gbrp10le", "gbrp12le" };
            if (!supported.Contains(p)) throw new MediaFailure("pixel");
            if ((p.Contains("10") || p.Contains("12") || (p.Contains("16") && p != "nv16")) && !allow8Bit) throw new MediaFailure("depth");
            if (Number(stream, "width") % 2 != 0 || Number(stream, "height") % 2 != 0) throw new MediaFailure("odd");
            return Text(stream, "color_range") == "pc" ? "yuvj420p" : "yuv420p";
        }

        public static List<string> BuildArguments(JObject source, string input, string temporary, bool allow8Bit)
        {
            var video = Streams(source, "video");
            if (!video.Any(s => !Cover(s))) throw new MediaFailure("no-video");
            var args = new List<string> { "-hide_banner", "-nostdin", "-n", "-loglevel", "error", "-xerror", "-noautorotate", "-protocol_whitelist", "file,pipe", "-i", input,
                "-map", "0", "-map_metadata", "0", "-map_chapters", "0", "-copy_unknown", "-c", "copy" };
            for (int i = 0; i < video.Count; i++)
            {
                var v = video[i]; if (Cover(v)) continue;
                string n = ":v:" + i, pixel = PixelFormat(v, allow8Bit);
                args.AddRange(new[] { "-c" + n, "libx264", "-crf" + n, "24", "-preset" + n, "slow", "-b" + n, "0", "-pix_fmt" + n, pixel,
                    "-fps_mode" + n, "passthrough", "-enc_time_base" + n, "-1" });
                foreach (var pair in new[] { new[] { "color_range", "color_range" }, new[] { "color_space", "colorspace" }, new[] { "color_transfer", "color_trc" }, new[] { "color_primaries", "color_primaries" } })
                {
                    string value = Text(v, pair[0]);
                    if (Known(value)) args.AddRange(new[] { "-" + pair[1] + n, value == "gbr" && pair[0] == "color_space" ? "rgb" : value });
                }
                string range = Text(v, "color_range");
                if (range == "pc" || range == "tv") args.AddRange(new[] { "-bsf" + n, "h264_metadata=video_full_range_flag=" + (range == "pc" ? "1" : "0") });
                string field = Text(v, "field_order");
                if (new[] { "tt", "bb", "tb", "bt" }.Contains(field)) args.AddRange(new[] { "-flags" + n, "+ilme+ildct", "-x264-params" + n, field == "tt" || field == "bt" ? "tff=1" : "bff=1" });
            }
            var audio = Streams(source, "audio");
            for (int i = 0; i < audio.Count; i++)
                if (Text(audio[i], "codec_name") != "aac") args.AddRange(new[] { "-c:a:" + i, "aac", "-b:a:" + i, Math.Min(512, Math.Max(1, Number(audio[i], "channels")) * 96).ToString(CultureInfo.InvariantCulture) + "k" });
            if (Streams(source, "subtitle").Any(s => Text(s, "codec_name") != "mov_text")) throw new MediaFailure("subtitles");
            args.AddRange(new[] { "-movflags", "+faststart+use_metadata_tags", "-progress", "pipe:1", "-nostats", "-f", "mov", temporary });
            return args;
        }

        static string DisplayField(string f) { return f == "tt" || f == "bt" ? "top" : f == "bb" || f == "tb" ? "bottom" : f; }
        static void Validate(JObject source, JObject dest)
        {
            var a = Streams(source, "video").Where(s => !Cover(s)).ToList();
            var b = Streams(dest, "video").Where(s => !Cover(s)).ToList();
            if (a.Count != b.Count) throw new MediaFailure("validation");
            for (int i = 0; i < a.Count; i++)
            {
                foreach (string key in new[] { "width", "height", "sample_aspect_ratio", "color_space", "color_transfer", "color_primaries", "color_range" })
                    if (Known(Text(a[i], key)) && Text(a[i], key) != Text(b[i], key)) throw new MediaFailure("validation");
                if (Known(Text(a[i], "field_order")) && DisplayField(Text(a[i], "field_order")) != DisplayField(Text(b[i], "field_order"))) throw new MediaFailure("validation");
                if (Number(a[i], "nb_frames") > 0 && Number(b[i], "nb_frames") > 0 && Number(a[i], "nb_frames") != Number(b[i], "nb_frames")) throw new MediaFailure("timing");
                if (Number(a[i], "duration") > 0 && Number(b[i], "duration") > 0 && Math.Abs(Number(a[i], "duration") - Number(b[i], "duration")) > .002) throw new MediaFailure("timing");
                if (Math.Abs(Rotation(a[i]) - Rotation(b[i])) > .01 || Text(b[i], "pix_fmt") != PixelFormat(a[i], true)) throw new MediaFailure("validation");
            }
            a = Streams(source, "audio"); b = Streams(dest, "audio");
            if (a.Count != b.Count || Streams(source, "subtitle").Count != Streams(dest, "subtitle").Count) throw new MediaFailure("validation");
            for (int i = 0; i < a.Count; i++)
                foreach (string key in new[] { "sample_rate", "channels" })
                    if (Text(a[i], key) != Text(b[i], key)) throw new MediaFailure("validation");
        }

        public CompressionResult Compress(string input, bool allow8Bit, CancellationToken token)
        {
            var result = new CompressionResult(); string temporary = null;
            try
            {
                token.ThrowIfCancellationRequested(); input = Path.GetFullPath(input);
                var file = new FileInfo(input); result.InputBytes = file.Length;
                if ((file.Attributes & FileAttributes.Directory) != 0) throw new MediaFailure("file");
                Progress("inspecting", 0);
                JObject source = Probe(input, token);
                temporary = Path.Combine(file.DirectoryName, ".CMPRS-" + Guid.NewGuid().ToString("N") + ".mov");
                var args = BuildArguments(source, input, temporary, allow8Bit);
                var first = Streams(source, "video").First(s => !Cover(s));
                Progress("encoding", 0);
                Run(ffmpeg, args, token, false, Number(source["format"] ?? new JObject(), "duration"), Number(first, "nb_frames"));
                Progress("verifying", .98);
                JObject dest = Probe(temporary, token); Validate(source, dest);
                result.OutputBytes = new FileInfo(temporary).Length;
                if (result.OutputBytes <= 0) throw new MediaFailure("empty");
                if (result.OutputBytes >= result.InputBytes) { result.Status = "skipped"; result.Message = "larger"; return result; }
                token.ThrowIfCancellationRequested();
                string stem = "CMPRS-" + Path.GetFileNameWithoutExtension(input);
                // Same-volume move publishes atomically and never overwrites an existing file.
                for (int suffix = 1; ; suffix++)
                {
                    string output = Path.Combine(file.DirectoryName, stem + (suffix == 1 ? "" : " (" + suffix + ")") + ".mov");
                    try { File.Move(temporary, output); result.Output = output; break; }
                    catch (IOException) { if (!File.Exists(output) && !Directory.Exists(output)) throw; }
                    token.ThrowIfCancellationRequested();
                }
                result.Status = "ok"; Progress("complete", 1); return result;
            }
            catch (OperationCanceledException) { result.Status = "cancelled"; return result; }
            catch (MediaFailure e) { result.Status = e.Code == "depth" ? "needs-consent" : new[] { "hdr", "alpha", "pixel", "odd", "subtitles" }.Contains(e.Code) ? "skipped" : "error"; result.Message = e.Code; return result; }
            catch (UnauthorizedAccessException) { result.Status = "error"; result.Message = "permission"; return result; }
            catch (IOException) { result.Status = "error"; result.Message = "io"; return result; }
            catch (Exception) { result.Status = "error"; result.Message = "unexpected"; return result; }
            finally { if (temporary != null) { try { File.Delete(temporary); } catch { } } }
        }
    }
}
