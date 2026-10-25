#include "machine.h"
#include "platform.h"
#define DECLARE(name) extern void probe_##name(void); extern char probe_##name##_fault,probe_##name##_resume
DECLARE(ecall); DECLARE(ebreak); DECLARE(illegal); DECLARE(misaligned_load); DECLARE(misaligned_store);
DECLARE(load_access); DECLARE(rom_write); DECLARE(unknown_csr); DECLARE(readonly_csr); DECLARE(misaligned_jump); DECLARE(fetch_access);
typedef struct { const char *name; void (*call)(void); const char *fault,*resume; uint32_t cause,tval; } test_case;
#define CASE(name,cause,tval) {#name,probe_##name,&probe_##name##_fault,&probe_##name##_resume,cause,tval}
static const test_case cases[]={
    CASE(ecall,11,0),CASE(ebreak,3,0),CASE(illegal,2,0),CASE(misaligned_load,4,1),CASE(misaligned_store,6,1),
    CASE(load_access,5,0x50000000u),CASE(rom_write,7,0),CASE(unknown_csr,2,0),CASE(readonly_csr,2,0),
    CASE(misaligned_jump,0,2),CASE(fetch_access,1,0x50000000u)
};
static const test_case * volatile expected;
static volatile unsigned exception_count,nested_request,nested_done;
static volatile uint32_t irq_count;
void machine_exception(machine_frame *frame) {
    const test_case *test=(const test_case *)expected;
    if(!test) machine_fatal(frame);
    uint32_t epc=test->cause==1 ? test->tval : (uint32_t)(uintptr_t)test->fault;
    uint32_t tval=test->cause==2 ? *(const uint32_t *)(uintptr_t)test->fault : test->cause==3 ? epc : test->tval;
    if(frame->mcause!=test->cause || frame->mepc!=epc || frame->mtval!=tval || (frame->mstatus & 8u))
        machine_fatal(frame);
    ++exception_count;
    if(nested_request) {
        nested_request=0; expected=&cases[1]; probe_ebreak(); expected=test; nested_done=1;
    }
    frame->mepc=(uint32_t)(uintptr_t)test->resume;
}
void machine_timer_interrupt(machine_frame *frame) {
    (void)frame;
    timer_disable_compare();
    timer_set_compare(timer_ticks()+SOC_CLOCK_HZ/4u);
    ++irq_count;
    GPIO_TOGGLE=1u;
}
int main(void) {
    uart_init(); GPIO_OE=0x83; GPIO_OUT=0;
    uart_puts("RV32I MACHINE DEMO\nBUILD=CACHE3_BOARD\nCLK=25000000 BAUD=115200\n");
    uint32_t impl=csr_read(mimpid);
    uart_puts("BP_ENABLE="); uart_put_u32(impl&1u); uart_puts(" BP_ENTRIES="); uart_put_u32(1u<<((impl>>8)&31u)); uart_putc('\n');
    platform_identity();
    uint32_t cache_result=platform_cache_selftest();
    if(cache_result) { uart_puts("CACHE_SELFTEST_FAIL code="); uart_put_u32(cache_result); uart_putc('\n'); GPIO_OUT=3; uart_flush(); for(;;) {} }
    for(unsigned index=0;index<sizeof(cases)/sizeof(cases[0]);++index) {
        expected=&cases[index]; cases[index].call();
        if(exception_count!=index+1) machine_fatal(&(machine_frame){0});
        uart_puts("TRAP_PASS "); uart_puts(cases[index].name); uart_putc('\n');
    }
    expected=&cases[0]; nested_request=1; probe_ecall();
    if(!nested_done || exception_count!=13) machine_fatal(&(machine_frame){0});
    uart_puts("NESTED_TRAP_PASS\nEXCEPTIONS=13\n");
    GPIO_SET=2u; timer_start(); timer_set_compare(timer_ticks()+SOC_CLOCK_HZ/4u);
    csr_write(mie,128u); csr_set(mstatus,8u);
    uart_puts("MACHINE_READY timer_irq=250ms h=status r=reset\n");
    uint32_t printed=0;
    for(;;) {
        uint32_t count=irq_count;
        if(count!=printed) { printed=count; uart_puts("IRQ_TICK="); uart_put_u32(count); uart_putc('\n'); }
        if(UART_STATUS & UART_RX_VALID) {
            char command=(char)UART_DATA;
            if(command=='h') { uart_puts("IRQ_COUNT="); uart_put_u32(irq_count); uart_putc('\n'); platform_identity(); platform_stats(); }
            if(command=='r') { csr_clear(mstatus,8u); uart_puts("RESET\n"); uart_flush(); GPIO_SET=0x80; for(;;) {} }
        }
    }
}
