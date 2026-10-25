#include "soc.h"
#include "arithmetic_vectors.h"

volatile uint32_t initialized_word=0x12345678u;
volatile uint8_t initialized_bytes[7]={1,3,5,7,9,0x80,0xff};
static volatile uint32_t bss_words[32];
static unsigned char scratch[96];
volatile uint32_t completed_checks;

static int fail(unsigned code) {
    uart_puts("FAIL "); uart_put_u32(code); uart_putc('\n'); uart_flush();
    return (int)code;
}
#define CHECK(cond,code) do { if (!(cond)) return fail(code); ++completed_checks; } while (0)

int main(void) {
    uart_init(); timer_start();
    uart_puts("RV32I SOC BOOT\n");
    CHECK(initialized_word == 0x12345678u,1);
    CHECK(initialized_bytes[0] == 1 && initialized_bytes[5] == 0x80 && initialized_bytes[6] == 0xff,2);
    for (unsigned k=0;k<32;++k) CHECK(bss_words[k] == 0,3);
    uintptr_t stack;
    __asm__ volatile("mv %0, sp" : "=r"(stack));
    CHECK((stack & 15u) == 0,4);
    memset(scratch,0x5a,sizeof scratch);
    for (unsigned k=0;k<sizeof scratch;++k) CHECK(scratch[k] == 0x5a,5);
    const char *payload="copy from ROM to RAM";
    memcpy(scratch+1,payload,strlen(payload)+1);
    CHECK(memcmp(scratch+1,payload,strlen(payload)+1) == 0,6);
    CHECK(scratch[0] == 0x5a && scratch[95] == 0x5a,7);
    uart_puts("MEM PASS\n");

    // Volatile operands force compiler-generated runtime arithmetic.
    for (unsigned k=0;k<ARITH_COUNT;++k) {
        volatile uint32_t a=arith[k].a,b=arith[k].b;
        CHECK(a*b == arith[k].product,10);
        CHECK(a/b == arith[k].quotient,11);
        CHECK(a%b == arith[k].remainder,12);
        volatile int32_t sa=arith[k].sa,sb=arith[k].sb;
        CHECK(sa/sb == arith[k].signed_quotient,13);
        CHECK(sa%sb == arith[k].signed_remainder,14);
    }
    // Defined helper behavior, not undefined C expressions involving /0 or overflow.
    CHECK(__udivsi3(123,0) == UINT32_MAX && __umodsi3(123,0) == 123,15);
    CHECK((uint32_t)__divsi3(INT32_MIN,-1) == 0x80000000u && __modsi3(INT32_MIN,-1) == 0,16);
    uart_puts("ARITH PASS\n");

    GPIO_OE=0xff; GPIO_OUT=0x12; GPIO_SET=0x81; GPIO_CLEAR=0x10; GPIO_TOGGLE=0x3c;
    CHECK(GPIO_OUT == 0xbf && GPIO_OE == 0xff,20);
    *((volatile uint8_t *)(uintptr_t)(GPIO_BASE+1u))=0xff;
    CHECK(GPIO_OUT == 0xbf,21);
    CHECK(GPIO_IN == 0xa6,22);
    GPIO_OUT=0x5a;
    uart_puts("GPIO PASS\n");

    uint64_t begin=timer_ticks();
    timer_set_compare(begin+20000u);
    CHECK((TIMER_STATUS & 1u) == 0,30);
    timer_delay(22000u);
    CHECK(timer_ticks()-begin >= 20000u && (TIMER_STATUS & 1u),31);
    timer_disable_compare();
    CHECK((TIMER_STATUS & 1u) == 0,32);
    uart_puts("TIMER PASS\n");

    uart_puts("RX?\n");
    uint8_t received;
    CHECK(uart_getc_timeout(&received,SOC_CLOCK_HZ/10u),40);
    CHECK(received == 0xa5 && !(UART_STATUS & (UART_OVERRUN|UART_FRAME_ERROR)),41);
    uart_puts("RX="); uart_puthex8(received); uart_putc('\n');
    uart_puts("SOC PASS\n"); uart_flush();
    return 0;
}
