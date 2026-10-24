#define MMIO32(address) (*(volatile unsigned int *)(address))
#define UART_TXDATA MMIO32(0x00030100u)
#define UART_STATUS MMIO32(0x00030104u)
#define GPIO_DATA MMIO32(0x00030108u)
#define CYCLE_COUNT MMIO32(0x0003000cu)

static volatile unsigned int initialized_word = 0x12345678u;
static volatile unsigned int scratch[64];
static volatile unsigned char lanes[8] __attribute__((aligned(4)));

static void uart_putc(char character)
{
    while ((UART_STATUS & 1u) == 0u) {}
    UART_TXDATA = (unsigned int)(unsigned char)character;
}

static void uart_puts(const char *text)
{
    while (*text)
        uart_putc(*text++);
}

static int fail(void)
{
    GPIO_DATA = 2u;
    uart_puts("SELFTEST FAIL\r\n");
    while ((UART_STATUS & 1u) == 0u) {}
    return 0;
}

int main(void)
{
    unsigned int index;
    unsigned int previous_cycles;
    volatile signed char *signed_lanes = (volatile signed char *)lanes;
    volatile unsigned short *halves = (volatile unsigned short *)lanes;
    volatile signed short *signed_halves = (volatile signed short *)lanes;
    volatile unsigned int *words = (volatile unsigned int *)lanes;

    uart_puts("RV32I FPGA 25MHz 115200\r\n");
    if (initialized_word != 0x12345678u || scratch[0] != 0u || scratch[63] != 0u)
        return fail();

    for (index = 0; index < 64; ++index)
        scratch[index] = (index << 16) ^ (0x10203040u + index);
    for (index = 0; index < 64; ++index)
        if (scratch[index] != ((index << 16) ^ (0x10203040u + index)))
            return fail();

    words[0] = 0x11223344u;
    lanes[1] = 0x80u;
    if (words[0] != 0x11228044u || signed_lanes[1] != -128 || lanes[1] != 128u)
        return fail();
    halves[1] = 0x8001u;
    if (words[0] != 0x80018044u || signed_halves[1] != -32767 || halves[1] != 32769u)
        return fail();
    words[1] = 0xaabbccddu;
    if (lanes[4] != 0xddu || halves[3] != 0xaabbu)
        return fail();

    GPIO_DATA = 1u;
    if (GPIO_DATA != 1u)
        return fail();
    previous_cycles = CYCLE_COUNT;
    if (CYCLE_COUNT <= previous_cycles)
        return fail();

    uart_puts("RAM INIT/BSS/BYTE/HALF/WORD PASS\r\n");
    uart_puts("SELFTEST PASS\r\n");
    while ((UART_STATUS & 1u) == 0u) {}
    return 1;
}
