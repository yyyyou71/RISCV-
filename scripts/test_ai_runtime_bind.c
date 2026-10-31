/* Actual runtime with a minimal software MMIO responder. No operator math or
 * RTL is simulated: check descriptor preflight and exact input rebinding. */
#define _GNU_SOURCE
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include "ai_runtime.h"
#define REG(a) (*(volatile uint32_t *)(a))
static uint8_t *memory;
static uint32_t expected_input,launched;
void ai_runtime_poll(void){
    if(REG(0x30200)&1){
        if(!launched){assert(REG(0x30208)==expected_input && REG(0x3020c)==0x12000);}
        else{assert(REG(0x30208)==0x20000 && REG(0x3020c)==expected_input);}
        launched++;REG(0x30200)=0;REG(0x30230)=REG(0x30234)=1;
        REG(0x30228)=10;REG(0x3022c)=8;REG(0x31004)=18;
    }else if(REG(0x31000)&1){
        uint32_t address=REG(0x31008),bytes=REG(0x3100c);assert(address+bytes<=0x40000);
        if(REG(0x31000)&2)memcpy(memory+address,(void *)0x31100,bytes);
        else memcpy((void *)0x31100,memory+address,bytes);
        REG(0x31000)=0;REG(0x31004)=18;
    }
}
int main(void){
    assert(mmap((void *)0x30000,0x2000,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED,-1,0)!=(void *)-1);
    memory=calloc(1,0x40000);assert(memory);REG(0x31004)=16;REG(0x30244)=16;
    ai_model_header h={AI_MODEL_MAGIC,2,64,64,2,0x10040,0x10000,0x30000,0x11000,32,0x21000,32,0x20000,1,0,0};
    ai_task tasks[2]={{1,0x11000,0x12000,0,0x20000,0x13000,0x10001,0x10001,5,4,1,1,0,{0,0,0}},
                      {2,0x20000,0x11000,0,0x21000,0x14000,0x10001,0x10001,0,4,1,1,0,{0,0,0}}};
    memcpy(memory+0x10000,&h,64);memcpy(memory+0x10040,tasks,sizeof(tasks));ai_run_result r;
    expected_input=0x11000;assert(ai_run_model(0x10000,&r)==0 && launched==2);
    launched=0;expected_input=0x3f00000;
    assert(ai_run_model_input(0x10000,expected_input,32,&r)==0 && launched==2 && r.completed==2);
    assert(!memcmp(memory+0x10040,tasks,sizeof(tasks)));
    launched=0;
    assert(ai_run_model_input(0x10000,0x20000,32,&r)==AI_BAD_RANGE && !launched);
    assert(ai_run_model_input(0x10000,0x3f00000,16,&r)==AI_BAD_RANGE && !launched);
    assert(ai_run_model_input(0x10000,0x3fffff0,32,&r)==AI_BAD_RANGE && !launched);
    ((ai_task *)(memory+0x10040))->input_addr+=16;
    assert(ai_run_model_input(0x10000,expected_input,32,&r)==AI_BAD_RANGE && !launched && r.failed_task==0);
    puts("PASS runtime software: original path, bound CONV/ADD input, immutable DDR descriptors, overlap/size/range preflight rejection");
    return 0;
}
