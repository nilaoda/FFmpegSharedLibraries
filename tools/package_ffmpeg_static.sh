#!/usr/bin/env bash
set -euo pipefail

platform="${1:?Missing target platform}"
version="${2:?Missing FFmpeg version}"
license_flavor="${3:?Missing license flavor}"
work_root="${4:?Missing build work root}"
install_root="${5:?Missing FFmpeg install directory}"
config_mak="${6:?Missing FFmpeg config.mak}"
artifact="${7:?Missing output ZIP path}"
target="${8:-}"
case "$platform:$target" in
  windows:|windows:win64|windows:win-arm64)
    [[ -n "$target" ]] && target_arch="$target" || target_arch=win64
    ;;
  linux:|macos:)
    target_arch=""
    ;;
  *)
    echo "Unsupported target platform/architecture: $platform:$target" >&2
    exit 1
    ;;
esac
artifact="$(cd "$(dirname "$artifact")" && pwd)/$(basename "$artifact")"

stage="$(mktemp -d "$(dirname "$artifact")/.static-package.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/lib/pkgconfig" "$stage/include"
cp -R "$install_root/include/." "$stage/include/"
cp -R "$work_root/subtitle-install/include/ass" "$work_root/disc-install/include/libbluray" "$stage/include/"
if [[ "$license_flavor" == gpl ]]; then
  cp -R "$work_root/disc-install/include/dvdread" "$stage/include/"
fi

# Keep FFmpeg's configure library order for archive resolution.
components=(avdevice avfilter swscale avformat avcodec swresample avutil)
for component in "${components[@]}"; do
  cp "$install_root/lib/lib$component.a" "$stage/lib/"
done

dependency_roots=(encoder-install subtitle-install disc-install uavs3d-install)
if [[ "$license_flavor" == gpl ]]; then
  dependency_roots+=(davs2-install)
fi
for root in "${dependency_roots[@]}"; do
  for archive in "$work_root/$root/lib/"*.a; do
    name="${archive##*/}"
    if [[ "$name" == *.dll.a || -e "$stage/lib/$name" ]]; then
      echo "Unexpected archive for static package: $archive" >&2
      exit 1
    fi
    cp "$archive" "$stage/lib/"
  done
done

link_flags=()
for component in "${components[@]}"; do
  link_flags+=("-l$component")
done

# Read the same dependency flags used by FFmpeg. The SDK stages all archives
# in one directory, so runner-local search paths can be dropped.
extra_libraries="$(
  for component in "${components[@]}"; do
    sed -n "s/^EXTRALIBS-$component=//p" "$config_mak"
  done
  sed -n 's/^EXTRALIBS=//p' "$config_mak"
)"
if [[ "$platform" == windows ]]; then
  # Configure can add its own bare C++ runtime flags after querying pkg-config.
  # Keep the explicit static runtime group from the Windows build instead.
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  extra_libraries="$(printf '%s\n' "$extra_libraries" |
    bash "$script_dir/pkg_config_windows_static.sh" --normalize-link-flags)"
fi
read -r -a extra_flags <<< "${extra_libraries//$'\n'/ }"
for flag in "${extra_flags[@]}"; do
  case "$platform:$flag" in
    *:-L*) ;;
    windows:*/libgdi32.a)
      link_flags+=(-lgdi32)
      ;;
    windows:*/libiconv.a|windows:-liconv)
      if [[ ! -f "$stage/lib/libiconv.a" ]]; then
        iconv_archive="$flag"
        if [[ "$flag" == -liconv ]]; then
          if [[ "$target_arch" == win-arm64 ]]; then
            iconv_archive="$(clang -print-file-name=libiconv.a)"
          else
            iconv_archive="$(gcc -print-file-name=libiconv.a)"
          fi
        fi
        cp "$iconv_archive" "$stage/lib/libiconv.a"
      fi
      # Require the bundled static archive even if the consumer has an import library.
      link_flags+=(-Wl,-l:libiconv.a)
      ;;
    windows:/*|windows:[a-zA-Z]:[\\/]*)
      echo "Unexpected absolute library path for static package: $flag" >&2
      exit 1
      ;;
    *) link_flags+=("$flag") ;;
  esac
done
if [[ "$platform" == windows ]]; then
  if [[ "$target_arch" == win-arm64 ]]; then
    # clang 的 MinGW 驱动：-static-libstdc++ 提供静态 libc++（含 unwind）；
    # MSYS2 clang 23.x 不接受 -static-unwindlib；-static-libgcc 为空操作。
    link_flags+=(-static-libstdc++)
  else
    link_flags+=(-static-libgcc -static-libstdc++)
  fi
elif [[ "$platform" == linux ]]; then
  link_flags+=(-static-libgcc)
fi

cat > "$stage/lib/pkgconfig/ffmpeg-static.pc" <<EOF
prefix=\${pcfiledir}/../..
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: ffmpeg-static
Description: FFmpeg static libraries and link dependencies
Version: $version
Libs: -L\${libdir} ${link_flags[*]}
Cflags: -I\${includedir}
EOF

{
  echo "FFmpeg version: $version"
  echo "Target: $platform"
  if [[ "$platform" == windows && "$target_arch" == win-arm64 ]]; then
    echo "Target architecture: win-arm64"
  fi
  echo "License flavor: $license_flavor"
  sed -n 's/^FFMPEG_CONFIGURATION=/Configure flags: /p' "$config_mak"
  cat "$work_root/encoder-install/versions.txt" "$work_root/subtitle-install/versions.txt"
  echo "Bundled static archives:"
  printf '  %s\n' "$stage"/lib/*.a | sed "s|$stage/||"
} > "$stage/manifest.txt"

rm -f -- "$artifact"
(
  cd "$stage"
  zip -qr "$artifact" include lib manifest.txt
)
echo "Created artifact: $artifact"
