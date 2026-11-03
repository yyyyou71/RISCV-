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
void ai_first_layer_status(uint8_t *out){(void)out;assert(0);}
uint16_t ai_network_command(uint16_t op,const uint8_t *request,uint16_t length,
 uint8_t *response,uint16_t capacity,uint16_t *size,const struct pp_frame *f,
 int ready,int busy,int first_busy){
    (void)op;(void)request;(void)length;(void)response;(void)capacity;(void)size;
    (void)f;(void)ready;(void)busy;(void)first_busy;assert(0);return COMM_BAD_OPCODE;
}
int ai_network_busy(void){return 0;}
int ai_first_layer_busy(void){return 0;}
static uint32_t mock_network_state;
void ai_network_debug_status(uint32_t values[4]){
    values[0]=mock_network_state;values[1]=0;values[2]=3;values[3]=99;
}
static unsigned result_queries;
int ai_network_result(uint32_t *run,uint32_t *id,uint32_t *slot,uint32_t *count){
    result_queries++;*run=9;*id=7;*slot=2;*count=16;return 1;
}
uint32_t ai_ddr_read(uint32_t address,uint32_t *data,uint32_t bytes){
    (void)address;(void)data;(void)bytes;assert(0);return 1;
}
size_t rk_comm_send(const uint8_t *data,size_t size){(void)data;return size;}

static void writer_sample(uint32_t source,uint32_t decoded,uint32_t bursts,uint32_t published){
    CYCLES+=DEBUG_INTERVAL;debug_poll();assert(debug_pending);
    for(unsigned i=0;i<12;i++)REG(0x309c4u+i*4)=0;
    REG(0x309c4u)=0x56444731u;
    REG(0x309ccu)=source;REG(0x309d0u)=decoded;REG(0x309d4u)=bursts;
    REG(0x309dcu)=16200;REG(0x309e0u)=published;
    REG(0x309c0u)=2;debug_poll();
}
static void check_pipeline_debug(void){
    memset((void *)0x30000,0,0x2000);video_present_init();
    debug_valid=debug_pending=debug_requested=debug_failed=0;
    for(unsigned i=0;i<12;i++)debug_writer[i]=0;
    output_mode=requested_mode=VIDEO_OUTPUT_RAW;RAW_STATUS=16;
    start_waiting();poll_video();poll_video();assert(state==COMM_VIDEO_CAPTURE);
    writer_sample(0,0,0,0);assert(debug_step==VD_WAIT_SOURCE);
    writer_sample(1,0,0,0);assert(debug_step==VD_WAIT_FIFO);
    writer_sample(1,1,0,0);assert(debug_step==VD_WAIT_WRITE);
    writer_sample(1,1,1,0);assert(debug_step==VD_WAIT_PUBLISH);
    writer_sample(2,2,16200,1);assert(debug_step==VD_WAIT_LEASE);
    RAW_STATUS=16|4|2;REG(0x30608u)=2;REG(0x3060cu)=7;
    poll_video();debug_poll();assert(debug_step==VD_FRAME_READY);
    uint8_t present[COMM_PRESENT_WORDS*4];REG(0x30904u)=8;
    assert(video_present_command(1,present,&frame,1,0)==COMM_OK);
    debug_poll();assert(debug_step==VD_PRESENT_PREPARE);
    video_present_poll(0);debug_poll();assert(debug_step==VD_WAIT_PCIE_DMA);
    REG(0x30904u)=0;debug_poll();assert(debug_step==VD_WAIT_PCIE_LINK);
    REG(0x30904u)=8|2;REG(0x30928u)=7;video_present_poll(0);debug_poll();
    assert(debug_step==VD_PCIE_DONE && (debug_seen&512u));
    video_present_init();REG(0x30904u)=8;
    mock_network_state=NW_RUNNING;debug_poll();assert(debug_step==VD_AI_RUNNING);
    mock_network_state=NW_POSTPROCESS;debug_poll();assert(debug_step==VD_AI_POSTPROCESS);
    mock_network_state=NW_DONE;debug_poll();assert(debug_step==VD_AI_DONE);
    mock_network_state=NW_EMPTY;RAW_STATUS=16;start_waiting();poll_video();poll_video();
    writer_sample(3,3,16201,1);assert(debug_step==VD_WAIT_PUBLISH);
    fail(5);debug_poll();
    assert(debug_step==VD_ERROR && debug_failure_step==VD_WAIT_PUBLISH && debug_failed);
    uint32_t frozen=debug_failure_writer[4],age=debug_failure_age;
    writer_sample(4,4,32400,2);
    assert(debug_failure_writer[4]==frozen && debug_failure_age==age);
    uint8_t response[COMM_VIDEO_DEBUG_WORDS*4];uint16_t bytes=0;
    assert(rk_comm_application_command(COMM_VIDEO_DEBUG,0,0,response,sizeof(response),&bytes)==COMM_OK);
    assert(bytes==sizeof(response) && comm_u32(response+2*4)==VD_WAIT_PUBLISH);
    assert(comm_u32(response+40*4)==frozen && (comm_u32(response+8*4)&8u));
    /* A diagnostic sample cannot issue capture/release commands. */
    uint32_t control=RAW_CONTROL;CYCLES+=DEBUG_INTERVAL;debug_poll();
    assert(debug_pending && RAW_CONTROL==control);
    CYCLES+=25001;debug_poll();assert(debug_code==1 && RAW_CONTROL==control);
    start_waiting();assert(!debug_failed && debug_failure_flags==0);
    puts("PASS pipeline: one-second snapshots, stage classification, AI status, frozen pre-error sample, timeout and no capture side effects");
}

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
    check_pipeline_debug();
    assert(!munmap(mmio,0x2000));
    puts("PASS firmware: geometry is diagnostic, RAW bypasses tensor/AI, mode switch releases lease, integrity and DMA protection retained");
    return 0;
}
