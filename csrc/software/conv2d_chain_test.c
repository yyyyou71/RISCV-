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
#define AISSUES R(0x3022c)
#define AOH R(0x30230)
#define AOW R(0x30234)
#define APOST R(0x30238)
#define AQUANT R(0x3023c)

static int wait_result(uint32_t code)
{
    for(uint32_t n=0;n<400000;n++) {
        uint32_t s=STATUS;
        if(!(s&1))return !(s&8) && ERROR==code && (s&6)==(code ? 4u:2u);
    }
    return 0;
}
static int move(uint32_t addr,uint32_t len,uint32_t write)
{
    DADDR=addr;DLEN=len;DCTRL=write ? 3:1;
    return wait_result(0);
}
/* 这份小参考只处理本例范围，避免 CPU 执行浮点或整网推理。 */
static int quant(int value,uint32_t mult,uint32_t shift,uint32_t relu)
{
    int magnitude=value<0 ? -value:value;
    int result=(magnitude*(int)mult+(shift ? (1<<(shift-1)):0))>>shift;
    if(value<0)result=-result;
    if(relu && result<0)result=0;
    if(result>127)result=127;
    if(result< -128)result= -128;
    return result;
}
static int first(uint32_t y,uint32_t x,uint32_t c)
{
    int ny=y==1 ? 3:2,nx=(x==0 || x==4) ? 2:3;
    return quant(ny*nx*17*((int)c-2)+(int)c-7,c+1,c+3,1);
}
static int second(uint32_t y,uint32_t x,uint32_t o)
{
    int value=o==0 ? -1:(o==1 ? 2:-3);
    for(uint32_t c=0;c<5;c++) {
        int w=o==0 ? -2:(o==1 ? (int)c-2:3);
        value+=first(y*2,x*2,c)*w;
    }
    return quant(value,o==1 ? 3:1,o==2 ? 0:(o==1 ? 2:1),0);
}
int main(void)
{
    uint32_t ready=0;
    for(uint32_t n=0;n<400000;n++)if(STATUS&16){ready=1;break;}
    if(!ready)return 10;
    /* 装载第一层：HWC 输入 Cin=17，物理间距 32；尾部故意填非零。 */
    for(uint32_t p=0;p<15;p++) {
        for(uint32_t word=0;word<8;word++) {
            uint32_t packed=0;
            for(uint32_t b=0;b<4;b++)packed|=(word*4+b<17 ? 1u:0x55u)<<(b*8);
            DATA[word]=packed;
        }
        if(!move(0x7f0+p*32,32,1))return 11;
    }
    for(uint32_t c=0;c<8;c++)for(uint32_t tap=0;tap<9;tap++) {
        for(uint32_t word=0;word<8;word++) {
            uint32_t packed=0;
            for(uint32_t b=0;b<4;b++)packed|=((word*4+b<17 ? c-2:0x66u)&255)<<(b*8);
            DATA[word]=packed;
        }
        if(!move(0x1fff0+(c*9+tap)*32,32,1))return 12;
    }
    for(uint32_t c=0;c<8;c++)DATA[c]=(uint32_t)((int)c-7);
    if(!move(0x40000,32,1))return 13;
    for(uint32_t c=0;c<8;c++) {
        DATA[0]=c<5 ? c+1:0xdeadbeef;DATA[1]=c<5 ? c+3:0xffffffff;DATA[2]=0;DATA[3]=0;
        if(!move(0x50000+c*16,16,1))return 14;
    }
    /* 第二层权重、偏置与量化参数也预先装载；CPU 不生成中间特征图。 */
    for(uint32_t o=0;o<4;o++) {
        for(uint32_t word=0;word<4;word++) {
            uint32_t packed=0;
            for(uint32_t b=0;b<4;b++) {
                uint32_t c=word*4+b;
                int w=o==0 ? -2:(o==1 ? (int)c-2:3);
                packed|=((c<5 ? (uint32_t)w:0x66u)&255)<<(b*8);
            }
            DATA[word]=packed;
        }
        if(!move(0x60000+o*16,16,1))return 15;
    }
    DATA[0]=(uint32_t)-1;DATA[1]=2;DATA[2]=(uint32_t)-3;DATA[3]=0;
    if(!move(0x61000,16,1))return 16;
    for(uint32_t o=0;o<4;o++) {
        DATA[0]=o==1 ? 3:1;DATA[1]=o==2 ? 0:(o==1 ? 2:1);DATA[2]=0;DATA[3]=0;
        if(!move(0x62000+o*16,16,1))return 17;
    }
    AINPUT=0x7f0;AWEIGHT=0x1fff0;ABIAS=0x40000;AOUTPUT=0x807f0;
    AHW=(5u<<16)|3u;ACHANNELS=(5u<<16)|17u;ACONV=0x57;APOST=3;AQUANT=0x50000;
    ACTRL=1;
    /* 新配置和旧配置一样，忙时写入不能污染跨时钟请求。 */
    APOST=0;AQUANT=0xdeadbeef;
    if(!wait_result(0) || APOST!=3 || AQUANT!=0x50000 || AISSUES!=4320 || AOH!=3 || AOW!=5)return 20;
    /* 不读取、不改写第一层结果，直接用同一 DDR 地址启动第二层。 */
    AINPUT=0x807f0;AWEIGHT=0x60000;ABIAS=0x61000;AOUTPUT=0x90000;
    ACHANNELS=(3u<<16)|5u;ACONV=0x49;APOST=1;AQUANT=0x62000;ACTRL=1;
    if(!wait_result(0) || AISSUES!=48 || AOH!=2 || AOW!=3)return 21;
    for(uint32_t y=0;y<2;y++)for(uint32_t x=0;x<3;x++) {
        if(!move(0x90000+(y*3+x)*16,16,0))return 22;
        uint32_t expected=0;
        for(uint32_t o=0;o<3;o++)expected|=((uint32_t)second(y,x,o)&255)<<(o*8);
        if(DATA[0]!=expected || DATA[1]!=0 || DATA[2]!=0 || DATA[3]!=0)return 23;
    }
    /* 第二层完成后，再检查中间图和全部填充字节。 */
    for(uint32_t y=0;y<3;y++)for(uint32_t x=0;x<5;x++) {
        if(!move(0x807f0+(y*5+x)*16,16,0))return 24;
        uint32_t expected=0;
        for(uint32_t c=0;c<4;c++)expected|=((uint32_t)first(y,x,c)&255)<<(c*8);
        if(DATA[0]!=expected || DATA[1]!=(uint32_t)first(y,x,4) || DATA[2]!=0 || DATA[3]!=0)return 25;
    }
    /* 配置错误可以清除；原始输出模式仍保留原来的格式。 */
    APOST=2;ACTRL=1;if(!wait_result(7))return 30;
    ACTRL=4;if(STATUS&15)return 31;
    return 1;
}
