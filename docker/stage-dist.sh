#!/usr/bin/env bash
# Stages what the runtime image needs from one NInfer build tree into <dist dir>:
#   bin/              ninfer and ninfer-serve, stripped
#   packages.txt      the Ubuntu packages providing their other shared libraries (libcurl, zlib, the
#                     CUDA runtime), so the runtime stage installs exactly those; the driver library
#                     comes from the host
#   lib/              the FFmpeg libraries they resolve, under their sonames. FFmpeg is no Ubuntu
#                     package here but the build stage's LGPL build under /opt/ffmpeg
#                     (docker/build-ffmpeg.sh)
#   licenses/         ninfer/ (LICENSE and every third_party license, copying and notice file, paths
#                     kept), ffmpeg/ (with SOURCE) and dav1d/
#
#   docker/stage-dist.sh <build dir> <dist dir>
set -euo pipefail
(( $# == 2 )) || { printf 'usage: stage-dist.sh <build dir> <dist dir>\n' >&2; exit 2; }
build_dir="$1" dist="$2" ffmpeg=/opt/ffmpeg
source_root="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p -- "$dist/bin" "$dist/lib" "$dist/licenses/ninfer"
for name in ninfer ninfer-serve; do
  install -m 0755 -- "$build_dir/apps/$name" "$dist/bin/$name"
  strip --strip-unneeded -- "$dist/bin/$name"
done

# An FFmpeg library resolved anywhere else (a distribution FFmpeg left in the build environment)
# would put that build's license back into the image, so it stops the staging.
resolved="$(for name in ninfer ninfer-serve; do ldd "$dist/bin/$name"; done \
  | awk '$2 == "=>" && $3 ~ /^\// { print $1, $3 }' | sort -u)"
stray="$(awk -v ffmpeg="$ffmpeg/lib/" '$1 ~ /^lib(av|sw|postproc)/ && index($2, ffmpeg) != 1' <<< "$resolved")"
if [[ -n "$stray" ]]; then
  printf 'stage-dist.sh: FFmpeg libraries resolved outside %s:\n%s\n' "$ffmpeg/lib" "$stray" >&2
  exit 1
fi
# dpkg -S names the package owning each library; the FFmpeg ones are copied instead.
while read -r soname library; do
  real="$(readlink -f -- "$library")"
  case "$real" in
    "$ffmpeg"/lib/*) install -m 0644 -- "$real" "$dist/lib/$soname" ;;
    *) dpkg -S "$real" 2>/dev/null || dpkg -S "$library" 2>/dev/null || true ;;
  esac
done <<< "$resolved" | cut -d: -f1 | sort -u > "$dist/packages.txt"
cp -R -- "$ffmpeg/licenses/." "$dist/licenses/"

licenses="$(cd "$dist/licenses/ninfer" && pwd)"
(cd "$source_root" && find . -maxdepth 1 -type f -name LICENSE -print0
 find third_party -mindepth 2 -type f \
   \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -print0) \
  | (cd "$source_root" && xargs -0 -r cp --parents -t "$licenses")

printf 'staged %s: packages %s; FFmpeg %s\n' "$(ls "$dist/bin" | tr '\n' ' ')" \
  "$(tr '\n' ' ' < "$dist/packages.txt")" "$(ls "$dist/lib" | tr '\n' ' ')"
