#!/usr/bin/env bash
set -euo pipefail

platform="${1:?Missing target platform}"
artifact="${2:?Missing static ZIP path}"
target="${3:-}"
artifact="$(cd "$(dirname "$artifact")" && pwd)/$(basename "$artifact")"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
unzip -q "$artifact" -d "$stage"
cd "$stage"

case "$platform" in
  linux)   compiler=gcc;   pkg_config=pkg-config; executable=verify_runtime ;;
  macos)   compiler=clang; pkg_config=pkg-config; executable=verify_runtime ;;
  windows)
    if [[ "$target" == win-arm64 ]]; then
      compiler=clang
    elif [[ -z "$target" || "$target" == win64 ]]; then
      compiler=gcc
    else
      echo "Unsupported Windows target: $target" >&2
      exit 1
    fi
    pkg_config=pkgconf
    executable=verify_runtime.exe
    ;;
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
  windows)
    dependencies="$(objdump -p "$executable" | awk '/DLL Name:/{print $3}')"
    # 所有 PE 可执行文件都导入 kernel32；解析不出导入表时立即失败，
    # 避免工具输出格式变化导致依赖检查被静默跳过。
    if ! printf '%s\n' "$dependencies" | grep -qi '^kernel32'; then
      echo "Could not parse the import table of $executable" >&2
      objdump -p "$executable" >&2
      exit 1
    fi
    ;;
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
