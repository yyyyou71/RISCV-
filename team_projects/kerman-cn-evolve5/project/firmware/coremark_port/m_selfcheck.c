#include "coremark.h"
#include "coremark_build_config.h"
#include "soc.h"
#if COREMARK_NATIVE_M
#include "m_boot_vectors.h"
static uint32_t operation(unsigned op,uint32_t a,uint32_t b) {
    uint32_t value;
    switch(op) {
    case 0: __asm__ volatile("mul %0,%1,%2":"=r"(value):"r"(a),"r"(b)); break;
    case 1: __asm__ volatile("mulh %0,%1,%2":"=r"(value):"r"(a),"r"(b)); break;
    case 2: __asm__ volatile("mulhsu %0,%1,%2":"=r"(value):"r"(a),"r"(b)); break;
    case 3: __asm__ volatile("mulhu %0,%1,%2":"=r"(value):"r"(a),"r"(b)); break;
    case 4: __asm__ volatile("div %0,%1,%2":"=r"(value):"r"(a),"r"(b)); break;
    case 5: __asm__ volatile("divu %0,%1,%2":"=r"(value):"r"(a),"r"(b)); break;
    case 6: __asm__ volatile("rem %0,%1,%2":"=r"(value):"r"(a),"r"(b)); break;
    default: __asm__ volatile("remu %0,%1,%2":"=r"(value):"r"(a),"r"(b)); break;
    }
    return value;
}
#endif
int m_selfcheck(void) {
#if COREMARK_NATIVE_M
    for(unsigned i=0;i<sizeof(m_vectors)/sizeof(m_vectors[0]);++i) {
        for(unsigned op=0;op<8;++op) {
            uint32_t actual=operation(op,m_vectors[i][0],m_vectors[i][1]);
            if(actual!=m_vectors[i][op+2]) {
                ee_printf("M_CHECK FAIL vector=%u op=%u expected=%08x actual=%08x\n",i,op,m_vectors[i][op+2],actual);
                return 0;
            }
        }
    }
    uart_puts("M_CHECK PASS vectors=128 instructions=8\n");
#else
    uart_puts("M_CHECK SKIP software-ISA control\n");
#endif
    return 1;
}
