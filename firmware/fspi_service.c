#include "rk_link.h"
#include "fspi_link.h"
static uint8_t buffer[256];
static void reply(uint8_t code,uint32_t value) {
    unsigned i;
    while(!rk_try_send(code)) {}
    for(i=0;i<4;i++) {while(!rk_try_send((uint8_t)value)) {} value>>=8;}
}
int main(void) {
    uint32_t cmd,seq,sum;unsigned i;int result;
    /* RK must wait for the IIC reply before asserting FSPI CS. */
    reply(0x52,256);
    for(;;) if(rk_get_parameter(&cmd,&seq)) {
        if(cmd&0x80000000u) {
            result=fspi_copy_from_rk(buffer,256);
            sum=0;
            if(!result) for(i=0;i<256;i++) sum+=buffer[i];
        } else {
            for(i=0;i<256;i++) buffer[i]=(uint8_t)(i^(cmd&255u));
            result=fspi_copy_to_rk(buffer,256);
            sum=256;
        }
        rk_ack_parameter(seq);
        reply(result ? 0xe0 : ((cmd&0x80000000u) ? 0x43 : 0x50),
              result ? (uint32_t)(-result) : sum);
    }
}
