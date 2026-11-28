#!/usr/bin/env bash
set -euo pipefail

FFMPEG_VERSION="${1:?usage: build_ffmpeg_musl.sh <ffmpeg-version> <gpl|lgpl> <work-root> <linux-musl-x64|linux-musl-arm64>}"
LICENSE_FLAVOR="${2:?Missing license flavor}"
WORK_ROOT="${3:?Missing build work root}"
TARGET_ARCH="${4:?Missing musl target architecture}"

case "$TARGET_ARCH" in
  linux-musl-x64|linux-musl-arm64) ;;
  *) echo "Unsupported musl target architecture: $TARGET_ARCH" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/build_ffmpeg_runtime_linux.sh" \
  "$FFMPEG_VERSION" "$LICENSE_FLAVOR" "$WORK_ROOT" "$TARGET_ARCH"
