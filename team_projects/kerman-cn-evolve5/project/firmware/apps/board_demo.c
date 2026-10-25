#include "soc.h"

static volatile uint32_t boot_magic=0x25c0ffeeu;
static volatile uint32_t boot_zero[16];
static uint32_t manual_led;

static void help(void) {
    uart_puts("h=help s=status t=toggle r=reset\n");
}

static void status(void) {
    uart_puts("KEY1="); uart_put_u32(GPIO_IN & 1u);
    uart_puts(" LED1="); uart_put_u32((GPIO_OUT >> 1) & 1u);
    uart_putc('\n');
}

static void update_led1(uint32_t key) {
    if ((key ^ manual_led) & 1u) GPIO_SET=2u;
    else GPIO_CLEAR=2u;
}

static void boot_fail(uint32_t code) {
    uart_puts("BOOT FAIL "); uart_put_u32(code); uart_putc('\n'); uart_flush();
    __asm__ volatile("mv a0,%0; li a7,93; ecall" :: "r"(code) : "a0","a7","memory");
    for (;;) { }
}

int main(void) {
    uart_init(); timer_start();
    GPIO_OUT=0; GPIO_OE=0x83u; // GPIO[7] is an internal software-reset request.
    uart_puts("RV32I BOARD READY\nCLK="); uart_put_u32(SOC_CLOCK_HZ);
    uart_puts(" BAUD="); uart_put_u32(SOC_UART_BAUD); uart_putc('\n');
    if (boot_magic != 0x25c0ffeeu) boot_fail(1);
    for (unsigned k=0;k<16;++k) if (boot_zero[k] != 0) boot_fail(2);
    uart_puts("BOOTCHECK PASS\n"); help();
    uint32_t last_key=GPIO_IN & 1u;
    uint32_t last_tick=(uint32_t)timer_ticks();
    update_led1(last_key);
    for (;;) {
        uint32_t now=(uint32_t)timer_ticks();
        // Unsigned subtraction remains valid when the timer low half wraps.
        if ((uint32_t)(now-last_tick) >= SOC_CLOCK_HZ/2u) {
            last_tick=now; GPIO_TOGGLE=1u;
        }
        uint32_t key=GPIO_IN & 1u;
        if (key != last_key) {
            last_key=key; update_led1(key);
            uart_puts("KEY1="); uart_put_u32(key); uart_putc('\n');
        }
        uint32_t serial_status=UART_STATUS;
        if (serial_status & (UART_OVERRUN|UART_FRAME_ERROR)) {
            UART_STATUS=serial_status & (UART_OVERRUN|UART_FRAME_ERROR);
            uart_puts("UART ERROR\n");
        }
        if (serial_status & UART_RX_VALID) {
            uint8_t c=(uint8_t)UART_DATA;
            if (c=='h' || c=='?') help();
            else if (c=='s') status();
            else if (c=='t') {
                manual_led ^= 1u; update_led1(last_key); status();
            } else if (c=='r') {
                uart_puts("RESET\n"); uart_flush(); GPIO_SET=0x80u;
                for (;;) { } // board_reset restarts CPU and clears peripheral state.
            } else if (c!='\r' && c!='\n') uart_puts("UNKNOWN\n");
        }
    }
}
