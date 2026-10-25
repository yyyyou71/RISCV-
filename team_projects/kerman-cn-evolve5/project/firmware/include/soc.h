#ifndef RV32_SOC_H
#define RV32_SOC_H
#include <stdint.h>
#include <stddef.h>
#ifndef SOC_CLOCK_HZ
#define SOC_CLOCK_HZ 50000000u
#endif
#ifndef SOC_UART_BAUD
#define SOC_UART_BAUD 115200u
#endif
#define UART_BASE 0x40000000u
#define GPIO_BASE 0x40001000u
#define TIMER_BASE 0x40002000u
#define MMIO32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))
#define UART_DATA   MMIO32(UART_BASE + 0x00u)
#define UART_STATUS MMIO32(UART_BASE + 0x04u)
#define UART_DIV    MMIO32(UART_BASE + 0x08u)
#define UART_LEVEL  MMIO32(UART_BASE + 0x0cu)
#define UART_TX_READY 1u
#define UART_RX_VALID 2u
#define UART_OVERRUN  4u
#define UART_FRAME_ERROR 8u
#define GPIO_OUT    MMIO32(GPIO_BASE + 0x00u)
#define GPIO_OE     MMIO32(GPIO_BASE + 0x04u)
#define GPIO_IN     MMIO32(GPIO_BASE + 0x08u)
#define GPIO_SET    MMIO32(GPIO_BASE + 0x0cu)
#define GPIO_CLEAR  MMIO32(GPIO_BASE + 0x10u)
#define GPIO_TOGGLE MMIO32(GPIO_BASE + 0x14u)
#define TIMER_LO    MMIO32(TIMER_BASE + 0x00u)
#define TIMER_HI    MMIO32(TIMER_BASE + 0x04u)
#define TIMER_CMP_LO MMIO32(TIMER_BASE + 0x08u)
#define TIMER_CMP_HI MMIO32(TIMER_BASE + 0x0cu)
#define TIMER_CTRL  MMIO32(TIMER_BASE + 0x10u)
#define TIMER_STATUS MMIO32(TIMER_BASE + 0x14u)
_Static_assert(sizeof(void *) == 4, "Firmware requires ILP32");
_Static_assert(sizeof(uint32_t) == 4, "Firmware requires 32-bit words");
void uart_init(void);
void uart_putc(char c);
void uart_puts(const char *text);
void uart_puthex8(uint8_t value);
void uart_put_u32(uint32_t value);
void uart_flush(void);
int uart_getc_timeout(uint8_t *value, uint32_t ticks);
void timer_start(void);
uint64_t timer_ticks(void);
void timer_delay(uint32_t ticks);
void timer_set_compare(uint64_t target);
void timer_disable_compare(void);
uint32_t __mulsi3(uint32_t a,uint32_t b);
uint32_t __udivsi3(uint32_t a,uint32_t b);
uint32_t __umodsi3(uint32_t a,uint32_t b);
int32_t __divsi3(int32_t a,int32_t b);
int32_t __modsi3(int32_t a,int32_t b);
void *memcpy(void *dst,const void *src,size_t n);
void *memset(void *dst,int value,size_t n);
int memcmp(const void *a,const void *b,size_t n);
size_t strlen(const char *s);
#endif
