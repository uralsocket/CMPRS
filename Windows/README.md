# CMPRS for Windows

Smaller videos. Ready to send. The compact macOS interface, now in a Windows application.

## Install

Open **CMPRS-2.0.1-Windows-x64-Setup.exe** and click **Install**. No scripts or administrator rights are needed. The installer includes FFmpeg and adds CMPRS to the Start menu, Explorer's context menu, Send to, and Windows Installed apps. Microsoft WebView2 is installed automatically if missing; that step requires an internet connection.

Requires 64-bit Windows 10 22H2 / Windows 11 with .NET Framework 4.8. This build targets Intel/AMD x64. Native Windows ARM64 is not included. The installer is unsigned; Windows may display an unrecognized-publisher warning. No Windows code-signing certificate has been configured.

## Compress

Select one or more videos in File Explorer → right-click → **CMPRS — Compress video**. In Windows 11 the classic action is under **Show more options** (Shift+F10). **Send to → CMPRS** is another batch entry point. Launching CMPRS from Start opens a file picker.

The same **Ironclad** settings as CMPRS for Mac: **libx264, CRF 24, slow**, in a MOV container. No resolution reduction, FPS cap or GPU preset substitution. Outputs are saved beside the originals as **CMPRS-name.mov**, with numbered suffixes when needed. Existing files are never overwritten. Only smaller results that pass metadata validation are kept.

The window shows the blinking ASCII eye, progress, queue and before/after sizes. **Cancel** stops the queue; **Done** closes the completed batch. The interface follows the system language: Russian on Russian Windows, English otherwise.

HDR/Dolby Vision and transparent video are skipped because this H.264 preset cannot preserve them. Converting 10/12-bit SDR to compatible 8-bit 4:2:0 requires consent for the current batch. Odd dimensions and unsupported MOV tracks are skipped. If dimensions, timing or other checked parameters change, the output is rejected. Some irregular VFR inputs may consequently be declined rather than altered. Audio track count, sample rate and channel count are preserved; AAC is copied and other audio is encoded to AAC.

Processing is local. CMPRS writes no logs, history or disk queue. Incomplete MOV files are removed after cancellation/errors; finished smaller copies remain. The WebView2 interface uses a temporary InPrivate profile, with cleanup on normal exit. Windows/runtime-managed diagnostics and cleanup after a forced process kill are outside the app's control.

## Remove / update

Close CMPRS before installing an update. The installer replaces the previous recognized package and rolls back if installation fails. Remove it through **Settings → Apps → Installed apps → CMPRS → Uninstall**. Videos are not part of the installation folder and are not removed.

## Validation

Cross-compiled on macOS. Shared engine tests used native macOS FFmpeg, including 4K, 120 FPS, rotation, multichannel audio, cancellation, smaller-only output and idle watchdogs. The actual React interface was inspected in a browser at 420×560 and smaller sizes. On October 27, 2026, the owner reported that the Windows build works and approved publication. No automated Windows end-to-end run is claimed. The manual checklist remains in Verification/WINDOWS-CHECK.md.

## Build from source

Install .NET SDK 8.0.427+, Node.js 18+, Python 3.9+ and pnpm. In UI run `pnpm install --frozen-lockfile`. Download the two Windows dependencies listed in Dependencies/downloads.lock.json to Dependencies/ (preserve filenames and verify SHA-256). Then run `python build.py`. It builds the app and uninstaller, bundles FFmpeg and the React UI, and produces the setup EXE in the parent folder. All NuGet packages and React dependencies are pinned. See NOTICE.md for third-party attribution. The original submitted port is preserved separately in the development workspace; it is not shipped.

