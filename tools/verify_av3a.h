#ifndef VERIFY_AV3A_H
#define VERIFY_AV3A_H

/* 使用构建产物的公开 API 验证探测和解析，不需要 AV3A 解码 SDK。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/mem.h"
#include "libavutil/dict.h"
#include "libavutil/sha.h"

#define FRAME_SIZE 1024
#define HEADER_SIZE 9
#define AV3A_CHECK(cond) do { if (!(cond)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond); return 1; } } while (0)

static int verify_channel_metadata(const AVStream *stream, const char *type,
                                   const char *bed, const char *layout,
                                   const char *objects, const char *order)
{
    static const char *const keys[] = {
        "av3a_content_type", "av3a_bed_channels", "av3a_bed_layout",
        "av3a_objects", "av3a_hoa_order"
    };
    const char *values[] = {type, bed, layout, objects, order};
    for (unsigned i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        const AVDictionaryEntry *entry = av_dict_get(stream->metadata, keys[i], NULL, 0);
        AV3A_CHECK(values[i] ? entry && !strcmp(entry->value, values[i]) : !entry);
    }
    return 0;
}

static void make_frame(uint8_t *buf)
{
    /* 真实 AATF 头：48 kHz、10 声道、384 kbit/s，每帧 1024 字节。 */
    static const uint8_t header[HEADER_SIZE] = {0xff, 0xf2, 0x10, 0x52, 0x42, 0x11, 0xb8, 0x0c, 0x24};
    memset(buf, 0x55, FRAME_SIZE);
    memcpy(buf, header, HEADER_SIZE);
}

static int probe_is_av3a(uint8_t *buf, int size)
{
    AVProbeData data = {.filename = "", .buf = buf, .buf_size = size};
    const AVInputFormat *format = av_probe_input_format(&data, 1);
    return format && !strcmp(format->name, "av3a");
}

static int verify_parser(const uint8_t *frames, int size, int chunk, int frame_size, int bit_rate)
{
    AVCodecParserContext *parser = av_parser_init(AV_CODEC_ID_AV3A);
    AVCodecContext *ctx = avcodec_alloc_context3(NULL);
    uint8_t input[4096 + AV_INPUT_BUFFER_PADDING_SIZE], *output;
    int offset = 0, output_size, count = 0;
    AV3A_CHECK(parser && ctx);
    ctx->codec_id = AV_CODEC_ID_AV3A;
    while (offset < size) {
        int bytes = size - offset < chunk ? size - offset : chunk;
        int consumed = 0;
        memcpy(input, frames + offset, bytes);
        memset(input + bytes, 0, AV_INPUT_BUFFER_PADDING_SIZE);
        while (consumed < bytes) {
            int used = av_parser_parse2(parser, ctx, &output, &output_size,
                                       input + consumed, bytes - consumed,
                                       AV_NOPTS_VALUE, AV_NOPTS_VALUE, offset + consumed);
            AV3A_CHECK(used >= 0 && (used || output_size));
            consumed += used;
            if (output_size) {
                AV3A_CHECK(output_size == frame_size);
                AV3A_CHECK(!memcmp(output, frames + count * frame_size, frame_size));
                AV3A_CHECK(parser->duration == 1024);
                count++;
            }
        }
        offset += bytes;
    }
    AV3A_CHECK(av_parser_parse2(parser, ctx, &output, &output_size, NULL, 0,
                          AV_NOPTS_VALUE, AV_NOPTS_VALUE, size) >= 0);
    if (output_size) {
        AV3A_CHECK(output_size == frame_size);
        AV3A_CHECK(!memcmp(output, frames + count * frame_size, frame_size));
        count++;
    }
    AV3A_CHECK(count == size / frame_size);
    AV3A_CHECK(ctx->sample_rate == 48000 && ctx->ch_layout.nb_channels == 10 && ctx->bit_rate == bit_rate);
    av_parser_close(parser);
    avcodec_free_context(&ctx);
    return 0;
}

