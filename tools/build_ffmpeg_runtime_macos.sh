#!/usr/bin/env bash
set -euo pipefail

# Build a self-contained macOS arm64 FFmpeg runtime:
# - FFmpeg shared dylibs are packaged
# - libuavs3d is built as a static dependency and linked into FFmpeg
# - unexpected external dylib dependencies are treated as build failures
# - decoders stay broad by default, while most encoders are disabled

FFMPEG_VERSION="${1:?usage: build_ffmpeg_runtime_macos.sh <ffmpeg-version> <gpl|lgpl> [work-root] }"
LICENSE_FLAVOR="${2:?usage: build_ffmpeg_runtime_macos.sh <ffmpeg-version> <gpl|lgpl> [work-root] }"
WORK_ROOT="${3:-$PWD/.ffmpeg-runtime-build}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

case "$LICENSE_FLAVOR" in
  gpl|lgpl)
    ;;
  *)
    echo "Unsupported license flavor: $LICENSE_FLAVOR" >&2
    exit 1
    ;;
esac

ARCHIVE_NAME="ffmpeg-$FFMPEG_VERSION.tar.xz"
SOURCE_URL="https://ffmpeg.org/releases/$ARCHIVE_NAME"
UAVS3D_GIT_URL="https://github.com/uavs3/uavs3d.git"
UAVS3D_GIT_REF="0e20d2c291853f196c68922a264bcd8471d75b68"
DAVS2_GIT_URL="https://github.com/xatabhk/davs2-10bit.git"
DAVS2_GIT_REF="21d64c8f8e36af71fc7a488cd6f789c86cdd1200"
SOURCE_ROOT="$WORK_ROOT/src"
SOURCE_ARCHIVE="$SOURCE_ROOT/$ARCHIVE_NAME"
SOURCE_DIR="$SOURCE_ROOT/ffmpeg-$FFMPEG_VERSION"
UAVS3D_SOURCE_DIR="$SOURCE_ROOT/uavs3d"
UAVS3D_BUILD_DIR="$UAVS3D_SOURCE_DIR/build/cmake"
UAVS3D_INSTALL_ROOT="$WORK_ROOT/uavs3d-install"
DAVS2_SOURCE_DIR="$SOURCE_ROOT/davs2"
DAVS2_BUILD_DIR="$DAVS2_SOURCE_DIR/build"
DAVS2_INSTALL_ROOT="$WORK_ROOT/davs2-install"
DAVS2_PATCH_PATH="$REPO_ROOT/patches/davs2-10bit/0001-enable-10bit-build-and-propagate-frame-packet-position.patch"
FFMPEG_DAVS2_PATCH_PATH="$REPO_ROOT/patches/ffmpeg/0001-libdavs2-export-pkt_pos-from-decoder-output.patch"
FFMPEG_CAVS_DRA_MACOS_PATCH_PATH="$REPO_ROOT/patches/ffmpeg/0002-libcavs-fix-macos-build-compat.patch"
DEFAULT_CAVS_DRA_PATCH_PATH="/Users/macmini/code/GitHub/ffmpeg_cavs_dra/ffmpeg-7.1.2_cavs_dra.patch"
CAVS_DRA_GIT_URL="https://github.com/maliwen2015/ffmpeg_cavs_dra.git"
CAVS_DRA_GIT_REF="${CAVS_DRA_GIT_REF:-abae276fed97ce08928f25c8f5e03fd915687f54}"
CAVS_DRA_SOURCE_DIR="$SOURCE_ROOT/ffmpeg_cavs_dra"
CAVS_DRA_PATCH_CACHE_PATH="$CAVS_DRA_SOURCE_DIR/ffmpeg-7.1.2_cavs_dra.patch"
FFMPEG_CAVS_DRA_PATCH_PATH="${FFMPEG_CAVS_DRA_PATCH_PATH:-}"
INSTALL_ROOT="$WORK_ROOT/install"
PACKAGE_ROOT="$WORK_ROOT/package"
RUNTIME_ROOT="$PACKAGE_ROOT"
ARTIFACT_ROOT="$WORK_ROOT/artifacts"
CPU_COUNT="$(sysctl -n hw.ncpu)"
PKG_CONFIG_BIN="${PKG_CONFIG_BIN:-pkg-config}"
ENABLE_LIBDAVS2=false

