#!/usr/bin/env bash
set -euo pipefail

# 将静态 libass 的目标文件直接加入 avfilter，供三平台的链接及导出表生成器使用。
ASS_EMBED_SOURCE="$(cd "${1:?Missing FFmpeg source directory}" && pwd)"
ASS_EMBED_PREFIX="$(cd "${2:?Missing subtitle install directory}" && pwd)"
ASS_EMBED_AR="${AR:-ar}"
ASS_EMBED_ARCHIVE="$ASS_EMBED_PREFIX/lib/libass.a"
ASS_EMBED_SYMBOLS="$ASS_EMBED_PREFIX/share/libass/libass.sym"
ASS_EMBED_DIRECTORY="$ASS_EMBED_SOURCE/libavfilter/libass-embedded"
ASS_EMBED_MAKEFILE="$ASS_EMBED_SOURCE/libavfilter/libass-embedded.mak"
ASS_EMBED_EXPORTS="$ASS_EMBED_SOURCE/libavfilter/libavfilter.v"

[[ -f "$ASS_EMBED_ARCHIVE" && -s "$ASS_EMBED_SYMBOLS" ]] || {
  echo "Missing static libass archive or public API list in $ASS_EMBED_PREFIX" >&2
  exit 1
}

# 不允许重复文件名，避免提取时覆盖目标文件，静默丢失部分接口或汇编实现。
ASS_EMBED_MEMBERS="$("$ASS_EMBED_AR" t "$ASS_EMBED_ARCHIVE" | sed -E '/^__\.SYMDEF(_64)?( SORTED)?$/d')"
[[ -n "$ASS_EMBED_MEMBERS" && -z "$(printf '%s\n' "$ASS_EMBED_MEMBERS" | sort | uniq -d)" ]] || {
  echo "Invalid or duplicate static libass archive members" >&2
  exit 1
}
while IFS= read -r member; do
  [[ "$member" =~ ^[a-zA-Z0-9_.-]+\.(o|obj)$ ]] || {
    echo "Unexpected static libass archive member: $member" >&2
    exit 1
  }
done <<< "$ASS_EMBED_MEMBERS"
while IFS= read -r symbol; do
  [[ "$symbol" =~ ^ass_[a-zA-Z0-9_]+$ ]] || {
    echo "Invalid libass public symbol: $symbol" >&2
    exit 1
  }
done < "$ASS_EMBED_SYMBOLS"

rm -rf "$ASS_EMBED_DIRECTORY"
mkdir -p "$ASS_EMBED_DIRECTORY"
(
  cd "$ASS_EMBED_DIRECTORY"
  "$ASS_EMBED_AR" x "$ASS_EMBED_ARCHIVE"
)
: > "$ASS_EMBED_MAKEFILE"
while IFS= read -r member; do
  # Meson 在 Windows 上可能生成 .obj，FFmpeg 的链接规则只收集 .o。
  if [[ "$member" == *.obj ]]; then
    normalized="${member%.obj}.o"
    [[ ! -e "$ASS_EMBED_DIRECTORY/$normalized" ]] || {
      echo "Conflicting static libass object names: $member / $normalized" >&2
      exit 1
    }
    mv "$ASS_EMBED_DIRECTORY/$member" "$ASS_EMBED_DIRECTORY/$normalized"
    member="$normalized"
  fi
  printf 'SHLIBOBJS-$(CONFIG_LIBASS) += libass-embedded/%s\n' "$member" >> "$ASS_EMBED_MAKEFILE"
done <<< "$ASS_EMBED_MEMBERS"

# 只加入上游公开接口；重复运行时先移除此前生成的条目。
awk 'FNR == NR { symbols[++count] = $0; next }
     /^[ \t]*ass_[a-zA-Z0-9_]+;[ \t]*$/ { next }
     /local:/ { for (i = 1; i <= count; i++) print "        " symbols[i] ";" }
     { print }' "$ASS_EMBED_SYMBOLS" "$ASS_EMBED_EXPORTS" > "$ASS_EMBED_EXPORTS.embedded"
mv "$ASS_EMBED_EXPORTS.embedded" "$ASS_EMBED_EXPORTS"