static int verify_corruption(const uint8_t *frames)
{
    AVCodecParserContext *parser = av_parser_init(AV_CODEC_ID_AV3A);
    AVCodecContext *ctx = avcodec_alloc_context3(NULL);
    uint8_t junk[4096 + AV_INPUT_BUFFER_PADDING_SIZE], *output;
    int output_size, total = 0;
    AV3A_CHECK(parser && ctx);
    ctx->codec_id = AV_CODEC_ID_AV3A;
    memset(junk, 0x55, sizeof(junk));
    /* 连续 1 MiB 无同步数据必须被有界地消费，随后仍能恢复识别。 */
    for (int i = 0; i < 256; i++) {
        int offset = 0;
        while (offset < 4096) {
            int used = av_parser_parse2(parser, ctx, &output, &output_size,
                                       junk + offset, 4096 - offset,
                                       AV_NOPTS_VALUE, AV_NOPTS_VALUE, i * 4096 + offset);
            AV3A_CHECK(used >= 0 && (used || output_size));
            AV3A_CHECK(output_size <= 65536);
            offset += used;
            total += output_size;
        }
    }
    AV3A_CHECK(total == 1024 * 1024);
    AV3A_CHECK(av_parser_parse2(parser, ctx, &output, &output_size, frames, FRAME_SIZE,
                          AV_NOPTS_VALUE, AV_NOPTS_VALUE, total) == FRAME_SIZE);
    AV3A_CHECK(output_size == FRAME_SIZE && ctx->sample_rate == 48000);
    av_parser_close(parser);
    avcodec_free_context(&ctx);
    return 0;
}

typedef struct AV3AMemoryInput {
    const uint8_t *data;
    int size;
    int offset;
} AV3AMemoryInput;

static int av3a_read_memory(void *opaque, uint8_t *buf, int size)
{
    AV3AMemoryInput *input = opaque;
    int remaining = input->size - input->offset;
    if (!remaining) return AVERROR_EOF;
    if (size > remaining) size = remaining;
    memcpy(buf, input->data + input->offset, size);
    input->offset += size;
    return size;
}

static int verify_ts(uint8_t *frames)
{
    uint8_t ts[32 * 188];
    uint8_t pes[3 * FRAME_SIZE + 9];
    AVFormatContext *context;
    AVIOContext *io;
    /* 无 PAT/PMT 的 PES，用于确认内容探测确实接通了编码映射。 */
    memcpy(pes, "\x00\x00\x01\xc0\x0c\x03\x80\x00\x00", 9);
    memcpy(pes + 9, frames, 3 * FRAME_SIZE);
    int offset = 0, packets = 0;
    while (offset < (int)sizeof(pes)) {
        int bytes = (int)sizeof(pes) - offset;
        uint8_t *packet = ts + packets * 188;
        if (bytes > 184) bytes = 184;
        memset(packet, 0xff, 188);
        packet[0] = 0x47;
        packet[1] = 0x02 | (offset == 0 ? 0x40 : 0);
        packet[2] = 0x01;
        packet[3] = 0x10 | (packets & 15);
        int start = 4;
        if (bytes < 184) {
            packet[3] |= 0x20;
            packet[4] = 183 - bytes;
            if (packet[4]) packet[5] = 0;
            start = 188 - bytes;
        }
        memcpy(packet + start, pes + offset, bytes);
        offset += bytes;
        packets++;
    }
    /* 动态内存 IO 只供读取，不写出任何素材。 */
    AV3AMemoryInput input = {ts, packets * 188, 0};
    uint8_t *buffer = av_malloc(4096);
    AV3A_CHECK(buffer);
    io = avio_alloc_context(buffer, 4096, 0, &input, av3a_read_memory, NULL, NULL);
    AV3A_CHECK(io);
    context = avformat_alloc_context();
    AV3A_CHECK(context);
    context->pb = io;
    AV3A_CHECK(avformat_open_input(&context, NULL, av_find_input_format("mpegts"), NULL) >= 0);
    AV3A_CHECK(avformat_find_stream_info(context, NULL) >= 0);
    AV3A_CHECK(context->probesize == 5000000 && context->nb_programs == 0 && context->nb_streams == 1);
    AV3A_CHECK(context->streams[0]->codecpar->codec_id == AV_CODEC_ID_AV3A);
    AV3A_CHECK(context->streams[0]->codecpar->sample_rate == 48000);
    AV3A_CHECK(context->streams[0]->codecpar->ch_layout.nb_channels == 10);
    AV3A_CHECK(!verify_channel_metadata(context->streams[0], "channel-based", "10", "5.1.4", NULL, NULL));
    avformat_close_input(&context);
    av_freep(&io->buffer);
    avio_context_free(&io);
    return 0;
}

