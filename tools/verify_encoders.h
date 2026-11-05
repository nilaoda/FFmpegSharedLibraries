#ifndef VERIFY_ENCODERS_H
#define VERIFY_ENCODERS_H

#include "libavutil/intreadwrite.h"
#include "libavutil/samplefmt.h"

static int encoder_receive_frames(AVCodecContext *decoder, AVFrame *frame,
                                  const AVCodecContext *encoder, int *count)
{
    int ret;
    while ((ret = avcodec_receive_frame(decoder, frame)) >= 0) {
        if (frame->width != encoder->width || frame->height != encoder->height || frame->format != encoder->pix_fmt)
            return AVERROR_INVALIDDATA;
        if (encoder->field_order == AV_FIELD_TT || encoder->field_order == AV_FIELD_BB) {
            if (!(frame->flags & AV_FRAME_FLAG_INTERLACED) ||
                !!(frame->flags & AV_FRAME_FLAG_TOP_FIELD_FIRST) != (encoder->field_order == AV_FIELD_TT))
                return AVERROR_INVALIDDATA;
        }
        ++*count;
        av_frame_unref(frame);
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

/* 用短合成画面验证编码、延迟包排空和解码，避免只检查编码器名称。 */
static int verify_video_encoder(const char *name, enum AVPixelFormat format, int depth,
                                enum AVFieldOrder field_order)
{
    const AVCodec *codec = avcodec_find_encoder_by_name(name);
    const AVCodec *decode_codec;
    AVCodecContext *encoder = NULL, *decoder = NULL;
    AVCodecParameters *parameters = avcodec_parameters_alloc();
    AVFrame *frame = av_frame_alloc(), *decoded = av_frame_alloc();
    AVPacket *packet = av_packet_alloc();
    AVDictionary *options = NULL;
    int ret = codec ? AVERROR(ENOMEM) : AVERROR_ENCODER_NOT_FOUND, frames = 0, packets = 0;
    const int frame_count = 6;
    const int interlaced = field_order == AV_FIELD_TT || field_order == AV_FIELD_BB;
    const char *scan = field_order == AV_FIELD_TT ? "1080i50 TFF" : interlaced ? "1080i50 BFF" : "progressive";
    if (!codec || !parameters || !frame || !decoded || !packet)
        goto end;
    encoder = avcodec_alloc_context3(codec);
    if (!encoder)
        goto end;
    encoder->width = interlaced ? 1920 : 64;
    encoder->height = interlaced ? 1080 : 64;
    encoder->field_order = field_order;
    if (interlaced)
        encoder->flags |= AV_CODEC_FLAG_INTERLACED_DCT | AV_CODEC_FLAG_INTERLACED_ME;
    encoder->pix_fmt = format;
    encoder->time_base = (AVRational){1, 25};
    encoder->framerate = (AVRational){25, 1};
    encoder->thread_count = 1;
    encoder->bit_rate = interlaced ? 10000000 : 100000;
    encoder->gop_size = 12;
    encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (codec->id == AV_CODEC_ID_H264 || codec->id == AV_CODEC_ID_HEVC) {
        encoder->max_b_frames = 2;
        av_dict_set(&options, "preset", "ultrafast", 0);
        if (codec->id == AV_CODEC_ID_HEVC)
            av_dict_set(&options, "x265-params", "pools=none:frame-threads=1:log-level=error", 0);
    } else if (codec->id == AV_CODEC_ID_VP8 || codec->id == AV_CODEC_ID_VP9) {
        av_dict_set(&options, "deadline", "realtime", 0);
        av_dict_set(&options, "cpu-used", "8", 0);
        av_dict_set(&options, "lag-in-frames", "0", 0);
    } else if (!strcmp(name, "libsvtav1")) {
        av_dict_set(&options, "preset", "12", 0);
        av_dict_set(&options, "svtav1-params", "lp=1:lookahead=0", 0);
    } else if (codec->id == AV_CODEC_ID_AV1) {
        av_dict_set(&options, "usage", "realtime", 0);
        av_dict_set(&options, "cpu-used", "8", 0);
        av_dict_set(&options, "lag-in-frames", "0", 0);
    }
    ret = avcodec_open2(encoder, codec, &options);
    if (ret < 0)
        goto end;
    ret = avcodec_parameters_from_context(parameters, encoder);
    if (ret < 0)
        goto end;
    decode_codec = codec->id == AV_CODEC_ID_AV1 ? avcodec_find_decoder_by_name("libaom-av1")
                                              : avcodec_find_decoder(codec->id);
    decoder = avcodec_alloc_context3(decode_codec);
    if (!decode_codec || !decoder) {
        ret = AVERROR_DECODER_NOT_FOUND;
        goto end;
    }
    ret = avcodec_parameters_to_context(decoder, parameters);
    if (ret < 0)
        goto end;
    decoder->thread_count = 1;
    ret = avcodec_open2(decoder, decode_codec, NULL);
    if (ret < 0)
        goto end;
    frame->format = format;
    frame->width = encoder->width;
    frame->height = encoder->height;
    if (interlaced) {
        frame->flags |= AV_FRAME_FLAG_INTERLACED;
        if (field_order == AV_FIELD_TT)
            frame->flags |= AV_FRAME_FLAG_TOP_FIELD_FIRST;
    }
    ret = av_frame_get_buffer(frame, 32);
    if (ret < 0)
        goto end;
    for (int index = 0; index <= frame_count; ++index) {
        if (index < frame_count) {
            ret = av_frame_make_writable(frame);
            if (ret < 0)
                goto end;
            frame->pts = index;
            for (int plane = 0; plane < 3; ++plane) {
                int width = plane ? frame->width / 2 : frame->width;
                int height = plane ? frame->height / 2 : frame->height;
                for (int y = 0; y < height; ++y) {
                    uint8_t *row = frame->data[plane] + y * frame->linesize[plane];
                    for (int x = 0; x < width; ++x) {
                        int time = interlaced ? index * 2 + ((y & 1) ^ (field_order == AV_FIELD_BB)) : index;
                        int value = plane ? 128 : 32 + ((x + y + time * 11) % 160);
                        if (depth > 8)
                            AV_WL16(row + x * 2, value << (depth - 8));
                        else
                            row[x] = value;
                    }
                }
            }
        }
        ret = avcodec_send_frame(encoder, index < frame_count ? frame : NULL);
        if (ret < 0)
            goto end;
        while ((ret = avcodec_receive_packet(encoder, packet)) >= 0) {
            ++packets;
            ret = avcodec_send_packet(decoder, packet);
            av_packet_unref(packet);
            if (ret < 0)
                goto end;
            ret = encoder_receive_frames(decoder, decoded, encoder, &frames);
            if (ret < 0)
                goto end;
        }
        if (ret != (index < frame_count ? AVERROR(EAGAIN) : AVERROR_EOF)) {
            ret = ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? AVERROR_INVALIDDATA : ret;
            goto end;
        }
    }
    ret = avcodec_send_packet(decoder, NULL);
    if (ret < 0)
        goto end;
    ret = encoder_receive_frames(decoder, decoded, encoder, &frames);
    if (ret >= 0 && (frames != frame_count || packets == 0))
        ret = AVERROR_INVALIDDATA;
end:
    if (ret < 0) {
        char error[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(ret, error, sizeof(error));
        fprintf(stderr, "Video encoder %s/%d-bit/%s failed: %s (%d frames, %d packets)\n",
                name, depth, scan, error, frames, packets);
    } else {
        printf("Video encoder %s/%d-bit/%s: %d frames round-tripped\n", name, depth, scan, frames);
    }
    av_dict_free(&options);
    av_packet_free(&packet);
    av_frame_free(&frame);
    av_frame_free(&decoded);
    avcodec_parameters_free(&parameters);
    avcodec_free_context(&encoder);
    avcodec_free_context(&decoder);
    return ret < 0;
}

/* 音频使用内存中的静音样本，不访问音频设备或外部素材。 */
static int verify_audio_encoder(const char *name)
{
    const AVCodec *codec = avcodec_find_encoder_by_name(name);
    AVCodecContext *encoder = avcodec_alloc_context3(codec);
    AVFrame *frame = av_frame_alloc();
    AVPacket *packet = av_packet_alloc();
    const enum AVSampleFormat *formats = NULL;
    int ret = codec ? AVERROR(ENOMEM) : AVERROR_ENCODER_NOT_FOUND, count = 0, packets = 0;
    if (!codec || !encoder || !frame || !packet)
        goto end;
    encoder->sample_rate = 48000;
    encoder->time_base = (AVRational){1, 48000};
    encoder->bit_rate = 128000;
    encoder->thread_count = 1;
    av_channel_layout_default(&encoder->ch_layout, 2);
    ret = avcodec_get_supported_config(encoder, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0,
                                       (const void **)&formats, &count);
    if (ret < 0 || !formats || count < 1) {
        ret = AVERROR(EINVAL);
        goto end;
    }
    encoder->sample_fmt = formats[0];
    ret = avcodec_open2(encoder, codec, NULL);
    if (ret < 0)
        goto end;
    frame->format = encoder->sample_fmt;
    frame->sample_rate = encoder->sample_rate;
    frame->nb_samples = encoder->frame_size ? encoder->frame_size : 1024;
    ret = av_channel_layout_copy(&frame->ch_layout, &encoder->ch_layout);
    if (ret < 0)
        goto end;
    ret = av_frame_get_buffer(frame, 0);
    if (ret < 0)
        goto end;
    for (int index = 0; index <= 3; ++index) {
        if (index < 3) {
            ret = av_frame_make_writable(frame);
            if (ret < 0)
                goto end;
            av_samples_set_silence(frame->extended_data, 0, frame->nb_samples, 2, encoder->sample_fmt);
            frame->pts = (int64_t)index * frame->nb_samples;
        }
        ret = avcodec_send_frame(encoder, index < 3 ? frame : NULL);
        if (ret < 0)
            goto end;
        while ((ret = avcodec_receive_packet(encoder, packet)) >= 0) {
            packets += packet->size > 0;
            av_packet_unref(packet);
        }
        if (ret != (index < 3 ? AVERROR(EAGAIN) : AVERROR_EOF)) {
            ret = ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? AVERROR_INVALIDDATA : ret;
            goto end;
        }
    }
    ret = packets > 0 ? 0 : AVERROR_INVALIDDATA;
end:
    if (ret < 0) {
        char error[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(ret, error, sizeof(error));
        fprintf(stderr, "Audio encoder %s failed: %s\n", name, error);
    } else {
        printf("Audio encoder %s: %d packets encoded and drained\n", name, packets);
    }
    av_packet_free(&packet);
    av_frame_free(&frame);
    avcodec_free_context(&encoder);
    return ret < 0;
}

static int verify_encoders(void)
{
    const char *required[] = {
        "png", "mjpeg", "bmp", "tiff", "gif", "apng", "ass", "mov_text", "srt", "webvtt", "dvbsub", "dvdsub",
        "mpeg1video", "mpeg2video", "mpeg4", "ffv1", "huffyuv", "ffvhuff", "utvideo", "prores_ks", "dnxhd", "rawvideo",
        "aac", "ac3", "ac3_fixed", "eac3", "mp2", "mp2fixed", "alac", "flac", "wavpack", "tta",
        "pcm_s8", "pcm_u8", "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be",
        "pcm_f32le", "pcm_f32be", "pcm_f64le", "pcm_f64be", "pcm_alaw", "pcm_mulaw",
        "libmp3lame", "libopus", "libvorbis", "libvpx", "libvpx-vp9", "libaom-av1", "libsvtav1", "libx264", "libx264rgb", "libx265"
    };
    for (unsigned i = 0; i < sizeof(required) / sizeof(required[0]); ++i) {
        if (!avcodec_find_encoder_by_name(required[i])) {
            fprintf(stderr, "Missing software encoder: %s\n", required[i]);
            return 1;
        }
    }
    const struct {
        const char *name;
        enum AVPixelFormat format;
        int depth;
        enum AVFieldOrder field_order;
    } videos[] = {
        {"libx264", AV_PIX_FMT_YUV420P, 8, AV_FIELD_PROGRESSIVE}, {"libx264", AV_PIX_FMT_YUV420P10LE, 10, AV_FIELD_PROGRESSIVE},
        {"libx265", AV_PIX_FMT_YUV420P, 8, AV_FIELD_PROGRESSIVE}, {"libx265", AV_PIX_FMT_YUV420P10LE, 10, AV_FIELD_PROGRESSIVE},
        {"libx265", AV_PIX_FMT_YUV420P12LE, 12, AV_FIELD_PROGRESSIVE}, {"mpeg2video", AV_PIX_FMT_YUV420P, 8, AV_FIELD_PROGRESSIVE},
        {"libvpx", AV_PIX_FMT_YUV420P, 8, AV_FIELD_PROGRESSIVE}, {"libvpx-vp9", AV_PIX_FMT_YUV420P10LE, 10, AV_FIELD_PROGRESSIVE},
        {"libaom-av1", AV_PIX_FMT_YUV420P10LE, 10, AV_FIELD_PROGRESSIVE}, {"libsvtav1", AV_PIX_FMT_YUV420P10LE, 10, AV_FIELD_PROGRESSIVE},
        {"libx264", AV_PIX_FMT_YUV420P, 8, AV_FIELD_TT}, {"libx264", AV_PIX_FMT_YUV420P, 8, AV_FIELD_BB},
        {"mpeg2video", AV_PIX_FMT_YUV420P, 8, AV_FIELD_TT}, {"mpeg2video", AV_PIX_FMT_YUV420P, 8, AV_FIELD_BB}
    };
    const char *audio[] = {"aac", "libmp3lame", "libopus", "libvorbis", "flac"};
    for (unsigned i = 0; i < sizeof(videos) / sizeof(videos[0]); ++i)
        if (verify_video_encoder(videos[i].name, videos[i].format, videos[i].depth, videos[i].field_order))
            return 1;
    for (unsigned i = 0; i < sizeof(audio) / sizeof(audio[0]); ++i)
        if (verify_audio_encoder(audio[i]))
            return 1;
    return 0;
}
#endif