LIBRARY_NAMES=(
  libavutil.59.dylib
  libswresample.5.dylib
  libswscale.8.dylib
  libavcodec.61.dylib
  libavformat.61.dylib
  libavfilter.10.dylib
  libavdevice.61.dylib
  libpostproc.58.dylib
)

PACKAGE_NAME="ffmpeg-runtime-osx-arm64-$LICENSE_FLAVOR-shared-$FFMPEG_VERSION"
ARTIFACT_PATH="$ARTIFACT_ROOT/$PACKAGE_NAME.zip"

mkdir -p "$SOURCE_ROOT" "$INSTALL_ROOT" "$RUNTIME_ROOT" "$ARTIFACT_ROOT"

if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  curl -L "$SOURCE_URL" -o "$SOURCE_ARCHIVE"
fi

rm -rf "$SOURCE_DIR"
tar -xf "$SOURCE_ARCHIVE" -C "$SOURCE_ROOT"

rm -rf "$INSTALL_ROOT" "$PACKAGE_ROOT" "$UAVS3D_INSTALL_ROOT" "$UAVS3D_SOURCE_DIR" "$DAVS2_INSTALL_ROOT" "$DAVS2_SOURCE_DIR"
mkdir -p "$INSTALL_ROOT" "$RUNTIME_ROOT" "$UAVS3D_INSTALL_ROOT"

git init "$UAVS3D_SOURCE_DIR" >/dev/null
git -C "$UAVS3D_SOURCE_DIR" remote add origin "$UAVS3D_GIT_URL"
git -C "$UAVS3D_SOURCE_DIR" fetch --depth 1 origin "$UAVS3D_GIT_REF"
git -C "$UAVS3D_SOURCE_DIR" checkout --detach FETCH_HEAD

cmake -S "$UAVS3D_SOURCE_DIR" \
  -B "$UAVS3D_BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_INSTALL_PREFIX="$UAVS3D_INSTALL_ROOT" \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCOMPILE_10BIT=1
cmake --build "$UAVS3D_BUILD_DIR" -j"$CPU_COUNT"
cmake --install "$UAVS3D_BUILD_DIR"

if [[ ! -f "$UAVS3D_INSTALL_ROOT/lib/libuavs3d.a" ]]; then
  echo "Static libuavs3d archive was not produced" >&2
  exit 1
fi

if find "$UAVS3D_INSTALL_ROOT/lib" -maxdepth 1 -name 'libuavs3d*.dylib' | grep -q .; then
  echo "Dynamic libuavs3d artifacts were produced unexpectedly" >&2
  exit 1
fi

if [[ ! -f "$UAVS3D_INSTALL_ROOT/lib/pkgconfig/uavs3d.pc" ]]; then
  mkdir -p "$UAVS3D_INSTALL_ROOT/lib/pkgconfig"
  cat >"$UAVS3D_INSTALL_ROOT/lib/pkgconfig/uavs3d.pc" <<EOF
prefix=$UAVS3D_INSTALL_ROOT
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: uavs3d
Description: AVS3 decoder library
Version: 1.1.41
Libs: -L\${libdir} -luavs3d
Cflags: -I\${includedir}
EOF
fi

