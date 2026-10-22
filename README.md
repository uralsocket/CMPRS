# CMPRS

**Smaller videos. More room.**

A small, open-source utility for batch video compression, right in Finder. Free and local.

[Download for Mac](https://github.com/uralsocket/CMPRS/releases/latest) · [Website](https://gleb.day/cmprs/) · [Support](https://gleb.day/cmprs/support/)

## Getting started

1. Open the DMG, launch **Install CMPRS**, and click **Install**. No terminal or administrator password is required.
2. Select one or more videos in Finder.
3. Choose **Quick Actions → CMPRS Ironclad 100%**. On some macOS versions, the action appears under **Services**.

MOV results are saved beside the source files with the `CMPRS-` prefix. Originals and previous results are never overwritten. A number is added if a filename is already taken. If compression does not make a file smaller, no extra copy is saved.

**Requires Apple Silicon (M1 or later) and macOS 13 or later.**

The app and installer are signed with Developer ID and notarized by Apple. The current compression window uses Russian labels; the installer supports English and Russian. The website opens in English and offers a Russian language switch.

## Compression profile

Ironclad is based on [compressO](https://github.com/codeforreal1/compressO/tree/dca85e4a9555fb635d56e2a85ebf200553206c9e): `libx264`, `CRF 24`, `preset slow`, and H.264 in a MOV container. “100%” identifies the original preset’s quality setting; it does not mean lossless compression.

CMPRS preserves frame dimensions, source frame timestamps, supported 8/10-bit depth, and 4:2:0 / 4:2:2 / 4:4:4 chroma. Audio is copied; audio formats incompatible with MOV are decoded to lossless PCM. Supported metadata is retained, and the result is checked before saving.

HDR, Dolby Vision, transparency, unsupported pixel formats, and incompatible tracks are skipped with an explanation. Some professional H.264 profiles do not play in QuickTime. Output size depends on the source. Video compression is lossy.

## Processing diagnostics

In **1.0.6**, progress is read from a regular file, removing the blocking pipe EOF wait. Before the first encoded frames, the app shows a preparation timer. If the encoder produces no new frames, timestamps, or output data for five minutes, CMPRS stops it and reports an error. Encoding that continues to make progress has no overall time limit. Cancellation forcibly stops a process that ignores the normal termination signal.

The diagnostics button at the bottom of the processing window is available while a job is running. Logs are stored locally in `~/Library/Logs/CMPRS/` and include the app version, video properties, commands, and FFmpeg messages. They are never sent automatically.

Validation covers [14 media scenarios](Verification.json) and [7 process lifecycle scenarios](ProcessVerification.json), including a stalled encoder, crashes, inherited stdout, and cancellation. A successful local test does not establish that every machine-specific issue is resolved; copied diagnostics help investigate failures on another Mac.

## Building from source

You need Apple Silicon, Xcode / Command Line Tools, Python 3.9+, and an internet connection for the initial tool downloads. From the project root:

```sh
bash Source/Build.command
bash Source/BuildInstaller.command
```

The first command builds FFmpeg 8.0.1, x264 core 164, and dav1d 1.5.1 from pinned sources, then builds the Swift app. Intermediate files stay in `build/`. The full third-party source archives are included in [CMPRS-Source-1.0.6.zip](https://github.com/uralsocket/CMPRS/releases/download/v1.0.6/CMPRS-Source-1.0.6.zip). Repository builds download the archives with SHA-256 verification.

By default, builds use an ad-hoc signature for local use. For distribution, set `CMPRS_SIGNING_IDENTITY` to your Developer ID Application identity, then separately submit the app and installer for Apple notarization. Check the notarization tickets for both the installer and its nested app after export. No private keys or credentials are included in this repository.

Public releases use a minimal, locally built FFmpeg rather than the broader prebuilt upstream bundle. H.264 encoding still uses software x264 with CRF 24 / slow. FFmpeg’s built-in decoders and dav1d handle common containers and AV1. Network protocols are disabled. Unsupported inputs fail with a message, leaving originals intact.

## Project layout

- `Source/CMPRS.swift` — compression, queue, and progress window.
- `Source/Installer.swift` — graphical installation, updates, and rollback on failure.
- `Resources/` — app manifest and Automator action.
- `Source/BuildEngines.sh`, `FetchSources.py` — pinned codec build.
- `Licenses/` — licenses and notices.

CMPRS is licensed under AGPL-3.0-or-later. The FFmpeg/x264 executables are GPL-2.0-or-later; dav1d is BSD-2-Clause. See [NOTICE](Licenses/NOTICE.md). Developed by Gleb Karavaev. Contact: uralsocket@gmail.com.
