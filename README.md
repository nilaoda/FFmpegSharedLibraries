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

For `libdavs2`, the build applies local patches that:
- enable 10-bit build support in `davs2-10bit`,
- propagate packet file position metadata through decoder output,
- map decoder output packet position to FFmpeg frame `pkt_pos`.

## Workflow Inputs

All build workflows are fixed to:

- `ffmpeg_version`: `7.1.3`
- `license_flavor`: `gpl`

Manual runs use `workflow_dispatch` without custom input fields.

## Workflows

- [`.github/workflows/build-ffmpeg-runtime-macos.yml`](./.github/workflows/build-ffmpeg-runtime-macos.yml)
- [`.github/workflows/build-ffmpeg-runtime-windows.yml`](./.github/workflows/build-ffmpeg-runtime-windows.yml)
- [`.github/workflows/build-ffmpeg-runtime-linux.yml`](./.github/workflows/build-ffmpeg-runtime-linux.yml)