static int verify_raw(const uint8_t *frames, int prefix, int force_format)
{
    int size = prefix + 4 * FRAME_SIZE;
    uint8_t *data = av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE);
    AV3A_CHECK(data);
    memset(data, 0x55, prefix);
    memcpy(data + prefix, frames, 4 * FRAME_SIZE);
    AV3AMemoryInput input = {data, size, 0};
    /* 不可 seek 的小 IO 缓冲覆盖前导残片和帧头跨缓冲边界。 */
    AVIOContext *io = avio_alloc_context(av_malloc(4096), 4096, 0, &input, av3a_read_memory, NULL, NULL);
    AV3A_CHECK(io);
    AVFormatContext *context = avformat_alloc_context();
    AV3A_CHECK(context);
    context->pb = io;
    AV3A_CHECK(avformat_open_input(&context, NULL, force_format ? av_find_input_format("av3a") : NULL, NULL) >= 0);
    AV3A_CHECK(avformat_find_stream_info(context, NULL) >= 0);
    AV3A_CHECK(context->nb_streams == 1 && context->streams[0]->codecpar->codec_id == AV_CODEC_ID_AV3A);
    AV3A_CHECK(context->streams[0]->codecpar->sample_rate == 48000 && context->streams[0]->codecpar->ch_layout.nb_channels == 10);
    AV3A_CHECK(!verify_channel_metadata(context->streams[0], "channel-based", "10", "5.1.4", NULL, NULL));
    /* 裸流同步后仍须保留 MP4 配置，码率 384 kbit/s 使用大端序。 */
    AV3A_CHECK(context->streams[0]->codecpar->extradata_size == 10);
    AV3A_CHECK(context->streams[0]->codecpar->extradata[8] == 1 && context->streams[0]->codecpar->extradata[9] == 0x80);
    AVPacket *packet = av_packet_alloc();
    int count = 0;
    AV3A_CHECK(packet);
    while (av_read_frame(context, packet) >= 0) {
        if (packet->size >= HEADER_SIZE && !memcmp(packet->data, frames, HEADER_SIZE)) {
            AV3A_CHECK(packet->size == FRAME_SIZE && !memcmp(packet->data, frames, FRAME_SIZE));
            count++;
        }
        av_packet_unref(packet);
    }
    AV3A_CHECK(count == 4);
    av_packet_free(&packet);
    avformat_close_input(&context);
    av_freep(&io->buffer);
    avio_context_free(&io);
    av_free(data);
    return 0;
}

static int64_t av3a_seek_memory(void *opaque, int64_t offset, int whence)
{
    AV3AMemoryInput *input = opaque;
    int64_t position;
    if (whence == AVSEEK_SIZE) return input->size;
    whence &= ~AVSEEK_FORCE;
    position = whence == SEEK_SET ? offset : whence == SEEK_CUR ? input->offset + offset :
               whence == SEEK_END ? input->size + offset : -1;
    if (position < 0 || position > input->size) return AVERROR(EINVAL);
    input->offset = position;
    return position;
}

