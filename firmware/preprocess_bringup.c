#include "preprocess_capture.h"
#define REG(a) (*(volatile uint32_t *)(a))
#define GPIO REG(0x30108u)
#define CYCLES REG(0x3000cu)
static void fail(void){GPIO=2;for(;;){}}
static void wait_done(void){
    uint32_t started=CYCLES;
    while(REG(0x31004u)&1u)if(CYCLES-started>6250000u)fail();
    if((REG(0x31004u)&14u)!=2u)fail();
}
static void check_pixel(uint32_t address){
    volatile uint32_t *data=(volatile uint32_t *)0x31100u;
    unsigned i;
    REG(0x31008u)=address;REG(0x3100cu)=32;REG(0x31000u)=1;wait_done();
    if((data[0]&0xff00ff00u) || (data[1]&0xffffff00u))fail();
    for(i=2;i<8;i++)if(data[i])fail();
}
int main(void){
    struct pp_frame frame;
    uint32_t started,previous;
    unsigned level=0;
    /* Let the reference HDMI configuration finish before the short capture
       deadline begins. The frame monitor reports geometry from actual input. */
    while(!(PP_REG(4)&PP_DDR_READY)){}
    started=CYCLES;
    while(REG(0x3061cu)!=((1080u<<16)|1920u))if(CYCLES-started>50000000u)fail();
    if(pp_capture_start(PP_DEFAULT_BASE))fail();
    started=CYCLES;
    for(;;){
        int result=pp_capture_result(&frame);
        if(result<0 || CYCLES-started>6250000u)fail();
        if(result>0)break;
    }
    if(frame.bytes!=PP_TENSOR_BYTES || frame.raw_slot>=5)fail();
    check_pixel(frame.tensor_logical_base);
    check_pixel(frame.tensor_logical_base+frame.bytes-32);
    /* Hold this descriptor for inspection. Success toggles LED1 every 0.5 s;
       failure keeps its RTL output high. LED0 independently reports DDR ready. */
    previous=CYCLES;
    for(;;)if(CYCLES-previous>=12500000u){previous=CYCLES;level^=2;GPIO=level;}
}
