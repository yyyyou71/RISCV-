#ifndef AI_FIRST_LAYER_H
#define AI_FIRST_LAYER_H
#include <stdint.h>
#define FL_IDLE 0u
#define FL_UPLOAD 1u
#define FL_UPLOAD_WAIT 2u
#define FL_PATCH 3u
#define FL_PATCH_WAIT 4u
#define FL_START 5u
#define FL_RUNNING 6u
#define FL_READ 7u
#define FL_READ_WAIT 8u
#define FL_PASSED 9u
#define FL_FAILED 10u
void ai_first_layer_init(void);
int ai_first_layer_start(uint32_t frame_id,uint32_t input_base,uint32_t bytes);
void ai_first_layer_poll(void);
int ai_first_layer_busy(void);
void ai_first_layer_clear(void);
void ai_first_layer_status(uint8_t *out);
#endif
