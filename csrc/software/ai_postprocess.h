#ifndef AI_POSTPROCESS_H
#define AI_POSTPROCESS_H
#include "ai_runtime.h"

/* AIP1独立后处理描述符，不改变AIM1/AIR1格式。地址均为DDR字节偏移。
 * 当前支持reg_max=1的l/t/r/b检测头；两次稳定Top-K，无NMS、无坐标裁剪。
 * 元数据放0x5000..0x7fff，结果放0x8000..0xffff，不占模型工作区。 */
#define AI_POST_MAGIC 0x31504941u /* "AIP1" */
#define AI_POST_CONFIG_ADDR 0x5000u
#define AI_POST_REPORT_ADDR 0x5040u
#define AI_POST_OUTPUT_MIN 0x8000u
#define AI_POST_MAX_HEADS 4u
#define AI_POST_MAX_CLASSES 128u
#define AI_POST_MAX_DETECTIONS 300u

typedef struct {
    uint32_t magic,version,header_bytes,head_bytes;
    uint32_t head_count,heads_addr,threshold_q16,max_detections;
    uint32_t output_addr,output_bytes,model_addr,lut_addr;
    uint32_t input_h,input_w,flags,reserved;
} ai_post_config;

typedef struct {
    uint32_t box_addr,cls_addr,height,width;
    uint32_t classes,stride,logit_multiplier,logit_shift;
    /* 距离的像素Q16码 = RHU(raw_int16 * box_multiplier / 2^box_shift)。 */
    uint32_t box_multiplier,box_shift,reserved[6];
} ai_post_head;

typedef struct {
    int32_t x1_q16,y1_q16,x2_q16,y2_q16;
    uint32_t score_q16,class_id,anchor_id,reserved;
} ai_detection;

typedef struct {
    uint32_t code,count,anchors,selected_anchors;
    uint32_t read_calls,read_bytes,written,reserved;
} ai_post_result;

_Static_assert(sizeof(ai_post_config)==64,"post config ABI");
_Static_assert(sizeof(ai_post_head)==64,"post head ABI");
_Static_assert(sizeof(ai_detection)==32,"detection ABI");
_Static_assert(sizeof(ai_post_result)==32,"post result ABI");

/* 同一份代码用于主机数值检查与RV32I。只通过现有DDR窗口读取/写入。
 * 结果坐标对应模型输入尺寸，保留负数及越界坐标；显示端再映射、裁剪。
 * 出错时count/written只记录已成功写回的检测数，调用者检查code后使用。 */
uint32_t ai_postprocess(uint32_t config_address,uint32_t model_address,ai_post_result *result);
#endif