static void av3a_hash_packet(struct AVSHA *hash, const AVPacket *packet)
{
    uint8_t size[] = {packet->size >> 24, packet->size >> 16, packet->size >> 8, packet->size};
    av_sha_update(hash, size, sizeof(size));
    av_sha_update(hash, packet->data, packet->size);
}

/* Verify packet boundaries, payloads and codec configuration without decoding. */
static int verify_av3a_remux(AVFormatContext *input, const char *format)
{
    AVFormatContext *output = NULL, *reopened = NULL;
    AVPacket *packet = av_packet_alloc();
    struct AVSHA *hash = av_sha_alloc();
    uint8_t expected[32], actual[32], config[10], *data = NULL;
    int stream = -1, count = 0, retained = 0, ret, size;
    const AVCodecParameters *par;
    AVIOContext *io;
    AV3A_CHECK(packet && hash);
    for (unsigned i = 0; i < input->nb_streams; i++)
        if (input->streams[i]->codecpar->codec_id == AV_CODEC_ID_AV3A) { stream = i; break; }
    AV3A_CHECK(stream >= 0);
    par = input->streams[stream]->codecpar;
    AV3A_CHECK(par->extradata_size == 10);
    memcpy(config, par->extradata, sizeof(config));
    AV3A_CHECK(avformat_alloc_output_context2(&output, NULL, format, NULL) >= 0 && output);
    AVStream *out_stream = avformat_new_stream(output, NULL);
    AV3A_CHECK(out_stream && avcodec_parameters_copy(out_stream->codecpar, par) >= 0);
    out_stream->codecpar->codec_tag = 0;
    out_stream->time_base = input->streams[stream]->time_base;
    AV3A_CHECK(avio_open_dyn_buf(&output->pb) >= 0);
    AV3A_CHECK(avformat_write_header(output, NULL) >= 0);
    av_sha_init(hash, 256);
    while ((ret = av_read_frame(input, packet)) >= 0) {
        if (packet->stream_index == stream) {
            av3a_hash_packet(hash, packet);
            if (packet->pts == AV_NOPTS_VALUE)
                packet->pts = av_rescale_q((int64_t)count * 1024, (AVRational){1, par->sample_rate}, input->streams[stream]->time_base);
            if (packet->dts == AV_NOPTS_VALUE) packet->dts = packet->pts;
            av_packet_rescale_ts(packet, input->streams[stream]->time_base, out_stream->time_base);
            packet->stream_index = 0;
            packet->pos = -1;
            AV3A_CHECK(av_interleaved_write_frame(output, packet) >= 0);
            count++;
        }
        av_packet_unref(packet);
    }
    AV3A_CHECK(ret == AVERROR_EOF && count > 0);
    av_sha_final(hash, expected);
    AV3A_CHECK(av_write_trailer(output) >= 0);
    size = avio_close_dyn_buf(output->pb, &data);
    output->pb = NULL;
    AV3A_CHECK(size > 0);
    avformat_free_context(output);
    AV3AMemoryInput memory = {data, size, 0};
    io = avio_alloc_context(av_malloc(4096), 4096, 0, &memory, av3a_read_memory, NULL, av3a_seek_memory);
    AV3A_CHECK(io);
    reopened = avformat_alloc_context();
    AV3A_CHECK(reopened);
    reopened->pb = io;
    AV3A_CHECK(avformat_open_input(&reopened, NULL, av_find_input_format(!strcmp(format, "mp4") ? "mov" : format), NULL) >= 0);
    AV3A_CHECK(avformat_find_stream_info(reopened, NULL) >= 0 && reopened->nb_streams == 1);
    AVCodecParameters *roundtrip = reopened->streams[0]->codecpar;
    AV3A_CHECK(roundtrip->codec_id == AV_CODEC_ID_AV3A && roundtrip->sample_rate == par->sample_rate);
    AV3A_CHECK(roundtrip->ch_layout.nb_channels == par->ch_layout.nb_channels);
    AV3A_CHECK(roundtrip->extradata_size == sizeof(config) && !memcmp(roundtrip->extradata, config, sizeof(config)));
    av_sha_init(hash, 256);
    while ((ret = av_read_frame(reopened, packet)) >= 0) {
        av3a_hash_packet(hash, packet);
        retained++;
        av_packet_unref(packet);
    }
    av_sha_final(hash, actual);
    AV3A_CHECK(ret == AVERROR_EOF && retained == count && !memcmp(expected, actual, sizeof(expected)));
    printf("  AV3A %s roundtrip: %d packets, configuration and SHA-256 match\n", format, count);
    av_packet_free(&packet);
    av_free(hash);
    avformat_close_input(&reopened);
    av_freep(&io->buffer);
    avio_context_free(&io);
    av_free(data);
    return 0;
}

