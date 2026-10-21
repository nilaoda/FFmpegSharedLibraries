#!/usr/bin/env bash
set -euo pipefail

# 字幕依赖独立安装；只发布 libass，共享库内部静态链接字体和排版依赖。
SUBTITLE_PLATFORM="${1:?usage: build_subtitle_runtime.sh <macos|linux|windows> <work-root> [jobs]}"
SUBTITLE_WORK_ROOT="${2:?Missing work root}"
SUBTITLE_JOBS="${3:-4}"
SUBTITLE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBTITLE_SOURCE_ROOT="$SUBTITLE_WORK_ROOT/subtitle-src"
SUBTITLE_BUILD_ROOT="$SUBTITLE_WORK_ROOT/subtitle-build"
SUBTITLE_INSTALL_ROOT="$SUBTITLE_WORK_ROOT/subtitle-install"
SUBTITLE_PKG_CONFIG="${PKG_CONFIG_BIN:-pkg-config}"
SUBTITLE_CC="${CC:-cc}"
SUBTITLE_AR="${AR:-ar}"

case "$SUBTITLE_PLATFORM" in macos|linux|windows) ;; *) echo "Unknown subtitle platform: $SUBTITLE_PLATFORM" >&2; exit 1 ;; esac
if [[ ! "$SUBTITLE_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Subtitle build jobs must be a positive integer" >&2
  exit 1
fi
for subtitle_tool in cmake meson ninja "$SUBTITLE_PKG_CONFIG"; do
  command -v "$subtitle_tool" >/dev/null || { echo "Missing subtitle build tool: $subtitle_tool" >&2; exit 1; }
done
mkdir -p "$SUBTITLE_SOURCE_ROOT"
rm -rf "$SUBTITLE_BUILD_ROOT" "$SUBTITLE_INSTALL_ROOT"
mkdir -p "$SUBTITLE_BUILD_ROOT" "$SUBTITLE_INSTALL_ROOT/lib/pkgconfig"

# 固定版本和校验值，复用已下载的归档；解压前始终检查文件完整性。
subtitle_source() {
  local name="$1" url="$2" digest="$3" directory="$4"
  local archive="$SUBTITLE_SOURCE_ROOT/$name"
  if [[ ! -f "$archive" ]]; then
    curl -fL --retry 3 "$url" -o "$archive"
  fi
  if command -v sha256sum >/dev/null; then
    printf '%s  %s\n' "$digest" "$archive" | sha256sum -c -
  else
    printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c -
  fi
  rm -rf "$SUBTITLE_SOURCE_ROOT/$directory"
  tar -xf "$archive" -C "$SUBTITLE_SOURCE_ROOT"
}

subtitle_source freetype-2.13.3.tar.gz \
  https://codeload.github.com/freetype/freetype/tar.gz/refs/tags/VER-2-13-3 \
  bc5c898e4756d373e0d991bab053036c5eb2aa7c0d5c67e8662ddc6da40c4103 freetype-VER-2-13-3
subtitle_source harfbuzz-10.2.0.tar.xz \
  https://github.com/harfbuzz/harfbuzz/releases/download/10.2.0/harfbuzz-10.2.0.tar.xz \
  620e3468faec2ea8685d32c46a58469b850ef63040b3565cde05959825b48227 harfbuzz-10.2.0
subtitle_source fribidi-1.0.16.tar.xz \
  https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz \
  1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c fribidi-1.0.16
subtitle_source libunibreak-6.1.tar.gz \
  https://codeload.github.com/adah1972/libunibreak/tar.gz/refs/tags/libunibreak_6_1 \
  890674996168ef5ba143d80d49ab8b61594a4eb70198dcac76caf6e1bd264a41 libunibreak-libunibreak_6_1
subtitle_source libass-0.17.4.tar.xz \
  https://github.com/libass/libass/releases/download/0.17.4/libass-0.17.4.tar.xz \
  78f1179b838d025e9c26e8fef33f8092f65611444ffa1bfc0cfac6a33511a05a libass-0.17.4

# 只在此安装目录内查找第三方库，避免误用构建机上同名的动态库。
export PKG_CONFIG_LIBDIR="$SUBTITLE_INSTALL_ROOT/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG="$SUBTITLE_PKG_CONFIG"
SUBTITLE_MESON_FLAGS=(--buildtype=release --libdir=lib --wrap-mode=nodownload --auto-features=disabled -Db_staticpic=true)
SUBTITLE_STATIC_FLAGS=("${SUBTITLE_MESON_FLAGS[@]}" --default-library=static --prefix="$SUBTITLE_INSTALL_ROOT")

cmake -S "$SUBTITLE_SOURCE_ROOT/freetype-VER-2-13-3" -B "$SUBTITLE_BUILD_ROOT/freetype" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$SUBTITLE_INSTALL_ROOT" -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF \
  -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
cmake --build "$SUBTITLE_BUILD_ROOT/freetype" -j"$SUBTITLE_JOBS"
cmake --install "$SUBTITLE_BUILD_ROOT/freetype"

meson setup "$SUBTITLE_BUILD_ROOT/fribidi" "$SUBTITLE_SOURCE_ROOT/fribidi-1.0.16" \
  "${SUBTITLE_STATIC_FLAGS[@]}" -Ddocs=false -Dbin=false -Dtests=false
meson compile -C "$SUBTITLE_BUILD_ROOT/fribidi" -j "$SUBTITLE_JOBS"
meson install -C "$SUBTITLE_BUILD_ROOT/fribidi"

meson setup "$SUBTITLE_BUILD_ROOT/harfbuzz" "$SUBTITLE_SOURCE_ROOT/harfbuzz-10.2.0" \
  "${SUBTITLE_STATIC_FLAGS[@]}" -Dtests=disabled -Ddocs=disabled -Dutilities=disabled \
  -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dfreetype=disabled -Dicu=disabled -Dintrospection=disabled
meson compile -C "$SUBTITLE_BUILD_ROOT/harfbuzz" -j "$SUBTITLE_JOBS"
meson install -C "$SUBTITLE_BUILD_ROOT/harfbuzz"

# 上游提供 Autotools 工程；按其 Makefile.am 的文件清单构建小型纯 C 静态库。
mkdir -p "$SUBTITLE_BUILD_ROOT/unibreak" "$SUBTITLE_INSTALL_ROOT/include"
SUBTITLE_UNIBREAK_OBJECTS=()
SUBTITLE_PIC_FLAGS=()
if [[ "$SUBTITLE_PLATFORM" != windows ]]; then SUBTITLE_PIC_FLAGS=(-fPIC); fi
for unit in unibreakbase unibreakdef linebreak linebreakdata linebreakdef eastasianwidthdef emojidef graphemebreak wordbreak; do
  "$SUBTITLE_CC" -O2 "${SUBTITLE_PIC_FLAGS[@]}" -I"$SUBTITLE_SOURCE_ROOT/libunibreak-libunibreak_6_1/src" \
    -c "$SUBTITLE_SOURCE_ROOT/libunibreak-libunibreak_6_1/src/$unit.c" -o "$SUBTITLE_BUILD_ROOT/unibreak/$unit.o"
  SUBTITLE_UNIBREAK_OBJECTS+=("$SUBTITLE_BUILD_ROOT/unibreak/$unit.o")
done
"$SUBTITLE_AR" rcs "$SUBTITLE_INSTALL_ROOT/lib/libunibreak.a" "${SUBTITLE_UNIBREAK_OBJECTS[@]}"
for header in unibreakbase unibreakdef linebreak linebreakdef eastasianwidthdef graphemebreak wordbreak; do
  cp "$SUBTITLE_SOURCE_ROOT/libunibreak-libunibreak_6_1/src/$header.h" "$SUBTITLE_INSTALL_ROOT/include/"
done
cat > "$SUBTITLE_INSTALL_ROOT/lib/pkgconfig/libunibreak.pc" <<PC
prefix=$SUBTITLE_INSTALL_ROOT
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libunibreak
Description: Unicode line and word breaking
Version: 6.1
Libs: -L\${libdir} -lunibreak
Cflags: -I\${includedir}
PC

SUBTITLE_PLATFORM_FLAGS=(-Dfontconfig=disabled -Dcoretext=disabled -Ddirectwrite=disabled)
case "$SUBTITLE_PLATFORM" in
  macos) SUBTITLE_PLATFORM_FLAGS=(-Dfontconfig=disabled -Dcoretext=enabled -Ddirectwrite=disabled) ;;
  windows)
    # 依赖中的位计数等辅助函数也必须静态链接，避免引入 libgcc_s_seh-1.dll。
    SUBTITLE_PLATFORM_FLAGS=(-Dfontconfig=disabled -Dcoretext=disabled -Ddirectwrite=enabled -Dc_link_args=-static-libgcc)
    ;;
  linux)
    subtitle_source expat-2.6.4.tar.xz \
      https://github.com/libexpat/libexpat/releases/download/R_2_6_4/expat-2.6.4.tar.xz \
      a695629dae047055b37d50a0ff4776d1d45d0a4c842cf4ccee158441f55ff7ee expat-2.6.4
    subtitle_source fontconfig-2.16.0.tar.gz \
      https://codeload.github.com/fontconfig/fontconfig/tar.gz/refs/tags/2.16.0 \
      136da485b6c222222a016584ef35eb6fe7dfee52e3fa8f51a63405819285012f fontconfig-2.16.0
    cmake -S "$SUBTITLE_SOURCE_ROOT/expat-2.6.4" -B "$SUBTITLE_BUILD_ROOT/expat" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$SUBTITLE_INSTALL_ROOT" -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DEXPAT_SHARED_LIBS=OFF -DEXPAT_BUILD_TOOLS=OFF \
      -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF
    cmake --build "$SUBTITLE_BUILD_ROOT/expat" -j"$SUBTITLE_JOBS"
    cmake --install "$SUBTITLE_BUILD_ROOT/expat"
    # 构建时使用暂存目录，运行时从系统 /etc/fonts 读取字体配置。
    meson setup "$SUBTITLE_BUILD_ROOT/fontconfig" "$SUBTITLE_SOURCE_ROOT/fontconfig-2.16.0" \
      "${SUBTITLE_MESON_FLAGS[@]}" --default-library=static -Dprefer_static=true \
      --prefix=/usr --libdir=lib --sysconfdir=/etc --localstatedir=/var \
      -Ddoc=disabled -Dnls=disabled -Dtests=disabled -Dtools=disabled -Dcache-build=disabled -Dxml-backend=expat
    meson compile -C "$SUBTITLE_BUILD_ROOT/fontconfig" -j "$SUBTITLE_JOBS"
    meson install -C "$SUBTITLE_BUILD_ROOT/fontconfig" --destdir "$SUBTITLE_BUILD_ROOT/fontconfig-stage"
    cp "$SUBTITLE_BUILD_ROOT/fontconfig-stage/usr/lib/libfontconfig.a" "$SUBTITLE_INSTALL_ROOT/lib/"
    cp -R "$SUBTITLE_BUILD_ROOT/fontconfig-stage/usr/include/fontconfig" "$SUBTITLE_INSTALL_ROOT/include/"
    awk -v prefix="$SUBTITLE_INSTALL_ROOT" '/^prefix=/{print "prefix=" prefix; next} {print}' \
      "$SUBTITLE_BUILD_ROOT/fontconfig-stage/usr/lib/pkgconfig/fontconfig.pc" > "$SUBTITLE_INSTALL_ROOT/lib/pkgconfig/fontconfig.pc"
    SUBTITLE_PLATFORM_FLAGS=(-Dfontconfig=enabled -Dcoretext=disabled -Ddirectwrite=disabled)
    ;;
