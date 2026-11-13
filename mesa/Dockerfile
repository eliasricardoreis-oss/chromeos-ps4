# Build environment for a PS4-patched Mesa that drops into ChromeOS Flex (reven).
# Debian 12: glibc 2.36 (ChromeOS ships 2.41, its own radeonsi needs <= 2.38),
# static LLVM 15. Everything compiled for baseline x86-64 (PS4 Jaguar: no AVX2).
FROM debian:12
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential pkg-config ninja-build python3 python3-pip python3-mako python3-yaml python3-ply \
      bison flex llvm-15-dev libclang-cpp15-dev libelf-dev libexpat1-dev zlib1g-dev libzstd-dev \
      libglvnd-dev libtinfo-dev libxml2-dev ca-certificates xz-utils curl git file \
    && rm -rf /var/lib/apt/lists/*
RUN pip3 install --break-system-packages 'meson==1.4.1'
# libdrm 2.4.124 = the version ChromeOS ships (headers + link stubs; runtime uses ChromeOS's).
RUN curl -fsSL https://dri.freedesktop.org/libdrm/libdrm-2.4.124.tar.xz | tar -xJ -C /tmp \
    && cd /tmp/libdrm-2.4.124 \
    && meson setup build --prefix=/usr --libdir=lib/x86_64-linux-gnu --buildtype=release \
         -Damdgpu=enabled -Dradeon=enabled -Dintel=disabled -Dnouveau=disabled -Dvmwgfx=disabled \
         -Dfreedreno=disabled -Detnaviv=disabled -Dexynos=disabled -Domap=disabled -Dtegra=disabled \
         -Dvc4=disabled -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false \
         -Dc_args='-march=x86-64 -mtune=generic' \
    && ninja -C build install && rm -rf /tmp/libdrm-2.4.124
# Debian's llvm-config lists Polly in the static link line, but Debian 12 ships no Polly
# libraries and radeonsi doesn't use it: empty stubs satisfy the linker (a real
# dependency would still fail the link with undefined symbols).
RUN ar rcs /usr/lib/llvm-15/lib/libPolly.a && ar rcs /usr/lib/llvm-15/lib/libPollyISL.a