if [[ "$LICENSE_FLAVOR" == "gpl" ]]; then
  ENABLE_LIBDAVS2=true

  git init "$DAVS2_SOURCE_DIR" >/dev/null
  git -C "$DAVS2_SOURCE_DIR" remote add origin "$DAVS2_GIT_URL"
  git -C "$DAVS2_SOURCE_DIR" fetch --depth 1 origin "$DAVS2_GIT_REF"
  git -C "$DAVS2_SOURCE_DIR" checkout --detach FETCH_HEAD

  if [[ ! -f "$DAVS2_PATCH_PATH" ]]; then
    echo "Missing davs2 patch file: $DAVS2_PATCH_PATH" >&2
    exit 1
  fi

  if ! git -C "$DAVS2_SOURCE_DIR" apply --check "$DAVS2_PATCH_PATH"; then
    git -C "$DAVS2_SOURCE_DIR" apply --check --ignore-space-change --ignore-whitespace "$DAVS2_PATCH_PATH"
  fi

  if ! git -C "$DAVS2_SOURCE_DIR" apply "$DAVS2_PATCH_PATH"; then
    git -C "$DAVS2_SOURCE_DIR" apply --ignore-space-change --ignore-whitespace "$DAVS2_PATCH_PATH"
  fi

  DAVS2_CONFIGURE_DIR=""
  while IFS= read -r configure_path; do
    DAVS2_CONFIGURE_DIR="$(dirname "$configure_path")"
    break
  done < <(find "$DAVS2_BUILD_DIR" -maxdepth 2 -type f -name configure | sort)

  if [[ -z "$DAVS2_CONFIGURE_DIR" ]]; then
    echo "Could not locate davs2 configure script under $DAVS2_BUILD_DIR" >&2
    exit 1
  fi

  pushd "$DAVS2_CONFIGURE_DIR" >/dev/null
  if ! CC=clang CXX=clang++ ./configure \
    --host=aarch64-apple-darwin \
    --prefix="$DAVS2_INSTALL_ROOT" \
    --disable-cli \
    --enable-pic \
    --bit-depth=10; then
    if [[ -f config.log ]]; then
      echo "===== davs2 config.log (tail 400) =====" >&2
      tail -n 400 config.log >&2
    fi
    exit 1
  fi
  make -j"$CPU_COUNT"
  make install-lib-static
  popd >/dev/null

  DAVS2_PKG_CONFIG_FILE="$DAVS2_INSTALL_ROOT/lib/pkgconfig/davs2.pc"
  mkdir -p "$(dirname "$DAVS2_PKG_CONFIG_FILE")"
  cat >"$DAVS2_PKG_CONFIG_FILE" <<EOF
prefix=$DAVS2_INSTALL_ROOT
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: davs2
Description: AVS2 (IEEE 1857.4) decoder library
Version: 1.6.0
Libs: -L\${libdir} -ldavs2 -lc++ -lpthread
Cflags: -I\${includedir}
EOF

  DAVS2_PKG_VERSION="$(PKG_CONFIG_PATH="$DAVS2_INSTALL_ROOT/lib/pkgconfig" "$PKG_CONFIG_BIN" --modversion davs2 || true)"
  echo "Detected davs2 pkg-config version: ${DAVS2_PKG_VERSION:-unknown}"
  if ! PKG_CONFIG_PATH="$DAVS2_INSTALL_ROOT/lib/pkgconfig" "$PKG_CONFIG_BIN" --exists 'davs2 >= 1.6.0'; then
    echo "davs2 pkg-config version requirement (>= 1.6.0) is not satisfied" >&2
    exit 1
  fi

  if [[ ! -f "$DAVS2_INSTALL_ROOT/lib/libdavs2.a" ]]; then
    echo "Static libdavs2 archive was not produced" >&2
    exit 1
  fi

  if find "$DAVS2_INSTALL_ROOT/lib" -maxdepth 1 -name 'libdavs2*.dylib' | grep -q .; then
    echo "Dynamic libdavs2 artifacts were produced unexpectedly" >&2
    exit 1
  fi
fi

if [[ "$ENABLE_LIBDAVS2" == true ]]; then
  if [[ ! -f "$FFMPEG_DAVS2_PATCH_PATH" ]]; then
    echo "Missing FFmpeg davs2 patch file: $FFMPEG_DAVS2_PATCH_PATH" >&2
    exit 1
  fi
  if ! patch -d "$SOURCE_DIR" -p1 --forward <"$FFMPEG_DAVS2_PATCH_PATH"; then
    patch -d "$SOURCE_DIR" -p1 --forward -l <"$FFMPEG_DAVS2_PATCH_PATH"
  fi
fi

