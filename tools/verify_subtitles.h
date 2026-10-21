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
    avsubtitle_free(&subtitle);
    av_packet_free(&packet);
    avcodec_free_context(&decoder);
    return verify_ass_render();
}

#undef SUBTITLE_CHECK
#endif
