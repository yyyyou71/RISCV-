#ifndef RV32_MACHINE_H
#define RV32_MACHINE_H
#include "soc.h"
typedef struct {
    uint32_t x[32];
    uint32_t mepc,mstatus,mcause,mtval;
} machine_frame;
_Static_assert(sizeof(machine_frame)==144,"Trap frame layout must match entry assembly");
void machine_init(void);
void machine_trap_dispatch(machine_frame *frame);
void machine_exception(machine_frame *frame);
void machine_timer_interrupt(machine_frame *frame);
void machine_fatal(machine_frame *frame);
#define csr_read(name) ({ uint32_t value; __asm__ volatile("csrr %0, " #name : "=r"(value)); value; })
#define csr_write(name,value) __asm__ volatile("csrw " #name ", %0" :: "r"((uint32_t)(value)) : "memory")
#define csr_set(name,value) __asm__ volatile("csrs " #name ", %0" :: "r"((uint32_t)(value)) : "memory")
#define csr_clear(name,value) __asm__ volatile("csrc " #name ", %0" :: "r"((uint32_t)(value)) : "memory")
#endif