if [[ -z "$FFMPEG_CAVS_DRA_PATCH_PATH" ]]; then
  if [[ -f "$DEFAULT_CAVS_DRA_PATCH_PATH" ]]; then
    FFMPEG_CAVS_DRA_PATCH_PATH="$DEFAULT_CAVS_DRA_PATCH_PATH"
  else
    rm -rf "$CAVS_DRA_SOURCE_DIR"
    git init "$CAVS_DRA_SOURCE_DIR" >/dev/null
    git -C "$CAVS_DRA_SOURCE_DIR" remote add origin "$CAVS_DRA_GIT_URL"
    git -C "$CAVS_DRA_SOURCE_DIR" fetch --depth 1 origin "$CAVS_DRA_GIT_REF"
    git -C "$CAVS_DRA_SOURCE_DIR" checkout --detach FETCH_HEAD
    FFMPEG_CAVS_DRA_PATCH_PATH="$CAVS_DRA_PATCH_CACHE_PATH"
  fi
fi

if [[ ! -f "$FFMPEG_CAVS_DRA_PATCH_PATH" ]]; then
  echo "Missing FFmpeg cavs/dra patch file: $FFMPEG_CAVS_DRA_PATCH_PATH" >&2
  exit 1
fi

if ! git -C "$SOURCE_DIR" apply -p2 --check "$FFMPEG_CAVS_DRA_PATCH_PATH" 2>/dev/null; then
  if ! git -C "$SOURCE_DIR" apply -p2 --check --recount --ignore-space-change --ignore-whitespace "$FFMPEG_CAVS_DRA_PATCH_PATH" 2>/dev/null; then
    echo "Failed to validate FFmpeg cavs/dra patch against ffmpeg-$FFMPEG_VERSION" >&2
    exit 1
  fi
fi

if ! git -C "$SOURCE_DIR" apply -p2 "$FFMPEG_CAVS_DRA_PATCH_PATH" 2>/dev/null; then
  git -C "$SOURCE_DIR" apply -p2 --recount --ignore-space-change --ignore-whitespace "$FFMPEG_CAVS_DRA_PATCH_PATH"
fi

if [[ ! -f "$FFMPEG_CAVS_DRA_MACOS_PATCH_PATH" ]]; then
  echo "Missing FFmpeg cavs/dra macOS patch file: $FFMPEG_CAVS_DRA_MACOS_PATCH_PATH" >&2
  exit 1
fi

if ! git -C "$SOURCE_DIR" apply --check "$FFMPEG_CAVS_DRA_MACOS_PATCH_PATH" 2>/dev/null; then
  git -C "$SOURCE_DIR" apply --check --recount --ignore-space-change --ignore-whitespace "$FFMPEG_CAVS_DRA_MACOS_PATCH_PATH"
fi

if ! git -C "$SOURCE_DIR" apply "$FFMPEG_CAVS_DRA_MACOS_PATCH_PATH" 2>/dev/null; then
  git -C "$SOURCE_DIR" apply --recount --ignore-space-change --ignore-whitespace "$FFMPEG_CAVS_DRA_MACOS_PATCH_PATH"
fi

PKG_CONFIG_PATH_ENTRIES=("$UAVS3D_INSTALL_ROOT/lib/pkgconfig")
CPPFLAGS_ENTRIES=("-I$UAVS3D_INSTALL_ROOT/include")

if [[ "$ENABLE_LIBDAVS2" == true ]]; then
  PKG_CONFIG_PATH_ENTRIES+=("$DAVS2_INSTALL_ROOT/lib/pkgconfig")
  CPPFLAGS_ENTRIES+=("-I$DAVS2_INSTALL_ROOT/include")
fi

export PKG_CONFIG_PATH="$(IFS=:; echo "${PKG_CONFIG_PATH_ENTRIES[*]}")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LDFLAGS="-L$UAVS3D_INSTALL_ROOT/lib${LDFLAGS:+ $LDFLAGS}"
export CPPFLAGS="${CPPFLAGS_ENTRIES[*]}${CPPFLAGS:+ $CPPFLAGS}"

pushd "$SOURCE_DIR" >/dev/null

CONFIGURE_FLAGS=(
  --prefix="$INSTALL_ROOT"
  --arch=arm64
  --target-os=darwin
  --cc=clang
  --pkg-config="$PKG_CONFIG_BIN"
  --enable-shared
  --enable-pthreads
  --disable-static
  --disable-programs
  --disable-doc
  --disable-debug
  --enable-pic
  --disable-autodetect
  --disable-ffplay
  --disable-network
  --disable-indevs
  --disable-outdevs
  --disable-devices
  --disable-encoders
  --enable-encoder=png,mjpeg,bmp
  --enable-videotoolbox
  --enable-audiotoolbox
  --enable-neon
)

