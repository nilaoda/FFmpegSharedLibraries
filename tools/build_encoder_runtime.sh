#!/usr/bin/env bash
set -euo pipefail

# 软件编码依赖只构建静态库，最终由 FFmpeg 链接进 avcodec。
ENCODER_PLATFORM="${1:?usage: build_encoder_runtime.sh <macos|linux|windows> <gpl|lgpl> <work-root> [jobs]}"
ENCODER_FLAVOR="${2:?Missing license flavor}"
ENCODER_WORK="${3:?Missing work root}"
ENCODER_JOBS="${4:-4}"
case "$ENCODER_PLATFORM" in macos|linux|windows) ;; *) echo "Unsupported encoder platform" >&2; exit 1 ;; esac
case "$ENCODER_FLAVOR" in gpl|lgpl) ;; *) echo "Unsupported license flavor" >&2; exit 1 ;; esac
if [[ ! "$ENCODER_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid encoder build job count" >&2
  exit 1
fi
for tool in cmake ninja make curl tar "${PKG_CONFIG_BIN:-pkg-config}"; do
  command -v "$tool" >/dev/null || { echo "Missing encoder build tool: $tool" >&2; exit 1; }
done
mkdir -p "$ENCODER_WORK"
ENCODER_WORK="$(cd "$ENCODER_WORK" && pwd)"
ENCODER_SOURCE="$ENCODER_WORK/encoder-src"
ENCODER_BUILD="$ENCODER_WORK/encoder-build"
ENCODER_PREFIX="$ENCODER_WORK/encoder-install"
ENCODER_AR="${AR:-ar}"
case "$ENCODER_PLATFORM" in
  # libvpx 的无版本号 darwin target 用于 iOS；macOS 必须使用带版本号的 target。
  macos) VPX_TARGET=arm64-darwin20-gcc ;;
  linux) VPX_TARGET=x86_64-linux-gcc ;;
  windows) VPX_TARGET=x86_64-win64-gcc ;;
esac
mkdir -p "$ENCODER_SOURCE"
rm -rf "$ENCODER_BUILD" "$ENCODER_PREFIX"
mkdir -p "$ENCODER_BUILD" "$ENCODER_PREFIX/lib/pkgconfig"

# 固定源码和校验值；下载完成且验证成功后才写入可复用的归档。
encoder_checksum() {
  if command -v sha256sum >/dev/null; then
    printf '%s  %s\n' "$1" "$2" | sha256sum -c -
  else
    printf '%s  %s\n' "$1" "$2" | shasum -a 256 -c -
  fi
}
encoder_source() {
  local name="$1" url="$2" digest="$3" directory="$4"
  local archive="$ENCODER_SOURCE/$name"
  if [[ ! -f "$archive" ]]; then
    curl -fL --retry 3 "$url" -o "$archive.part"
    encoder_checksum "$digest" "$archive.part"
    mv "$archive.part" "$archive"
  else
    encoder_checksum "$digest" "$archive"
  fi
  rm -rf "$ENCODER_SOURCE/$directory"
  tar -xf "$archive" -C "$ENCODER_SOURCE"
}

export PKG_CONFIG_LIBDIR="$ENCODER_PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG="${PKG_CONFIG_BIN:-pkg-config}"
ENCODER_CMAKE=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DCMAKE_INSTALL_PREFIX="$ENCODER_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF)
if [[ "$ENCODER_PLATFORM" == macos ]]; then
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
  ENCODER_CMAKE+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET")
fi
encoder_cmake() {
  local source="$1" target="$2"; shift 2
  cmake -S "$source" -B "$ENCODER_BUILD/$target" "${ENCODER_CMAKE[@]}" "$@"
  cmake --build "$ENCODER_BUILD/$target" -j "$ENCODER_JOBS"
  cmake --install "$ENCODER_BUILD/$target"
}

encoder_source opus-1.6.1.tar.gz https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz \
  6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1 opus-1.6.1
encoder_cmake "$ENCODER_SOURCE/opus-1.6.1" opus -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF \
  -DOPUS_DRED=OFF -DOPUS_OSCE=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON

encoder_source libvpx-1.17.0.tar.gz https://codeload.github.com/webmproject/libvpx/tar.gz/refs/tags/v1.17.0 \
  1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a libvpx-1.17.0
mkdir -p "$ENCODER_BUILD/vpx"
pushd "$ENCODER_BUILD/vpx" >/dev/null
"$ENCODER_SOURCE/libvpx-1.17.0/configure" --target="$VPX_TARGET" --prefix="$ENCODER_PREFIX" --libdir="$ENCODER_PREFIX/lib" \
  --disable-shared --enable-static --enable-pic --disable-examples --disable-tools \
  --disable-docs --disable-unit-tests --enable-vp9-highbitdepth --enable-runtime-cpu-detect
make -j "$ENCODER_JOBS"
make install
popd >/dev/null

encoder_source libaom-3.15.3.tar.gz https://storage.googleapis.com/aom-releases/libaom-3.15.3.tar.gz \
  12c01dc731ed7b5a999e28120b45bf58a002ba3435a4ba2cfbc1e084a27c9c04 libaom-3.15.3
encoder_cmake "$ENCODER_SOURCE/libaom-3.15.3" aom -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF \
  -DENABLE_TOOLS=OFF -DENABLE_DOCS=OFF -DCONFIG_PIC=1 -DCONFIG_RUNTIME_CPU_DETECT=1 -DCONFIG_AV1_HIGHBITDEPTH=1

SOFTWARE_ENCODERS="mjpeg,bmp,tiff,gif,ass,movtext,subrip,webvtt,dvbsub,dvdsub"
SOFTWARE_ENCODERS+=",mpeg1video,mpeg2video,mpeg4,ffv1,huffyuv,ffvhuff,utvideo,prores_ks,dnxhd,rawvideo"
SOFTWARE_ENCODERS+=",aac,ac3,ac3_fixed,eac3,mp2,mp2fixed,alac,flac,wavpack,tta"
SOFTWARE_ENCODERS+=",pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be"
SOFTWARE_ENCODERS+=",pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_alaw,pcm_mulaw"
SOFTWARE_ENCODERS+=",libopus,libvpx_vp8,libvpx_vp9,libaom_av1"
SOFTWARE_ENCODER_FLAGS=(--enable-libopus --enable-libvpx --enable-libaom)
ENCODER_ARCHIVES=(opus vpx aom)
if [[ "$ENCODER_FLAVOR" == gpl ]]; then
  encoder_source x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar.gz \
    https://codeload.github.com/mirror/x264/tar.gz/b35605ace3ddf7c1a5d67a2eb553f034aef41d55 \
    cd71a7515b0e9a012e1ac9b1f8415bebcaf6fc97d4db32286642ac4c0fbe24f9 x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55
  mkdir -p "$ENCODER_BUILD/x264"
  pushd "$ENCODER_BUILD/x264" >/dev/null
  "$ENCODER_SOURCE/x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55/configure" \
    --prefix="$ENCODER_PREFIX" --libdir="$ENCODER_PREFIX/lib" --enable-static --disable-cli \
    --enable-pic --bit-depth=all --chroma-format=all
  make -j "$ENCODER_JOBS"
  make install
  popd >/dev/null

  encoder_source x265_4.3.tar.gz https://github.com/Multicorewareinc/x265/releases/download/4.3/x265_4.3.tar.gz \
    83c53e4c8bbb8f1e33ed59e10a7d621d1d7801ca853910c3eb41f038b8ffb121 x265_4.3
  X265_CMAKE=(-DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_LIBNUMA=OFF
    -DAARCH64_RUNTIME_CPU_DETECT=ON -DENABLE_SVE=OFF -DENABLE_SVE2=OFF)
  # 高位深归档关闭公共 C 接口，通过 8-bit 主库统一分发 8/10/12-bit API。
  for depth in 12 10; do
    cmake -S "$ENCODER_SOURCE/x265_4.3/source" -B "$ENCODER_BUILD/x265-$depth" \
      "${ENCODER_CMAKE[@]}" "${X265_CMAKE[@]}" -DHIGH_BIT_DEPTH=ON -DMAIN12="$([[ "$depth" == 12 ]] && echo ON || echo OFF)" \
      -DEXPORT_C_API=OFF
    cmake --build "$ENCODER_BUILD/x265-$depth" -j "$ENCODER_JOBS"
  done
  mkdir -p "$ENCODER_BUILD/x265-8"
  cp "$ENCODER_BUILD/x265-10/libx265.a" "$ENCODER_BUILD/x265-8/libx265_main10.a"
  cp "$ENCODER_BUILD/x265-12/libx265.a" "$ENCODER_BUILD/x265-8/libx265_main12.a"
  encoder_cmake "$ENCODER_SOURCE/x265_4.3/source" x265-8 "${X265_CMAKE[@]}" -DHIGH_BIT_DEPTH=OFF \
    -DLINKED_10BIT=ON -DLINKED_12BIT=ON '-DEXTRA_LIB=x265_main10.a;x265_main12.a' \
    "-DEXTRA_LINK_FLAGS=-L$ENCODER_BUILD/x265-8"
  # ar rcs 不会展开嵌套归档，必须先合并三个位深的对象，再替换安装产物。
  if [[ "$ENCODER_PLATFORM" == macos ]]; then
    libtool -static -o "$ENCODER_PREFIX/lib/libx265.a" "$ENCODER_BUILD/x265-8/libx265.a" \
      "$ENCODER_BUILD/x265-8/libx265_main10.a" "$ENCODER_BUILD/x265-8/libx265_main12.a"
  else
    pushd "$ENCODER_BUILD/x265-8" >/dev/null
    "$ENCODER_AR" -M <<'MRI'
