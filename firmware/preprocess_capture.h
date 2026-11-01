#ifndef PREPROCESS_CAPTURE_H
#define PREPROCESS_CAPTURE_H
#include <stdint.h>
#define PP_REG(offset) (*(volatile uint32_t *)(0x00030800u+(offset)))
#define PP_BUSY 1u
#define PP_DONE 2u
#define PP_ERROR 4u
#define PP_HELD 8u
#define PP_DDR_READY 16u
#define PP_FAULT 32u
#define PP_DEFAULT_BASE 0x03f00000u
#define PP_TENSOR_BYTES 294912u
struct pp_frame {
    uint32_t frame_id,raw_slot,raw_native_base,tensor_logical_base,bytes;
};
/* Raw input measurement; hardware pads the missing rightmost pixel to black. */
static inline int pp_input_shape_usable(uint32_t shape) {
    uint32_t width=shape&0xffffu;
    return (shape>>16)==1080u && width>=1919u && width<=1920u;
}
static inline int pp_capture_start(uint32_t logical_base) {
    uint32_t status=PP_REG(4);
    if((status&(PP_BUSY|PP_HELD|PP_FAULT)) || !(status&PP_DDR_READY))return -1;
    PP_REG(0x10)=logical_base;
    PP_REG(0)=1;
    return 0;
}
/* 0=pending, 1=valid retained pair, -1=failed; retain ownership until release. */
static inline int pp_capture_result(struct pp_frame *frame) {
    uint32_t status=PP_REG(4);
    if((status&PP_BUSY) || !(status&PP_DONE))return 0;
    if((status&(PP_ERROR|PP_FAULT)) || !(status&PP_HELD))return -1;
    frame->frame_id=PP_REG(8);frame->raw_slot=PP_REG(0x0c);
    frame->raw_native_base=PP_REG(0x20);frame->tensor_logical_base=PP_REG(0x10);
    frame->bytes=PP_REG(0x1c);
    return 1;
}
static inline int pp_capture_release(void) {
    if(PP_REG(4)&PP_BUSY)return -1;
    PP_REG(0)=2;
    return 0;
}
#endif