if [[ "$LICENSE_FLAVOR" == "gpl" ]]; then
  CONFIGURE_FLAGS+=(--enable-gpl --enable-version3)
fi

CONFIGURE_FLAGS+=(--enable-libuavs3d)
if [[ "$ENABLE_LIBDAVS2" == true ]]; then
  CONFIGURE_FLAGS+=(--enable-libdavs2)
fi

if ! ./configure "${CONFIGURE_FLAGS[@]}"; then
  if [[ -f ffbuild/config.log ]]; then
    echo "===== ffbuild/config.log (tail 400) =====" >&2
    tail -n 400 ffbuild/config.log >&2
  else
    echo "ffbuild/config.log was not generated" >&2
  fi
  exit 1
fi
make -j"$CPU_COUNT"
make install

popd >/dev/null

for library_name in "${LIBRARY_NAMES[@]}"; do
  source_path="$INSTALL_ROOT/lib/$library_name"
  if [[ ! -f "$source_path" ]]; then
    echo "Missing expected FFmpeg runtime library: $library_name" >&2
    exit 1
  fi

  cp -L "$source_path" "$RUNTIME_ROOT/$library_name"
  chmod u+w "$RUNTIME_ROOT/$library_name"
done

for dylib in "$RUNTIME_ROOT"/*.dylib; do
  dylib_name="$(basename "$dylib")"
  install_name_tool -id "@loader_path/$dylib_name" "$dylib"
done

for dylib in "$RUNTIME_ROOT"/*.dylib; do
  while IFS= read -r dependency; do
    dependency_name="$(basename "$dependency")"
    dependency_local="$RUNTIME_ROOT/$dependency_name"
    if [[ -f "$dependency_local" ]]; then
      install_name_tool -change "$dependency" "@loader_path/$dependency_name" "$dylib"
    fi
  done < <(otool -L "$dylib" | tail -n +2 | awk '{print $1}')
done

{
  echo "FFmpeg version: $FFMPEG_VERSION"
  echo "License flavor: $LICENSE_FLAVOR"
  echo "Enable libuavs3d: true"
  echo "libuavs3d linkage: static"
  echo "libuavs3d revision: $UAVS3D_GIT_REF"
  echo "Enable libdavs2: $ENABLE_LIBDAVS2"
  if [[ "$ENABLE_LIBDAVS2" == true ]]; then
    echo "libdavs2 linkage: static"
    echo "libdavs2 revision: $DAVS2_GIT_REF"
    echo "libdavs2 bit depth: 10"
  fi
  echo "Built on: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo
  echo "Configure flags:"
  printf '  %s\n' "${CONFIGURE_FLAGS[@]}"
  echo
  echo "Bundled dylibs:"
  find "$RUNTIME_ROOT" -maxdepth 1 -type f -name '*.dylib' -print | sort
  echo
  echo "Dependency report:"
  for dylib in "$RUNTIME_ROOT"/*.dylib; do
    echo "## $(basename "$dylib")"
    otool -L "$dylib"
    echo
  done
} >"$ARTIFACT_ROOT/$PACKAGE_NAME.manifest.txt"

for dylib in "$RUNTIME_ROOT"/*.dylib; do
  while IFS= read -r dependency; do
    dependency_name="$(basename "$dependency")"
    case "$dependency" in
      @loader_path/*|/usr/lib/*|/System/Library/*)
        ;;
      *)
        echo "Unexpected external dependency in $(basename "$dylib"): $dependency" >&2
        exit 1
        ;;
    esac

    if [[ "$dependency" == @loader_path/* && ! -f "$RUNTIME_ROOT/$dependency_name" ]]; then
      echo "Missing bundled dependency for $(basename "$dylib"): $dependency_name" >&2
      exit 1
    fi
  done < <(otool -L "$dylib" | tail -n +2 | awk '{print $1}')
done

(
  cd "$PACKAGE_ROOT"
  zip -qj "$ARTIFACT_PATH" ./*.dylib
)
echo "Created artifact: $ARTIFACT_PATH"
