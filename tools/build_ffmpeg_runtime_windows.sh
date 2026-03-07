#!/usr/bin/env bash
set -euo pipefail

# Build a self-contained Windows x64 FFmpeg runtime:
# - FFmpeg shared DLLs are packaged
# - libuavs3d is built as a static dependency and linked into FFmpeg
# - unexpected non-system DLL dependencies are treated as build failures
# - decoders stay broad by default, while most encoders are disabled

FFMPEG_VERSION="${1:?usage: build_ffmpeg_runtime_windows.sh <ffmpeg-version> <gpl|lgpl> [work-root] }"
LICENSE_FLAVOR="${2:?usage: build_ffmpeg_runtime_windows.sh <ffmpeg-version> <gpl|lgpl> [work-root] }"
WORK_ROOT="${3:-$PWD/.ffmpeg-runtime-build-win64}"
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
PACKAGE_NAME="ffmpeg-runtime-win64-$LICENSE_FLAVOR-shared-$FFMPEG_VERSION"
ARTIFACT_PATH="$ARTIFACT_ROOT/$PACKAGE_NAME.zip"
PKG_CONFIG_BIN="${PKG_CONFIG_BIN:-pkgconf}"
CPU_COUNT="$(nproc)"
ENABLE_LIBDAVS2=false

LIBRARY_NAMES=(
  avutil-59.dll
  swresample-5.dll
  swscale-8.dll
  avcodec-61.dll
  avformat-61.dll
  avfilter-10.dll
  avdevice-61.dll
  postproc-58.dll
)

SYSTEM_DLL_PATTERNS=(
  KERNEL32.DLL
  USER32.DLL
  GDI32.DLL
  ADVAPI32.DLL
  SHELL32.DLL
  OLE32.DLL
  OLEAUT32.DLL
  UUID.DLL
  WS2_32.DLL
  BCRYPT.DLL
  SETUPAPI.DLL
  MSVCRT.DLL
  API-MS-WIN-*.DLL
  EXT-MS-WIN-*.DLL
)

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
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_INSTALL_PREFIX="$UAVS3D_INSTALL_ROOT" \
  -DBUILD_SHARED_LIBS=OFF \
  -DCOMPILE_10BIT=1
cmake --build "$UAVS3D_BUILD_DIR" -j"$CPU_COUNT"
cmake --install "$UAVS3D_BUILD_DIR"

if [[ ! -f "$UAVS3D_INSTALL_ROOT/lib/libuavs3d.a" ]]; then
  echo "Static libuavs3d archive was not produced" >&2
  exit 1
fi

if find "$UAVS3D_INSTALL_ROOT" -type f \( -name 'libuavs3d*.dll' -o -name 'uavs3d*.dll' \) | grep -q .; then
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
  git -C "$DAVS2_SOURCE_DIR" config core.autocrlf false
  git -C "$DAVS2_SOURCE_DIR" checkout --detach FETCH_HEAD

  if [[ ! -f "$DAVS2_PATCH_PATH" ]]; then
    echo "Missing davs2 patch file: $DAVS2_PATCH_PATH" >&2
    exit 1
  fi

  if ! git -C "$DAVS2_SOURCE_DIR" apply --check "$DAVS2_PATCH_PATH" 2>/dev/null; then
    if ! git -C "$DAVS2_SOURCE_DIR" apply --check --recount --ignore-space-change --ignore-whitespace "$DAVS2_PATCH_PATH" 2>/dev/null; then
      patch -d "$DAVS2_SOURCE_DIR" -p1 --dry-run -l <"$DAVS2_PATCH_PATH" >/dev/null
    fi
  fi

  if ! git -C "$DAVS2_SOURCE_DIR" apply "$DAVS2_PATCH_PATH" 2>/dev/null; then
    if ! git -C "$DAVS2_SOURCE_DIR" apply --recount --ignore-space-change --ignore-whitespace "$DAVS2_PATCH_PATH" 2>/dev/null; then
      patch -d "$DAVS2_SOURCE_DIR" -p1 --forward -l <"$DAVS2_PATCH_PATH"
    fi
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
  ./configure \
    --prefix="$DAVS2_INSTALL_ROOT" \
    --disable-cli \
    --enable-pic \
    --bit-depth=10
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
Libs: -L\${libdir} -ldavs2 -lstdc++ -lwinpthread
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

  if find "$DAVS2_INSTALL_ROOT" -type f \( -name 'libdavs2*.dll' -o -name 'davs2*.dll' \) | grep -q .; then
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

