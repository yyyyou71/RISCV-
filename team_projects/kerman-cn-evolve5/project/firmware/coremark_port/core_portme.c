/*
 * Bare-metal RV32I port. Algorithm files under third_party/coremark are unchanged.
 * All GPIO/UART reporting occurs outside the benchmark's measured interval.
 */
#include "coremark.h"
#include "soc.h"
#include "machine.h"
#include "platform.h"
#include <stdarg.h>

volatile ee_s32 seed1_volatile=0;
volatile ee_s32 seed2_volatile=0;
volatile ee_s32 seed3_volatile=0x66;
volatile ee_s32 seed4_volatile=COREMARK_DEFAULT_ITERATIONS;
volatile ee_s32 seed5_volatile=0;
ee_u32 default_num_contexts=1;
static uint64_t start_cycles,stop_cycles;
static unsigned mode_validation;
static unsigned tick_overflow;

/* Full-range unsigned 64/32 division. Used ONLY for timing/reporting, not algorithms. */
static uint64_t div64by32(uint64_t n,uint32_t d,uint32_t *remainder) {
    uint64_t q=0;
    uint32_t r=0;
    for(unsigned bit=0;bit<64;++bit) {
        uint32_t carry=r>>31;
        r=(r<<1)|(uint32_t)(n>>63); n<<=1; q<<=1;
        if(carry || r>=d) { r-=d; q|=1; }
    }
    if(remainder) *remainder=r;
    return q;
}

static int put_unsigned(uint64_t value,unsigned base,unsigned width,char pad) {
    char buffer[32]; unsigned count=0; int written=0;
    do {
        uint32_t digit;
        value=div64by32(value,base,&digit);
        buffer[count++]="0123456789abcdef"[digit];
    } while(value);
    while(width>count) { uart_putc(pad); --width; ++written; }
    while(count) { uart_putc(buffer[--count]); ++written; }
    return written;
}

int ee_printf(const char *format,...) {
    va_list ap; va_start(ap,format); int written=0;
    while(*format) {
        if(*format!='%') { uart_putc(*format++); ++written; continue; }
        ++format;
        char pad=' '; unsigned width=0; int is_long=0;
        if(*format=='0') { pad='0'; ++format; }
        while(*format>='0' && *format<='9') width=width*10u+(unsigned)(*format++-'0');
        if(*format=='l') { is_long=1; ++format; }
        char type=*format++;
        if(type=='s') {
            const char *s=va_arg(ap,const char *);
            if(!s) s="(null)";
            while(*s) { uart_putc(*s++); ++written; }
        } else if(type=='d' || type=='i') {
            int32_t v=is_long ? (int32_t)va_arg(ap,long) : va_arg(ap,int);
            uint32_t magnitude=(uint32_t)v;
            if(v<0) { uart_putc('-'); ++written; magnitude=0u-magnitude; }
            written+=put_unsigned(magnitude,10,width,pad);
        } else if(type=='u' || type=='x' || type=='X') {
            uint32_t v=is_long ? (uint32_t)va_arg(ap,unsigned long) : va_arg(ap,unsigned int);
            written+=put_unsigned(v,type=='u'?10:16,width,pad);
        } else if(type=='c') { uart_putc((char)va_arg(ap,int)); ++written; }
        else if(type=='%') { uart_putc('%'); ++written; }
        else { uart_puts("[FORMAT ERROR]"); }
    }
    va_end(ap); return written;
}

void start_time(void) {
    GPIO_SET=1;
    /* A flushed UART cannot leave a final report byte in flight at measurement start. */
    uart_flush();
    start_cycles=timer_ticks();
}

void stop_time(void) {
    stop_cycles=timer_ticks();
    GPIO_CLEAR=1;
}

CORE_TICKS get_time(void) {
    uint64_t us=div64by32(stop_cycles-start_cycles,SOC_CLOCK_HZ/1000000u,0);
    if(us>UINT32_MAX) { tick_overflow=1; return UINT32_MAX; }
    return (CORE_TICKS)us;
}

