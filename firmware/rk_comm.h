#ifndef RK_COMM_H
#define RK_COMM_H
#include <stdint.h>
#include <stddef.h>
/* Cooperative service: call poll frequently; no IRQ/other producer may use
 * the same IIC mailbox, SPI registers or log queue concurrently.
 * No dynamic allocation. Parameter 0 controls GPIO[1:0]; 1..15 are application values.
 */
void rk_comm_init(void);
void rk_comm_poll(void);
uint32_t rk_comm_parameter(unsigned index);
/* Queue CPU-originated serial/log bytes. Returns accepted count; full drops
 * remaining bytes and increments drop counter. No UART RX hardware is implied. */
size_t rk_comm_send(const uint8_t *data,size_t size);
#endif
