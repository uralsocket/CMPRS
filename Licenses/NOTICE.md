# CMPRS 1.0.5 — source and third-party notices

Copyright 2026 Gleb Karavaev. CMPRS Swift app, installer and build scripts: AGPL-3.0-or-later; see ../LICENSE. The full corresponding source is published at https://github.com/uralsocket/CMPRS and accompanies this release as CMPRS-Source-1.0.5.zip.

The Ironclad profile is based on the preset values in compressO by codeforreal1, revision dca85e4a9555fb635d56e2a85ebf200553206c9e, AGPL-3.0: https://github.com/codeforreal1/compressO/tree/dca85e4a9555fb635d56e2a85ebf200553206c9e . The native Swift wrapper was implemented independently. The original preset uses libx264, CRF 24 and slow at quality=100. CMPRS preserves supported source bit depth and chroma rather than forcing yuv420p.

## Included executable tools

FFmpeg and FFprobe 8.0.1, https://ffmpeg.org, copyright the FFmpeg developers. Built with GPL support, static x264, static dav1d, local file support, system Apple frameworks, zlib, bzip2 and iconv. The complete FFmpeg binary is GPL-2.0-or-later. It is not an LGPL-only build. See FFmpeg-GPL-2.0.txt and FFmpeg-LICENSE.md.

x264, commit c24e06c2e184345ceb33eb20a15d1024d9fd3497 (core 164), copyright its authors, GPL-2.0-or-later. Mirror: https://github.com/mirror/x264 . License: x264-GPL-2.0.txt.

dav1d 1.5.1, copyright VideoLAN and dav1d authors, BSD-2-Clause. https://github.com/videolan/dav1d . License: dav1d-BSD-2-Clause.txt.

Full unmodified corresponding source archives and checksums for these exact versions are included under ThirdPartySources/ in CMPRS-Source-1.0.5.zip. Source/BuildEngines.sh contains the build configuration. No source-availability promise is substituted for these archives.

The executable tools are invoked as separate processes. The CMPRS app does not link FFmpeg libraries into its Swift executable. No commercial x264 license is claimed.

pkgconf 2.4.3 (ISC) is included as a build tool in the source package, not bundled in the app. Meson 1.7.2 and Ninja 1.11.1.4 are ordinary build tools installed from PyPI when building; they are not bundled in the distributed app. System libraries and SDK frameworks remain part of macOS/Xcode.

CMPRS contains no pngquant, jpegoptim, or gifski executables. Their notices from the upstream multi-purpose application do not describe this video-only bundle.
