#ifndef VERIFY_DISCS_H
#define VERIFY_DISCS_H

#include <stdio.h>
#include <libbluray/bluray.h>
#include <dvdread/dvd_reader.h>
#include <dvdread/ifo_read.h>
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"

/* 故意只链接 avformat：这些接口必须由其静态内置的光盘库提供。 */
static int verify_discs(void)
{
    void (*volatile exports[])(void) = {
        (void (*)(void))bd_get_version, (void (*)(void))bd_open,
        (void (*)(void))bd_close, (void (*)(void))bd_get_disc_info,
        (void (*)(void))bd_get_titles, (void (*)(void))bd_get_title_info,
        (void (*)(void))bd_free_title_info, (void (*)(void))bd_select_playlist,
        (void (*)(void))bd_select_angle, (void (*)(void))bd_read,
        (void (*)(void))bd_seek, (void (*)(void))bd_seek_time,
        (void (*)(void))bd_tell, (void (*)(void))bd_get_title_size,
        (void (*)(void))DVDOpen, (void (*)(void))DVDClose,
        (void (*)(void))DVDOpenFile, (void (*)(void))DVDCloseFile,
        (void (*)(void))DVDReadBytes, (void (*)(void))DVDReadBlocks,
        (void (*)(void))DVDFileSize, (void (*)(void))ifoOpen,
        (void (*)(void))ifoClose,
    };
    for (unsigned i = 0; i < sizeof(exports) / sizeof(exports[0]); ++i)
        if (!exports[i]) return 1;
    int major, minor, micro;
    bd_get_version(&major, &minor, &micro);
    if (major != 1 || minor < 5 || !av_find_input_format("dvdvideo") ||
        !avcodec_find_decoder(AV_CODEC_ID_DVD_SUBTITLE) ||
        !avcodec_find_decoder(AV_CODEC_ID_HDMV_PGS_SUBTITLE)) {
        fprintf(stderr, "Missing/incompatible embedded disc support (libbluray %d.%d.%d)\n", major, minor, micro);
        return 1;
    }
    printf("Embedded disc APIs: libbluray %d.%d.%d, DVD input, VOB/PGS subtitle decoders\n", major, minor, micro);
    return 0;
}
#endif
