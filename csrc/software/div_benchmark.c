/* 比较硬件/软件除法的独立程序，两次运行的乘法和算法完全一致。
 * 分母随数据变化，避免编译器把常数除法变成移位或乘法。
 * 第一个打印值是目标 CPU 计时周期，第二个是可核对的校验和。
 */
#define PRINT (*(volatile unsigned int *)0x00030004)
#define CYCLES (*(volatile unsigned int *)0x0003000c)

int main(void)
{
    unsigned int state = 0x12345678u;
    unsigned int checksum = 0;
    unsigned int begin = CYCLES;
    for (unsigned int i = 0; i < 200; ++i) {
        state = state * 1664525u + 1013904223u;
        unsigned int divisor = (state >> 24) + 1u;
        checksum += state / divisor;
    }
    unsigned int elapsed = CYCLES - begin;
    PRINT = elapsed;
    PRINT = checksum;
    return 1;
}
