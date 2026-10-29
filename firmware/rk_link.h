#ifndef RK_LINK_H
#define RK_LINK_H
#include <stdint.h>
#define RK_REG(a) (*(volatile uint32_t *)(a))
/* CPU MMIO only; the RK-side I2C slave remains at 7-bit address 0x66. */
#define RK_TX RK_REG(0x00030400u)
#define RK_STATUS RK_REG(0x00030404u)
#define RK_PARAM RK_REG(0x00030408u)
#define RK_SEQ RK_REG(0x0003040cu)
#define RK_ACK RK_REG(0x00030410u)
#define RK_CLEAR RK_REG(0x00030414u)
/* Single producer; full returns 0 so caller can retry without losing data. */
static inline int rk_try_send(uint8_t byte) {
    if (!(RK_STATUS & 1u)) return 0;
    RK_TX = byte;
    return 1;
}
/* Latest value snapshot. Sequence comparison handles concurrent updates. */
static inline int rk_get_parameter(uint32_t *value, uint32_t *seq) {
    uint32_t before, after, data;
    if (!(RK_STATUS & 4u)) return 0;
    do { before=RK_SEQ; data=RK_PARAM; after=RK_SEQ; } while(before!=after);
    *value=data; *seq=after; return 1;
}
/* Acknowledge after using/copying the value; stale ACK leaves new data pending. */
static inline void rk_ack_parameter(uint32_t seq) { RK_ACK=seq; }
#endif
