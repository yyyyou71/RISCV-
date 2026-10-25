/* Platform port for the unmodified EEMBC CoreMark 1.0 sources. */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H
#include <stdint.h>
#include <stddef.h>
#include "coremark_build_config.h"
#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0
#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MULTITHREAD 1
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0
#define COMPILER_VERSION "GCC " __VERSION__
#define COMPILER_FLAGS COREMARK_FLAGS_TEXT
#define MEM_LOCATION "Code=ROM32KiB Data=RAM32KiB Static2000B; cache/backend/latency: see matching simulation manifest"
typedef int16_t ee_s16;
typedef uint16_t ee_u16;
typedef int32_t ee_s32;
typedef uint32_t ee_u32;
typedef uint8_t ee_u8;
typedef double ee_f32;
typedef uintptr_t ee_ptr_int;
typedef size_t ee_size_t;
typedef uint32_t CORE_TICKS; /* microseconds, NOT CPU cycles */
#define CORETIMETYPE uint64_t
#define align_mem(x) ((void *)((((ee_ptr_int)(x))+3u)&~(ee_ptr_int)3u))
extern ee_u32 default_num_contexts;
typedef struct CORE_PORTABLE_S { ee_u8 portable_id; } core_portable;
void portable_init(core_portable *p,int *argc,char *argv[]);
void portable_fini(core_portable *p);
int ee_printf(const char *format,...);
/* Rename the entry through this permitted port header, without editing core_main.c. */
#define main coremark_main
#endif
