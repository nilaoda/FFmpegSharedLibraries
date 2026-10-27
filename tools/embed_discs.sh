#!/usr/bin/env bash
set -euo pipefail

# 将 PIC 静态归档的对象加入 avformat，保留并导出 GUI 使用的公开接口。
DISC_EMBED_SOURCE="$(cd "${1:?Missing FFmpeg source}" && pwd)"
DISC_EMBED_PREFIX="$(cd "${2:?Missing disc prefix}" && pwd)"
DISC_EMBED_FLAVOR="${3:?Missing license flavor}"
DISC_EMBED_AR="${AR:-ar}"
DISC_EMBED_DIR="$DISC_EMBED_SOURCE/libavformat/disc-embedded"
DISC_EMBED_MAK="$DISC_EMBED_SOURCE/libavformat/disc-embedded.mak"
DISC_EMBED_EXPORTS="$DISC_EMBED_SOURCE/libavformat/libavformat.v"
DISC_EMBED_LIBRARIES=(bluray udfread)
if [[ "$DISC_EMBED_FLAVOR" == gpl ]]; then DISC_EMBED_LIBRARIES+=(dvdread dvdnav dvdcss); fi
rm -rf "$DISC_EMBED_DIR"
mkdir -p "$DISC_EMBED_DIR"
: > "$DISC_EMBED_MAK"
for component in "${DISC_EMBED_LIBRARIES[@]}"; do
  archive="$DISC_EMBED_PREFIX/lib/lib$component.a"
  [[ -f "$archive" ]] || { echo "Missing disc archive: $archive" >&2; exit 1; }
  members="$("$DISC_EMBED_AR" t "$archive" | sed -E '/^__\.SYMDEF(_64)?( SORTED)?$/d')"
  [[ -n "$members" && -z "$(printf '%s\n' "$members" | sort | uniq -d)" ]] || {
    echo "Invalid/duplicate objects in $archive" >&2; exit 1;
  }
  mkdir -p "$DISC_EMBED_DIR/$component"
  while IFS= read -r member; do
    [[ "$member" =~ ^[a-zA-Z0-9_.-]+\.(o|obj)$ ]] || { echo "Invalid object: $member" >&2; exit 1; }
  done <<< "$members"
  (cd "$DISC_EMBED_DIR/$component"; "$DISC_EMBED_AR" x "$archive")
  while IFS= read -r member; do
    if [[ "$member" == *.obj ]]; then
      normalized="${member%.obj}.o"
      [[ ! -e "$DISC_EMBED_DIR/$component/$normalized" ]] || { echo "Object collision: $member" >&2; exit 1; }
      mv "$DISC_EMBED_DIR/$component/$member" "$DISC_EMBED_DIR/$component/$normalized"
      member="$normalized"
    fi
    printf 'SHLIBOBJS += disc-embedded/%s/%s\n' "$component" "$member" >> "$DISC_EMBED_MAK"
  done <<< "$members"
done

# 最小公开接口集；DVD 仅加入 GPL 版本，不将 GPL 依赖混入 LGPL 版本。
DISC_EMBED_SYMBOLS="$DISC_EMBED_DIR/public-api.txt"
cat > "$DISC_EMBED_SYMBOLS" <<'EOF'
bd_get_version
bd_open
bd_close
bd_get_disc_info
bd_get_titles
bd_get_title_info
bd_free_title_info
bd_select_playlist
bd_select_angle
bd_read
bd_seek
bd_seek_time
bd_tell
bd_get_title_size
EOF
if [[ "$DISC_EMBED_FLAVOR" == gpl ]]; then
  cat >> "$DISC_EMBED_SYMBOLS" <<'EOF'
DVDOpen
DVDClose
DVDOpenFile
DVDCloseFile
DVDReadBytes
DVDReadBlocks
DVDFileSize
ifoOpen
ifoClose
EOF
fi
awk 'FNR == NR { symbols[++count] = $0; next }
     /^[ \t]*(bd_[a-zA-Z0-9_]+|DVD[a-zA-Z0-9_]+|ifo[A-Za-z0-9_]+);[ \t]*$/ { next }
     /local:/ { for (i = 1; i <= count; i++) print "        " symbols[i] ";" }
     { print }' "$DISC_EMBED_SYMBOLS" "$DISC_EMBED_EXPORTS" > "$DISC_EMBED_EXPORTS.embedded"
mv "$DISC_EMBED_EXPORTS.embedded" "$DISC_EMBED_EXPORTS"
