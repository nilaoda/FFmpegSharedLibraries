#!/usr/bin/env bash
set -euo pipefail

# 新依赖的 -lpthread 会优先选中 MinGW 动态导入库，必须与 C++ 运行时统一使用静态实现。
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
    for (i = 1; i <= NF; ++i)
      if ($i == "-lpthread" || $i == "-lwinpthread" || $i == "-pthread")
        $i = "-Wl,-l:libwinpthread.a";
    print;
  }
'
