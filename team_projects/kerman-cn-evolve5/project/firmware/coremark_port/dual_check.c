#include "coremark.h"
#include "soc.h"
#include "platform.h"
extern void dual_smoke_loop(uint32_t iterations,uint32_t *result);
int dual_selfcheck(void) {
    uint32_t out[11]={0};
    uint32_t issue;
    __asm__ volatile("csrr %0,0xfc1":"=r"(issue));
    if((issue&~3u)!=0xd1000000u) return 0;
    dual_smoke_loop(1024u,out);
    for(unsigned n=0;n<8;++n) if(out[n]!=4096u*(n+1u)) return 0;
    /* The minstret window includes the start CSR and one alignment NOP.
       The cycle window additionally includes fixed CSR serialization overhead;
       its measured IPC is conservative, not an overhead-subtracted peak. */
    if(out[9]!=34818u || out[8]==0u) return 0;
    if(!(issue&1u) && out[10]!=0u) return 0;
    if((issue&1u) && out[10]==0u) return 0;
    if((issue&3u)==3u && (MON_REG(4)&1u) && out[8]>=out[9]) return 0;
    ee_printf("DUAL_CHECK PASS iterations=1024 cycles=%u instret=%u pairs=%u\n",out[8],out[9],out[10]);
    return 1;
}
