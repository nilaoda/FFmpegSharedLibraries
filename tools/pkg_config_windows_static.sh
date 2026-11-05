#!/usr/bin/env bash
set -euo pipefail

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
"${FFMPEG_PKG_CONFIG_BIN:?Missing pkg-config executable}" "$@" | awk '
  {
    output = "";
    for (i = 1; i <= NF; ++i) {
      if ($i == "-lstdc++" || $i == "-lgcc_s" || $i == "-lgcc" || $i == "-lgcc_eh")
        continue;
      if ($i == "-lpthread" || $i == "-lwinpthread" || $i == "-pthread")
        $i = "-Wl,-l:libwinpthread.a";
      output = output (output == "" ? "" : " ") $i;
    }
    print output;
  }
'
