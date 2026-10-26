using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace Cmprs
{
    sealed class QueueFile
    {
        public string id = Guid.NewGuid().ToString("N"), name, status = "queued", message;
        public long bytes; public long? outputBytes;
        [JsonIgnore] public string Path;
    }

    sealed class MainForm : Form
    {
        readonly List<QueueFile> files = new List<QueueFile>();
        readonly WebView2 web = new WebView2();
        readonly CompressionEngine engine = new CompressionEngine(System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "bin"));
        readonly string[] initial;
        readonly CancellationTokenSource cancellation = new CancellationTokenSource();
        readonly System.Windows.Forms.Timer stateTimer = new System.Windows.Forms.Timer { Interval = 100 };
        string stage = "queued", notice;
        double progress;
        bool working, cancelling, finished, ready, dirty, closing, allow8Bit;
        string profile;

        public MainForm(string[] paths)
        {
            initial = paths; Text = "CMPRS";
            BackColor = Color.FromArgb(221, 214, 199);
            ClientSize = new Size(420, 560); MinimumSize = new Size(376, 519);
            StartPosition = FormStartPosition.CenterScreen; AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            web.Dock = DockStyle.Fill; web.DefaultBackgroundColor = BackColor; web.AllowExternalDrop = false;
            Controls.Add(web); AllowDrop = true;
            DragEnter += (s, e) => e.Effect = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
            DragDrop += (s, e) => Receive(e.Data.GetData(DataFormats.FileDrop) as string[] ?? new string[0]);
            stateTimer.Tick += (s, e) => { if (dirty) Emit(); }; stateTimer.Start();
            Shown += async (s, e) => await Initialize();
        }

        async Task Initialize()
        {
            try
            {
                profile = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "CMPRS-WebView-" + Guid.NewGuid().ToString("N"));
                var env = await CoreWebView2Environment.CreateAsync(null, profile, new CoreWebView2EnvironmentOptions());
                var options = env.CreateCoreWebView2ControllerOptions(); options.IsInPrivateModeEnabled = true;
                await web.EnsureCoreWebView2Async(env, options);
                var core = web.CoreWebView2;
                core.Settings.AreDevToolsEnabled = false; core.Settings.AreDefaultContextMenusEnabled = false;
                core.Settings.AreBrowserAcceleratorKeysEnabled = false; core.Settings.IsStatusBarEnabled = false;
                core.Settings.IsZoomControlEnabled = false; core.Settings.IsBuiltInErrorPageEnabled = false;
                core.Settings.IsPasswordAutosaveEnabled = false; core.Settings.IsGeneralAutofillEnabled = false;
                core.SetVirtualHostNameToFolderMapping("cmprs.invalid", System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "UI"), CoreWebView2HostResourceAccessKind.DenyCors);
                core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
                core.WebResourceRequested += (s, e) => {
                    Uri u;
                    if (!Uri.TryCreate(e.Request.Uri, UriKind.Absolute, out u) || u.Scheme != "https" || u.Host != "cmprs.invalid")
                        e.Response = env.CreateWebResourceResponse(null, 403, "Blocked", "");
                };
                core.NavigationStarting += (s, e) => { if (!e.Uri.StartsWith("https://cmprs.invalid/", StringComparison.Ordinal)) e.Cancel = true; };
                core.NewWindowRequested += (s, e) => e.Handled = true;
                core.PermissionRequested += (s, e) => e.State = CoreWebView2PermissionState.Deny;
                core.DownloadStarting += (s, e) => e.Cancel = true;
                core.WebMessageReceived += (s, e) => {
                    if (e.Source != "https://cmprs.invalid/index.html") return;
                    try {
                        string action = (string)JObject.Parse(e.WebMessageAsJson)["action"];
                        if (action == "ready") { ready = true; Emit(); }
                        if (action == "cancel") Cancel();
                        if (action == "done" && !working) Close();
                    } catch (JsonException) { }
                };
                core.ProcessFailed += (s, e) => {
                    Cancel(); notice = Program.Local("The interface stopped. Close CMPRS and reopen your videos.", "Интерфейс остановился. Закрой CMPRS и открой ролики снова.");
                    MessageBox.Show(this, notice, "CMPRS");
                };
                web.Source = new Uri("https://cmprs.invalid/index.html");
                if (initial.Length > 0) Receive(initial); else Pick();
            }
            catch (Exception)
            {
                MessageBox.Show(this, Program.Local("The interface could not start. Run the CMPRS installer to install or repair Microsoft WebView2 Runtime.", "Не удалось открыть интерфейс. Запусти установщик CMPRS для установки или восстановления Microsoft WebView2 Runtime."), "CMPRS");
                Close();
            }
        }

        void Pick()
        {
            using (var picker = new OpenFileDialog { Multiselect = true, Title = Program.Local("Choose videos", "Выбрать видео"), Filter = "Video|*.mov;*.mp4;*.m4v;*.mkv;*.avi;*.webm;*.wmv;*.mts;*.m2ts;*.3gp;*.mxf;*.flv;*.mpg;*.mpeg;*.vob;*.ts|All files|*.*" })
                if (picker.ShowDialog(this) == DialogResult.OK) Receive(picker.FileNames);
                else if (files.Count == 0) Close();
        }

        internal bool Receive(string[] paths)
        {
            if (closing || cancelling) return false;
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Show(); Activate();
            foreach (string path in paths)
            {
                try
                {
                    var file = new FileInfo(path);
                    if (!file.Exists || files.Any(f => string.Equals(f.Path, file.FullName, StringComparison.OrdinalIgnoreCase))) continue;
                    files.Add(new QueueFile { Path = file.FullName, name = file.Name, bytes = file.Length });
                }
                catch (Exception) { notice = Program.Local("A selected file could not be opened.", "Не удалось открыть один из выбранных файлов."); }
            }
            if (files.Any(f => f.status == "queued") && !working) { finished = false; _ = Work(); }
            Emit(); return true;
        }

        async Task Work()
        {
            working = true; finished = false;
            try
            {
                QueueFile job;
                while (!cancellation.IsCancellationRequested && (job = files.FirstOrDefault(f => f.status == "queued")) != null)
                {
                    job.status = stage = "inspecting"; Emit();
                    var activeJob = job;
                    engine.Progress = (s, p) => {
                        if (closing || IsDisposed) return;
                        try { BeginInvoke(new Action(() => { if (new[] { "ok", "error", "skipped", "cancelled" }.Contains(activeJob.status)) return; activeJob.status = s == "complete" ? "verifying" : s; stage = activeJob.status; progress = (files.Count(f => f.status == "ok" || f.status == "error" || f.status == "skipped") + p) / Math.Max(1, files.Count); dirty = true; })); } catch (InvalidOperationException) { }
                    };
                    CompressionResult result = await Task.Run(() => engine.Compress(activeJob.Path, allow8Bit, cancellation.Token));
                    if (result.Status == "needs-consent" && !cancellation.IsCancellationRequested)
                    {
                        var answer = MessageBox.Show(this, Program.Local("Convert 10/12-bit video to 8-bit 4:2:0 for compatible H.264? Resolution and frame timing stay unchanged. Applies to this batch only.\n\nYes: convert. No: skip this file.", "Перевести 10/12-битное видео в 8 бит 4:2:0 для совместимого H.264? Разрешение и тайминг кадров сохранятся. Только для этой очереди.\n\nДа: перевести. Нет: пропустить файл."), "CMPRS", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
                        if (answer == DialogResult.Yes) { allow8Bit = true; result = await Task.Run(() => engine.Compress(activeJob.Path, true, cancellation.Token)); }
                        else { result.Status = "skipped"; result.Message = "depth-declined"; }
                    }
                    job.status = result.Status; job.outputBytes = result.OutputBytes > 0 ? (long?)result.OutputBytes : null; job.message = Message(result.Message);
                    if (job.status != "cancelled") progress = (double)files.Count(f => f.status == "ok" || f.status == "error" || f.status == "skipped") / files.Count;
                    Emit();
                }
            }
            finally
            {
                foreach (var f in files.Where(f => f.status == "queued")) f.status = "cancelled";
                working = false; finished = true; stage = cancellation.IsCancellationRequested ? "cancelled" : "complete";
                cancelling = false; if (stage == "complete") progress = 1; Emit();
                if (closing) Close();
            }
        }

        static string Message(string code)
        {
            if (code == null) return null;
            switch (code)
            {
                case "hdr": return Program.Local("HDR / Dolby Vision cannot be preserved by Ironclad H.264. Original unchanged.", "Ironclad H.264 не сохраняет HDR / Dolby Vision. Оригинал не изменён.");
                case "alpha": return Program.Local("H.264 does not support transparency. Original unchanged.", "H.264 не поддерживает прозрачность. Оригинал не изменён.");
                case "larger": return Program.Local("File size did not decrease. No additional copy saved.", "Размер не уменьшился. Дополнительная копия не сохранена.");
                case "depth-declined": return Program.Local("8-bit conversion was not allowed. Original unchanged.", "Переход в 8 бит не разрешён. Оригинал не изменён.");
                case "probe-timeout": case "encode-timeout": return Program.Local("Processing stopped making progress. Original unchanged.", "Обработка перестала продвигаться. Оригинал не изменён.");
                case "validation": case "timing": return Program.Local("The result did not preserve source parameters. No copy saved.", "Результат не сохранил параметры исходника. Копия не сохранена.");
                case "odd": return Program.Local("Odd dimensions cannot be preserved in compatible H.264. Original unchanged.", "Нечётные размеры нельзя сохранить в совместимом H.264. Оригинал не изменён.");
                case "subtitles": return Program.Local("These subtitles cannot be preserved in MOV. Original unchanged.", "Эти субтитры нельзя сохранить в MOV. Оригинал не изменён.");
                case "permission": return Program.Local("No access to the source folder. Original unchanged.", "Нет доступа к папке исходника. Оригинал не изменён.");
                case "pixel": return Program.Local("Unsupported pixel format. Original unchanged.", "Неподдерживаемый пиксельный формат. Оригинал не изменён.");
                default: return Program.Local("Unable to process this video. Original unchanged.", "Не удалось обработать видео. Оригинал не изменён.");
            }
        }

        void Emit()
        {
            dirty = false; if (!ready || IsDisposed || web.CoreWebView2 == null) return;
            web.CoreWebView2.PostWebMessageAsJson(JsonConvert.SerializeObject(new { language = Program.Russian ? "ru" : "en", working, preparing = false, cancelling, finished, progress, stage, files, message = notice }));
        }
        void Cancel() { if (!working || cancelling) return; cancelling = true; cancellation.Cancel(); Emit(); }
        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            closing = true;
            if (working) { e.Cancel = true; Cancel(); }
            else { stateTimer.Stop(); cancellation.Dispose(); web.Dispose(); CleanupProfile(); }
            base.OnFormClosing(e);
        }
        void CleanupProfile()
        {
            if (profile == null) return;
            var path = profile;
            // Runtime may release the temporary profile shortly after the control is disposed.
            Task.Run(() => { for (int i = 0; i < 50; i++) { try { if (Directory.Exists(path)) Directory.Delete(path, true); return; } catch (IOException) { } catch (UnauthorizedAccessException) { } Thread.Sleep(100); } }).Wait(5500);
        }
    }
}
