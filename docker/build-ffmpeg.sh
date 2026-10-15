#!/usr/bin/env bash
# Builds the FFmpeg the image ships, from release tarballs pinned by sha256, into <prefix>:
# headers, pkg-config files, shared libraries, and licenses/ffmpeg/ (with SOURCE naming what was
# built) and licenses/dav1d/.
#
# It is LGPL 2.1 or later and decodes only: no encoders, muxers, filters, devices or network, no
# --enable-gpl or --enable-version3, and --disable-autodetect so no library the build environment
# happens to carry is linked in. Everything else is enabled -- every native demuxer, decoder and
# parser -- because NInfer probes whatever media a request sends. dav1d (BSD 2-Clause) is compiled
# into libavcodec for software AV1 decoding, which FFmpeg's own av1 decoder does only with a
# hardware accelerator; zlib (for PNG and compressed containers) is the build environment's.
#
#   FFMPEG_VERSION=8.1.3 FFMPEG_SHA256=... DAV1D_VERSION=1.5.4 DAV1D_SHA256=... \
#     docker/build-ffmpeg.sh /opt/ffmpeg
set -euo pipefail
(( $# == 1 )) || { printf 'usage: build-ffmpeg.sh <prefix>\n' >&2; exit 2; }
prefix="$1"
: "${FFMPEG_VERSION:?}" "${FFMPEG_SHA256:?}" "${DAV1D_VERSION:?}" "${DAV1D_SHA256:?}"
ffmpeg_url="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
dav1d_url="https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

fetch() {  # fetch <url> <sha256> <dir>
  curl -fsSLo "$work/src.tar.xz" "$1"
  echo "$2  $work/src.tar.xz" | sha256sum --check --strict --quiet -
  mkdir -p -- "$3"
  tar -xJf "$work/src.tar.xz" -C "$3" --strip-components=1
  rm -f -- "$work/src.tar.xz"
}

fetch "$dav1d_url" "$DAV1D_SHA256" "$work/dav1d"
meson setup "$work/dav1d/build" "$work/dav1d" --prefix="$prefix" --libdir=lib --buildtype=release \
  --default-library=static -Denable_tools=false -Denable_tests=false -Denable_examples=false
meson install -C "$work/dav1d/build" --quiet

fetch "$ffmpeg_url" "$FFMPEG_SHA256" "$work/ffmpeg"
configuration=(
  --enable-shared --disable-static --disable-debug --disable-doc --disable-programs
  --disable-autodetect --disable-network
  --disable-avdevice --disable-avfilter --disable-encoders --disable-muxers --disable-filters
  --disable-devices --disable-hwaccels
  --enable-zlib --enable-libdav1d --pkg-config-flags=--static
)
(cd "$work/ffmpeg" \
  && PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
     ./configure --prefix="$prefix" --libdir="$prefix/lib" "${configuration[@]}" > "$work/configure.log")
# The license follows from the configuration; refuse one that is not LGPL.
grep -qx '#define CONFIG_GPL 0' "$work/ffmpeg/config.h" \
  && grep -qx '#define CONFIG_VERSION3 0' "$work/ffmpeg/config.h" \
  && grep -qx '#define CONFIG_NONFREE 0' "$work/ffmpeg/config.h" \
  || { printf 'build-ffmpeg.sh: the configuration is not LGPL 2.1 or later\n' >&2; exit 1; }
make -C "$work/ffmpeg" -j"$(nproc)" > "$work/make.log"
make -C "$work/ffmpeg" install > /dev/null

mkdir -p -- "$prefix/licenses/ffmpeg" "$prefix/licenses/dav1d"
cp -- "$work/ffmpeg/COPYING.LGPLv2.1" "$work/ffmpeg/LICENSE.md" "$prefix/licenses/ffmpeg/"
cp -- "$work/dav1d/COPYING" "$prefix/licenses/dav1d/"
printf '%s\n' \
  "FFmpeg $FFMPEG_VERSION, LGPL version 2.1 or later (COPYING.LGPLv2.1, LICENSE.md)." \
  "Source: $ffmpeg_url (sha256 $FFMPEG_SHA256)" \
  "Configured: ${configuration[*]}" \
  "dav1d $DAV1D_VERSION, BSD 2-Clause (../dav1d/COPYING), compiled into libavcodec." \
  "Source: $dav1d_url (sha256 $DAV1D_SHA256)" \
  "This software is based in part on the work of the Independent JPEG Group." \
  > "$prefix/licenses/ffmpeg/SOURCE"
