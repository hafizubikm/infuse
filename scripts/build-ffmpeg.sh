#!/usr/bin/env bash
#
# Builds FFmpeg 7.1.x from source as a static, LGPL-only, arm64 macOS library
# and wraps it as Vendor/FFmpeg/FFmpeg.xcframework for the Reel Xcode project.
#
# Needs only Xcode (clang, libtool, xcodebuild) and the system `make` — no Homebrew.
#
# Usage:   scripts/build-ffmpeg.sh            # build if missing or out of date
#          scripts/build-ffmpeg.sh --force    # always rebuild
#
# Environment overrides: FFMPEG_VERSION, FFMPEG_SHA256, JOBS
#
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1.4}"
# SHA-256 of ffmpeg-7.1.4.tar.xz (Debian ships this exact upstream tarball next to
# upstream's detached signature, so the checksum matches ffmpeg.org's file).
FFMPEG_SHA256="${FFMPEG_SHA256:-71f4aac3573ed9060489cb62526a6c7dda815ae10993789611acd7be9fa9fbf4}"
MACOS_MIN="14.0"
ARCH="arm64"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/FFmpeg"
WORK="$OUT/.build"
SRC="$WORK/ffmpeg-$FFMPEG_VERSION"
PREFIX="$WORK/install"
TARBALL="$WORK/ffmpeg-$FFMPEG_VERSION.tar.xz"
XCFRAMEWORK="$OUT/FFmpeg.xcframework"
STAMP="$OUT/BUILD_INFO"

# Keep this list in sync with BUILD_INFO so a change forces a rebuild.
CONFIGURE_FLAGS=(
  --prefix="$PREFIX"
  --arch="$ARCH"
  --target-os=darwin
  --enable-cross-compile
  --enable-static
  --disable-shared
  --enable-pic
  --disable-debug
  --disable-programs
  --disable-doc
  --disable-avdevice
  --disable-avfilter
  --disable-postproc
  --disable-network
  --disable-encoders
  --disable-muxers
  --disable-devices
  --disable-autodetect
  --enable-videotoolbox
  --enable-zlib
  --enable-bzlib
  --enable-iconv
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "This script must run on macOS (it needs Xcode's toolchain)."
command -v xcrun >/dev/null || fail "xcrun not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk macosx -f clang)"
ARCHFLAGS="-arch $ARCH -mmacosx-version-min=$MACOS_MIN"
BUILD_ID="ffmpeg=$FFMPEG_VERSION min=$MACOS_MIN arch=$ARCH flags=${CONFIGURE_FLAGS[*]//$PREFIX/PREFIX}"

if [[ "${1:-}" != "--force" && -d "$XCFRAMEWORK" && -f "$STAMP" ]] && grep -qxF "$BUILD_ID" "$STAMP"; then
  log "FFmpeg $FFMPEG_VERSION already built: $XCFRAMEWORK (use --force to rebuild)"
  exit 0
fi

mkdir -p "$WORK"

# --- Download + verify ------------------------------------------------------
if [[ ! -f "$TARBALL" ]]; then
  log "Downloading FFmpeg $FFMPEG_VERSION"
  curl -fL --retry 3 -o "$TARBALL.part" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  mv "$TARBALL.part" "$TARBALL"
fi
ACTUAL_SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$FFMPEG_SHA256" ]]; then
  rm -f "$TARBALL"
  fail "Checksum mismatch for ffmpeg-$FFMPEG_VERSION.tar.xz
  expected $FFMPEG_SHA256
  got      $ACTUAL_SHA"
fi
log "Checksum OK ($ACTUAL_SHA)"

rm -rf "$SRC" "$PREFIX"
tar -xf "$TARBALL" -C "$WORK"

# --- Configure --------------------------------------------------------------
log "Configuring (LGPL, static, $ARCH, macOS $MACOS_MIN+)"
cd "$SRC"
./configure \
  "${CONFIGURE_FLAGS[@]}" \
  --cc="$CC" \
  --host-cc="$CC" \
  --sysroot="$SDK" \
  --extra-cflags="$ARCHFLAGS -O3 -fno-common" \
  --extra-ldflags="$ARCHFLAGS" \
  | tee "$WORK/configure.log"

# Refuse to continue unless FFmpeg reports an LGPL-only configuration.
grep -q '^#define FFMPEG_LICENSE "LGPL version 2.1 or later"' config.h \
  || fail "FFmpeg configuration is not LGPL-only. Check $WORK/configure.log"
grep -q '^#define CONFIG_VIDEOTOOLBOX 1' config.h \
  || fail "VideoToolbox support was not enabled. Check $WORK/configure.log"
log "License check: LGPL version 2.1 or later ✓"

# --- Build ------------------------------------------------------------------
log "Building with $JOBS jobs"
make -j"$JOBS" >"$WORK/make.log" 2>&1 || { tail -50 "$WORK/make.log"; fail "make failed (full log: $WORK/make.log)"; }
make install >>"$WORK/make.log" 2>&1

# --- Package ----------------------------------------------------------------
log "Merging static libraries"
LIBS=(libavformat libavcodec libswscale libswresample libavutil)
LIB_PATHS=()
for l in "${LIBS[@]}"; do LIB_PATHS+=("$PREFIX/lib/$l.a"); done
xcrun libtool -static -no_warning_for_no_symbols -o "$WORK/libFFmpeg.a" "${LIB_PATHS[@]}"

log "Creating FFmpeg.xcframework"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
  -library "$WORK/libFFmpeg.a" \
  -headers "$PREFIX/include" \
  -output "$XCFRAMEWORK" >/dev/null

cp "$SRC/COPYING.LGPLv2.1" "$OUT/LICENSE.LGPLv2.1"

# The system libraries/frameworks FFmpeg's objects depend on, for Config/Reel.xcconfig.
LDFLAGS_FFMPEG="$(
  sed -n 's/^Libs.private: //p' "$PREFIX"/lib/pkgconfig/lib{avformat,avcodec,swscale,swresample,avutil}.pc \
  | tr ' ' '\n' | grep -v -e '^-lav' -e '^-lsw' -e '^-L' -e '^$' \
  | awk '/^-framework$/ { getline f; print "-framework " f; next } !seen[$0]++' \
  | awk '!seen[$0]++' | tr '\n' ' '
)"
cat > "$OUT/FFmpeg.xcconfig" <<EOF
// Generated by scripts/build-ffmpeg.sh — do not edit.
FFMPEG_VERSION = $FFMPEG_VERSION
FFMPEG_LDFLAGS = $LDFLAGS_FFMPEG
EOF
echo "$BUILD_ID" > "$STAMP"

# Keep the tarball and logs, drop the ~1 GB source/object tree.
rm -rf "$SRC" "$PREFIX" "$WORK/libFFmpeg.a"

SLICE="$(find "$XCFRAMEWORK" -maxdepth 1 -type d -name 'macos-*' | head -1)"
log "Done: $XCFRAMEWORK"
log "  slice:   $(basename "$SLICE")"
log "  size:    $(du -sh "$XCFRAMEWORK" | awk '{print $1}')"
log "  license: LGPL v2.1+ (see Vendor/FFmpeg/LICENSE.LGPLv2.1)"
