/* Compile against the built runtime, not the system FFmpeg. See README.md. */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libavcodec/avcodec.h"
#include "libavdevice/avdevice.h"
#include "libavfilter/avfilter.h"
#include "libavformat/avformat.h"
#include "libavutil/dict.h"
#include "libavutil/opt.h"
#include "libswresample/swresample.h"
#include "libswscale/swscale.h"

typedef struct SeenPacket {
    int64_t pos;
    int flags;
} SeenPacket;

static int decode_window(AVFormatContext *input, AVCodecContext *decoder,
                         int stream, int limit, int export_pos)
{
    SeenPacket seen[2048];
    unsigned sent = 0;
    int frames = 0, keys = 0, errors = 0, draining = 0, positioned = 0;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int ret = 0;

    if (!packet || !frame) {
        ret = AVERROR(ENOMEM);
        goto end;
    }
    while (frames < limit && sent < 10000) {
        ret = avcodec_receive_frame(decoder, frame);
        if (ret == 0) {
            const AVDictionaryEntry *entry = av_dict_get(frame->metadata,
                                                        "tscutter.packet_pos", NULL, 0);
            frames++;
            keys += !!(frame->flags & AV_FRAME_FLAG_KEY);
            if (export_pos) {
                int found = 0;
                int64_t pos = entry ? strtoll(entry->value, NULL, 10) : -1;
                for (unsigned i = 0; i < sent && i < 2048; i++)
                    found |= seen[i].pos == pos && pos >= 0;
                if (!found) {
                    fprintf(stderr, "Frame %d: unknown packet position %" PRId64 "\n", frames, pos);
                    errors++;
                } else {
                    positioned++;
                }
                /* CAVS must retain the originating packet through B-frame reordering. */
                if (decoder->codec_id == AV_CODEC_ID_CAVS &&
                    (!frame->opaque || pos != (int64_t)(intptr_t)frame->opaque - 1)) {
                    fprintf(stderr, "CAVS opaque/position mismatch\n");
                    errors++;
                }
                if (frame->flags & AV_FRAME_FLAG_KEY) {
                    int matched = 0;
                    for (unsigned i = 0; i < sent && i < 2048; i++)
                        matched |= seen[i].pos == pos && (seen[i].flags & AV_PKT_FLAG_KEY);
                    if (!matched) {
                        fprintf(stderr, "Keyframe position does not identify a key packet\n");
                        errors++;
                    }
                }
            } else if (entry) {
                fprintf(stderr, "Position metadata allocated while disabled\n");
                errors++;
            }
            if (frames <= 3)
                printf("  frame=%d pts=%" PRId64 " type=%c key=%d pos=%s\n",
                       frames, frame->pts, av_get_picture_type_char(frame->pict_type),
                       !!(frame->flags & AV_FRAME_FLAG_KEY), entry ? entry->value : "disabled");
            av_frame_unref(frame);
            continue;
        }
        if (ret == AVERROR_EOF)
            break;
        if (ret != AVERROR(EAGAIN))
            goto end;
        if (draining) {
            ret = AVERROR_BUG;
            goto end;
        }
        do {
            av_packet_unref(packet);
            ret = av_read_frame(input, packet);
        } while (ret >= 0 && packet->stream_index != stream);
        if (ret == AVERROR_EOF) {
            ret = avcodec_send_packet(decoder, NULL);
            draining = 1;
        } else if (ret >= 0) {
            seen[sent % 2048] = (SeenPacket){packet->pos, packet->flags};
            sent++;
            packet->opaque = (void *)(intptr_t)(packet->pos + 1);
            ret = avcodec_send_packet(decoder, packet);
        }
        if (ret < 0)
            goto end;
    }
    printf("  decoded=%d keys=%d positioned=%d packets=%u errors=%d\n",
           frames, keys, positioned, sent, errors);
    ret = frames > 0 && !errors ? 0 : AVERROR_INVALIDDATA;
end:
    av_packet_free(&packet);
    av_frame_free(&frame);
    return ret;
}

