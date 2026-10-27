#include "video_capture.h"
#include "ai_runtime.h"

int main(void)
{
    volatile uint32_t *status=(volatile uint32_t *)(uintptr_t)0x30304;
    uint32_t n;
    for(n=0;n<200000;n++)if(*status&16)break;
    if(n==200000)return 10;
    video_capture_config c={0x7f0,7,3,48,1000000,1};
    video_capture_result result;
    for(uint32_t round=0;round<2;round++) {
        c.base=round?0x10000000:0x7f0;
        if(video_capture_start(&c))return 11;
        if(video_capture_start(&c)!=VIDEO_BUSY)return 12;
        if(video_capture_wait(200000,&result) || result.written_bytes!=96)return 13;
        for(uint32_t y=0;y<3;y++) {
            uint32_t row[8];
            if(ai_ddr_read(c.base+y*48,row,32))return 14;
            for(uint32_t x=0;x<8;x++) {
                uint32_t expected=x==7?0:((x+17)|((y+33)<<8)|((x^y^0x55)<<16));
                if(row[x]!=expected)return 15;
            }
        }
    }
    return 1;
}
