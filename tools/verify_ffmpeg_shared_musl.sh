#!/usr/bin/env bash
set -euo pipefail

target="${1:?usage: verify_ffmpeg_shared_musl.sh <linux-musl-x64|linux-musl-arm64> <shared ZIP> <work-root>}"
artifact="${2:?Missing shared ZIP path}"
work_root="${3:?Missing build work root}"
artifact="$(cd "$(dirname "$artifact")" && pwd)/$(basename "$artifact")"
work_root="$(cd "$work_root" && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
unzip -q "$artifact" -d "$stage"

case "$target:$(uname -m)" in
  linux-musl-x64:x86_64) expected_machine="Advanced Micro Devices X86-64"; musl_name=libc.musl-x86_64.so.1 ;;
  linux-musl-arm64:aarch64) expected_machine=AArch64; musl_name=libc.musl-aarch64.so.1 ;;
  *) echo "Shared musl verification must run on the matching host: $target on $(uname -m)" >&2; exit 1 ;;
esac

libraries=(libavutil.so.61 libswresample.so.7 libswscale.so.10 libavcodec.so.63
  libavformat.so.63 libavfilter.so.12 libavdevice.so.63)
if [[ ! -s "$stage/libgcc_s.so.1" ]]; then
  echo "Missing bundled musl GCC runtime: libgcc_s.so.1" >&2
  exit 1
fi
gcc_machine="$(readelf -h "$stage/libgcc_s.so.1" | awk '/Machine:/{sub(/^.*Machine:[[:space:]]*/, ""); print}')"
if [[ "$gcc_machine" != "$expected_machine" ]]; then
  echo "Unexpected ELF architecture in libgcc_s.so.1: $gcc_machine" >&2
  exit 1
fi
gcc_soname="$(readelf -d "$stage/libgcc_s.so.1" | awk -F'[][]' '/SONAME/{print $2}')"
if [[ "$gcc_soname" != libgcc_s.so.1 ]]; then
  echo "Unexpected SONAME in bundled GCC runtime: $gcc_soname" >&2
  exit 1
fi
for library in "${libraries[@]}"; do
  if [[ ! -s "$stage/$library" ]]; then
    echo "Missing shared FFmpeg library: $library" >&2
    exit 1
  fi
  machine="$(readelf -h "$stage/$library" | awk '/Machine:/{sub(/^.*Machine:[[:space:]]*/, ""); print}')"
  if [[ "$machine" != "$expected_machine" ]]; then
    echo "Unexpected ELF architecture in $library: $machine" >&2
    exit 1
  fi
  if ! readelf -d "$stage/$library" | grep -F '$ORIGIN' >/dev/null; then
    echo "Missing relocatable \$ORIGIN runpath in $library" >&2
    echo "patchelf runpath: $(patchelf --print-rpath "$stage/$library")" >&2
    readelf -d "$stage/$library" >&2
    exit 1
  fi
done

# Alpine's libgcc_s can use GLIBC_* symbol-version labels; the NEEDED allowlist and musl run verify actual providers.
check_dependencies() {
  local elf="$1" dependency
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      "$musl_name"|linux-vdso.so.1) ;;
      libgcc_s.so.1)
        [[ -s "$stage/$dependency" ]] || { echo "Missing bundled GCC runtime dependency: $dependency" >&2; exit 1; }
        ;;
      libavutil.so.61|libswresample.so.7|libswscale.so.10|libavcodec.so.63|libavformat.so.63|libavfilter.so.12|libavdevice.so.63)
        [[ -f "$stage/$dependency" ]] || { echo "Missing bundled FFmpeg dependency: $dependency" >&2; exit 1; }
        ;;
      *) echo "Unexpected external dependency in $elf: $dependency" >&2; exit 1 ;;
    esac
  done < <(readelf -d "$elf" | awk '/NEEDED/{gsub(/\[|\]/, "", $5); print $5}' | sort -u)
}
for library in "${libraries[@]}"; do
  check_dependencies "$stage/$library"
done
check_dependencies "$stage/libgcc_s.so.1"

gcc -O2 -Wall -Wextra -static-libgcc \
  -I"$work_root/install/include" \
  -I"$work_root/subtitle-install/include" \
  -I"$work_root/disc-install/include" \
  "$script_dir/verify_runtime.c" \
  "$stage/libavformat.so.63" \
  "$stage/libavcodec.so.63" \
  "$stage/libavutil.so.61" \
  "$stage/libavdevice.so.63" \
  "$stage/libavfilter.so.12" \
  "$stage/libswscale.so.10" \
  "$stage/libswresample.so.7" \
  -Wl,-rpath,'$ORIGIN' -Wl,-rpath-link,"$stage" \
  -o "$stage/verify_runtime"
check_dependencies "$stage/verify_runtime"

trace_file="$stage/runtime-files.trace"
strace -f -e trace=%file -o "$trace_file" "$stage/verify_runtime"
gcc_runtime_needed=false
for library in "${libraries[@]}"; do
  if readelf -d "$stage/$library" | awk -F'[][]' '/NEEDED/{print $2}' | grep -Fx 'libgcc_s.so.1' >/dev/null; then
    gcc_runtime_needed=true
    break
  fi
done
if [[ "$gcc_runtime_needed" == true ]] && ! grep -F "$stage/libgcc_s.so.1" "$trace_file" >/dev/null; then
  echo "The shared runtime did not load the required bundled libgcc_s.so.1" >&2
  exit 1
fi
if grep -E '"[^"]*/libgcc_s\.so\.1"' "$trace_file" |
  grep -Fv "\"$stage/libgcc_s.so.1\""; then
  echo "The shared runtime accessed libgcc_s.so.1 outside its package" >&2
  exit 1
fi
if grep -E '"[^"]*(\.so([.][^"]*)?|/plugins?/[^\"]*)"' "$trace_file" |
  grep -Ev '"[^"]*/(libav(util|codec|format|filter|device)|libsw(scale|resample))\.so\.[0-9]+|libc\.musl-(x86_64|aarch64)\.so\.1|libgcc_s\.so\.1|ld-musl-(x86_64|aarch64)\.so\.1|linux-vdso\.so\.1)"'; then
  echo "The shared runtime attempted to access an external shared object or plugin" >&2
  exit 1
fi
