# syntax=docker/dockerfile:1
#
# NInfer server image for the RTX 5090 (sm_120a, the one architecture NInfer builds for).
#
# FFmpeg is built here from its release tarball (docker/build-ffmpeg.sh): LGPL 2.1 or later and
# decode-only, with dav1d compiled in for AV1. Ubuntu builds FFmpeg with --enable-gpl and links x264
# and x265, and ready-made "LGPL" builds compile in GPL code too (BtbN's links FFTW through
# chromaprint), either of which puts the binaries that link it under the GPL. NInfer only decodes
# media, so nothing it calls is lost. The shared libraries travel in the image as separate,
# replaceable files. The license files of NInfer, of everything under third_party/, of FFmpeg and of
# dav1d are installed under /opt/ninfer/licenses (docker/stage-dist.sh).

ARG CUDA_VERSION=13.1.2
ARG UBUNTU_VERSION=24.04
# Release tarballs, pinned by sha256: ffmpeg-8.1.3.tar.xz carries a good signature from the FFmpeg
# release signing key, and dav1d's sha256 is the one VideoLAN publishes beside it.
ARG FFMPEG_VERSION=8.1.3
ARG FFMPEG_SHA256=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
ARG DAV1D_VERSION=1.5.4
ARG DAV1D_SHA256=686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5

FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS build
ARG FFMPEG_VERSION
ARG FFMPEG_SHA256
ARG DAV1D_VERSION
ARG DAV1D_SHA256
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        cmake \
        curl \
        libcurl4-openssl-dev \
        meson \
        nasm \
        ninja-build \
        pkg-config \
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
COPY docker/build-ffmpeg.sh /tmp/build-ffmpeg.sh
RUN /tmp/build-ffmpeg.sh /opt/ffmpeg \
    && rm /tmp/build-ffmpeg.sh \
    && echo /opt/ffmpeg/lib > /etc/ld.so.conf.d/ffmpeg.conf \
    && ldconfig
ENV PKG_CONFIG_PATH=/opt/ffmpeg/lib/pkgconfig

WORKDIR /src
COPY . .

RUN cmake -S . -B /build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DNINFER_BUILD_APPS=ON \
        -DBUILD_TESTING=OFF \
        -DNINFER_BUILD_BENCHMARKS=OFF \
    && cmake --build /build --parallel --target ninfer ninfer-serve \
    && docker/stage-dist.sh /build /dist

# Plain Ubuntu, not a CUDA image: the binaries need only the CUDA runtime from the toolkit, which
# the package list names and NVIDIA's apt repository provides, and the driver library comes from
# the host through the NVIDIA Container Toolkit.
FROM ubuntu:${UBUNTU_VERSION}
ARG UBUNTU_VERSION
ARG DEBIAN_FRONTEND=noninteractive
COPY --from=build /dist/packages.txt /tmp/ninfer-packages.txt
COPY --from=build /dist/lib/ /opt/ninfer/lib/
COPY --from=build /dist/licenses/ /opt/ninfer/licenses/
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl \
    && curl -fsSLo /tmp/cuda-keyring.deb \
       "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu$(echo "$UBUNTU_VERSION" | tr -d .)/x86_64/cuda-keyring_1.1-1_all.deb" \
    && dpkg -i /tmp/cuda-keyring.deb \
    && apt-get update \
    && xargs apt-get install --yes --no-install-recommends < /tmp/ninfer-packages.txt \
    && find /usr/local -name 'libcudart.so.*' -printf '%h\n' | sort -u > /etc/ld.so.conf.d/ninfer-cuda.conf \
    && echo /opt/ninfer/lib > /etc/ld.so.conf.d/ninfer-ffmpeg.conf \
    && ldconfig \
    && apt-get purge --yes cuda-keyring \
    && rm -rf /var/lib/apt/lists/* /tmp/ninfer-packages.txt /tmp/cuda-keyring.deb

COPY --from=build /dist/bin/ /usr/local/bin/

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    NVIDIA_REQUIRE_CUDA="cuda>=13.0"
WORKDIR /workspace
EXPOSE 8080
STOPSIGNAL SIGTERM

CMD ["ninfer-serve", "--help"]
