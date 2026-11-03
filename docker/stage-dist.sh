#!/usr/bin/env bash
# Stages what the runtime image needs from one NInfer build tree into <dist dir>:
#   bin/              ninfer and ninfer-serve, stripped
#   packages.txt      the Ubuntu packages providing their other shared libraries (libcurl, zlib, the
#                     CUDA runtime), so the runtime stage installs exactly those; the driver library
#                     comes from the host
#   lib/              the FFmpeg libraries they resolve, under their sonames. FFmpeg is no Ubuntu
#                     package here but the build stage's LGPL build under /opt/ffmpeg
#                     (docker/build-ffmpeg.sh)
#   ninfer-lib/       NInfer's own shared libraries from <build dir>/lib, stripped. The binaries find
#                     them at $ORIGIN/../lib, so the image installs them beside /usr/local/bin
#   licenses/         ninfer/ (LICENSE and every third_party license, copying and notice file, paths
#                     kept), ffmpeg/ (with SOURCE) and dav1d/
#
#   docker/stage-dist.sh <build dir> <dist dir>
set -euo pipefail
(( $# == 2 )) || { printf 'usage: stage-dist.sh <build dir> <dist dir>\n' >&2; exit 2; }
build_dir="$1" dist="$2" ffmpeg=/opt/ffmpeg
source_root="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p -- "$dist/bin" "$dist/lib" "$dist/ninfer-lib" "$dist/licenses/ninfer"
for name in ninfer ninfer-serve; do
  install -m 0755 -- "$build_dir/apps/$name" "$dist/bin/$name"
  strip --strip-unneeded -- "$dist/bin/$name"
done
build_lib="$(cd "$build_dir/lib" && pwd -P)"
cp -P -- "$build_lib"/*.so* "$dist/ninfer-lib/"
find "$dist/ninfer-lib" -type f -exec strip --strip-unneeded -- {} +

# An FFmpeg library resolved anywhere else (a distribution FFmpeg left in the build environment)
# would put that build's license back into the image, so it stops the staging.
# Resolved from the build tree, where $ORIGIN/../lib reaches NInfer's own libraries.
resolved="$(for name in ninfer ninfer-serve; do ldd "$build_dir/apps/$name"; done \
  | awk '$2 == "=>" && $3 ~ /^\// { print $1, $3 }' | sort -u)"
stray="$(awk -v ffmpeg="$ffmpeg/lib/" '$1 ~ /^lib(av|sw|postproc)/ && index($2, ffmpeg) != 1' <<< "$resolved")"
if [[ -n "$stray" ]]; then
  printf 'stage-dist.sh: FFmpeg libraries resolved outside %s:\n%s\n' "$ffmpeg/lib" "$stray" >&2
  exit 1
fi
# dpkg -S names the package owning each library; the FFmpeg ones are copied instead, NInfer's own
# are staged above, and the driver library (the build stage links the toolkit's stub) comes from
# the host. A library none of these accounts for stops the staging rather than leave the image
# without it.
while read -r soname library; do
  real="$(readlink -f -- "$library")"
  case "$soname:$real" in
    libcuda.so.1:*) ;;
    *:"$ffmpeg"/lib/*) install -m 0644 -- "$real" "$dist/lib/$soname" ;;
    *:"$build_lib"/*) ;;
    *) dpkg -S "$real" 2>/dev/null || dpkg -S "$library" 2>/dev/null || {
         printf 'stage-dist.sh: no package owns %s (%s)\n' "$soname" "$library" >&2
         exit 1
       } ;;
  esac
done <<< "$resolved" | cut -d: -f1 | sort -u > "$dist/packages.txt"
cp -R -- "$ffmpeg/licenses/." "$dist/licenses/"

licenses="$(cd "$dist/licenses/ninfer" && pwd)"
(cd "$source_root" && find . -maxdepth 1 -type f -name LICENSE -print0
 find third_party -mindepth 2 -type f \
   \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -print0) \
  | (cd "$source_root" && xargs -0 -r cp --parents -t "$licenses")

printf 'staged %s: packages %s; FFmpeg %s; NInfer %s\n' "$(ls "$dist/bin" | tr '\n' ' ')" \
  "$(tr '\n' ' ' < "$dist/packages.txt")" "$(ls "$dist/lib" | tr '\n' ' ')" \
  "$(ls "$dist/ninfer-lib" | tr '\n' ' ')"
