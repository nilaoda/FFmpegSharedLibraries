#ifndef VERIFY_SUBTITLES_H
#define VERIFY_SUBTITLES_H

#include <limits.h>
#include <stdio.h>
#include <string.h>

#include <ass/ass.h>
#include "libavcodec/avcodec.h"
#include "libavfilter/avfilter.h"
#include "libavutil/mem.h"

#define SUBTITLE_CHECK(cond) do { if (!(cond)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #cond); return 1; } } while (0)

/* 检查真实的非透明像素，避免只验证注册成功而未实际生成字幕。 */
static int subtitle_image_left(const ASS_Image *image)
{
    int left = INT_MAX;
    for (; image; image = image->next) {
        if ((image->color & 255) == 255) continue;
        for (int y = 0; y < image->h; y++)
            for (int x = 0; x < image->w; x++)
                if (image->bitmap[y * image->stride + x] && image->dst_x + x < left)
                    left = image->dst_x + x;
    }
    return left;
}

static int verify_ass_render(void)
{
    /* 直接从 avfilter 链接全部公开接口，避免只导出滤镜自身用到的一部分函数。 */
    void (*volatile public_api[])(void) = {
        (void (*)(void))ass_library_init,
        (void (*)(void))ass_library_done,
        (void (*)(void))ass_library_version,
        (void (*)(void))ass_set_fonts_dir,
        (void (*)(void))ass_set_extract_fonts,
        (void (*)(void))ass_set_style_overrides,
        (void (*)(void))ass_renderer_init,
        (void (*)(void))ass_renderer_done,
        (void (*)(void))ass_set_frame_size,
        (void (*)(void))ass_set_storage_size,
        (void (*)(void))ass_set_margins,
        (void (*)(void))ass_set_use_margins,
        (void (*)(void))ass_set_aspect_ratio,
        (void (*)(void))ass_set_font_scale,
        (void (*)(void))ass_set_hinting,
        (void (*)(void))ass_set_line_spacing,
        (void (*)(void))ass_get_available_font_providers,
        (void (*)(void))ass_set_fonts,
        (void (*)(void))ass_render_frame,
        (void (*)(void))ass_new_track,
        (void (*)(void))ass_free_track,
        (void (*)(void))ass_alloc_style,
        (void (*)(void))ass_alloc_event,
        (void (*)(void))ass_free_style,
        (void (*)(void))ass_free_event,
        (void (*)(void))ass_process_data,
        (void (*)(void))ass_process_codec_private,
        (void (*)(void))ass_process_chunk,
        (void (*)(void))ass_read_file,
        (void (*)(void))ass_read_memory,
        (void (*)(void))ass_read_styles,
        (void (*)(void))ass_add_font,
        (void (*)(void))ass_clear_fonts,
        (void (*)(void))ass_step_sub,
        (void (*)(void))ass_process_force_style,
        (void (*)(void))ass_set_message_cb,
        (void (*)(void))ass_fonts_update,
        (void (*)(void))ass_set_cache_limits,
        (void (*)(void))ass_flush_events,
        (void (*)(void))ass_set_shaper,
        (void (*)(void))ass_set_line_position,
        (void (*)(void))ass_set_pixel_aspect,
        (void (*)(void))ass_set_selective_style_override_enabled,
        (void (*)(void))ass_set_selective_style_override,
        (void (*)(void))ass_set_check_readorder,
        (void (*)(void))ass_track_set_feature,
        (void (*)(void))ass_malloc,
        (void (*)(void))ass_free,
        (void (*)(void))ass_prune_events,
        (void (*)(void))ass_configure_prune,
    };
    for (unsigned i = 0; i < sizeof(public_api) / sizeof(public_api[0]); i++)
        SUBTITLE_CHECK(public_api[i] != NULL);
    char script[] =
        "[Script Info]\nScriptType: v4.00+\nPlayResX: 320\nPlayResY: 180\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
        "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding\n"
        "Style: Default,sans-serif,24,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,"
        "0,0,0,0,100,100,0,0,1,1,0,4,0,0,0,1\n"
        "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\move(50,70,180,70,0,1000)}Preview\n";
    ASS_Library *library = ass_library_init();
    ASS_Renderer *renderer;
    ASS_Track *track;
    int changed, first, later;
    SUBTITLE_CHECK(library && ass_library_version() >= 0x01704000);
    renderer = ass_renderer_init(library);
    SUBTITLE_CHECK(renderer);
    ass_set_frame_size(renderer, 320, 180);
    ass_set_storage_size(renderer, 320, 180);
    ass_set_fonts(renderer, NULL, "sans-serif", ASS_FONTPROVIDER_AUTODETECT, NULL, 1);
    track = ass_read_memory(library, script, sizeof(script) - 1, NULL);
    SUBTITLE_CHECK(track);
    SUBTITLE_CHECK(ass_track_set_feature(track, ASS_FEATURE_WRAP_UNICODE, 1) == 0);
    SUBTITLE_CHECK(!ass_render_frame(renderer, track, 500, &changed));
    first = subtitle_image_left(ass_render_frame(renderer, track, 1500, &changed));
    later = subtitle_image_left(ass_render_frame(renderer, track, 2500, &changed));
    SUBTITLE_CHECK(first != INT_MAX && later > first && later != INT_MAX);
    SUBTITLE_CHECK(!ass_render_frame(renderer, track, 3500, &changed));
    /* 向前、向后跳转时间都应重建同一时刻的画面。 */
    SUBTITLE_CHECK(subtitle_image_left(ass_render_frame(renderer, track, 1500, &changed)) == first);
    ass_free_track(track);
    ass_renderer_done(renderer);
    ass_library_done(library);
    puts("libass rendering, animation, system fonts, Unicode wrapping and seeking passed");
    return 0;
}

