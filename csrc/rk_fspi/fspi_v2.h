#ifndef FSPI_V2_H
#define FSPI_V2_H
#include <stddef.h>
#include <stdint.h>
/* Optional CPU-side driver. Not included in or linked into existing firmware.
 * Main acore_dual_top uses 0x30300. ENABLE_VIDEO=1 remaps to 0x30700.
 * Application must coordinate lengths/readiness with RK, e.g. over IIC.
 * Single CPU owner; no interrupts/second core may interleave INDEX/DATA.
 */
#ifndef FSPI_V2_BASE
#define FSPI_V2_BASE 0x00030300u
#endif
#define FSPI_V2_REG(o) (*(volatile uint32_t *)(uintptr_t)(FSPI_V2_BASE+(o)))
static inline void fspi_v2_fence(void) { __asm__ volatile("fence iorw, iorw" ::: "memory"); }
static inline int fspi_v2_present(void) {return FSPI_V2_REG(0x1c)==0x46535032u;}
/* Returns 0 on success; -1 bounds, -2 busy/ownership, -3 rejection, -4 ABI. */
static inline int fspi_v2_arm_rx(size_t n) {
 if(!fspi_v2_present())return -4;
 if(!n || n>2048)return -1;
 if((FSPI_V2_REG(8)&1u) || (FSPI_V2_REG(0x18)&4u))return -2;
 FSPI_V2_REG(12)=8;FSPI_V2_REG(0x10)=(uint32_t)n;fspi_v2_fence();
 return (FSPI_V2_REG(8)&8u)?-3:0;
}
static inline int fspi_v2_receive(uint8_t *dst,size_t n) {
 size_t i;
 if(!fspi_v2_present())return -4;
 if(!dst || !n || n>2048 || n!=FSPI_V2_REG(0x10))return -1;
 if((FSPI_V2_REG(8)&1u) || !(FSPI_V2_REG(0x18)&1u))return -2;
 FSPI_V2_REG(12)=8;
 for(i=0;i<n;i++){FSPI_V2_REG(0)=i;dst[i]=(uint8_t)FSPI_V2_REG(4);}
 fspi_v2_fence();return (FSPI_V2_REG(8)&8u)?-3:0;
}
static inline int fspi_v2_publish(const uint8_t *src,size_t n) {
 size_t i;
 if(!fspi_v2_present())return -4;
 if(!src || !n || n>2048)return -1;
 if((FSPI_V2_REG(8)&1u) || (FSPI_V2_REG(0x18)&2u))return -2;
 FSPI_V2_REG(12)=8;
 for(i=0;i<n;i++){
  FSPI_V2_REG(0)=i;FSPI_V2_REG(4)=src[i];
  if(FSPI_V2_REG(8)&8u)return -3;
 }
 fspi_v2_fence();FSPI_V2_REG(0x14)=(uint32_t)n;fspi_v2_fence();
 return (FSPI_V2_REG(8)&8u)?-3:0;
}
#endif
