/* UART MMIO demo for RV32I: no standard library is required. */
#define MMIO32(address) (*(volatile unsigned int *)(address))

/* Use 32-bit loads/stores: peripheral_bus accepts dev_size == 2'b10. */
#define UART_TXDATA MMIO32(0x00030100u)
#define UART_STATUS MMIO32(0x00030104u)
#define UART_READY  1u

/* STATUS bit 0 is 1 when the transmitter is idle. */
static void uart_wait_idle(void)
{
    while ((UART_STATUS & UART_READY) == 0u) {
        /* Hardware updates this volatile register while we wait. */
    }
}

static void uart_putc(char character)
{
    uart_wait_idle();
    /* Only the low byte is transmitted; the upper 24 bits are ignored. */
    UART_TXDATA = (unsigned int)(unsigned char)character;
}

static void uart_puts(const char *text)
{
    while (*text != '\0') {
        uart_putc(*text);
        ++text;
    }
}

int main(void)
{
    uart_puts("Hello RV32!\r\n");

    /* Do not let start.s end simulation before the final stop bit finishes. */
    uart_wait_idle();

    /* start.s writes this return value to TOHOST (0x00030000). */
    return 1;
}