static int verify_av3a_invalid_config(void)
{
    for (int test = 0; test < 2; test++) {
        AVFormatContext *output = NULL;
        AVPacket *packet = av_packet_alloc();
        uint8_t *data = NULL;
        int ret;
        AV3A_CHECK(packet && avformat_alloc_output_context2(&output, NULL, "mp4", NULL) >= 0 && output);
        AVStream *stream = avformat_new_stream(output, NULL);
        AV3A_CHECK(stream);
        stream->time_base = (AVRational){1, 48000};
        stream->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
        stream->codecpar->codec_id = AV_CODEC_ID_AV3A;
        stream->codecpar->sample_rate = 48000;
        stream->codecpar->frame_size = 1024;
        stream->codecpar->ch_layout.nb_channels = 10;
        if (test) {
            stream->codecpar->extradata = av_mallocz(9 + AV_INPUT_BUFFER_PADDING_SIZE);
            AV3A_CHECK(stream->codecpar->extradata);
            stream->codecpar->extradata_size = 9; /* Truncated configuration. */
        }
        AV3A_CHECK(avio_open_dyn_buf(&output->pb) >= 0);
        ret = avformat_write_header(output, NULL);
        if (ret >= 0) {
            AV3A_CHECK(av_new_packet(packet, FRAME_SIZE) >= 0);
            make_frame(packet->data);
            packet->pts = packet->dts = 0;
            packet->duration = 1024;
            AV3A_CHECK(av_interleaved_write_frame(output, packet) >= 0);
            ret = av_write_trailer(output);
        }
        AV3A_CHECK(ret < 0);
        avio_close_dyn_buf(output->pb, &data);
        output->pb = NULL;
        av_free(data);
        avformat_free_context(output);
        av_packet_free(&packet);
    }
    return 0;
}

static int verify_av3a_muxers(const uint8_t *frames)
{
    const char *formats[] = {"mp4", "mpegts", "av3a"};
    const AVOutputFormat *mp4 = av_guess_format("mp4", NULL, NULL);
    AV3A_CHECK(mp4 && avformat_query_codec(mp4, AV_CODEC_ID_AV3A, 0) > 0);
    for (unsigned i = 0; i < sizeof(formats) / sizeof(formats[0]); i++) {
        AV3AMemoryInput memory = {frames, 4 * FRAME_SIZE, 0};
        AVIOContext *io = avio_alloc_context(av_malloc(4096), 4096, 0, &memory, av3a_read_memory, NULL, NULL);
        AVFormatContext *input = avformat_alloc_context();
        AV3A_CHECK(io && input);
        input->pb = io;
        AV3A_CHECK(avformat_open_input(&input, NULL, av_find_input_format("av3a"), NULL) >= 0);
        AV3A_CHECK(avformat_find_stream_info(input, NULL) >= 0);
        AV3A_CHECK(!verify_av3a_remux(input, formats[i]));
        avformat_close_input(&input);
        av_freep(&io->buffer);
        avio_context_free(&io);
    }
    return 0;
}

