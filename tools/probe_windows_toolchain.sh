#!/usr/bin/env bash
set -euo pipefail

# 原生构建前的工具链探针：确认编译器 target、生成 PE 的机器类型、可执行文件可运行。
# MSYS2 的 Bash 可能运行在模拟层上，因此以编译器 target 和产物机器类型判断架构，
# 而不是以 uname 的结果判断。
CC_BIN="${1:?usage: probe_windows_toolchain.sh <cc> <cxx> <expected-target-prefix> <expected-pe-machine> [objdump-like-tool]}"
CXX_BIN="${2:?Missing C++ compiler}"
EXPECTED_TARGET="${3:?Missing expected compiler target prefix}"
EXPECTED_MACHINE="${4:?Missing expected PE machine type}"
PROBE_OBJDUMP="${5:-}"
PROBE_WORK="$(mktemp -d)"
trap 'rm -rf -- "$PROBE_WORK"' EXIT

target="$("$CC_BIN" -dumpmachine)"
if [[ "$target" != "$EXPECTED_TARGET"* || "$target" != *-gnu ]]; then
  echo "Unexpected compiler target: $target (expected $EXPECTED_TARGET* and a GNU/MinGW environment)" >&2
  exit 1
fi
echo "Compiler target: $target"

cat > "$PROBE_WORK/probe.c" <<'EOF'
#include <stdio.h>
int main(void)
{
    printf("c-probe-ok\n");
    return 0;
}
EOF

cat > "$PROBE_WORK/probe.cpp" <<'EOF'
#include <cstdio>
int main()
{
    try {
        throw 7;
    } catch (int value) {
        std::printf("cpp-probe-ok\n");
        return value == 7 ? 0 : 1;
    }
    return 1;
}
EOF

check_pe_machine() {
  local binary="$1" machine_line readobj
  if [[ -n "$PROBE_OBJDUMP" ]]; then
    machine_line="$("$PROBE_OBJDUMP" -f "$binary")"
    if [[ "$machine_line" =~ architecture:\ ${EXPECTED_MACHINE} ]]; then
      return 0
    fi
    echo "Unexpected PE machine type from $PROBE_OBJDUMP:" >&2
    printf '%s\n' "$machine_line" >&2
    return 1
  fi
  # -print-prog-name 只打印解析出的路径；先取路径再单独调用。
  readobj="$("$CC_BIN" -print-prog-name=llvm-readobj)"
  machine_line="$("$readobj" --file-headers "$binary")"
  if printf '%s\n' "$machine_line" | grep -qiE "IMAGE_FILE_MACHINE_${EXPECTED_MACHINE}|Machine: ${EXPECTED_MACHINE}"; then
    return 0
  fi
  echo "Unexpected PE machine type:" >&2
  printf '%s\n' "$machine_line" | grep -iE 'machine|format|arch' >&2
  return 1
}

for language in c cpp; do
  source_file="$PROBE_WORK/probe.$language"
  exe="$PROBE_WORK/probe-$language.exe"
  if [[ "$language" == c ]]; then
    "$CC_BIN" -O2 "$source_file" -o "$exe"
  else
    "$CXX_BIN" -O2 "$source_file" -o "$exe"
  fi
  check_pe_machine "$exe"
  output="$("$exe")"
  if [[ "$output" != "$language-probe-ok" ]]; then
    echo "Probe executable did not run correctly: $output" >&2
    exit 1
  fi
  echo "$language probe: built $(basename "$exe"), machine $EXPECTED_MACHINE, ran OK"
done
