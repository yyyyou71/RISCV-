#ifndef CACHE3_PLATFORM_H
#define CACHE3_PLATFORM_H
#include "soc.h"
#define MON_BASE 0x40003000u
#define MON_REG(offset) MMIO32(MON_BASE+(offset))
#define MON_MAGIC 0x43414333u
int platform_valid(void);
void platform_identity(void);
void platform_stats(void);
uint32_t cache_probe(void);
uint32_t platform_cache_selftest(void);
#endif
