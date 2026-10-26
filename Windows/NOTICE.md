# CMPRS Windows 2.0.1 — notices

Copyright 2026 Gleb Karavaev. CMPRS application, installer, engine adaptation and build scripts: AGPL-3.0-or-later, see LICENSE. Corresponding application sources accompany this testing build.

The Ironclad preset values originate in compressO by codeforreal1, revision dca85e4a9555fb635d56e2a85ebf200553206c9e (AGPL-3.0): https://github.com/codeforreal1/compressO/tree/dca85e4a9555fb635d56e2a85ebf200553206c9e . Quality 100 uses libx264, CRF 24 and slow. The Windows implementation follows the existing CMPRS macOS parameter-preservation and smaller-only policies.

FFmpeg/FFprobe 7.1.1 essentials x64: unmodified GyanD binary distribution, GPL-3.0. Exact archive https://github.com/GyanD/codexffmpeg/releases/download/7.1.1/ffmpeg-7.1.1-essentials_build.zip . SHA-256 04861d3339c5ebe38b56c19a15cf2c0cc97f5de4fa8910e4d47e5e6404e4a2d4. FFmpeg source revision https://github.com/FFmpeg/FFmpeg/commit/db69d06eee . The complete upstream README/build configuration and GPL text are retained in Licenses/. Upstream build information and library source links: https://www.gyan.dev/ffmpeg/builds/ and https://github.com/GyanD/codexffmpeg . This is an upstream binary dependency, not a CMPRS reproducible FFmpeg build or a claim that every corresponding library source is contained in this source archive. A complete corresponding-source package for bundled GPL dependencies must be verified before a public binary release.

x264 is a GPL dependency of this FFmpeg build. Its copyright/license are retained in the FFmpeg build notices; no commercial x264 license is claimed. The separate GPL-2.0-or-later text is also included.

React / ReactDOM 19.3.1: MIT, exact manifests and pnpm lockfile in UI/. Newtonsoft.Json 13.0.3: MIT. Microsoft.Web.WebView2 SDK 1.0.4314.35 and loader: Microsoft license in Licenses/Microsoft-WebView2.txt. Evergreen Runtime is installed via Microsoft's unmodified official bootstrapper when required; it is a separate Microsoft component. .NET Framework and Windows system components remain part of the operating system.

The native Windows title bar and fallback system fonts differ from macOS. Eye artwork and animation sources are identical to the macOS app. No user video or private metadata is included in this distribution.
