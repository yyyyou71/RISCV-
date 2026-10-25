#include "soc.h"

// Small, explicit RV32I software helpers. No prebuilt libgcc/newlib is linked.
// All internal arithmetic uses unsigned values to avoid signed-overflow UB.
uint32_t __mulsi3(uint32_t a,uint32_t b) {
    // Product modulo 2^32 for every input bit pattern, including INT32_MIN.
    // Normalize magnitudes and iterate over the smaller one; no benchmark constants.
    uint32_t negative=(a ^ b) >> 31;
    if (a >> 31) a=0u-a;
    if (b >> 31) b=0u-b;
    if (a < b) { uint32_t swap=a; a=b; b=swap; }
    uint32_t out=0;
    while (b) {
        if (b & 1u) out += a;
        a <<= 1; b >>= 1;
    }
    return negative ? 0u-out : out;
}

static uint32_t divide(uint32_t n,uint32_t d,uint32_t *remainder) {
    uint32_t q=0,r=0;
    if (!d) { *remainder=n; return UINT32_MAX; }
    for (int bit=31;bit>=0;--bit) {
        uint32_t carry=r >> 31;
        r=(r << 1) | ((n >> bit) & 1u);
        if (carry || r >= d) { r-=d; q |= 1u << bit; }
    }
    *remainder=r;
    return q;
}

uint32_t __udivsi3(uint32_t a,uint32_t b) {
    uint32_t rem;
    return divide(a,b,&rem);
}

uint32_t __umodsi3(uint32_t a,uint32_t b) {
    uint32_t rem;
    (void)divide(a,b,&rem);
    return rem;
}

int32_t __divsi3(int32_t a,int32_t b) {
    uint32_t ua=(uint32_t)a,ub=(uint32_t)b,rem;
    if (!ub) return -1;
    uint32_t q=divide(a < 0 ? 0u-ua : ua,b < 0 ? 0u-ub : ub,&rem);
    if ((a < 0) != (b < 0)) q=0u-q;
    return (int32_t)q;
}

int32_t __modsi3(int32_t a,int32_t b) {
    uint32_t ua=(uint32_t)a,ub=(uint32_t)b,rem;
    if (!ub) return a;
    (void)divide(a < 0 ? 0u-ua : ua,b < 0 ? 0u-ub : ub,&rem);
    return (int32_t)(a < 0 ? 0u-rem : rem);
}

__attribute__((used,externally_visible)) void *memcpy(void *dst,const void *src,size_t n) {
    unsigned char *d=dst;
    const unsigned char *s=src;
    for (size_t k=0;k<n;++k) d[k]=s[k];
    return dst;
}

__attribute__((used,externally_visible)) void *memset(void *dst,int value,size_t n) {
    unsigned char *d=dst;
    for (size_t k=0;k<n;++k) d[k]=(unsigned char)value;
    return dst;
}

int memcmp(const void *a,const void *b,size_t n) {
    const unsigned char *x=a,*y=b;
    for (size_t k=0;k<n;++k) if (x[k] != y[k]) return x[k] < y[k] ? -1 : 1;
    return 0;
}

size_t strlen(const char *s) {
    size_t n=0;
    while (s[n]) ++n;
    return n;
}
