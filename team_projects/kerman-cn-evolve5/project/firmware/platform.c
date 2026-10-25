#include "platform.h"
static void hex32(uint32_t v) {
    uart_puthex8((uint8_t)(v>>24)); uart_puthex8((uint8_t)(v>>16));
    uart_puthex8((uint8_t)(v>>8)); uart_puthex8((uint8_t)v);
}
int platform_valid(void) {
    uint32_t cfg=MON_REG(4);
    uint32_t misa; __asm__ volatile("csrr %0,misa":"=r"(misa));
    uint32_t impl,uarch;
    __asm__ volatile("csrr %0,mimpid":"=r"(impl));
    __asm__ volatile("csrr %0,0xfc0":"=r"(uarch));
    uint32_t bits=(impl>>8)&31u, pht=(uarch>>4)&15u;
    uint32_t ras=(uarch>>8)&31u, depth=(uarch>>16)&15u;
    if(bits<2 || bits>8 || (uarch>>24)!=0xf1u || ((uarch>>20)&15u)!=bits || pht<2 || pht>12) return 0;
    if((ras!=0 && ras!=4 && ras!=8 && ras!=16) || (depth!=1 && depth!=2 && depth!=4 && depth!=8)) return 0;
    if(((misa>>12)&1u)!=((cfg>>5)&1u) || (cfg&~0x3fu)) return 0;
    cfg&=~0x20u;
    return MON_REG(0)==MON_MAGIC && MON_REG(8)==SOC_CLOCK_HZ &&
        (cfg==0x1fu || cfg==0x17u || cfg==0x1cu) && MON_REG(12)==1024u &&
        MON_REG(16)==16u && MON_REG(20)==32u && MON_REG(24)==(1u<<bits) && MON_REG(28)==0;
}
void platform_identity(void) {
    uart_puts("HW_ID="); hex32(MON_REG(0)); uart_puts(" HW_CFG="); hex32(MON_REG(4));
    uart_puts(" CLOCK="); uart_put_u32(MON_REG(8)); uart_puts(" CACHE_BYTES="); uart_put_u32(MON_REG(12));
    uart_puts(" LINE_BYTES="); uart_put_u32(MON_REG(16)); uart_puts(" SETS="); uart_put_u32(MON_REG(20));
    uart_puts(" BP_ENTRIES="); uart_put_u32(MON_REG(24)); uart_puts(" WAIT="); uart_put_u32(MON_REG(28)&65535u);
    uart_puts(" GAP="); uart_put_u32(MON_REG(28)>>16); uart_putc('\n');
}
void platform_stats(void) {
    static const char *const names[]={" ih="," im="," dh="," dm="," wh="," wm="," read_cmd="," burst_cmd="," read_beat="," write_rsp="};
    MON_REG(0x24)=1;
    uart_puts("CACHE_STATS scope=cumulative32 seq="); uart_put_u32(MON_REG(0x20));
    for(unsigned i=0;i<10;i++) { uart_puts(names[i]); uart_put_u32(MON_REG(0x80+4*i)); }
    uart_putc('\n');
}
uint32_t platform_cache_selftest(void) {
    if(!platform_valid() || (MON_REG(4)&~0x20u)!=0x1fu) return 100;
    uint32_t result=cache_probe(); if(result) return result;
    if(!MON_REG(0x100) || !MON_REG(0x104)) return 101;
    if(!MON_REG(0x11c)) return 102;
    GPIO_OUT=0; GPIO_TOGGLE=1;
    if(GPIO_OUT!=1) return 103;
    GPIO_TOGGLE=1; if(GPIO_OUT!=0) return 104;
    uart_puts("CACHE_SELFTEST_PASS lru=1 byte_halfword=1 write_through=1 mmio=1 burst=1\n");
    platform_stats();
    return 0;
}
