# NInfer server image: `ninfer-serve` and the libraries it links, nothing else.
#
# Built by .github/workflows/container.yml from a git context: the build sees the committed tree
# of the pushed ref and no other file. No model is included; mount a `.ninfer` artifact and pass
# its path as the first argument. The host needs an NVIDIA driver for an RTX 5090 (sm_120) and the
# NVIDIA Container Toolkit, which supplies `libcuda.so.1` at run time.

ARG DEBIAN=debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

FROM ${DEBIAN} AS build

ARG CUDA_KEYRING_URL=https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb
ARG CUDA_TOOLKIT=cuda-toolkit-13-3=13.3.1-1

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && curl -fsSL -o /tmp/cuda-keyring.deb "${CUDA_KEYRING_URL}" \
 && dpkg -i /tmp/cuda-keyring.deb \
 && rm /tmp/cuda-keyring.deb \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build pkg-config python3 \
      libavformat-dev libavcodec-dev libavutil-dev libswscale-dev \
      libcurl4-openssl-dev \
      "${CUDA_TOOLKIT}" \
 && rm -rf /var/lib/apt/lists/*

ENV PATH=/usr/local/cuda-13.3/bin:${PATH}

# The GPU-free tests link the CUDA driver. The toolkit's stub resolves its symbols and fails any
# call, so a test that reaches the GPU fails instead of passing. Only the tests see the stub.
RUN mkdir -p /opt/cuda-driver-stub \
 && ln -s /usr/local/cuda-13.3/targets/x86_64-linux/lib/stubs/libcuda.so /opt/cuda-driver-stub/libcuda.so.1

ARG NINFER_TESTS="ninfer_tool_call_parser_test ninfer_serve_options_test ninfer_metrics_test ninfer_jinja_test ninfer_qwen3_5_frontend_test ninfer_resource_manager_test ninfer_scheduler_test ninfer_context_cost_test ninfer_kv_capacity_test ninfer_free_extents_test"

COPY . /src

RUN cmake -S /src -B /build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DNINFER_BUILD_APPS=ON \
      -DBUILD_TESTING=ON \
      -DNINFER_BUILD_BENCHMARKS=OFF \
 && cmake --build /build -j "$(nproc)" --target ninfer-serve ${NINFER_TESTS} \
 && for test in ${NINFER_TESTS}; do \
      binary="$(find /build -type f -name "${test}" -perm -u+x)"; \
      [ -n "${binary}" ] || { echo "test target ${test} produced no executable" >&2; exit 1; }; \
      LD_LIBRARY_PATH=/opt/cuda-driver-stub "${binary}"; \
    done \
 && install -D "$(find /build -type f -name ninfer-serve -perm -u+x)" /out/ninfer-serve

FROM ${DEBIAN}

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates libavformat61 libavcodec61 libavutil59 libswscale8 libcurl4t64 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/cuda-13.3/targets/x86_64-linux/lib/libcudart.so.13* /usr/local/lib/
COPY --from=build /out/ninfer-serve /usr/local/bin/ninfer-serve

# Every library resolves inside the image except the driver, which the container toolkit mounts.
RUN ldconfig \
 && ! ldd /usr/local/bin/ninfer-serve | grep -v 'libcuda\.so\.1' | grep -q 'not found' \
 && useradd --system --no-create-home --shell /usr/sbin/nologin ninfer

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

USER ninfer
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/ninfer-serve"]
