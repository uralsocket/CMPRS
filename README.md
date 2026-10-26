# CMPRS

A small video compressor for macOS and Windows. Select one video or a batch in Finder or File Explorer, right-click, and choose **CMPRS — Compress video**. An animated ASCII eye watches the progress. Each file shows its original and compressed size. Cancel while processing; Done closes the finished batch.

## Download and install

| Platform | Requirements | Download |
| --- | --- | --- |
| macOS 2.0.0 | Apple Silicon (M1+), macOS 13+ | [Mac installer](https://github.com/uralsocket/CMPRS/releases/download/v2.0.0/CMPRS-2.0.0-AppleSilicon.dmg) |
| Windows 2.0.1 | Intel/AMD x64, Windows 10 22H2 / 11, .NET Framework 4.8 | [Windows installer](https://github.com/uralsocket/CMPRS/releases/download/v2.0.1/CMPRS-2.0.1-Windows-x64-Setup.exe) |

### Windows

Open the setup EXE and click **Install**. It includes FFmpeg and registers the Explorer action, Start menu shortcut and Windows uninstaller for the current user. Microsoft WebView2 is installed automatically if missing; that step needs internet. The installer is unsigned. In Windows 11, the action is under **Show more options** (Shift+F10); **Send to → CMPRS** also accepts a batch. Remove CMPRS through **Settings → Apps → Installed apps**. The Windows build has been tested and reported working by its owner.

Windows sources, build instructions, dependency versions and notices: [Windows/](Windows/). It uses the same Ironclad x264/CRF24/slow profile and compact React eye as the Mac version. Native Windows ARM64 is not included.

### macOS

Apple Silicon (M1 or newer), macOS 13 or later. This release does not run on Intel Macs. Download the DMG from [Releases](https://github.com/uralsocket/CMPRS/releases), open **Install CMPRS**, and click Install. The installer adds the app to `~/Applications` and registers its Finder service. It retires identified old CMPRS workflows with a recoverable backup and preserves unrelated workflows.

Finder normally displays the action directly in its context menu. macOS may group services under **Services**. If it is hidden, enable it under System Settings → Keyboard → Keyboard Shortcuts → Services → Files and Folders. To remove the menu item, disable that checkbox. Automator actions, if installed by an old release, live in `~/Library/Services`.

## Compression

- Ironclad preset: software x264, CRF 24, preset slow.
- Always MOV. Output: `CMPRS-[name].mov` beside the original; name collisions receive `(2)`, `(3)`, and so on.
- Original dimensions and frame timing are retained and checked. Originals and earlier outputs are never overwritten.
- Compatible SDR H.264 in 4:2:0. Reducing 10/12-bit video to 8-bit requires confirmation for that batch. HDR/Dolby Vision and transparency are skipped unchanged.
- AAC audio is copied. Other audio uses AAC without deliberately changing channel count or sample rate. Unsupported subtitle/container combinations are skipped.
- The result is kept only if it is smaller. Lossy compression is not guaranteed to shrink every source or be visually identical to it.

## Privacy and language

Video processing stays on your computer. No uploads, telemetry, log files, batch reports or processing history. Encoder diagnostics are discarded; errors are shown briefly in the current queue. Queue state and source-folder permissions last only for the current app session. macOS asks for access to the exact source folder when needed so the app can save next to the originals.

The interface follows the system/application language: Russian or English, with English as the fallback. There is no language switch or remembered language setting. The Mac interface uses an ephemeral WebKit data store; Windows uses a temporary InPrivate WebView2 profile with cleanup on normal exit. Both local interfaces block external navigation and network requests. The app retains its existing sandbox and WebKit network-client entitlement; the Mac FFmpeg build has no network support. The Windows engine restricts input protocols to local files and pipes.

## Build for macOS

Requires an Apple Silicon Mac, Xcode command-line tools, Python 3, Node.js and pnpm.

```sh
# Required for a Git checkout; optional in the full source release archive, which includes the exact tools.
bash Source/BuildEngines.sh
cd UI
pnpm install --frozen-lockfile
pnpm build
cd ..
python3 Build.py
# For a distributable Developer ID build, pass your signing identity:
python3 Build.py --identity 'Developer ID Application: Your Name (TEAMID)'
python3 Installer/BuildInstaller.py --app Release/CMPRS.app --identity 'Developer ID Application: Your Name (TEAMID)'
```

`Build.py` defaults to `Build/CMPRS.app`; use `--output-dir Release` for the last installer example. It validates the actual encoder architectures and refuses to label an ARM-only engine universal. The installer targets the same architectures as its payload. Notarize and staple both app and installer before public distribution.

AGPL-3.0-or-later. FFmpeg/x264 GPL and other third-party notices are included in [NOTICE.md](NOTICE.md). The Mac source release includes its corresponding engine archives. Windows dependency/source references are described separately in [Windows/NOTICE.md](Windows/NOTICE.md). Support: https://gleb.day/cmprs/support/ · uralsocket@gmail.com.
