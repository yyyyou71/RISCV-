/* Host-only firmware test: mapped fake MMIO, no FPGA/RK device accesses. */
#define _GNU_SOURCE
#include <assert.h>
#include <stdio.h>
#include <sys/mman.h>
#include <string.h>
#define main video_firmware_main
#include "../../firmware/video_diagnostic.c"
#undef main

void ai_network_clear_result(void){}
void ai_first_layer_clear(void){}
int ai_network_busy(void){return 0;}
int ai_first_layer_busy(void){return 0;}
static unsigned result_queries;
int ai_network_result(uint32_t *run,uint32_t *id,uint32_t *slot,uint32_t *count){
    result_queries++;*run=9;*id=7;*slot=2;*count=16;return 1;
}
uint32_t ai_ddr_read(uint32_t address,uint32_t *data,uint32_t bytes){
    (void)address;(void)data;(void)bytes;assert(0);return 1;
}
size_t rk_comm_send(const uint8_t *data,size_t size){(void)data;return size;}

static void arm_with_measurement(uint32_t measured){
    output_mode=requested_mode=VIDEO_OUTPUT_AI;
    VIDEO_SHAPE=measured;VIDEO_PERIOD=100;CYCLES=1;
    PP_REG(4)=PP_DDR_READY;
    start_waiting();poll_video();
    assert(state==COMM_VIDEO_WAIT_INPUT);
    poll_video();
    assert(state==COMM_VIDEO_CAPTURE && error_stage==0 && PP_REG(0)==1);
}
int main(void){
    void *mmio=mmap((void *)0x30000,0x2000,PROT_READ|PROT_WRITE,
                    MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE,-1,0);
    assert(mmio==(void *)0x30000);
    memset(mmio,0,0x2000);
    arm_with_measurement((4443u<<16)|7u);
    PP_REG(4)=PP_DONE|PP_ERROR|PP_DDR_READY;poll_video();
    assert(state==COMM_VIDEO_ERROR && error_stage==4);
    arm_with_measurement(0);
    PP_REG(4)=PP_DONE|PP_HELD|PP_DDR_READY;
    PP_REG(8)=7;PP_REG(0x0c)=6;PP_REG(0x1c)=PP_TENSOR_BYTES;poll_video();
    assert(state==COMM_VIDEO_ERROR && error_stage==6);
    arm_with_measurement((1080u<<16)|1919u);
    PP_REG(4)=PP_DONE|PP_HELD|PP_DDR_READY;
    PP_REG(0x0c)=2;PP_REG(0x1c)=32;poll_video();
    assert(state==COMM_VIDEO_ERROR && error_stage==6);
    /* RAW does not depend on preprocessor readiness/geometry or stale AI boxes. */
    video_present_init();output_mode=requested_mode=VIDEO_OUTPUT_RAW;
    RAW_STATUS=16;PP_REG(4)=PP_FAULT;PP_REG(0)=0;
    VIDEO_SHAPE=(4443u<<16)|7u;
    start_waiting();poll_video();poll_video();
    assert(state==COMM_VIDEO_CAPTURE && RAW_CONTROL==1 && PP_REG(0)==0);
    RAW_STATUS=16|8|4;CYCLES+=250000u;poll_video();
    assert(state==COMM_VIDEO_CAPTURE && RAW_CONTROL==1); /* retry no complete frame */
    RAW_STATUS=16|4|2;REG(0x30608u)=2;REG(0x3060cu)=7;REG(0x30610u)=2u<<22;
    poll_video();assert(state==COMM_VIDEO_SUCCESS && frame.bytes==0 && !frame.tensor_logical_base);
    assert(capture_status()==(PP_DDR_READY|PP_DONE|PP_HELD));
    uint8_t response[COMM_PRESENT_WORDS*4];
    REG(0x30904u)=8;result_queries=0;
    assert(video_present_command(1,response,&frame,1,0)==COMM_OK);
    assert(set_output_mode(VIDEO_OUTPUT_AI)==COMM_BUSY); /* DMA lease cannot be switched */
    video_present_poll(0);
    assert(REG(0x30910u)==0 && !result_queries); /* zero boxes, no AI reads/auto-submit */
    video_present_init();
    assert(set_output_mode(2)==COMM_BAD_ARGUMENT);
    assert(set_output_mode(VIDEO_OUTPUT_AI)==COMM_OK);
    assert(state==COMM_VIDEO_RELEASING && RAW_CONTROL==2 && output_mode==VIDEO_OUTPUT_RAW);
    RAW_STATUS=16|4;PP_REG(4)=PP_DDR_READY;poll_video();
    assert(output_mode==VIDEO_OUTPUT_AI && state==COMM_VIDEO_WAIT_DDR && PP_REG(0)==4);
    poll_video();poll_video();
    assert(state==COMM_VIDEO_CAPTURE && PP_REG(0)==1);
    assert(!munmap(mmio,0x2000));
    puts("PASS firmware: geometry is diagnostic, RAW bypasses tensor/AI, mode switch releases lease, integrity and DMA protection retained");
    return 0;
}
