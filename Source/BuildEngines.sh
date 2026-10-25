#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -m)" == arm64 ]] || { echo 'Build on an Apple Silicon Mac.'; exit 1; }
cd "$ROOT"
python3 Source/FetchSources.py
mkdir -p build/source build/pkgconf build/x264 build/ffmpeg
for archive in ThirdPartySources/*.tar.*; do tar -xf "$archive" -C build/source; done
python3 -m venv build/tools
build/tools/bin/python3 -m pip install --disable-pip-version-check meson==1.7.2 ninja==1.11.1.4
PREFIX="$ROOT/build/prefix"
export PATH="$ROOT/build/tools/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=13.0
export CFLAGS='-mmacosx-version-min=13.0'
export LDFLAGS='-mmacosx-version-min=13.0'
cd "$ROOT/build/pkgconf"
"$ROOT/build/source/pkgconf-2.4.3/configure" --prefix="$PREFIX" --disable-shared --enable-static
make -j8; make install
cd "$ROOT/build/x264"
"$ROOT/build/source/x264-c24e06c2e184345ceb33eb20a15d1024d9fd3497/configure" --prefix="$PREFIX" --host=aarch64-apple-darwin --enable-static --disable-cli --bit-depth=all
make -j8; make install
meson setup "$ROOT/build/dav1d" "$ROOT/build/source/dav1d-1.5.1" --prefix="$PREFIX" --default-library=static --buildtype=release -Denable_tools=false -Denable_tests=false
ninja -C "$ROOT/build/dav1d" -j8
ninja -C "$ROOT/build/dav1d" install
cd "$ROOT/build/ffmpeg"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
"$ROOT/build/source/ffmpeg-8.0.1/configure" --prefix="$PREFIX" --pkg-config="$PREFIX/bin/pkgconf" --pkg-config-flags=--static --extra-cflags="-I$PREFIX/include -mmacosx-version-min=13.0" --extra-ldflags="-L$PREFIX/lib -mmacosx-version-min=13.0" --extra-libs=-liconv --arch=arm64 --target-os=darwin --enable-gpl --enable-libx264 --enable-libdav1d --enable-gray --disable-autodetect --enable-zlib --enable-bzlib --enable-iconv --enable-videotoolbox --enable-audiotoolbox --disable-network --disable-ffplay --disable-doc --disable-debug --disable-shared --enable-static
make -j8; make install

mkdir -p "$ROOT/Resources/bin"
cp "$PREFIX/bin/ffmpeg" "$PREFIX/bin/ffprobe" "$ROOT/Resources/bin/"
