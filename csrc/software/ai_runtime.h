#ifndef AI_RUNTIME_H
#define AI_RUNTIME_H
#include <stdint.h>

/* 版本 1：所有地址均为 DDR 字节偏移；固定小端、固定 32 位字段。 */
#define AI_ABI_VERSION 1u
#define AI_MODEL_MAGIC 0x314d4941u /* "AIM1" */
#define AI_RUN_MAGIC 0x31524941u   /* "AIR1" */
#define AI_BOOT_ADDR 0x1000u
#define AI_MODEL_MIN 0x10000u     /* 前 64 KiB 留给运行请求、列表和报告 */
#define AI_DDR_BYTES 0x20000000u
#define AI_OP_CONV2D 1u
#define AI_MAX_JOBS 64u

enum ai_runtime_code {
    AI_OK=0, AI_BAD_HEADER=1, AI_BAD_RANGE=2, AI_BAD_OPCODE=3,
    AI_BAD_TASK=4, AI_DDR_ERROR=5, AI_ENGINE_ERROR=6,
    AI_POLL_TIMEOUT=7, AI_SHAPE_ERROR=8
};

typedef struct {
    uint32_t magic,version,header_bytes,task_bytes;
    uint32_t task_count,tasks_addr,arena_begin,arena_end;
    uint32_t input_addr,input_bytes,output_addr,output_bytes;
    uint32_t readonly_end,flags,reserved0,reserved1;
} ai_model_header;

typedef struct {
    uint32_t opcode,input_addr,weight_addr,bias_addr;
    uint32_t output_addr,quant_addr,hw,channels;
    uint32_t conv,post,out_h,out_w;
    uint32_t reserved[4];
} ai_task;

typedef struct {
    uint32_t code,failed_task,hardware_code,completed;
    uint32_t cycles,issues,out_h,out_w;
} ai_run_result;

_Static_assert(sizeof(ai_model_header)==64,"model ABI size");
_Static_assert(sizeof(ai_task)==64,"task ABI size");
_Static_assert(sizeof(ai_run_result)==32,"result ABI size");

/* 只暂存一块数据，不将 DDR 映射成 CPU 的栈/堆或普通 load/store 内存。 */
uint32_t ai_ddr_read(uint32_t address,uint32_t *words,uint32_t bytes);
uint32_t ai_ddr_write(uint32_t address,const uint32_t *words,uint32_t bytes);
uint32_t ai_run_model(uint32_t header_address,ai_run_result *result);
#endif
