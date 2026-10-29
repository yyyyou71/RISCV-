/*
Copyright 2018 Embedded Microprocessor Benchmark Consortium (EEMBC)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Original Author: Shay Gal-on
*/
#include "coremark.h"
#include "core_portme.h"
#include "platform.h"

#ifndef ITERATIONS
#define ITERATIONS 1000
#endif

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
#define CYCLE_COUNT (*(volatile ee_u32 *)COREMARK_CYCLE_COUNT)

static CORE_TICKS start_cycles;
static CORE_TICKS stop_cycles;

void
start_time(void)
{
    start_cycles = CYCLE_COUNT;
}

void
stop_time(void)
{
    stop_cycles = CYCLE_COUNT;
}

CORE_TICKS
get_time(void)
{
    /* 无符号减法允许跨越回绕点；测量区间必须小于 2^32 个周期。 */
    return (CORE_TICKS)(stop_cycles - start_cycles);
}

secs_ret
time_in_secs(CORE_TICKS ticks)
{
    /* HAS_FLOAT=1 时 secs_ret 为 double，保留不足一秒的小数部分。 */
    return (secs_ret)ticks / (secs_ret)CPU_CLOCK_HZ;
}

ee_u32 default_num_contexts = 1;

/* Function : portable_init
        Target specific initialization code
        Test for some common mistakes.
*/
void
portable_init(core_portable *p, int *argc, char *argv[])
{
    start_cycles = 0;
    stop_cycles = 0;
    *(volatile ee_u32 *)COREMARK_GPIO_DATA = 0;
#ifdef COREMARK_ACORE_DUAL
    ee_printf("Acore in-order dual issue / RV32I+Zmmul / %u Hz / UART 115200\n", CPU_CLOCK_HZ);
#else
    ee_printf("Acore single issue / RV32I+Zmmul / %u Hz / UART 115200\n", CPU_CLOCK_HZ);
#endif

    (void)argc; // prevent unused warning
    (void)argv; // prevent unused warning

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
    {
        ee_printf(
            "ERROR! Please define ee_ptr_int to a type that holds a "
            "pointer!\n");
    }
    if (sizeof(ee_u32) != 4)
    {
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    }
    p->portable_id = 1;
}
/* Function : portable_fini
        Target specific final code
*/
void
portable_fini(core_portable *p)
{
    p->portable_id = 0;
    if (get_time() != 0) {
        ee_printf("CoreMark        : %f\n", (secs_ret)default_num_contexts * seed4_volatile / time_in_secs(get_time()));
        ee_printf("CoreMark/MHz    : %f\n", (secs_ret)default_num_contexts * seed4_volatile * 1000000.0 / get_time());
    }
    ee_printf("COREMARK DONE\n");
    while ((*(volatile ee_u32 *)COREMARK_UART_STATUS & 1u) == 0u) {}
    *(volatile ee_u32 *)COREMARK_GPIO_DATA = 1;
}
