using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Newtonsoft.Json;

namespace Cmprs
{
    static class Program
    {
        internal static bool Russian { get { return CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru"; } }
        internal static string Local(string en, string ru) { return Russian ? ru : en; }
        static readonly string Identity = WindowsIdentity.GetCurrent().User.Value;
        static readonly string Channel = "CMPRS-" + Identity;
        static NamedPipeServerStream server;
        static volatile bool exiting;

        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            var files = args.Where(a => !a.StartsWith("--", StringComparison.Ordinal)).ToArray();
            using (var owner = new Mutex(false, @"Local\" + Channel))
            {
                bool owns = false;
                // Forward via user-restricted IPC. No file names/queue are persisted to disk.
                for (int i = 0; i < 100; i++)
                {
                    try { owns = owner.WaitOne(0); } catch (AbandonedMutexException) { owns = true; }
                    if (owns) break;
                    if (Forward(files)) return;
                    Thread.Sleep(100);
                }
                if (!owns) { MessageBox.Show(Local("CMPRS is busy closing. Please try again.", "CMPRS завершает работу. Попробуй ещё раз."), "CMPRS"); return; }
                try
                {
                    using (var form = new MainForm(files))
                    {
                        // Force creation on the UI thread before the inbox can invoke it.
                        var handle = form.Handle;
                        var inbox = new Thread(() => Listen(form)) { IsBackground = true }; inbox.Start();
                        Application.Run(form);
                        exiting = true; try { server?.Dispose(); } catch { }
                    }
                }
                catch (Exception) { MessageBox.Show(Local("CMPRS could not start. Reinstall the application and WebView2 Runtime.", "CMPRS не запустился. Переустанови приложение и WebView2 Runtime."), "CMPRS"); }
                finally { owner.ReleaseMutex(); }
            }
        }

        static bool Forward(string[] files)
        {
            try
            {
                using (var pipe = new NamedPipeClientStream(".", Channel, PipeDirection.InOut))
                {
                    pipe.Connect(100);
                    byte[] bytes = Encoding.UTF8.GetBytes(JsonConvert.SerializeObject(files));
                    if (bytes.Length > 1024 * 1024) return false;
                    byte[] length = BitConverter.GetBytes(bytes.Length); pipe.Write(length, 0, 4); pipe.Write(bytes, 0, bytes.Length); pipe.Flush();
                    var ack = new byte[1]; var read = pipe.BeginRead(ack, 0, 1, null, null);
                    using (read.AsyncWaitHandle) { if (!read.AsyncWaitHandle.WaitOne(5000)) return false; }
                    return pipe.EndRead(read) == 1 && ack[0] == 1;
                }
            }
            catch (IOException) { return false; } catch (TimeoutException) { return false; }
        }

        static byte[] Read(NamedPipeServerStream pipe, int count)
        {
            var bytes = new byte[count]; int offset = 0;
            while (offset < count)
            {
                var read = pipe.BeginRead(bytes, offset, count - offset, null, null);
                using (read.AsyncWaitHandle) { if (!read.AsyncWaitHandle.WaitOne(5000)) throw new IOException(); }
                int n = pipe.EndRead(read); if (n == 0) throw new IOException(); offset += n;
            }
            return bytes;
        }

        static void Listen(MainForm form)
        {
            var security = new PipeSecurity();
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(Identity), PipeAccessRights.FullControl, AccessControlType.Allow));
            while (!exiting)
            {
                try
                {
                    using (var pipe = new NamedPipeServerStream(Channel, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 4096, 4096, security))
                    {
                        server = pipe; pipe.WaitForConnection();
                        int n = BitConverter.ToInt32(Read(pipe, 4), 0); if (n < 2 || n > 1024 * 1024) continue;
                        var files = JsonConvert.DeserializeObject<string[]>(Encoding.UTF8.GetString(Read(pipe, n)));
                        bool accepted = false;
                        form.Invoke(new Action(() => { accepted = form.Receive(files ?? new string[0]); }));
                        pipe.WriteByte(accepted ? (byte)1 : (byte)0); pipe.Flush();
                    }
                }
                catch (Exception) { if (!exiting) Thread.Sleep(100); }
            }
        }
    }
}