static int verify_av3a_file(const char *path)
{
    const char *formats[] = {"mp4", "mpegts", "av3a"};
    for (unsigned i = 0; i < sizeof(formats) / sizeof(formats[0]); i++) {
        AVFormatContext *input = NULL;
        AV3A_CHECK(avformat_open_input(&input, path, NULL, NULL) >= 0);
        AV3A_CHECK(avformat_find_stream_info(input, NULL) >= 0);
        AV3A_CHECK(!verify_av3a_remux(input, formats[i]));
        avformat_close_input(&input);
    }
    return 0;
}

static int verify_metadata_changes(void)
{
    static const uint8_t headers[][HEADER_SIZE] = {
        {0xff, 0xf2, 0x10, 0x52, 0x42, 0x11, 0xb8, 0x0c, 0x24},
        {0xff, 0xf2, 0x12, 0x46, 0xa8, 0xa4, 0x07, 0x6d, 0x88},
        {0xff, 0xf2, 0x14, 0x40, 0x04, 0x98, 0x00, 0x00, 0x00},
        {0xff, 0xf2, 0x12, 0x40, 0x00, 0x34, 0x40, 0x00, 0x00}
    };
    static const int sizes[] = {1024, 4267, 1366, 683};
    uint8_t *data = av_mallocz(3 * (1024 + 4267 + 1366 + 683) + AV_INPUT_BUFFER_PADDING_SIZE);
    AVFormatContext *input = avformat_alloc_context();
    AVPacket *packet = av_packet_alloc();
    int size = 0, count = 0, ret;
    AV3A_CHECK(data && input && packet);
    for (int config = 0; config < 4; config++) {
        for (int frame = 0; frame < 3; frame++) {
            memset(data + size, 0x55, sizes[config]);
            memcpy(data + size, headers[config], HEADER_SIZE);
            size += sizes[config];
        }
    }
    AV3AMemoryInput memory = {data, size, 0};
    AVIOContext *io = avio_alloc_context(av_malloc(4096), 4096, 0, &memory, av3a_read_memory, NULL, NULL);
    AV3A_CHECK(io);
    input->pb = io;
    AV3A_CHECK(avformat_open_input(&input, NULL, av_find_input_format("av3a"), NULL) >= 0);
    /* 不提前探测，逐帧验证配置切换会更新字段并清理旧字段。 */
    while ((ret = av_read_frame(input, packet)) >= 0) {
        int config = count / 3;
        AV3A_CHECK(config < 4 && packet->size == sizes[config]);
        AV3A_CHECK(!!(input->streams[0]->event_flags & AVSTREAM_EVENT_FLAG_METADATA_UPDATED) == (count % 3 == 0));
        input->streams[0]->event_flags &= ~AVSTREAM_EVENT_FLAG_METADATA_UPDATED;
        if (config == 0)
            AV3A_CHECK(!verify_channel_metadata(input->streams[0], "channel-based", "10", "5.1.4", NULL, NULL));
        else if (config == 1)
            AV3A_CHECK(!verify_channel_metadata(input->streams[0], "channels+objects", "12", "7.1.4", "4", NULL));
        else if (config == 2)
            AV3A_CHECK(!verify_channel_metadata(input->streams[0], "HOA", NULL, NULL, NULL, "3"));
        else
            AV3A_CHECK(!verify_channel_metadata(input->streams[0], "object-based", NULL, NULL, "4", NULL));
        count++;
        av_packet_unref(packet);
    }
    AV3A_CHECK(ret == AVERROR_EOF && count == 12);
    av_packet_free(&packet);
    avformat_close_input(&input);
    av_freep(&io->buffer);
    avio_context_free(&io);
    av_free(data);
    return 0;
}

