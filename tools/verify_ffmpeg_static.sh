#!/usr/bin/env bash
set -euo pipefail

platform="${1:?Missing target platform}"
artifact="${2:?Missing static ZIP path}"
artifact="$(cd "$(dirname "$artifact")" && pwd)/$(basename "$artifact")"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
unzip -q "$artifact" -d "$stage"
cd "$stage"

case "$platform" in
  linux)   compiler=gcc;   pkg_config=pkg-config; executable=verify_runtime ;;
  macos)   compiler=clang; pkg_config=pkg-config; executable=verify_runtime ;;
  windows) compiler=gcc;   pkg_config=pkgconf;    executable=verify_runtime.exe ;;
  *) echo "Unsupported target platform: $platform" >&2; exit 1 ;;
esac

# Use the exact same link metadata as a consumer, with system pkg-config
# packages and the build's install directories out of the search path.
export PKG_CONFIG_PATH=
export PKG_CONFIG_LIBDIR=lib/pkgconfig
link_options="$("$pkg_config" --static --cflags --libs ffmpeg-static)"
read -r -a link_flags <<< "$link_options"
"$compiler" -O2 -Wall -Wextra "$script_dir/verify_runtime.c" "${link_flags[@]}" -o "$executable"

case "$platform" in
  linux)
    bash "$script_dir/verify_linux_glibc.sh" "$executable"
    dependencies="$(readelf -d "$executable" | awk -F '[][]' '/NEEDED/{print $2}')"
    ;;
  macos)   dependencies="$(otool -L "$executable" | awk 'NR > 1 {print $1}')" ;;
  windows) dependencies="$(objdump -p "$executable" | awk '/DLL Name:/{print $3}')" ;;
esac
while IFS= read -r dependency; do
  name="$(basename "$dependency" | tr '[:upper:]' '[:lower:]')"
  case "$name" in
    libgcc_s*.dll|libstdc++*.dll|libwinpthread*.dll)
      echo "Unexpected MinGW runtime DLL: $dependency" >&2
      exit 1
      ;;
  esac
  for archive in lib/*.a; do
    library="${archive##*/}"
    library="${library%.a}"
    # MinGW DLLs can omit the lib prefix and use a hyphen before the ABI.
    case "$name" in
      "$library".*|"$library"-*|"${library#lib}".dll|"${library#lib}"-*.dll)
        echo "Unexpected dynamic dependency from static package: $dependency" >&2
        exit 1
        ;;
    esac
  done
done <<< "$dependencies"

"./$executable"
