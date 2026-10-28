/* make test-interrupt 使用的 C 示例：请求与 ACK 寄存器由测试台提供。
 * 板上使用时，trap_handler 应改为重设真正的定时器截止时间以撤销请求。
 */
#define IRQ_ACK (*(volatile unsigned int *)0x00030010)

static volatile unsigned int interrupt_count;
static volatile unsigned int bad_cause;
extern void trap_entry(void);

void trap_handler(void)
{
    unsigned int cause;
    __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
    if (cause == 0x80000007u)
        ++interrupt_count;
    else
        bad_cause = cause;
    IRQ_ACK = 0;
}

int main(void)
{
    interrupt_count = 0;
    bad_cause = 0;
    __asm__ volatile ("csrw mtvec, %0" :: "r"(trap_entry) : "memory");
    __asm__ volatile ("csrs mie, %0" :: "r"(0x80u) : "memory");
    __asm__ volatile ("csrsi mstatus, 8" ::: "memory");

    /* 测试台在这个全局标签对应的指令处提出请求。 */
    __asm__ volatile (".globl interrupt_demo_wait\ninterrupt_demo_wait:\nnop" ::: "memory");
    while (interrupt_count == 0)
        __asm__ volatile ("nop");

    __asm__ volatile ("csrci mstatus, 8" ::: "memory");
    return (interrupt_count == 1 && bad_cause == 0) ? 1 : 0;
}