static int verify_av3a(void)
{
    uint8_t frames[4 * FRAME_SIZE + AV_INPUT_BUFFER_PADDING_SIZE] = {0};
    const AVCodecDescriptor *desc = avcodec_descriptor_get(AV_CODEC_ID_AV3A);
    AV3A_CHECK(desc && !strcmp(desc->name, "av3a") && desc->type == AVMEDIA_TYPE_AUDIO);
    for (int i = 0; i < 4; i++) make_frame(frames + i * FRAME_SIZE);
    AV3A_CHECK(probe_is_av3a(frames, 3 * FRAME_SIZE));
    AV3A_CHECK(probe_is_av3a(frames + 1, 4 * FRAME_SIZE - 1));
    AV3A_CHECK(!probe_is_av3a(frames, FRAME_SIZE));
    AV3A_CHECK(!probe_is_av3a(frames, 3 * FRAME_SIZE - 1));
    for (int size = 0; size < HEADER_SIZE; size++) AV3A_CHECK(!probe_is_av3a(frames, size));
    /* 单字节字段损坏不能仅凭同步字和扩展名被确认。 */
    frames[2 * FRAME_SIZE + 2] = 0xff;
    AV3A_CHECK(!probe_is_av3a(frames, 3 * FRAME_SIZE));
    make_frame(frames + 2 * FRAME_SIZE);
    for (int chunk = 1; chunk <= 4096; chunk = chunk == 1 ? 7 : chunk == 7 ? 188 : chunk == 188 ? 1024 : chunk == 1024 ? 4096 : 4097)
        AV3A_CHECK(!verify_parser(frames, 4 * FRAME_SIZE, chunk, FRAME_SIZE, 384000));
    /* 非 1024 字节帧覆盖整数取整及一包多帧/跨包多次拼接。 */
    {
        static const int sizes[] = {470, 683, 1878};
        static const int rates[] = {176000, 256000, 704000};
        static const int indexes[] = {0, 4, 3};
        uint8_t varied[4 * 1878 + AV_INPUT_BUFFER_PADDING_SIZE] = {0};
        for (int test = 0; test < 3; test++) {
            memset(varied, 0x55, 4 * sizes[test]);
            for (int frame = 0; frame < 4; frame++) {
                memcpy(varied + frame * sizes[test], frames, HEADER_SIZE);
                varied[frame * sizes[test] + 5] = (varied[frame * sizes[test] + 5] & 0xf0) | indexes[test];
            }
            AV3A_CHECK(probe_is_av3a(varied, 3 * sizes[test]));
            AV3A_CHECK(!verify_parser(varied, 4 * sizes[test], 7, sizes[test], rates[test]));
            AV3A_CHECK(!verify_parser(varied, 4 * sizes[test], 1024, sizes[test], rates[test]));
        }
    }
    AV3A_CHECK(!verify_av3a_invalid_config());
    AV3A_CHECK(!verify_av3a_muxers(frames));
    {
        uint8_t ambisonic[sizeof(frames)];
        memcpy(ambisonic, frames, sizeof(frames));
        for (int i = 0; i < 4; i++) {
            /* AATF profile 2, second-order HOA, 48 kHz, 384 kbit/s. */
            ambisonic[i * FRAME_SIZE + 2] = 0x14;
            ambisonic[i * FRAME_SIZE + 5] = 0x99;
        }
        AV3A_CHECK(!verify_av3a_muxers(ambisonic));
    }
    AV3A_CHECK(!verify_corruption(frames));
    AV3A_CHECK(!verify_metadata_changes());
    AV3A_CHECK(!verify_ts(frames));
    for (int forced = 0; forced <= 1; forced++) {
        AV3A_CHECK(!verify_raw(frames, 0, forced));
        AV3A_CHECK(!verify_raw(frames, 1, forced));
        AV3A_CHECK(!verify_raw(frames, 187, forced));
        AV3A_CHECK(!verify_raw(frames, 4092, forced));
    }
    puts("AV3A probe, fragmented parser, metadata changes, raw input and table-free TS passed");
    return 0;
}

#undef AV3A_CHECK
#endif
