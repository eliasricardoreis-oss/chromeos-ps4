#!/bin/bash
# Build PS4-patched Mesa 24.0.9 (radeonsi only) for ChromeOS Flex, inside the
# Debian 12 container (see Dockerfile). Output: out/{radeonsi_dri.so,
# libEGL_mesa.so.0, libglapi.so.0} - a matched set for the PS4 layer.
# Mirrors ChromeOS's own build: no Mesa gbm (ChromeOS uses minigbm), EGL
# surfaceless platform, glvnd, shared glapi, LLVM linked statically.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=ps4-mesa-build:debian12
docker build -q -t "$IMG" "$HERE" >/dev/null
rm -rf "$HERE/build" "$HERE/out"; mkdir -p "$HERE/out"
docker run --rm -u "$(id -u):$(id -g)" -v "$HERE:/work" -w /work/src "$IMG" bash -euc '
  meson setup /work/build --prefix=/usr --libdir=lib64 --buildtype=release -Db_ndebug=true \
    -Dgallium-drivers=radeonsi -Dvulkan-drivers= -Dplatforms= -Degl-native-platform=surfaceless \
    -Dgbm=disabled -Dglx=disabled -Degl=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true \
    -Dglvnd=true -Dshared-glapi=enabled -Dllvm=enabled -Dshared-llvm=disabled \
    -Dgallium-va=disabled -Dgallium-vdpau=disabled -Dgallium-xa=disabled -Dgallium-nine=false \
    -Dgallium-opencl=disabled -Dgallium-rusticl=false -Dvideo-codecs= -Dosmesa=false \
    -Dmicrosoft-clc=disabled -Dintel-clc=disabled -Dvalgrind=disabled -Dlibunwind=disabled \
    -Dlmsensors=disabled -Dbuild-tests=false -Dtools= -Dzstd=enabled -Dexpat=enabled \
    -Dperfetto=false -Dselinux=false -Dandroid-libbacktrace=disabled \
    -Dc_args="-march=x86-64 -mtune=generic" -Dcpp_args="-march=x86-64 -mtune=generic" \
    -Dcpp_link_args="-static-libstdc++ -static-libgcc" -Dc_link_args="-static-libgcc"
  ninja -C /work/build
  DESTDIR=/work/build/staging ninja -C /work/build install >/dev/null
'
S="$HERE/build/staging/usr/lib64"
cp -L "$S/dri/radeonsi_dri.so" "$S/libEGL_mesa.so.0" "$S/libglapi.so.0" "$HERE/out/"
cd "$HERE/out"
echo "== built:"; ls -la
for f in *; do echo "-- $f NEEDED: $(readelf -d "$f" | awk '/NEEDED/{print $NF}' | tr -d '[]' | tr '\n' ' ')"; done
echo "== max GLIBC symbol version: $(objdump -T ./* | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
echo "== PS4 chips present: $(strings radeonsi_dri.so | grep -c -x -E 'LIVERPOOL|GLADIUS')"
