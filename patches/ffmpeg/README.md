# FFmpeg 9 runtime patch

`0001-avs-dra-runtime.patch` targets the official FFmpeg 9.0.2 source archive.
It vendors the native CAVS/AVS+ and DRA decoders from
[`maliwen2015/ffmpeg_cavs_dra`](https://github.com/maliwen2015/ffmpeg_cavs_dra),
revision `abae276fed97ce08928f25c8f5e03fd915687f54`, together with the previous
runtime's CAVS compatibility, frame-property and seek fixes. Build scripts do
not fetch or apply the external FFmpeg 7.1.2 patch anymore. The previous 7.x patches are preserved in Git history.

Changes for FFmpeg 9:

- Use the internal `FFCodec` format-list macros and `FFCodecParser` API.
- Append the custom DRA codec ID after the upstream audio IDs; preserve all
  upstream enum values and recognize the MPEG-TS `DRA1` registration descriptor.
- Keep the upstream CAVS parser's sequence-header dimensions and frame rate.
  Sequence/picture byte offsets override parser positions only for raw CAVS;
  transport streams retain their demuxed packet file positions.
- Carry CAVS packet provenance through the decoder's asynchronous workers and
  reconstructed images. A fixed 256-entry history stores packet **properties**,
  without retaining compressed payloads. Frame reordering, drain and seek use
  the originating properties, including `AV_CODEC_FLAG_COPY_OPAQUE`. An expired
  history entry returns an error rather than assigning a different packet.
- Probe CAVS directly from the input buffer without a temporary packet copy;
  remove redundant B-frame pixel copies and duplicate packet-property storage.
  Propagate invalid sequence-header errors to the caller.
- Remove the replaced upstream CAVS decoder's unused x86 DSP objects, which
  otherwise retain unrelated HPEL references and break minimal CAVS builds.
- Reset DRA queued data and overlap state on seek/flush while retaining its
  allocated buffer and transform tables. Drain buffered audio at EOF, use
  negative FFmpeg errors, copy channel layouts with the layout API, and use
  `memmove` when compacting overlapping input. Reject unsupported output above
  two channels rather than returning partially initialized PCM.
- Preserve decoder-side AVS2/AVS3 positions across frame reordering. AVS2/AVS3
  wrappers set their own frame properties instead of inheriting the currently
  submitted packet's opaque value for delayed output. They do not implement
  arbitrary application opaque propagation.

## Packet positions after `AVFrame.pkt_pos` removal

The `cavs`, `libdavs2` and `libuavs3d` decoders expose a private boolean option,
`export_packet_pos`, defaulting to **0**. Enable it before decoding:

```c
av_opt_set_int(codec_context->priv_data, "export_packet_pos", 1, 0);
```

Decoded frames then expose the original demuxed packet position as the decimal
value of `frame->metadata["tscutter.packet_pos"]`. Unknown positions are omitted.
The position identifies the originating packet, not the currently submitted
packet; it may point to a TS/PES packet or, for raw CAVS keyframes, its sequence
header. Consumers should preserve their existing format-specific cut rules.

The metadata uses small per-output-frame dictionary allocations **only when
enabled**. No PTS-indexed map or application `GCHandle` is required. CAVS users
can alternatively associate their own position token through the standard
`AV_CODEC_FLAG_COPY_OPAQUE` path. Upstream codecs such as H.264 and HEVC retain
their upstream API and can use that standard path as supported by the decoder.

The public FFmpeg 9 frame/packet layouts are unchanged; the removed `pkt_pos`
member is not reintroduced. Consumers must use bindings for the 9.x ABI.

## AV3A identification without a decoder

`0002-av3a-demux-probing.patch` applies after `0001` on FFmpeg 9.0.2.
The AATF header fields and bit-rate/channel tables derive from Shuai Liu's
LGPL AV3A integration in [OpenHarmony FFmpeg](https://github.com/openharmony/third_party_ffmpeg).
Original copyright and LGPL notices are retained.

The patch adds the AV3A codec descriptor, raw demuxer, frame parser, MPEG-TS
signalling and content-probe mapping. It reads audio parameters without an
AV3A decoder or renderer SDK. Probing validates three consecutive frames within
64 KiB of the existing buffer; parsing bounds malformed-input buffering and
preserves known channel layouts. Program information still requires PAT/PMT.

## AV3A container remuxing

`0003-av3a-container-remux.patch` applies after `0002` on FFmpeg 9.0.2.
The original AV3A MP4 `av3a`/`dca3`, MPEG-TS stream-type and raw muxer
implementation comes from Shuai Liu's
[OpenHarmony `third_party_ffmpeg` integration](https://github.com/openharmony/third_party_ffmpeg/commit/ac883016d94bb95354e2824a501702f64c9ad945),
introduced on 2024-11-01 (`av3a格式封装和解封装`). Its `libavformat/mov.c`,
`movenc.c` and `rawenc.c` contain the original container implementation.
This patch adapts it to FFmpeg 9.0.2 and adds configuration validation and
TS registration signalling. The existing bounded probe and fragmented parser
remain in use; no decoder or renderer SDK is added.

MP4 configuration uses the OpenHarmony integration's ten-byte representation:
eight single-byte fields and a big-endian 16-bit bitrate in kbit/s. Raw/TS
parsing supplies this configuration for remuxing; MP4 reads and writes the
`dca3` atom with length and field validation. Missing or invalid configuration
returns an error. Object channels retain an unspecified speaker layout, and
ambisonic configurations retain their channel order. No private MKV codec ID
is introduced.

The packaged-runtime verifier exercises MP4, MPEG-TS and raw AV3A round trips,
checks configuration and packet hashes, and rejects missing/truncated output
configuration. Its optional `av3a` sample mode runs the same payload checks on
real files without decoding or writing sample output to disk.

## AV3A stream metadata

`0006-av3a-stream-metadata.patch` applies after the existing AV3A patches.
It reads complete AATF frames in the demux path and exposes `av3a_content_type`,
`av3a_bed_channels`, `av3a_bed_layout`, `av3a_objects` and `av3a_hoa_order`
as stream metadata for MP4, MPEG-TS and raw AV3A inputs. Fields that do not
apply to the current configuration are omitted. Configuration changes update
the metadata and clear obsolete fields; unchanged configurations avoid repeated
dictionary allocation.

The codec channel count is preserved. A 7.1.4 bed with four objects reports
12 bed channels, layout `7.1.4`, and four objects while retaining 16 coded
components. The same metadata is available to `ffprobe -show_streams` and
library clients after stream probing or packet reading, without a decoder SDK.

## AVS2 color metadata

`0004-libdavs2-export-sequence-display-color-metadata.patch` applies after `0003`
in GPL builds. It requires
`patches/davs2-10bit/0004-export-sequence-display-color-description.patch` and
rebuilding the static davs2 dependency with its matching header. It does not
change the public FFmpeg ABI or add a runtime library.

The patches read the signalled AVS2 sequence-display color description.
AVS2 transfer identifiers 12 (PQ) and 14 (HLG), and matrix identifiers
8/9 (BT.2020), require explicit conversion to FFmpeg's different enum values.

The patches bound extension reads to their start-code unit, return each output
frame's own sequence header across reordering and same-size sequence changes,
and fall back to the initial container color fields when a new sequence omits
color descriptions. Out-of-table identifiers become unspecified rather than
retaining the previous sequence's tags. Decoded frame and codec-context color
fields are both populated for downstream previews and stream probing.

## Embedded libass API

`0005-embed-libass-in-avfilter.patch` applies after the preceding FFmpeg patches
on all platforms. `tools/embed_libass.sh` extracts the pinned static libass
archive into the FFmpeg source tree and generates `libass-embedded.mak` plus the
public export list before FFmpeg is configured. Linking the objects directly
keeps APIs that FFmpeg's own subtitle filters do not call and lets Windows build
them into its DLL export/import tables.

Exports follow upstream `libass.sym`. The macOS symbol-list generator preserves
these exact names, and the Windows definition generator matches complete names,
so an API such as `ass_free` does not also expose internal `ass_free_*` helpers.
The existing FFmpeg public API and structure layouts are unchanged.

libass and its font/shaping dependencies are static. Only the seven FFmpeg
shared libraries are packaged. The runtime verifier links and checks all public
libass APIs through libavfilter, then renders real subtitle pixels with system
fonts, animation, Unicode wrapping and seeking.
