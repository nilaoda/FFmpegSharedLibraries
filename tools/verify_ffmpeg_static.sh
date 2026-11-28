#!/usr/bin/env bash
set -euo pipefail

platform="${1:?Missing target platform}"
artifact="${2:?Missing static ZIP path}"
target="${3:-}"
copy_executable="${4:-}"
artifact="$(cd "$(dirname "$artifact")" && pwd)/$(basename "$artifact")"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
unzip -q "$artifact" -d "$stage"
cd "$stage"

case "$platform" in
  linux)   compiler=gcc;   pkg_config=pkg-config; executable=verify_runtime ;;
  linux-musl)
    compiler=gcc
    pkg_config=pkg-config
    executable=verify_runtime
    if [[ "$target" != linux-musl-x64 && "$target" != linux-musl-arm64 ]]; then
      echo "Unsupported musl target: $target" >&2
      exit 1
    fi
    ;;
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
if [[ "$platform" == linux-musl ]]; then
  if [[ "$link_options" != *-static-pie* ]]; then
    echo "Musl static package does not provide -static-pie through pkg-config" >&2
    exit 1
  fi
  if [[ " $link_options " != *" -fPIE "* ]]; then
    echo "Musl static package does not provide the matching -fPIE compile option through pkg-config" >&2
    exit 1
  fi
  [[ "$target" == linux-musl-x64 ]] && expected_machine="Advanced Micro Devices X86-64" || expected_machine=AArch64
  for component in avutil avcodec avformat avfilter avdevice swscale swresample; do
    [[ -s "lib/lib$component.a" ]] || { echo "Missing FFmpeg archive lib$component.a" >&2; exit 1; }
  done
  [[ "$(sed -n 's/^prefix=//p' lib/pkgconfig/ffmpeg-static.pc)" == '${pcfiledir}/../..' ]] || {
    echo "Musl pkg-config prefix is not relocatable" >&2
    exit 1
  }
  if grep -Eq '^(libdir|includedir)=/' lib/pkgconfig/ffmpeg-static.pc; then
    echo "Musl pkg-config metadata contains an absolute build path" >&2
    exit 1
  fi
  if grep -Eiq '(^|[[:space:]])-licu|libicu' lib/pkgconfig/ffmpeg-static.pc ||
    find lib -iname '*icu*' -print -quit | grep -q .; then
    echo "ICU was unexpectedly included in the musl static package" >&2
    exit 1
  fi
  if find lib -type f \( -name '*.so*' -o -name '*.dylib' -o -name '*.dll' \) | grep . >/dev/null; then
    echo "Dynamic libraries were included in the musl static package" >&2
    exit 1
  fi
  for archive in lib/*.a; do
    machines="$(readelf -h "$archive" 2>/dev/null | awk '/Machine:/{sub(/^.*Machine:[[:space:]]*/, ""); print}' | sort -u)"
    if [[ "$machines" != "$expected_machine" ]]; then
      echo "Unexpected ELF architecture in $archive: ${machines:-unreadable}" >&2
      exit 1
    fi
    if readelf --wide --symbols "$archive" 2>/dev/null | grep -E ' UND .*GLIBC_[0-9]' >/dev/null; then
      echo "Undefined glibc-versioned symbol found in musl archive: $archive" >&2
      exit 1
    fi
  done
fi
read -r -a link_flags <<< "$link_options"
"$compiler" -O2 -Wall -Wextra "$script_dir/verify_runtime.c" "${link_flags[@]}" -o "$executable"

if [[ "$platform" == linux-musl ]]; then
  "./$executable"
  gcc -x c++ -std=c++17 -O2 -Wall -Wextra "$script_dir/verify_musl_cpp_runtime.cpp" \
    "${link_flags[@]}" -o verify_cpp_runtime_pie
  for binary in "$executable" verify_cpp_runtime_pie; do
    if readelf -l "$binary" | grep 'INTERP' >/dev/null; then
      echo "Unexpected PT_INTERP in static musl executable: $binary" >&2
      exit 1
    fi
    needed="$(readelf -d "$binary" 2>/dev/null | awk -F '[][]' '/\(NEEDED\)/{print $2}')"
    if [[ -n "$needed" ]]; then
      echo "Unexpected DT_NEEDED entries in static musl executable: $binary" >&2
      printf '%s\n' "$needed" >&2
      printf 'pkg-config link flags: %s\n' "$link_options" >&2
      exit 1
    fi
    machine="$(readelf -h "$binary" | awk '/Machine:/{sub(/^.*Machine:[[:space:]]*/, ""); print}')"
    if [[ "$machine" != "$expected_machine" ]]; then
      echo "Unexpected ELF architecture in $binary: $machine" >&2
      exit 1
    fi
    if [[ "$binary" == "$executable" || "$binary" == verify_cpp_runtime_pie ]]; then
      elf_type="$(readelf -h "$binary" | awk '/Type:/{print $2}')"
      if [[ "$elf_type" != DYN ]]; then
        echo "Expected a static PIE (ET_DYN) in $binary, found $elf_type" >&2
        exit 1
      fi
    fi
  done
fi

case "$platform" in
  linux)
    bash "$script_dir/verify_linux_glibc.sh" "$executable"
    dependencies="$(readelf -d "$executable" | awk -F '[][]' '/NEEDED/{print $2}')"
    ;;
  linux-musl)
    ./verify_cpp_runtime_pie
    trace_file="$stage/runtime-files.trace"
    trace_status=0
    strace -f -e trace=%file -o "$trace_file" "./$executable" || trace_status=$?
    if [[ "$trace_status" -ne 0 ]]; then
      echo "Static FFmpeg consumer failed under strace (exit $trace_status); recent file trace:" >&2
      tail -n 80 "$trace_file" >&2
      exit "$trace_status"
    fi
    if grep -E '"[^"]*(\.so([.][^"]*)?|/plugins?/[^\"]*)"' "$trace_file"; then
      echo "The static verifier attempted to access a shared object or plugin" >&2
      exit 1
    fi
    dependencies=""
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

if [[ "$platform" != linux-musl ]]; then
  "./$executable"
fi

if [[ "$platform" == linux-musl && -n "$copy_executable" ]]; then
  mkdir -p "$(dirname "$copy_executable")"
  cp "$executable" "$copy_executable"
fi
