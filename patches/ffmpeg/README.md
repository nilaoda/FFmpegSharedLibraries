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
