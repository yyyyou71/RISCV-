#include <stdint.h>
#define REG(a) (*(volatile uint32_t *)(a))
#define CTRL REG(0x31000u)
#define STATUS REG(0x31004u)
#define ADDRESS REG(0x31008u)
#define LENGTH REG(0x3100cu)
#define DATA ((volatile uint32_t *)0x31100u)
#define GPIO REG(0x30108u)
static void fail(void){GPIO=2;for(;;){}}
static void wait_transfer(void){
    uint32_t n=0,s;
    do{s=STATUS;if(++n==10000000u)fail();}while(s&1u);
    if((s&14u)!=2u)fail();
}
int main(void){
    uint32_t n=0;
    while(!(STATUS&16u))if(++n==10000000u)fail();
    /* Dedicated bring-up scratch at the end of the 64 MiB AI region. */
    ADDRESS=0x03fff000u;LENGTH=256;
    for(n=0;n<64;n++)DATA[n]=0x5a5a0000u^(n*0x01010101u);
    CTRL=3;wait_transfer();
    CTRL=1;wait_transfer();
    for(n=0;n<64;n++)if(DATA[n]!=(0x5a5a0000u^(n*0x01010101u)))fail();
    /* The logical region ends here; this request must fail locally, not alias video. */
    ADDRESS=0x04000000u;LENGTH=16;CTRL=1;
    while(STATUS&1u){}
    if((STATUS&14u)!=4u || REG(0x31010u)!=3u)fail();
    ADDRESS=0x03fff000u;LENGTH=256;CTRL=1;wait_transfer();
    GPIO=1;
    /* Exercise lease CDC repeatedly while video/PCIe run independently. */
    for(;;){
        REG(0x30600u)=1;
        while(REG(0x30604u)&1u){}
        if(REG(0x30604u)&2u){
            volatile uint32_t id=REG(0x3060cu);
            (void)id;
            REG(0x30600u)=2;
            while(REG(0x30604u)&1u){}
        }
        for(n=0;n<25000;n++)__asm__ volatile("nop");
    }
}
