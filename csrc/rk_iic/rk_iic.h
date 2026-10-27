#ifndef RK_IIC_H
#define RK_IIC_H
#include <stdint.h>
#define RK_IIC_DEFAULT_ADDRESS 0x66u
#define RK_IIC_INIT { -1, RK_IIC_DEFAULT_ADDRESS }
/* RK Linux API, not RV32 firmware. Initialize with RK_IIC_INIT.
 * One owner per device; serialize complete operations across threads/processes.
 * Return 0 on success or -1 with errno unless stated otherwise.
 * Failed side-effect writes have uncertain outcome: do not blindly retry. */
typedef struct { int fd; uint8_t address; } rk_iic;
int rk_iic_open(rk_iic *dev, const char *path, uint8_t address);
void rk_iic_close(rk_iic *dev);
int rk_iic_read_reg(rk_iic *dev, uint8_t reg, uint8_t *value);
int rk_iic_write_reg(rk_iic *dev, uint8_t reg, uint8_t value);
int rk_iic_get_status(rk_iic *dev, uint8_t *version, uint8_t *status);
/* Verify shadow bytes, commit, verify sequence increment. Not frame-level ACK. */
int rk_iic_set_parameter(rk_iic *dev, uint32_t value);
/* Returns 1 with byte, 0 if empty, -1 on error. Read is non-destructive. */
int rk_iic_peek(rk_iic *dev, uint8_t *value);
/* Call once after handling a peeked byte. No automatic retry. */
int rk_iic_consume(rk_iic *dev);
#endif