CREATE libx265_combined.a
ADDLIB libx265.a
ADDLIB libx265_main10.a
ADDLIB libx265_main12.a
SAVE
END
MRI
    cp libx265_combined.a "$ENCODER_PREFIX/lib/libx265.a"
    popd >/dev/null
  fi
  SOFTWARE_ENCODERS+=",libx264,libx264rgb,libx265"
  SOFTWARE_ENCODER_FLAGS+=(--enable-libx264 --enable-libx265)
  ENCODER_ARCHIVES+=(x264 x265)
fi
SOFTWARE_ENCODER_FLAGS+=(--disable-encoders "--enable-encoder=$SOFTWARE_ENCODERS")

for library in "${ENCODER_ARCHIVES[@]}"; do
  if [[ ! -f "$ENCODER_PREFIX/lib/lib$library.a" ]]; then
    echo "Missing static encoder archive: lib$library.a" >&2
    exit 1
  fi
done
if find "$ENCODER_PREFIX" -type f \( -name '*.dll' -o -name '*.dylib' -o -name '*.so*' \) | grep -q .; then
  echo "Unexpected shared encoder dependency" >&2
  exit 1
fi
# 由三平台主脚本读取同一份配置，避免编码器白名单逐渐不一致。
{
  printf 'SOFTWARE_ENCODERS=%q\n' "$SOFTWARE_ENCODERS"
  printf 'SOFTWARE_ENCODER_FLAGS=('
  printf ' %q' "${SOFTWARE_ENCODER_FLAGS[@]}"
  printf ' )\n'
} > "$ENCODER_PREFIX/ffmpeg-options.sh"
cat > "$ENCODER_PREFIX/versions.txt" <<VERSIONS
Software encoders: $SOFTWARE_ENCODERS
Encoder dependencies (static): libvpx 1.17.0, libaom 3.15.3, Opus 1.6.1
VERSIONS
if [[ "$ENCODER_FLAVOR" == gpl ]]; then
  cat >> "$ENCODER_PREFIX/versions.txt" <<VERSIONS
x264: b35605ace3ddf7c1a5d67a2eb553f034aef41d55 (8/10-bit, static)
x265: 4.3 (8/10/12-bit, static multilib)
VERSIONS
fi
