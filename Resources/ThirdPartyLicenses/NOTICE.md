# CMPRS 2.0.0 — source and third-party notices

Copyright 2026 Gleb Karavaev. CMPRS application, installer and build scripts are AGPL-3.0-or-later; see LICENSE. Corresponding application and engine sources accompany the release as CMPRS-Source-2.0.0.zip at https://github.com/uralsocket/CMPRS.

The Ironclad preset values originate in compressO by codeforreal1, revision dca85e4a9555fb635d56e2a85ebf200553206c9e, AGPL-3.0: https://github.com/codeforreal1/compressO/tree/dca85e4a9555fb635d56e2a85ebf200553206c9e . At quality 100, the upstream preset uses libx264, CRF 24 and slow. CMPRS uses those values, keeps source dimensions and frame timing, writes MOV, converts compatible SDR video to 4:2:0, and requires explicit batch consent before reducing 10/12-bit sources to 8-bit. HDR/Dolby Vision and alpha are skipped unchanged.

FFmpeg and FFprobe 8.0.1, copyright the FFmpeg developers, https://ffmpeg.org. Built with GPL support, static x264 and dav1d, system Apple frameworks, zlib, bzip2 and iconv; networking is disabled. The complete tools are GPL-2.0-or-later, not LGPL-only. See FFmpeg-GPL-2.0.txt, FFmpeg-LGPL-2.1.txt and FFmpeg-LICENSE.md.

x264 commit c24e06c2e184345ceb33eb20a15d1024d9fd3497 (core 164), copyright its authors, GPL-2.0-or-later: https://github.com/mirror/x264. See x264-GPL-2.0.txt.

dav1d 1.5.1, copyright VideoLAN and dav1d authors, BSD-2-Clause: https://github.com/videolan/dav1d. See dav1d-BSD-2-Clause.txt.

Full unmodified corresponding engine source archives and checksums are included in ThirdPartySources/. Source/BuildEngines.sh and Source/FetchSources.py specify the exact build inputs and configuration. Tools run as child processes; the Swift application does not link FFmpeg libraries.

React and ReactDOM 19.3.1 are MIT licensed; see react.txt and react-dom.txt. Their exact source distributions are available through the pinned UI package manifest and lockfile.

pkgconf 2.4.3 (ISC) is a source-package build dependency and is not bundled in the app. Meson 1.7.2 and Ninja 1.11.1.4 are ordinary build tools installed from PyPI. System libraries and SDK frameworks remain part of macOS/Xcode. No commercial x264 license is claimed. No unrelated upstream image-compression executables are bundled.
