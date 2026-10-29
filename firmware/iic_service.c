#include "rk_link.h"
#define UART_TX RK_REG(0x00030100u)
#define UART_STATUS RK_REG(0x00030104u)
#define GPIO_DATA RK_REG(0x00030108u)
static void uart_putc(uint8_t c) {
    while (!(UART_STATUS & 1u)) {} UART_TX=c;
}
int main(void) {
    static const uint8_t hello[]={'R','V','3','2',' ','R','E','A','D','Y',10,0};
    const uint8_t *p=hello;
    const char *banner="RV32 IIC SERVICE";
    uint32_t value=0, seq=0;
    unsigned int remaining=0;
    while (*banner) uart_putc((uint8_t)*banner++);
    uart_putc(13); uart_putc(10);
    /* Example application: GPIO uses low two bits; return four LE bytes. */
    for (;;) {
        if (*p) { if (rk_try_send(*p)) ++p; }
        else if (remaining) {
            if (rk_try_send((uint8_t)value)) { value >>= 8; --remaining; }
        } else if (rk_get_parameter(&value,&seq)) {
            GPIO_DATA=value & 3u;
            rk_ack_parameter(seq);
            remaining=4;
        }
    }
}