esac

# 沿用上游公开 API 清单，隐藏静态依赖和 libass 的内部符号。
patch -d "$SUBTITLE_SOURCE_ROOT/libass-0.17.4" -p1 --batch --forward --fuzz=0 \
  < "$SUBTITLE_SCRIPT_DIR/../patches/libass/0001-meson-shared-library-exports.patch"
awk '{print "_" $0}' "$SUBTITLE_SOURCE_ROOT/libass-0.17.4/libass/libass.sym" \
  > "$SUBTITLE_SOURCE_ROOT/libass-0.17.4/libass/libass.exports"
{
  echo '{ global:'
  awk '{print $0 ";"}' "$SUBTITLE_SOURCE_ROOT/libass-0.17.4/libass/libass.sym"
  echo 'local: *; };'
} > "$SUBTITLE_SOURCE_ROOT/libass-0.17.4/libass/libass.map"

meson setup "$SUBTITLE_BUILD_ROOT/libass" "$SUBTITLE_SOURCE_ROOT/libass-0.17.4" \
  "${SUBTITLE_MESON_FLAGS[@]}" --default-library=shared --prefix="$SUBTITLE_INSTALL_ROOT" -Dprefer_static=true \
  "${SUBTITLE_PLATFORM_FLAGS[@]}" -Dlibunibreak=enabled -Dasm=enabled -Dtest=disabled -Dcompare=disabled \
  -Dprofile=disabled -Dcheckasm=disabled -Dfuzz=disabled
meson compile -C "$SUBTITLE_BUILD_ROOT/libass" -j "$SUBTITLE_JOBS"
meson install -C "$SUBTITLE_BUILD_ROOT/libass"

cat > "$SUBTITLE_INSTALL_ROOT/versions.txt" <<VERSIONS
libass: 0.17.4 (shared, ABI 9)
FreeType: 2.13.3 (static)
HarfBuzz: 10.2.0 (static)
FriBidi: 1.0.16 (static)
libunibreak: 6.1 (static)
System font provider: $SUBTITLE_PLATFORM
VERSIONS
if [[ "$SUBTITLE_PLATFORM" == linux ]]; then
  cat >> "$SUBTITLE_INSTALL_ROOT/versions.txt" <<VERSIONS
Fontconfig: 2.16.0 (static)
Expat: 2.6.4 (static)
VERSIONS
fi
