# FFmpegSharedLibraries

GitHub Actions workflows for building FFmpeg shared-library runtimes with `libuavs3d` and optional `libdavs2` (from `davs2-10bit`) support.

## Outputs

- `macos-14`: arm64 `.dylib`
- `windows-latest`: win64 `.dll`
- `ubuntu-latest`: linux x64 `.so`

Each workflow builds FFmpeg shared libraries only.

- `libuavs3d` is always built from source as a static dependency and linked into FFmpeg.
- `libdavs2` (from `davs2-10bit`, bit depth 10) is built and enabled when `license_flavor=gpl`.
- Runtime artifacts do not include separate `libuavs3d`/`libdavs2` dynamic libraries.

## Workflow Inputs

All build workflows expose the same manual inputs:

- `ffmpeg_version`: FFmpeg release version, default `7.1.3`
- `license_flavor`: `gpl` or `lgpl`

## Workflows

- [`.github/workflows/build-ffmpeg-runtime-macos.yml`](/Users/macmini/code/GitHub/FFmpegSharedLibraries/.github/workflows/build-ffmpeg-runtime-macos.yml)
- [`.github/workflows/build-ffmpeg-runtime-windows.yml`](/Users/macmini/code/GitHub/FFmpegSharedLibraries/.github/workflows/build-ffmpeg-runtime-windows.yml)
- [`.github/workflows/build-ffmpeg-runtime-linux.yml`](/Users/macmini/code/GitHub/FFmpegSharedLibraries/.github/workflows/build-ffmpeg-runtime-linux.yml)
