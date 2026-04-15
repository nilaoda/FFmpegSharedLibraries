# FFmpegSharedLibraries

GitHub Actions workflows for building FFmpeg shared-library runtimes with `libuavs3d` enabled and `libdavs2` (from `davs2-10bit`) enabled in GPL builds.

## Outputs

- `macos-14`: arm64 `.dylib`
- `windows-latest`: win64 `.dll`
- `ubuntu-latest`: linux x64 `.so`

Each workflow builds FFmpeg shared libraries only.

- `libuavs3d` is always built from source as a static dependency and linked into FFmpeg.
- `libdavs2` (`davs2-10bit`) is built from source and linked statically when `license_flavor=gpl`.
- Runtime artifacts do not include separate `libuavs3d`/`libdavs2` dynamic libraries.

The build downloads third-party sources into the workflow temp work root (`$RUNNER_TEMP/ffmpeg-runtime-build` in GitHub Actions) and applies a small set of local patches across both `davs2-10bit` and FFmpeg:

- `patches/davs2-10bit/0001-enable-10bit-build-and-propagate-frame-packet-position.patch`
  - enables 10-bit `davs2-10bit` builds,
  - propagates decoder-side packet file position metadata through `libdavs2` output.
- `patches/davs2-10bit/0002-x86-build-avx-codepaths-as-dispatch-only.patch`
  - keeps generic `x86_64` objects on an SSE4.x baseline instead of compiling the whole library with `-mavx`,
  - builds AVX and AVX2 translation units separately so runtime CPUID dispatch stays compatible with both older and newer x86 devices.
- `patches/ffmpeg/0001-libdavs2-export-pkt_pos-from-decoder-output.patch`
  - maps `libdavs2` packet position metadata to FFmpeg frame `pkt_pos`.
- `patches/ffmpeg/0002-libcavs-fix-macos-build-compat.patch`
  - fixes `libcavs` build compatibility on macOS.
- `patches/ffmpeg/0003-libcavs-export-pkt_pos-and-simplify-profile-name.patch`
  - exports `pkt_pos` for `libcavs` decoded frames,
  - simplifies the reported CAVS profile name.
- `patches/ffmpeg/0004-libcavs-fix-reordered-frame-props.patch`
  - fixes reordered-frame property propagation in `libcavs`.
- `patches/ffmpeg/0005-cavs-parser-mark-key-packets.patch`
  - improves CAVS parser key-packet marking.
- `patches/ffmpeg/0006-cavsvideo-fix-backward-seek-and-key-pos.patch`
  - adjusts raw CAVS demuxing / indexing behavior for backward seek and keyframe position handling.

## Workflow Inputs

All build workflows are fixed to:

- `ffmpeg_version`: `7.1.3`
- `license_flavor`: `gpl`

Manual runs use `workflow_dispatch` without custom input fields.

## Third-Party Libraries

- FFmpeg: https://ffmpeg.org/
- uavs3d: https://github.com/uavs3/uavs3d
- davs2-10bit: https://github.com/xatabhk/davs2-10bit
- ffmpeg_cavs_dra patch source: https://github.com/maliwen2015/ffmpeg_cavs_dra

## Workflows

- [`.github/workflows/build-ffmpeg-runtime-macos.yml`](./.github/workflows/build-ffmpeg-runtime-macos.yml)
- [`.github/workflows/build-ffmpeg-runtime-windows.yml`](./.github/workflows/build-ffmpeg-runtime-windows.yml)
- [`.github/workflows/build-ffmpeg-runtime-linux.yml`](./.github/workflows/build-ffmpeg-runtime-linux.yml)
