#!/usr/bin/env bash
set -euo pipefail

normalize_link_flags() {
  # FFMPEG_TARGET_ARCH 由主构建脚本导出；win64 保持原有 GCC 假设，
  # win-arm64（LLVM/libc++）由驱动的 -static-libstdc++ 提供静态 libc++
  # （归档内含 libc++abi/libunwind），pkg-config 的对应条目一并剥离。
  local target_arch="${FFMPEG_TARGET_ARCH:-win64}"
  awk -v target_arch="$target_arch" '
  {
    output = "";
    for (i = 1; i <= NF; ++i) {
      if ($i == "-lstdc++" || $i == "-lgcc_s" || $i == "-lgcc" || $i == "-lgcc_eh")
        continue;
      if (target_arch == "win-arm64" &&
          ($i == "-lc++" || $i == "-lc++abi" || $i == "-lunwind"))
        continue;
      if ($i == "-lpthread" || $i == "-lwinpthread" || $i == "-pthread" || $i == "-pthreads")
        $i = "-Wl,-l:libwinpthread.a";
      output = output (output == "" ? "" : " ") $i;
    }
    print output;
  }
'
}

if [[ "${1:-}" == --normalize-link-flags ]]; then
  normalize_link_flags
  exit
fi

# 依赖中的线程参数改为静态归档；编译器隐式运行库由主脚本的静态库组和驱动选项提供。
normalize=false
for argument in "$@"; do
  case "$argument" in
    --libs|--libs-only-l|--libs-only-other) normalize=true ;;
  esac
done
if [[ "$normalize" == false ]]; then
  exec "${FFMPEG_PKG_CONFIG_BIN:?Missing pkg-config executable}" "$@"
fi
"${FFMPEG_PKG_CONFIG_BIN:?Missing pkg-config executable}" "$@" | normalize_link_flags
