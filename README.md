# CMPRS

A small Finder-first video compressor for macOS. Select one video or a batch, right-click, and choose **CMPRS — Compress video**. An animated ASCII eye watches the progress. Each file shows its original and compressed size. Cancel while processing; Done closes the finished batch.

## Download and install

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

Video processing stays on the Mac. No uploads, telemetry, log files, batch reports or processing history. Encoder diagnostics are discarded; errors are shown briefly in the current queue. Queue state and source-folder permissions last only for the current app session. macOS asks for access to the exact source folder when needed so the app can save next to the originals.

The interface follows the macOS application language: Russian or English, with English as the fallback. There is no language switch or remembered language setting. WebKit uses an ephemeral data store and the local UI blocks network requests and external navigation. The app retains its existing sandbox and WebKit network-client entitlement; the bundled FFmpeg build has no network support.

## Build

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

AGPL-3.0-or-later. FFmpeg/x264 GPL and other third-party notices are included in [NOTICE.md](NOTICE.md). Complete corresponding engine archives are included. Support: https://gleb.day/cmprs/support/ · uralsocket@gmail.com.