secs_ret time_in_secs(CORE_TICKS ticks) {
    return ticks/1000000u;
}

void portable_init(core_portable *p,int *argc,char *argv[]) {
    (void)argc; (void)argv;
    p->portable_id=1; tick_overflow=0;
    ee_printf("CM_BEGIN mode=%s requested_iterations=%u clock_hz=%u data_size=2000\n",
              mode_validation?"validation":"performance",(unsigned)seed4_volatile,(unsigned)SOC_CLOCK_HZ);
    uart_flush();
}

void portable_fini(core_portable *p) {
    core_results *r=(core_results *)((unsigned char *)p - offsetof(core_results,port));
    uint64_t cycles=stop_cycles-start_cycles;
    ee_s16 expected_seed=(ee_s16)(mode_validation?0x3415:0);
    unsigned crc_ok=r->err==0 && r->seed1==expected_seed && r->seed2==expected_seed && r->seed3==0x66
        && r->size==666 && r->execs==ALL_ALGORITHMS_MASK
        && r->crclist==(mode_validation?0xe3c1:0xe714)
        && r->crcmatrix==(mode_validation?0x0747:0x1fd7)
        && r->crcstate==(mode_validation?0x8d84:0x8e3a);
    unsigned time_ok=!tick_overflow && cycles >= (uint64_t)SOC_CLOCK_HZ*10u;
    unsigned score_valid=crc_ok && time_ok;
    ee_printf("CM_RESULT mode=%s iterations=%u cycles=",mode_validation?"validation":"performance",r->iterations);
    put_unsigned(cycles,10,0,' ');
    ee_printf(" clock_hz=%u tick_unit=us seed1=%u seed2=%u seed3=%u data_size=2000 contexts=1 crc_ok=%u time_ok=%u score_valid=%u list=%04x matrix=%04x state=%04x final=%04x\n",
              (unsigned)SOC_CLOCK_HZ,(unsigned)(ee_u16)r->seed1,(unsigned)(ee_u16)r->seed2,(unsigned)(ee_u16)r->seed3,
              crc_ok,time_ok,score_valid,r->crclist,r->crcmatrix,r->crcstate,r->crc);
    if(!crc_ok) uart_puts("CM_FAIL: CRC/data mismatch\n");
    else if(!time_ok) uart_puts("CM_SHORT_RUN: functional check only; not a reportable score\n");
    else uart_puts("CM_VALID: compute precise score from cycles and iterations\n");
    GPIO_OUT=score_valid?2u:crc_ok?0u:3u;
    platform_stats();
    p->portable_id=0;
    uart_flush();
}

int coremark_main(void);

static void run_case(unsigned validation,uint32_t iterations) {
    mode_validation=validation;
    seed1_volatile=validation?0x3415:0;
    seed2_volatile=validation?0x3415:0;
    seed3_volatile=0x66; seed4_volatile=(ee_s32)iterations; seed5_volatile=0;
    (void)coremark_main();
}

static void menu(void) {
    uart_puts("p/v/b [iterations] + Enter: performance/validation/both\n");
    uart_puts("q/w + Enter: 1-iteration function check; h: help; r: reset\n");
    ee_printf("Default iterations=%u; 0 selects upstream auto calibration\n",(unsigned)COREMARK_DEFAULT_ITERATIONS);
    uart_puts("CM_READY\n");
}

static int math_selfcheck(void) {
    uint32_t remainder;
    uint64_t q=div64by32(UINT64_MAX,25,&remainder);
    if(q!=UINT64_C(737869762948382064) || remainder!=15) return 0;
    q=div64by32(UINT64_MAX,UINT32_MAX,&remainder);
    if(q!=UINT64_C(4294967297) || remainder!=0) return 0;
    q=div64by32(UINT64_C(4294967301),25,&remainder);
    if(q!=UINT64_C(171798692) || remainder!=1) return 0;
    return 1;
}

