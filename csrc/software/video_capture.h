#ifndef VIDEO_CAPTURE_H
#define VIDEO_CAPTURE_H
#include <stdint.h>

/* 控制寄存器属于CPU外设空间；base/stride则是DDR字节偏移。 */
#define VIDEO_CAPTURE_MMIO 0x30300u
#define VIDEO_CAPTURE_RGBX 1u /* 每像素小端字节R、G、B、0 */
enum video_capture_code {
    VIDEO_OK=0, VIDEO_BAD_SHAPE=1, VIDEO_BAD_ALIGNMENT=2, VIDEO_BAD_RANGE=3,
    VIDEO_BAD_FRAME=4, VIDEO_OVERFLOW=5, VIDEO_INPUT_TIMEOUT=6,
    VIDEO_DDR_ERROR=7, VIDEO_NOT_READY=8,
    VIDEO_BUSY=16, VIDEO_POLL_TIMEOUT=17, VIDEO_NO_RESULT=18, VIDEO_UNAVAILABLE=19
};
typedef struct {
    uint32_t base, width, height, stride;
    uint32_t timeout_cycles; /* DDR用户时钟周期数，须覆盖等待下一帧及整帧采集 */
    uint32_t vs_active_high;
} video_capture_config;
typedef struct {
    uint32_t code, written_bytes, status;
} video_capture_result;

/* start异步发起；CPU可继续执行。wait的poll_limit=0表示一直轮询。 */
uint32_t video_capture_start(const video_capture_config *config);
uint32_t video_capture_wait(uint32_t poll_limit,video_capture_result *result);
#endif
