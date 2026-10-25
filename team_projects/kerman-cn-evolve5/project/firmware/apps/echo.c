#include "soc.h"
int main(void) {
    uart_init(); timer_start(); GPIO_OE=0xff;
    uart_puts("ECHO READY\n");
    for (unsigned k=0;k<4;++k) {
        uint8_t c;
        if (!uart_getc_timeout(&c,SOC_CLOCK_HZ/10u)) {
            uart_puts("TIMEOUT\n"); uart_flush(); return 1;
        }
        GPIO_OUT=c;
        uart_putc((char)c);
    }
    uart_puts("\nECHO PASS\n"); uart_flush();
    return 0;
}