int m_selfcheck(void);
int dual_selfcheck(void);
void coremark_entry(void) {
    _Static_assert(SOC_CLOCK_HZ%1000000u==0,"Microsecond ticks require an integral cycles/us ratio");
    _Static_assert(sizeof(ee_ptr_int)==4 && sizeof(ee_u32)==4 && sizeof(ee_u16)==2,"RV32I data types");
    uart_init(); timer_start(); GPIO_OUT=0; GPIO_OE=0x83;
    uart_puts("RISC-V COREMARK 1.0\n");
    uart_puts("BUILD=" COREMARK_BUILD_ID "\n");
    uint32_t implementation=csr_read(mimpid);
    ee_printf("BP_ENABLE=%u BP_ENTRIES=%u IMPL_ID=%08x\n",implementation&1u,
              1u<<((implementation>>8)&31u),implementation);
    ee_printf("CLK=%u BAUD=%u ISA=%s ABI=ILP32\n",(unsigned)SOC_CLOCK_HZ,(unsigned)SOC_UART_BAUD,COREMARK_SOFTWARE_ISA);
    ee_printf("MISA=%08x HW_M=%u\n",csr_read(misa),(csr_read(misa)>>12)&1u);
    uint32_t front; __asm__ volatile("csrr %0,0xfc0":"=r"(front));
    ee_printf("FRONT_CFG=%08x GSHARE=%u PHT_BITS=%u RAS=%u FETCH=%u LOAD_FWD=%u\n",
              front,front&1u,(front>>4)&15u,(front>>8)&31u,(front>>16)&15u,(front>>1)&1u);
    uint32_t issue; __asm__ volatile("csrr %0,0xfc1":"=r"(issue));
    ee_printf("ISSUE_CFG=%08x ISSUE_WIDTH=%u FETCH_WORDS=%u\n",issue,1u+(issue&1u),1u+((issue>>1)&1u));
    platform_identity();
    if(!platform_valid()) { uart_puts("PORT_CHECK FAIL\n"); uart_flush(); for(;;) {} }
    if(!math_selfcheck()) { uart_puts("PORT_CHECK FAIL\n"); uart_flush(); for(;;) {} }
    if(!m_selfcheck()) { uart_puts("PORT_CHECK FAIL\n"); uart_flush(); for(;;) {} }
    if(!dual_selfcheck()) { uart_puts("DUAL_CHECK FAIL\nPORT_CHECK FAIL\n"); uart_flush(); for(;;) {} }
    uart_puts("PORT_CHECK PASS\n");
    menu();
    char command[24]; unsigned used=0,too_long=0;
    for(;;) {
        if(!(UART_STATUS & UART_RX_VALID)) continue;
        char c=(char)UART_DATA;
        if(c!='\r' && c!='\n') {
            if(used<sizeof(command)-1) command[used++]=c;
            else too_long=1;
            continue;
        }
        if(used==0 && !too_long) continue;
        command[used]=0;
        char op=command[0];
        uint32_t iterations=COREMARK_DEFAULT_ITERATIONS;
        unsigned invalid=too_long;
        char *value=command+1;
        while(*value==' ') ++value;
        if(*value) {
            iterations=0;
            while(*value) {
                if(*value<'0' || *value>'9' || iterations>100000u) { invalid=1; break; }
                iterations=iterations*10u+(unsigned)(*value++-'0');
            }
            if(iterations>1000000u) invalid=1;
        }
        used=0; too_long=0;
        if(invalid) uart_puts("CM_COMMAND_ERROR\n");
        else if(op=='p') run_case(0,iterations);
        else if(op=='v') run_case(1,iterations);
        else if(op=='b') { run_case(0,iterations); run_case(1,iterations); }
        else if(op=='q') run_case(0,1);
        else if(op=='w') run_case(1,1);
        else if(op=='r') {
            uart_puts("RESET\n"); uart_flush(); GPIO_SET=0x80;
            for(;;) {}
        } else if(op=='h') { menu(); continue; }
        else uart_puts("CM_COMMAND_ERROR\n");
        uart_puts("CM_READY\n");
    }
}
