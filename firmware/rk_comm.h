#ifndef RK_COMM_H
#define RK_COMM_H
#include <stdint.h>
#include <stddef.h>
/* Cooperative service: call poll frequently; no IRQ/other producer may use
 * the same SPI registers or log queue concurrently. video_diagnostic and
 * fspi_service both use the SPI-only rk_spi_comm.c transport.
 * No dynamic allocation. Parameter 0 controls GPIO[1:0]; 1..15 are application values.
 */
void rk_comm_init(void);
void rk_comm_poll(void);
uint32_t rk_comm_parameter(unsigned index);
/* Optional application extension; run only short, non-blocking work here.
 * Response storage has response_capacity bytes. Return a COMM_* status and
 * supply its payload length; the transport seals and publishes the packet.
 */
uint16_t rk_comm_application_command(uint16_t operation,const uint8_t *request,
                                   uint16_t length,uint8_t *response,uint16_t response_capacity,
                                   uint16_t *response_length);
/* Queue CPU-originated serial/log bytes. Returns accepted count; full drops
 * remaining bytes and increments drop counter. No UART RX hardware is implied. */
size_t rk_comm_send(const uint8_t *data,size_t size);
#endif
