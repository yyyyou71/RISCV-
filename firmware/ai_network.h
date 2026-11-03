#ifndef AI_NETWORK_H
#define AI_NETWORK_H
#include <stdint.h>
#include "preprocess_capture.h"
void ai_network_init(void);
int ai_network_busy(void);
int ai_network_loading(void);
int ai_network_has_model(void);
void ai_network_clear_result(void);
void ai_network_poll(void);
void ai_network_debug_status(uint32_t values[4]);
int ai_network_result(uint32_t *run,uint32_t *frame,uint32_t *slot,uint32_t *count);
uint16_t ai_network_command(uint16_t operation,const uint8_t *request,uint16_t length,
 uint8_t *response,uint16_t capacity,uint16_t *size,const struct pp_frame *frame,
 int video_ready,int video_busy,int first_layer_busy);
#endif
