#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: verify_linux_glibc.sh <ELF file> [...]" >&2
  exit 1
fi

export LC_ALL=C
for elf in "$@"; do
  readelf --wide --version-info "$elf" | awk -v path="$elf" '
    /^Version needs section/ { needs = 1; next }
    /^Version .* section/ { needs = 0 }
    needs {
      for (i = 1; i < NF; i++) {
        label = $(i + 1)
        if ($i != "Name:" || label !~ /^GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?$/)
          continue
        split(substr(label, 7), version, ".")
        if (version[1] > 2 || (version[1] == 2 && (version[2] > 39 ||
            (version[2] == 39 && version[3] + 0 > 0)))) {
          printf "%s requires %s, above the Ubuntu 24.04 glibc 2.39 baseline\n", path, label
          failed = 1
        }
      }
    }
    END { exit failed }
  ' >&2
done
