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
- The macOS runtime enables VideoToolbox hardware decoding.
- The Windows runtime enables D3D11VA and DXVA2 hardware decoding through Windows system APIs without additional runtime DLLs.

The build downloads third-party sources into the workflow temp work root (`$RUNNER_TEMP/ffmpeg-runtime-build` in GitHub Actions) and applies a small set of local patches across both `davs2-10bit` and FFmpeg:

- `patches/davs2-10bit/0001-enable-10bit-build-and-propagate-frame-packet-position.patch`
  - enables 10-bit `davs2-10bit` builds,
  - propagates decoder-side packet file position metadata through `libdavs2` output.
- `patches/davs2-10bit/0002-x86-build-avx-codepaths-as-dispatch-only.patch`
  - keeps generic `x86_64` objects on an SSE4.x baseline instead of compiling the whole library with `-mavx`,
  - builds AVX and AVX2 translation units separately so runtime CPUID dispatch stays compatible with both older and newer x86 devices.
- `patches/davs2-10bit/0003-fix-dpb-stale-ref-frames.patch`
  - fixes a hang in the DPB (decoded picture buffer) allocation loop that can occur with certain AVS2 streams,
  - recycles stale reference frames that have `b_refered_by_others==1 && i_ref_count==0` (zombie frames never cleaned by the RPS) instead of blocking the pipeline forever.
- [`patches/ffmpeg/0001-avs-dra-runtime.patch`](./patches/ffmpeg/0001-avs-dra-runtime.patch)
  - vendors the existing native AVS+/DRA decoders and ports their integration to FFmpeg 9,
  - preserves the upstream 9.x CAVS parser's sequence-header parsing,
  - fixes CAVS packet provenance through asynchronous decoding and frame reordering,
  - exports optional decoder-side byte positions for AVS+/AVS2/AVS3 without restoring the removed `AVFrame.pkt_pos` ABI member.

- [`patches/ffmpeg/0002-av3a-demux-probing.patch`](./patches/ffmpeg/0002-av3a-demux-probing.patch)
  - recognizes AV3A (Audio Vivid) in raw streams and MPEG-TS, including before program tables arrive,
  - reads audio parameters without an AV3A decoder SDK, with bounded probing and parser buffering.

See [`patches/ffmpeg/README.md`](./patches/ffmpeg/README.md) for source provenance,
position metadata, allocation behavior and the decoder-specific opaque contract.

## Workflow Inputs

All build workflows are fixed to:

- `ffmpeg_version`: `9.0.2`
- `license_flavor`: `gpl`

Manual runs use `workflow_dispatch` without custom input fields.

Build scripts accept FFmpeg `9.0.x` only. Build concurrency defaults to at most
four jobs to limit peak compiler memory; set `BUILD_JOBS` to override it.

## FFmpeg 9 ABI

| Library | ABI major |
| --- | ---: |
| avutil | 61 |
| avcodec | 63 |
| avformat | 63 |
| avdevice | 63 |
| avfilter | 12 |
| swscale | 10 |
| swresample | 7 |

`libpostproc` was removed upstream and is no longer packaged. These libraries
require FFmpeg 9 bindings and cannot replace the current TSCutter 7.x runtime.
macOS packaging rewrites dependencies to `@loader_path` and renews the ad-hoc
signature after rewriting, so ARM64 libraries can load from the flat package.

## Verification

All workflows compile and run `tools/verify_runtime.c` against the **packaged**
runtime before uploading it. This checks loading, ABI majors and registration of
`cavs`, `libdra`, `libdavs2` and `libuavs3d` in the GPL builds, plus AV3A probing
and parsing without an audio decoder.

The Windows build first checks static C++/pthread linkage with both GCC drivers
using `tools/verify_windows_linkage.cpp`, including a thread and an exception.
The complete static library group is passed as one linker argument so FFmpeg
9's C++ driver selection cannot reorder the runtime libraries. Packaged DLLs
must still pass the final dependency check.

The verifier also accepts a local sample. It decodes a bounded window, checks
packet position metadata and key-packet provenance, then seeks, flushes and
decodes another window with position export disabled. For example, after a
macOS build:

```sh
ROOT=/absolute/path/to/work-root
clang -O2 -Wall -Wextra -I"$ROOT/install/include" tools/verify_runtime.c \
  "$ROOT/package/libavformat.63.dylib" \
  "$ROOT/package/libavcodec.63.dylib" \
  "$ROOT/package/libavutil.61.dylib" \
  "$ROOT/package/libavdevice.63.dylib" \
  "$ROOT/package/libavfilter.12.dylib" \
  "$ROOT/package/libswscale.10.dylib" \
  "$ROOT/package/libswresample.7.dylib" -o "$ROOT/package/verify_runtime"
"$ROOT/package/verify_runtime" /path/to/AVS2.ts
"$ROOT/package/verify_runtime" /path/to/DRA.ts dra
"$ROOT/package/verify_runtime" /path/to/raw.cavs cavsvideo
```

Use `audio` to select the best audio track, `dra` to explicitly select a DRA
track, or `cavsvideo` to force the raw CAVS demuxer. An optional fourth argument
sets the frame limit (1–10000); limits above 64 replay TS input from byte zero
after draining, which also supports short inputs containing a single keyframe.
Sample files are not bundled
with the repository or uploaded by the workflows.

## Third-Party Libraries

- FFmpeg: https://ffmpeg.org/
- uavs3d: https://github.com/uavs3/uavs3d
- davs2-10bit: https://github.com/xatabhk/davs2-10bit
- AV3A AATF table/header source: https://github.com/openharmony/third_party_ffmpeg
- ffmpeg_cavs_dra patch source: https://github.com/maliwen2015/ffmpeg_cavs_dra

## Workflows

- [`.github/workflows/build-ffmpeg-runtime-macos.yml`](./.github/workflows/build-ffmpeg-runtime-macos.yml)
- [`.github/workflows/build-ffmpeg-runtime-windows.yml`](./.github/workflows/build-ffmpeg-runtime-windows.yml)
- [`.github/workflows/build-ffmpeg-runtime-linux.yml`](./.github/workflows/build-ffmpeg-runtime-linux.yml)
