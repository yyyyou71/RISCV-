#include "preprocess_capture.h"
#define REG(a) (*(volatile uint32_t *)(a))
#define GPIO REG(0x30108u)
#define CYCLES REG(0x3000cu)
/* Keep details in on-chip RAM for later debugger/host inspection. */
volatile uint32_t preprocess_diagnostic_stage,preprocess_diagnostic_status;
volatile uint32_t preprocess_diagnostic_error,preprocess_diagnostic_shape;
static void pause_cycles(uint32_t cycles){
    uint32_t started=CYCLES;
    while(CYCLES-started<cycles){}
}
static void fail(unsigned stage){
    unsigned pulse;
    preprocess_diagnostic_stage=stage;
    preprocess_diagnostic_status=PP_REG(4);
    preprocess_diagnostic_error=PP_REG(0x18);
    preprocess_diagnostic_shape=REG(0x3061cu);
    for(;;){
        for(pulse=0;pulse<stage;pulse++){
            GPIO=3;pause_cycles(2500000u);
            GPIO=2;pause_cycles(2500000u);
        }
        pause_cycles(25000000u);
    }
}
static void wait_done(unsigned stage){
    uint32_t started=CYCLES;
    while(REG(0x31004u)&1u)if(CYCLES-started>6250000u)fail(stage);
    if((REG(0x31004u)&14u)!=2u)fail(stage);
}
static void check_pixel(uint32_t address,unsigned stage){
    volatile uint32_t *data=(volatile uint32_t *)0x31100u;
    unsigned i;
    REG(0x31008u)=address;REG(0x3100cu)=32;REG(0x31000u)=1;wait_done(stage);
    if((data[0]&0xff00ff00u) || (data[1]&0xffffff00u))fail(stage);
    for(i=2;i<8;i++)if(data[i])fail(stage);
}
int main(void){
    struct pp_frame frame;
    uint32_t started,previous;
    unsigned level=0;
    /* Let the reference HDMI configuration finish before the short capture
       deadline begins. The frame monitor reports geometry from actual input. */
    started=CYCLES;
    while(!(PP_REG(4)&PP_DDR_READY))if(CYCLES-started>75000000u)fail(1);
    started=CYCLES;
    while(REG(0x3061cu)!=((1080u<<16)|1920u))if(CYCLES-started>50000000u)fail(2);
    if(pp_capture_start(PP_DEFAULT_BASE))fail(3);
    started=CYCLES;
    for(;;){
        int result=pp_capture_result(&frame);
        if(result<0)fail(4);
        if(CYCLES-started>6250000u)fail(5);
        if(result>0)break;
    }
    if(frame.bytes!=PP_TENSOR_BYTES || frame.raw_slot>=5)fail(6);
    check_pixel(frame.tensor_logical_base,7);
    check_pixel(frame.tensor_logical_base+frame.bytes-32,8);
    /* Hold this descriptor for inspection. Success toggles LED1 every 0.5 s;
       failure keeps its output high and sends the stage number on LED0. */
    previous=CYCLES;
    for(;;)if(CYCLES-previous>=12500000u){previous=CYCLES;level^=2;GPIO=level;}
}
