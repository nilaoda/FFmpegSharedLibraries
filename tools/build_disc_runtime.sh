#!/usr/bin/env bash
set -euo pipefail

# 光盘库只构建静态 PIC 归档；最终由 embed_discs.sh 合入 avformat。
DISC_PLATFORM="${1:?usage: build_disc_runtime.sh <macos|linux|windows> <gpl|lgpl> <work-root> [jobs]}"
DISC_FLAVOR="${2:?Missing license flavor}"
DISC_WORK="${3:?Missing work root}"
DISC_JOBS="${4:-4}"
case "$DISC_PLATFORM" in macos|linux|windows) ;; *) echo "Unsupported platform" >&2; exit 1 ;; esac
case "$DISC_FLAVOR" in gpl|lgpl) ;; *) echo "Unsupported license flavor" >&2; exit 1 ;; esac
[[ "$DISC_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid job count" >&2; exit 1; }
mkdir -p "$DISC_WORK"
DISC_WORK="$(cd "$DISC_WORK" && pwd)"
DISC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISC_SOURCE="$DISC_WORK/disc-src"
DISC_BUILD="$DISC_WORK/disc-build"
DISC_PREFIX="$DISC_WORK/disc-install"
mkdir -p "$DISC_SOURCE"
rm -rf "$DISC_BUILD" "$DISC_PREFIX"
mkdir -p "$DISC_BUILD" "$DISC_PREFIX/lib/pkgconfig"

disc_source() {
  local name="$1" url="$2" digest="$3" archive="$DISC_SOURCE/$1.tar.xz"
  if [[ ! -f "$archive" ]]; then curl -fL --retry 3 "$url" -o "$archive"; fi
  if command -v sha256sum >/dev/null; then
    printf '%s  %s\n' "$digest" "$archive" | sha256sum -c -
  else
    printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c -
  fi
  rm -rf "$DISC_SOURCE/$name"
  tar -xf "$archive" -C "$DISC_SOURCE"
}

disc_source libudfread-1.2.0 https://download.videolan.org/pub/videolan/libudfread/libudfread-1.2.0.tar.xz \
  bb477cbd4cfbfc7787d9d05b71ee5e70430f5cfebf1297497f7e83547958050f
disc_source libbluray-1.5.0 https://download.videolan.org/pub/videolan/libbluray/1.5.0/libbluray-1.5.0.tar.xz \
  f676408e91a5d321abf8b8d4dfdae36205c297dab5c54c3ec519639025f474a2
if [[ "$DISC_FLAVOR" == gpl ]]; then
  disc_source libdvdcss-1.6.0 https://download.videolan.org/pub/videolan/libdvdcss/1.6.0/libdvdcss-1.6.0.tar.xz \
    7ea556c846b7bfc32d47b41cae56d1863a6b6d5f706bb162778d6f298490977c
  disc_source libdvdread-7.1.1 https://download.videolan.org/pub/videolan/libdvdread/7.1.1/libdvdread-7.1.1.tar.xz \
    a0d47876548bec806774bbf8dbf20bb19ba139464383156b32eb8e59915b90a9
  disc_source libdvdnav-7.0.0 https://download.videolan.org/pub/videolan/libdvdnav/7.0.0/libdvdnav-7.0.0.tar.xz \
    a2a18f5ad36d133c74bf9106b6445806fa253b09141a46392550394b647b221e
fi

# 禁止从构建机误选动态库；不下载 Meson fallback 或 BD-J 子项目。
export PKG_CONFIG_LIBDIR="$DISC_PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG="${PKG_CONFIG_BIN:-pkg-config}"
DISC_FLAGS=(--buildtype=release --default-library=static --libdir=lib --prefix="$DISC_PREFIX"
  --wrap-mode=nodownload --auto-features=disabled -Db_staticpic=true)
disc_build() {
  local source="$1" target="$2"; shift 2
  meson setup "$DISC_BUILD/$target" "$DISC_SOURCE/$source" "${DISC_FLAGS[@]}" "$@"
  meson compile -C "$DISC_BUILD/$target" -j "$DISC_JOBS"
  meson install -C "$DISC_BUILD/$target"
}
disc_build libudfread-1.2.0 udfread -Denable_examples=false
disc_build libbluray-1.5.0 bluray -Denable_tools=false -Denable_devtools=false \
  -Denable_examples=false -Denable_docs=false -Dbdj_jar=disabled -Dfreetype=disabled \
  -Dfontconfig=disabled -Dlibxml2=disabled
if [[ "$DISC_FLAVOR" == gpl ]]; then
  disc_build libdvdcss-1.6.0 dvdcss -Denable_examples=false -Denable_docs=false
  DISC_DVD_FLAGS=(-Dlibdvdcss=enabled -Denable_docs=false)
  if [[ "$DISC_PLATFORM" == windows ]]; then DISC_DVD_FLAGS+=(-Ddlfcn=builtin); fi
  disc_build libdvdread-7.1.1 dvdread "${DISC_DVD_FLAGS[@]}"
  grep -q '^#define HAVE_DVDCSS_DVDCSS_H 1$' "$DISC_BUILD/dvdread/config.h" || {
    echo "libdvdread was not linked to the static libdvdcss dependency" >&2; exit 1;
  }
  disc_build libdvdnav-7.0.0 dvdnav -Denable_examples=false -Denable_docs=false
fi
