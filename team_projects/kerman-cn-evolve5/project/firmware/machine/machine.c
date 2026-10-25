#include "machine.h"
extern void machine_trap_entry(void);
void machine_init(void) {
    csr_clear(mstatus,8u);
    csr_write(mie,0);
    csr_write(mtvec,(uintptr_t)machine_trap_entry);
}
void machine_fatal(machine_frame *frame) {
    csr_clear(mstatus,8u); csr_write(mie,0);
    GPIO_OE=0x83; GPIO_OUT=3;
    uart_puts("MACHINE_FATAL cause="); uart_put_u32(frame->mcause);
    uart_puts(" pc="); uart_put_u32(frame->mepc);
    uart_puts(" tval="); uart_put_u32(frame->mtval); uart_putc('\n'); uart_flush();
    for(;;) {}
}
__attribute__((weak)) void machine_exception(machine_frame *frame) { machine_fatal(frame); }
__attribute__((weak)) void machine_timer_interrupt(machine_frame *frame) {
    (void)frame; timer_disable_compare(); csr_clear(mie,128u);
}
void machine_trap_dispatch(machine_frame *frame) {
    if(frame->mcause==0x80000007u) machine_timer_interrupt(frame);
    else if(!(frame->mcause & 0x80000000u)) machine_exception(frame);
    else machine_fatal(frame);
}
