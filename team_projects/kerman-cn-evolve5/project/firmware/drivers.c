#include "soc.h"

void uart_init(void) {
    UART_DIV = (SOC_CLOCK_HZ + SOC_UART_BAUD/2u) / SOC_UART_BAUD;
    UART_STATUS = UART_OVERRUN | UART_FRAME_ERROR;
}

void uart_putc(char c) {
    // Hardware applies backpressure until the preceding frame is complete.
    UART_DATA = (uint8_t)c;
}

void uart_puts(const char *text) {
    while (*text) uart_putc(*text++);
}

void uart_flush(void) {
    while (!(UART_STATUS & UART_TX_READY)) { }
}

void uart_puthex8(uint8_t value) {
    const char *hex = "0123456789ABCDEF";
    uart_putc(hex[value >> 4]);
    uart_putc(hex[value & 15u]);
}

void uart_put_u32(uint32_t value) {
    char digits[10];
    unsigned count = 0;
    do {
        digits[count++] = (char)('0' + value % 10u);
        value /= 10u;
    } while (value != 0);
    while (count) uart_putc(digits[--count]);
}

uint64_t timer_ticks(void) {
    // Retrying high-low-high prevents tearing across a 32-bit rollover.
    uint32_t hi1,lo,hi2;
    do { hi1=TIMER_HI; lo=TIMER_LO; hi2=TIMER_HI; } while (hi1 != hi2);
    return ((uint64_t)hi1 << 32) | lo;
}

void timer_start(void) {
    TIMER_CTRL = 0;
    TIMER_HI = 0;
    TIMER_LO = 0;
    TIMER_CTRL = 1;
}

void timer_delay(uint32_t ticks) {
    uint64_t begin = timer_ticks();
    while (timer_ticks() - begin < ticks) { }
}

void timer_set_compare(uint64_t target) {
    uint32_t enabled = TIMER_CTRL & 1u;
    TIMER_CTRL = enabled;
    TIMER_CMP_HI = (uint32_t)(target >> 32);
    TIMER_CMP_LO = (uint32_t)target;
    TIMER_CTRL = enabled | 2u;
}

void timer_disable_compare(void) {
    TIMER_CTRL = TIMER_CTRL & 1u;
}

int uart_getc_timeout(uint8_t *value,uint32_t ticks) {
    uint64_t begin = timer_ticks();
    while (!(UART_STATUS & UART_RX_VALID)) {
        if (timer_ticks() - begin >= ticks) return 0;
    }
    *value = (uint8_t)UART_DATA;
    return 1;
}
