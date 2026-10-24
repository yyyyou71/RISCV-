#include <stdint.h>

/* CPU 始终从自身 ROM/RAM 执行；DDR 偏移通过外设寄存器传递。 */
#define REG32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))
#define DDR_CTRL REG32(0x31000)
#define DDR_STATUS REG32(0x31004)
#define DDR_ADDRESS REG32(0x31008)
#define DDR_LENGTH REG32(0x3100c)
#define DDR_ERROR REG32(0x31010)
#define DDR_DATA ((volatile uint32_t *)(uintptr_t)0x31100)

static int wait_result(uint32_t error)
{
    uint32_t status = 0;
    for (uint32_t n = 0; n < 200000; ++n) {
        status = DDR_STATUS;
        if (!(status & 1))
            return !(status & 8) && DDR_ERROR == error &&
                   ((status & 6) == (error ? 4u : 2u));
    }
    return 0;
}

static uint32_t pattern(uint32_t round, uint32_t word)
{
    /* 不依赖硬件乘法，确保测试程序完全属于 RV32I。 */
    return 0x91234567u ^ (round << 20) ^ (word << 10) ^ (word << 2) ^ word;
}

int main(void)
{
    uint32_t ready = 0;
    for (uint32_t n = 0; n < 200000; ++n)
        if (DDR_STATUS & 16) { ready = 1; break; }
    if (!ready) return 10;

    for (uint32_t round = 0; round < 16; ++round) {
        /* 长度覆盖 16～256 字节，故意跨 2 KiB 列边界，并包含高地址。 */
        uint32_t bytes = (round + 1) << 4;
        uint32_t address = round == 15 ? 0x1fffff00u : 0x7f0u + (round << 12);
        for (uint32_t word = 0; word < bytes / 4; ++word)
            DDR_DATA[word] = pattern(round, word);
        DDR_ADDRESS = address;
        DDR_LENGTH = bytes;
        DDR_CTRL = 3; /* START | WRITE */
        if (!wait_result(0)) return 20;
        for (uint32_t word = 0; word < bytes / 4; ++word) DDR_DATA[word] = 0;
        DDR_CTRL = 1; /* START，方向为读 */
        if (!wait_result(0)) return 21;
        for (uint32_t word = 0; word < bytes / 4; ++word)
            if (DDR_DATA[word] != pattern(round, word)) return 22;
    }

    DDR_LENGTH = 0;
    DDR_CTRL = 1;
    if (!wait_result(1)) return 30;
    DDR_CTRL = 4; /* 清除完成/错误，不能解除致命故障。 */
    if (DDR_STATUS & 15) return 31;
    return 1;
}
