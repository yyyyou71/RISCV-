#include "ai_postprocess.h"

/* Simulation-only entry. Copy an image through the real CPU DDR window into
 * the board's live tensor address, verify it, then use production runtime. */
#define LIVE_INPUT 0x03f00000u
#define MMIO(a) (*(volatile uint32_t *)(a))
int main(void){
    ai_model_header header;ai_run_result network;ai_post_result post;
    uint32_t source[64],verify[64],code;
    code=ai_ddr_read(0x10000u,(uint32_t *)&header,64);
    if(code || header.input_bytes!=294912u)return 0x301;
#ifdef BOARD_PREPROCESS
    MMIO(0x30810u)=LIVE_INPUT;MMIO(0x30800u)=1;
    uint32_t started=MMIO(0x3000cu);
    while(!(MMIO(0x30804u)&2u))
        if(MMIO(0x3000cu)-started>25000000u)return 0x401;
    if((MMIO(0x30804u)&47u)!=10u || MMIO(0x3081cu)!=header.input_bytes)return 0x402;
    if(MMIO(0x3080cu)>=5)return 0x403;
#endif
    for(uint32_t offset=0;offset<header.input_bytes;offset+=256){
        if(ai_ddr_read(header.input_addr+offset,source,256))return 0x302;
#ifndef BOARD_PREPROCESS
        if(ai_ddr_write(LIVE_INPUT+offset,source,256))return 0x303;
#endif
        if(ai_ddr_read(LIVE_INPUT+offset,verify,256))return 0x304;
        for(unsigned i=0;i<64;i++)if(source[i]!=verify[i])return 0x305;
    }
    ai_run_model_input(0x10000u,LIVE_INPUT,header.input_bytes,&network);
    code=ai_ddr_write(0x4000u,(const uint32_t *)&network,32);
    if(code || network.code || network.completed!=99)return 0x306;
    ai_postprocess(AI_POST_CONFIG_ADDR,0x10000u,&post);
    if(post.code)return 0x307;
    return ai_ddr_write(AI_POST_REPORT_ADDR,(const uint32_t *)&post,32)?0x308:1;
}
