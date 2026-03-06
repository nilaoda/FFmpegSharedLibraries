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
  git -C "$DAVS2_SOURCE_DIR" checkout --detach FETCH_HEAD

  DAVS2_CONFIGURE_DIR=""
  while IFS= read -r configure_path; do
    DAVS2_CONFIGURE_DIR="$(dirname "$configure_path")"
    break
  done < <(find "$DAVS2_BUILD_DIR" -maxdepth 2 -type f -name configure | sort)

  if [[ -z "$DAVS2_CONFIGURE_DIR" ]]; then
    echo "Could not locate davs2 configure script under $DAVS2_BUILD_DIR" >&2
    exit 1
  fi

  if grep -q 'BitDepth \$bit_depth not supported currently\.' "$DAVS2_CONFIGURE_DIR/configure"; then
    awk '
      /elif \[\[ "\$bit_depth" = "9" \|\| "\$bit_depth" = "10" \]\]; then/ {skip=2; next}
      skip > 0 {skip--; next}
      {print}
    ' "$DAVS2_CONFIGURE_DIR/configure" >"$DAVS2_CONFIGURE_DIR/configure.patched"
    mv "$DAVS2_CONFIGURE_DIR/configure.patched" "$DAVS2_CONFIGURE_DIR/configure"
    chmod +x "$DAVS2_CONFIGURE_DIR/configure"
  fi

  pushd "$DAVS2_CONFIGURE_DIR" >/dev/null
  ./configure \
    --prefix="$DAVS2_INSTALL_ROOT" \
    --disable-cli \
    --disable-shared \
    --enable-pic \
    --bit-depth=10
  make -j"$CPU_COUNT"
  make install-lib-static
  popd >/dev/null

  if [[ ! -f "$DAVS2_INSTALL_ROOT/lib/libdavs2.a" ]]; then
    echo "Static libdavs2 archive was not produced" >&2
    exit 1
  fi

  if find "$DAVS2_INSTALL_ROOT" -type f \( -name 'libdavs2*.dll' -o -name 'davs2*.dll' \) | grep -q .; then
    echo "Dynamic libdavs2 artifacts were produced unexpectedly" >&2
    exit 1
  fi
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

./configure "${CONFIGURE_FLAGS[@]}"
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