int main(int argc, char **argv)
{
    const char *names[] = {"cavs", "libdra", "libdavs2", "libuavs3d"};
    AVFormatContext *input = NULL;
    AVCodecContext *decoder = NULL;
    const AVCodec *codec = NULL;
    int ret, stream, export_pos, frame_limit = 64;
    char error[AV_ERROR_MAX_STRING_SIZE];

    printf("FFmpeg=%s avcodec=%u avformat=%u avutil=%u\n", av_version_info(),
           avcodec_version() >> 16, avformat_version() >> 16, avutil_version() >> 16);
    if (avcodec_version() >> 16 != 63 || avformat_version() >> 16 != 63 ||
        avutil_version() >> 16 != 61 || avdevice_version() >> 16 != 63 ||
        avfilter_version() >> 16 != 12 || swscale_version() >> 16 != 10 ||
        swresample_version() >> 16 != 7)
        return 1;
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (!avcodec_find_decoder_by_name(names[i])) {
            fprintf(stderr, "Missing decoder: %s\n", names[i]);
            return 1;
        }
    }
    if (argc < 2)
        return 0;
    if (argc > 3) {
        frame_limit = atoi(argv[3]);
        if (frame_limit < 1 || frame_limit > 10000)
            return 1;
    }
    av_log_set_level(AV_LOG_ERROR);
    ret = avformat_open_input(&input, argv[1],
                             argc > 2 && !strcmp(argv[2], "cavsvideo") ?
                             av_find_input_format("cavsvideo") : NULL, NULL);
    if (ret < 0) goto end;
    ret = avformat_find_stream_info(input, NULL);
    if (ret < 0) goto end;
    if (argc > 2 && !strcmp(argv[2], "dra")) {
        stream = AVERROR_STREAM_NOT_FOUND;
        for (unsigned i = 0; i < input->nb_streams; i++)
            if (input->streams[i]->codecpar->codec_id == AV_CODEC_ID_DRA) {
                stream = i;
                codec = avcodec_find_decoder(AV_CODEC_ID_DRA);
                break;
            }
    } else {
        stream = av_find_best_stream(input, argc > 2 && !strcmp(argv[2], "audio") ?
                                AVMEDIA_TYPE_AUDIO : AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    }
    if (stream < 0) { ret = stream; goto end; }
    decoder = avcodec_alloc_context3(codec);
    if (!decoder) { ret = AVERROR(ENOMEM); goto end; }
    ret = avcodec_parameters_to_context(decoder, input->streams[stream]->codecpar);
    if (ret < 0) goto end;
    decoder->pkt_timebase = input->streams[stream]->time_base;
    decoder->thread_count = 2;
    decoder->flags |= AV_CODEC_FLAG_COPY_OPAQUE;
    export_pos = decoder->priv_data &&
                 av_opt_find(decoder->priv_data, "export_packet_pos", NULL, 0, 0) != NULL;
    if (export_pos) {
        ret = av_opt_set_int(decoder->priv_data, "export_packet_pos", 1, 0);
        if (ret < 0) goto end;
    }
    printf("Sample=%s decoder=%s dimensions=%dx%d\n", argv[1], codec->name,
           decoder->width, decoder->height);
    ret = avcodec_open2(decoder, codec, NULL);
    if (ret < 0) goto end;
    ret = decode_window(input, decoder, stream, frame_limit, export_pos);
    if (ret < 0) goto end;
    /* Raw CAVS may start before its first decodable keyframe. Seek to an indexed key. */
    int64_t target = input->streams[stream]->start_time == AV_NOPTS_VALUE ?
                     0 : input->streams[stream]->start_time;
    if (!strcmp(input->iformat->name, "cavsvideo")) {
        const AVIndexEntry *first = avformat_index_get_entry(input->streams[stream], 0);
        if (first)
            target = first->timestamp + 1;
    }
    ret = frame_limit > 64 && strcmp(input->iformat->name, "cavsvideo") ?
          av_seek_frame(input, -1, 0, AVSEEK_FLAG_BYTE) :
          av_seek_frame(input, stream, target, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) goto end;
    avcodec_flush_buffers(decoder);
    if (export_pos) {
        ret = av_opt_set_int(decoder->priv_data, "export_packet_pos", 0, 0);
        if (ret < 0) goto end;
    }
    ret = decode_window(input, decoder, stream, 24, 0);
end:
    if (ret < 0) {
        av_strerror(ret, error, sizeof(error));
        fprintf(stderr, "FAIL: %s\n", error);
    }
    avcodec_free_context(&decoder);
    avformat_close_input(&input);
    return ret < 0;
}
