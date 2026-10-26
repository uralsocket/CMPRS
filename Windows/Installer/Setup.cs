using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Cmprs.Setup
{
    static class Install
    {
        internal static readonly string Dest = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CMPRS");
        internal static readonly string Shortcut = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "CMPRS.lnk");
        internal static readonly string SendTo = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SendTo), "CMPRS.lnk");
        const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\CMPRS";
        const string Marker = "cmprs-installation.txt";
        internal static readonly string[] Extensions = { ".mp4", ".mov", ".m4v", ".mkv", ".avi", ".webm", ".wmv", ".mts", ".m2ts", ".3gp", ".mxf", ".flv", ".mpg", ".mpeg", ".vob", ".ts" };
        internal static string Local(string en, string ru) { return CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru" ? ru : en; }
        static string ShellKey(string ext) { return @"Software\Classes\SystemFileAssociations\" + ext + @"\shell\CMPRS"; }
        [DllImport("shell32.dll")] static extern void SHChangeNotify(uint evt, uint flags, IntPtr first, IntPtr second);

        internal static Mutex LockApp()
        {
            string name = @"Local\CMPRS-" + WindowsIdentity.GetCurrent().User.Value;
            var gate = new Mutex(false, name); bool held;
            try { held = gate.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
            if (!held) { gate.Dispose(); throw new IOException(Local("Close CMPRS, then try again.", "Закрой CMPRS и повтори установку.")); }
            // Detect the original port too, which used a different mutex.
            try {
                using (var legacy = Mutex.OpenExisting(@"Local\CMPRS_ui")) {
                    bool free; try { free = legacy.WaitOne(0); } catch (AbandonedMutexException) { free = true; }
                    if (!free) throw new IOException(Local("Close the previous CMPRS version, then try again.", "Закрой предыдущую версию CMPRS и попробуй снова."));
                    legacy.ReleaseMutex();
                }
            } catch (WaitHandleCannotBeOpenedException) { }
            catch { gate.ReleaseMutex(); gate.Dispose(); throw; }
            return gate;
        }

        static bool Owned(string folder)
        {
            return File.Exists(Path.Combine(folder, Marker)) ||
                (File.Exists(Path.Combine(folder, "cmprs.exe")) && File.Exists(Path.Combine(folder, "uninstall.ps1")) && File.Exists(Path.Combine(folder, "cmprs.ico")));
        }
        static void CheckOwned()
        {
            if (Directory.Exists(Dest) && !Owned(Dest)) throw new IOException(Local("The CMPRS folder contains an unrecognized installation. Move it aside before installing.", "В папке CMPRS найдена неизвестная установка. Перемести её перед установкой."));
            if (Directory.Exists(Dest) && (File.GetAttributes(Dest) & FileAttributes.ReparsePoint) != 0) throw new IOException("CMPRS installation folder is a reparse point.");
        }

        static bool RuntimePresent()
        {
            const string key = @"Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
            foreach (var hive in new[] { RegistryHive.CurrentUser, RegistryHive.LocalMachine })
                foreach (var view in new[] { RegistryView.Registry32, RegistryView.Registry64 })
                    using (var root = RegistryKey.OpenBaseKey(hive, view))
                    using (var found = root.OpenSubKey(key))
                    { Version v; if (Version.TryParse(found?.GetValue("pv") as string, out v) && v.Major >= 100) return true; }
            return false;
        }

        static void EnsureRuntime(string stage, Action<string> status)
        {
            if (RuntimePresent()) return;
            status(Local("Installing Microsoft WebView2… Internet connection required.", "Устанавливаем Microsoft WebView2… Нужен интернет."));
            string installer = Path.Combine(stage, "MicrosoftEdgeWebview2Setup.exe");
            using (var p = Process.Start(new ProcessStartInfo(installer, "/silent /install") { UseShellExecute = false, CreateNoWindow = true }))
            {
                if (!p.WaitForExit(600000)) throw new IOException(Local("WebView2 installation timed out. Retry after it finishes.", "Установка WebView2 затянулась. Повтори после её завершения."));
                if (!RuntimePresent()) throw new IOException(Local("Microsoft WebView2 could not be installed. Check your connection and retry.", "Не удалось установить Microsoft WebView2. Проверь интернет и повтори."));
            }
            File.Delete(installer);
        }

        static void Extract(string stage)
        {
            using (var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("CMPRS.Payload"))
            using (var zip = new ZipArchive(resource, ZipArchiveMode.Read))
            {
                string prefix = Path.GetFullPath(stage) + Path.DirectorySeparatorChar;
                foreach (var entry in zip.Entries)
                {
                    string dest = Path.GetFullPath(Path.Combine(stage, entry.FullName));
                    if (!dest.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new IOException("Invalid package path.");
                    if (entry.Name.Length == 0) { Directory.CreateDirectory(dest); continue; }
                    Directory.CreateDirectory(Path.GetDirectoryName(dest));
                    using (var input = entry.Open()) using (var output = new FileStream(dest, FileMode.CreateNew)) input.CopyTo(output);
                }
            }
            // Build-generated manifest covers every bundled file; verify before executing tools.
            foreach (string line in File.ReadAllLines(Path.Combine(stage, "SHA256SUMS.txt")))
            {
                int sep = line.IndexOf("  ", StringComparison.Ordinal); if (sep != 64) throw new IOException("Invalid package manifest.");
                string path = Path.GetFullPath(Path.Combine(stage, line.Substring(sep + 2)));
                if (!path.StartsWith(Path.GetFullPath(stage) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new IOException("Invalid package manifest path.");
                using (var hash = SHA256.Create()) using (var file = File.OpenRead(path))
                { if (BitConverter.ToString(hash.ComputeHash(file)).Replace("-", "").ToLowerInvariant() != line.Substring(0, 64)) throw new IOException("Package checksum mismatch."); }
            }
        }

        static void MakeShortcut(string path, string exe)
        {
            Type type = Type.GetTypeFromProgID("WScript.Shell"); object shell = Activator.CreateInstance(type), link = null;
            try
            {
                link = type.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
                Type t = link.GetType();
                t.InvokeMember("TargetPath", BindingFlags.SetProperty, null, link, new object[] { exe });
                t.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, link, new object[] { Path.GetDirectoryName(exe) });
                t.InvokeMember("IconLocation", BindingFlags.SetProperty, null, link, new object[] { exe + ",0" });
                t.InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
            }
            finally { if (link != null) Marshal.FinalReleaseComObject(link); Marshal.FinalReleaseComObject(shell); }
        }

        static void Register()
        {
            string exe = Path.Combine(Dest, "CMPRS.exe");
            foreach (string ext in Extensions)
                using (var key = Registry.CurrentUser.CreateSubKey(ShellKey(ext)))
                {
                    key.SetValue("MUIVerb", Local("CMPRS — Compress video", "CMPRS — Сжать видео"));
                    key.SetValue("Icon", "\"" + exe + "\",0"); key.SetValue("MultiSelectModel", "Player");
                    using (var command = key.CreateSubKey("command")) command.SetValue("", "\"" + exe + "\" \"%1\"");
                }
            MakeShortcut(Shortcut, exe); MakeShortcut(SendTo, exe);
            using (var key = Registry.CurrentUser.CreateSubKey(UninstallKey))
            {
                key.SetValue("DisplayName", "CMPRS"); key.SetValue("DisplayVersion", "2.0.1"); key.SetValue("Publisher", "Gleb Karavaev");
                key.SetValue("InstallLocation", Dest); key.SetValue("DisplayIcon", exe);
                key.SetValue("UninstallString", "\"" + Path.Combine(Dest, "Uninstall.exe") + "\"");
                key.SetValue("NoModify", 1); key.SetValue("NoRepair", 1); key.SetValue("URLInfoAbout", "https://gleb.day/cmprs/");
                key.SetValue("EstimatedSize", (int)(Directory.GetFiles(Dest, "*", SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length) / 1024));
            }
            SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero);
        }

        // Snapshot only CMPRS-owned registration values to roll back a failed upgrade.
        sealed class RegSnapshot
        {
            public string Path; public Dictionary<string, object> Values;
        }
        static List<RegSnapshot> Snapshot()
        {
            var result = new List<RegSnapshot>();
            foreach (string path in Extensions.SelectMany(e => new[] { ShellKey(e), ShellKey(e) + @"\command" }).Concat(new[] { UninstallKey }))
                using (var key = Registry.CurrentUser.OpenSubKey(path))
                    result.Add(new RegSnapshot { Path = path, Values = key == null ? null : key.GetValueNames().ToDictionary(n => n, n => key.GetValue(n)) });
            return result;
        }
        static void Restore(List<RegSnapshot> snapshot)
        {
            foreach (var item in snapshot.OrderByDescending(s => s.Path.Length)) Registry.CurrentUser.DeleteSubKeyTree(item.Path, false);
            foreach (var item in snapshot.Where(s => s.Values != null))
                using (var key = Registry.CurrentUser.CreateSubKey(item.Path)) foreach (var value in item.Values) key.SetValue(value.Key, value.Value);
        }
        internal static void Run(Action<string> status)
        {
            using (var app = LockApp())
            {
                string stage = Path.Combine(Path.GetDirectoryName(Dest), ".CMPRS-stage-" + Guid.NewGuid().ToString("N"));
                string backup = Dest + "-previous-" + Guid.NewGuid().ToString("N");
                var snapshot = Snapshot();
                byte[] oldShortcut = File.Exists(Shortcut) ? File.ReadAllBytes(Shortcut) : null;
                byte[] oldSendTo = File.Exists(SendTo) ? File.ReadAllBytes(SendTo) : null;
                bool moved = false, published = false;
                try
                {
                    CheckOwned(); Directory.CreateDirectory(stage);
                    status(Local("Preparing CMPRS…", "Подготавливаем CMPRS…")); Extract(stage); EnsureRuntime(stage, status);
                    File.WriteAllText(Path.Combine(stage, Marker), "CMPRS 2.0.1\n");
                    status(Local("Installing application and Explorer action…", "Устанавливаем приложение и действие Проводника…"));
                    if (Directory.Exists(Dest)) { Directory.Move(Dest, backup); moved = true; }
                    Directory.Move(stage, Dest); published = true;
                    Register();
                    // Successful install; old package is no longer needed. Cleanup is best effort.
                    if (moved) { try { Directory.Delete(backup, true); } catch { } }
                }
                catch
                {
                    if (published && Directory.Exists(Dest)) Directory.Delete(Dest, true);
                    if (moved && Directory.Exists(backup)) Directory.Move(backup, Dest);
                    Restore(snapshot);
                    if (oldShortcut != null) File.WriteAllBytes(Shortcut, oldShortcut); else if (File.Exists(Shortcut)) File.Delete(Shortcut);
                    if (oldSendTo != null) File.WriteAllBytes(SendTo, oldSendTo); else if (File.Exists(SendTo)) File.Delete(SendTo);
                    throw;
                }
                finally { if (Directory.Exists(stage)) { try { Directory.Delete(stage, true); } catch { } } app.ReleaseMutex(); }
            }
        }

        internal static void Remove()
        {
            using (var app = LockApp())
            {
                try
                {
                    CheckOwned(); string exe = Path.Combine(Dest, "CMPRS.exe");
                    foreach (string ext in Extensions)
                    {
                        string path = ShellKey(ext); bool owned;
                        using (var key = Registry.CurrentUser.OpenSubKey(path + @"\command")) owned = ((string)key?.GetValue("") ?? "").StartsWith("\"" + exe + "\"", StringComparison.OrdinalIgnoreCase);
                        if (owned) Registry.CurrentUser.DeleteSubKeyTree(path, false);
                    }
                    if (File.Exists(Shortcut)) File.Delete(Shortcut); if (File.Exists(SendTo)) File.Delete(SendTo);
                    Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false);
                    if (Directory.Exists(Dest)) Directory.Delete(Dest, true);
                    SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero);
                }
                finally { app.ReleaseMutex(); }
            }
        }
    }

    sealed class SetupForm : Form
    {
        readonly Label title = new Label(), status = new Label();
        readonly Button action = new Button();
        bool busy, done;
#if INSTALLER
        static readonly bool Removing = false;
#else
        static readonly bool Removing = true;
#endif
        public SetupForm()
        {
            Text = "CMPRS"; AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi; ClientSize = new Size(440, 240); StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
            BackColor = Color.FromArgb(221, 214, 199); ForeColor = Color.FromArgb(41, 41, 35); Font = new Font("Arial", 11);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            title.Text = Removing ? Install.Local("Remove CMPRS", "Удалить CMPRS") : Install.Local("Install CMPRS", "Установить CMPRS");
            title.Font = new Font("Arial", 23, FontStyle.Bold); title.SetBounds(26, 26, 388, 42);
            status.Text = Removing ? Install.Local("Removes the app and Explorer action. Your videos stay untouched.", "Удаляет приложение и действие Проводника. Видеофайлы останутся.") : Install.Local("Ironclad compression, right from File Explorer.\nInstalls for your account. No administrator rights needed.", "Сжатие Ironclad прямо из Проводника.\nДля твоей учётной записи, без прав администратора.");
            status.SetBounds(28, 86, 384, 70);
            action.Text = Removing ? Install.Local("Remove", "Удалить") : Install.Local("Install", "Установить");
            action.SetBounds(28, 174, 384, 42); action.FlatStyle = FlatStyle.Flat;
            action.BackColor = ForeColor; action.ForeColor = BackColor;
            Controls.AddRange(new Control[] { title, status, action }); AcceptButton = action;
            action.Click += async (s, e) => {
                if (done) { Close(); return; } if (busy) return;
                busy = true; action.Enabled = false;
                try
                {
                    await Task.Run(() => { if (Removing) Install.Remove(); else Install.Run(text => BeginInvoke(new Action(() => status.Text = text))); });
                    status.Text = Removing ? Install.Local("CMPRS removed. Your videos are unchanged.", "CMPRS удалён. Видеофайлы не изменены.") : Install.Local("Installed. Right-click a video → CMPRS — Compress video.\nWindows 11: Show more options.", "Установлено. ПКМ по видео → CMPRS — Сжать видео.\nWindows 11: «Показать дополнительные параметры».");
                    done = true; action.Text = Install.Local("Done", "Готово");
                }
                catch (Exception e2) { status.Text = e2 is IOException ? e2.Message : Install.Local("Installation failed. Close CMPRS and try again.", "Не удалось завершить установку. Закрой CMPRS и повтори."); }
                finally { busy = false; action.Enabled = true; }
            };
            FormClosing += (s, e) => { if (busy) e.Cancel = true; };
        }
    }

    static class Entry
    {
        [STAThread] static void Main(string[] args)
        {
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
#if !INSTALLER
            // Run the uninstaller outside the package so Windows can remove the installed exe.
            if (!args.Contains("--temporary"))
            {
                string temp = Path.Combine(Path.GetTempPath(), "CMPRS-Remove-" + Guid.NewGuid().ToString("N") + ".exe");
                File.Copy(Application.ExecutablePath, temp); Process.Start(temp, "--temporary"); return;
            }
#endif
            if (!Environment.Is64BitOperatingSystem) { MessageBox.Show("CMPRS requires 64-bit Windows.", "CMPRS"); return; }
            // Never run two installers against the same per-user installation.
            using (var mutex = new Mutex(false, @"Local\CMPRS-Setup-" + WindowsIdentity.GetCurrent().User.Value))
            {
                bool owned; try { owned = mutex.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
                if (!owned) return;
                try { Application.Run(new SetupForm()); } finally { mutex.ReleaseMutex(); }
            }
        }
    }
}