static int verify_subtitles(void)
{
    const enum AVCodecID codecs[] = {
        AV_CODEC_ID_MOV_TEXT, AV_CODEC_ID_SUBRIP, AV_CODEC_ID_ASS, AV_CODEC_ID_WEBVTT,
        AV_CODEC_ID_HDMV_PGS_SUBTITLE, AV_CODEC_ID_DVB_SUBTITLE, AV_CODEC_ID_DVD_SUBTITLE, AV_CODEC_ID_EIA_608
    };
    AVCodecContext *decoder;
    AVPacket *packet;
    AVSubtitle subtitle = {0};
    int got = 0;
    for (unsigned i = 0; i < sizeof(codecs) / sizeof(codecs[0]); i++) {
        if (!avcodec_find_decoder(codecs[i])) {
            fprintf(stderr, "Missing subtitle decoder: %s\n", avcodec_get_name(codecs[i]));
            return 1;
        }
    }
    SUBTITLE_CHECK(avfilter_get_by_name("ass") && avfilter_get_by_name("subtitles"));
    decoder = avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_MOV_TEXT));
    packet = av_packet_alloc();
    SUBTITLE_CHECK(decoder && packet && avcodec_open2(decoder, NULL, NULL) >= 0);
    decoder->pkt_timebase = (AVRational){1, 1000};
    SUBTITLE_CHECK(av_new_packet(packet, 7) >= 0);
    memcpy(packet->data, "\0\5Hello", 7);
    packet->pts = 1000;
    packet->duration = 2000;
    SUBTITLE_CHECK(avcodec_decode_subtitle2(decoder, &subtitle, &got, packet) >= 0 && got);
    SUBTITLE_CHECK(subtitle.num_rects > 0 && subtitle.rects[0]->ass && strstr(subtitle.rects[0]->ass, "Hello"));
    /* Exercise both text encoders used by the muxer, including their ASS header. */
    const enum AVCodecID encoders[] = { AV_CODEC_ID_ASS, AV_CODEC_ID_MOV_TEXT };
    for (unsigned i = 0; i < sizeof(encoders) / sizeof(encoders[0]); i++) {
        const AVCodec *codec = avcodec_find_encoder(encoders[i]);
        SUBTITLE_CHECK(codec);
        AVCodecContext *encoder = avcodec_alloc_context3(codec);
        SUBTITLE_CHECK(encoder);
        encoder->time_base = (AVRational){1, 1000000};
        encoder->subtitle_header = av_mallocz(decoder->subtitle_header_size + 1);
        SUBTITLE_CHECK(encoder->subtitle_header);
        memcpy(encoder->subtitle_header, decoder->subtitle_header, decoder->subtitle_header_size);
        encoder->subtitle_header_size = decoder->subtitle_header_size;
        SUBTITLE_CHECK(avcodec_open2(encoder, NULL, NULL) >= 0);
        unsigned char encoded[4096];
        int size = avcodec_encode_subtitle(encoder, encoded, sizeof(encoded), &subtitle);
        SUBTITLE_CHECK(size > 0);
        if (encoders[i] == AV_CODEC_ID_MOV_TEXT)
            SUBTITLE_CHECK(size >= 7 && !memcmp(encoded, "\0\5Hello", 7));
        else
            SUBTITLE_CHECK(strstr((char *)encoded, "Hello"));
        avcodec_free_context(&encoder);
    }
    avsubtitle_free(&subtitle);
    av_packet_free(&packet);
    avcodec_free_context(&decoder);
    return verify_ass_render();
}

#undef SUBTITLE_CHECK
#endif
