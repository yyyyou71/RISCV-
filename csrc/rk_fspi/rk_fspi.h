#ifndef RK_FSPI_H
#define RK_FSPI_H
#include <stddef.h>
#include <stdint.h>
/* Initialize fd=-1. Only standard Linux spidev with quad support is supported. */
typedef struct { int fd; uint32_t speed_hz; } rk_fspi;
int rk_fspi_open(rk_fspi *dev, const char *path, uint32_t speed_hz);
void rk_fspi_close(rk_fspi *dev);
int rk_fspi_write(rk_fspi *dev, const uint8_t *data, size_t size);
int rk_fspi_read(rk_fspi *dev, uint8_t *data, size_t size);
#endif
