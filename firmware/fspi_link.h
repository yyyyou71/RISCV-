#ifndef FSPI_LINK_H
#define FSPI_LINK_H
#include <stdint.h>
#include <stddef.h>
#define FSPI_REG(a) (*(volatile uint32_t *)(a))
#define FSPI_INDEX FSPI_REG(0x00030300u)
#define FSPI_DATA FSPI_REG(0x00030304u)
#define FSPI_STATUS FSPI_REG(0x00030308u)
#define FSPI_CLEAR FSPI_REG(0x0003030cu)
/* Caller must coordinate ownership with RK (e.g. via IIC). Busy polling alone
   cannot exclude a new host transaction between these CPU instructions.
   Return -1 on bounds, -2 on busy, -3 on rejected access; no rollback. */
static inline int fspi_copy_to_rk(const uint8_t *src,size_t n) {
    size_t i;
    if(!src || !n || n>2048) return -1;
    if(FSPI_STATUS&1u) return -2;
    FSPI_CLEAR=8;
    for(i=0;i<n;i++) {
        if(FSPI_STATUS&1u) return -2;
        FSPI_INDEX=(uint32_t)i;FSPI_DATA=src[i];
        if(FSPI_STATUS&8u) return -3;
    }
    return 0;
}
static inline int fspi_copy_from_rk(uint8_t *dst,size_t n) {
    size_t i;
    if(!dst || !n || n>2048) return -1;
    if(FSPI_STATUS&1u) return -2;
    FSPI_CLEAR=8;
    for(i=0;i<n;i++) {
        if(FSPI_STATUS&1u) return -2;
        FSPI_INDEX=(uint32_t)i;dst[i]=(uint8_t)FSPI_DATA;
        if(FSPI_STATUS&8u) return -3;
    }
    return 0;
}
#endif
