#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:?usage: verify_encoder_config.sh <config-components.h> <encoders>}"
ENCODERS="${2:?Missing software encoder list}"

# FFmpeg 会静默禁用依赖不满足的编码器，在正式编译前检查完整白名单。
IFS=, read -r -a encoder_names <<< "$ENCODERS"
missing=0
for encoder in "${encoder_names[@]}"; do
  config_name="$(printf '%s' "$encoder" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
  if ! grep -Fqx "#define CONFIG_${config_name}_ENCODER 1" "$CONFIG_FILE"; then
    echo "Required software encoder was not enabled: $encoder" >&2
    missing=1
  fi
done
exit "$missing"