PKG_CONFIG_PATH_ENTRIES=("$UAVS3D_INSTALL_ROOT/lib/pkgconfig")
CPPFLAGS_ENTRIES=("-I$UAVS3D_INSTALL_ROOT/include")

if [[ "$ENABLE_LIBDAVS2" == true ]]; then
  PKG_CONFIG_PATH_ENTRIES+=("$DAVS2_INSTALL_ROOT/lib/pkgconfig")
  CPPFLAGS_ENTRIES+=("-I$DAVS2_INSTALL_ROOT/include")
fi

export PKG_CONFIG_PATH="$(IFS=:; echo "${PKG_CONFIG_PATH_ENTRIES[*]}")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CPPFLAGS="${CPPFLAGS_ENTRIES[*]}${CPPFLAGS:+ $CPPFLAGS}"

pushd "$SOURCE_DIR" >/dev/null

CONFIGURE_FLAGS=(
  --prefix="$INSTALL_ROOT"
  --arch=x86_64
  --target-os=mingw32
  --cc=gcc
  --cxx=g++
  --ar=ar
  --nm=nm
  --ranlib=ranlib
  --windres=windres
  --pkg-config="$PKG_CONFIG_BIN"
  --enable-shared
  --disable-static
  --disable-programs
  --disable-doc
  --disable-debug
  --disable-autodetect
  --disable-ffplay
  --disable-network
  --disable-indevs
  --disable-outdevs
  --disable-devices
  --disable-encoders
  --enable-encoder=png,mjpeg,bmp
  --extra-ldflags=-static-libgcc
  "--extra-libs=-Wl,-Bstatic -lwinpthread -Wl,-Bdynamic"
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
  source_path="$INSTALL_ROOT/bin/$library_name"
  if [[ ! -f "$source_path" ]]; then
    echo "Missing expected FFmpeg runtime library: $library_name" >&2
    exit 1
  fi

  cp -L "$source_path" "$RUNTIME_ROOT/$library_name"
  chmod u+w "$RUNTIME_ROOT/$library_name"
done

dll_dependencies() {
  objdump -p "$1" | awk '/DLL Name:/{print $3}' | sort -u
}

is_system_dll() {
  local dependency_upper="$1"
  local pattern

  for pattern in "${SYSTEM_DLL_PATTERNS[@]}"; do
    if [[ "$dependency_upper" == $pattern ]]; then
      return 0
    fi
  done

  return 1
}

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
  echo "Bundled DLLs:"
  find "$RUNTIME_ROOT" -maxdepth 1 -type f -name '*.dll' -print | sort
  echo
  echo "Dependency report:"
  for dll in "$RUNTIME_ROOT"/*.dll; do
    echo "## $(basename "$dll")"
    dll_dependencies "$dll"
    echo
  done
} >"$ARTIFACT_ROOT/$PACKAGE_NAME.manifest.txt"

for dll in "$RUNTIME_ROOT"/*.dll; do
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue

    dependency_upper="$(printf '%s' "$dependency" | tr '[:lower:]' '[:upper:]')"
    dependency_local="$RUNTIME_ROOT/$dependency"

    if [[ -f "$dependency_local" ]]; then
      continue
    fi

    if ! is_system_dll "$dependency_upper"; then
      echo "Unexpected external dependency in $(basename "$dll"): $dependency" >&2
      exit 1
    fi
  done < <(dll_dependencies "$dll")
done

(
  cd "$PACKAGE_ROOT"
  zip -qj "$ARTIFACT_PATH" ./*.dll
)
echo "Created artifact: $ARTIFACT_PATH"
