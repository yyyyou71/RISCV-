#ifndef VIDEO_PRESENT_H
#define VIDEO_PRESENT_H
#include <stdint.h>
#include "preprocess_capture.h"
void video_present_init(void);
int video_present_busy(void);
void video_present_poll(void);
uint16_t video_present_command(int start,uint8_t *out,const struct pp_frame *frame,int video_ready,int blocked);
#endif
