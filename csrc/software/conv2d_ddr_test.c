#include <stdint.h>
#define R(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define DCTRL R(0x31000)
#define STATUS R(0x31004)
#define DADDR R(0x31008)
#define DLEN R(0x3100c)
#define ERROR R(0x31010)
#define DATA ((volatile uint32_t *)(uintptr_t)0x31100)
#define ACTRL R(0x30200)
#define AINPUT R(0x30208)
#define AWEIGHT R(0x3020c)
#define ABIAS R(0x30210)
#define AOUTPUT R(0x30214)
#define AHW R(0x30218)
#define ACHANNELS R(0x3021c)
#define ACONV R(0x30220)
#define ACYCLES R(0x30228)
#define AISSUES R(0x3022c)
#define AOH R(0x30230)
#define AOW R(0x30234)

/* CPU 通过窗口装载；计算阶段只配置、轮询，不逐次提供乘法操作数。 */
static int wait_result(uint32_t code)
{
    for (uint32_t n=0;n<400000;n++) {
        uint32_t s=STATUS;
        if (!(s&1)) return !(s&8) && ERROR==code && (s&6)==(code ? 4u:2u);
    }
    return 0;
}
static int move(uint32_t address,uint32_t length,uint32_t write)
{
    DADDR=address;DLEN=length;DCTRL=write ? 3:1;
    return wait_result(0);
}
static void put_bytes(uint32_t weight,uint32_t is_input)
{
    for(uint32_t word=0;word<8;word++) {
        uint32_t packed=0;
        for(uint32_t byte=0;byte<4;byte++) {
            uint32_t c=word*4+byte;
            uint32_t v=c<17 ? (is_input ? 1u:weight):0x55u;
            packed|=(v&255)<<(byte*8);
        }
        DATA[word]=packed;
    }
}
int main(void)
{
    uint32_t initialized=0;
    for(uint32_t n=0;n<400000;n++) if(STATUS&16) {initialized=1;break;}
    if(!initialized)return 10;
    for(uint32_t p=0;p<15;p++) {
        put_bytes(0,1);
        if(!move(0x7f0+p*32,32,1))return 11;
    }
    for(uint32_t c=0;c<8;c++) DATA[c]=(uint32_t)((int)c-7);
    if(!move(0x40000,32,1))return 12;
    for(uint32_t phase=0;phase<2;phase++) {
        uint32_t taps=phase ? 1:9;
        for(uint32_t c=0;c<8;c++) for(uint32_t tap=0;tap<taps;tap++) {
            put_bytes(c-2,0);
            if(!move(0x1fff0+(c*taps+tap)*32,32,1))return 13;
        }
        AINPUT=0x7f0;AWEIGHT=0x1fff0;ABIAS=0x40000;AOUTPUT=0x807f0;
        AHW=(5u<<16)|3u;ACHANNELS=(5u<<16)|17u;ACONV=phase ? 0x49u:0x57u;
        DADDR=0x12300;
        ACTRL=1;
        /* 忙时的配置、重复启动及 CPU 窗口启动应忽略，不能抢占 DDR。 */
        ACHANNELS=0;DADDR=0xdeadbeef;DCTRL=3;ACTRL=1;
        if(!wait_result(0))return 20;
        uint32_t oh=phase ? 2:3,ow=phase ? 3:5;
        if(ACHANNELS!=((5u<<16)|17u) || DADDR!=0x12300 || AOH!=oh || AOW!=ow)return 21;
        if(AISSUES!=(phase ? 192u:4320u) || ACYCLES<AISSUES)return 22;
        for(uint32_t y=0;y<oh;y++) for(uint32_t x=0;x<ow;x++) {
            if(!move(0x807f0+(y*ow+x)*64,64,0))return 23;
            for(uint32_t c=0;c<8;c++) {
                int sum=0;
                if(c<5) {
                    int ny=phase ? 1:(y==0 || y==2 ? 2:3);
                    int nx=phase ? 1:(x==0 || x==4 ? 2:3);
                    sum=ny*nx*17*((int)c-2)+(int)c-7;
                }
                if(DATA[c*2]!=(uint32_t)sum || DATA[c*2+1]!=(sum<0 ? 0xffffffffu:0))return 24;
            }
        }
    }
    AOUTPUT=0x807f1;ACTRL=1;
    if(!wait_result(4))return 30;
    ACTRL=4;
    if(STATUS&15)return 31;
    return 1;
}
