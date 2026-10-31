#include "ai_first_layer.h"
#include "ai_first_layer_quant.h"
#include "rk_comm.h"
#include "preprocess_capture.h"
#include "../csrc/rk_fspi/comm_protocol.h"
#define REG(a) (*(volatile uint32_t *)(a))
#define CYCLES REG(0x3000cu)
#define STATUS REG(0x31004u)
#define DATA ((volatile uint32_t *)0x31100u)
#define WEIGHT_BASE 0x03d00000u
#define BIAS_BASE (WEIGHT_BASE+FL_BIAS_WORD*4)
#define QUANT_BASE (WEIGHT_BASE+FL_QUANT_WORD*4)
#define OUTPUT_BASE 0x03c00000u
#define OUTPUT_BYTES (48u*48u*32u*2u)
#define IO_TIMEOUT 6250000u
#define AI_TIMEOUT 750000000u
static uint32_t state,error,started,frame_id,input_base,input_bytes;
static uint32_t loaded,chunk,patch_index,checked,bad_channel,expected_bad,actual_bad;
static uint32_t hardware_cycles,hardware_issues,output_h,output_w,first_words[4];
static uint16_t patch[4][3];
static int16_t expected[32];

static void log_text(const char *s){const char *p=s;while(*p)p++;rk_comm_send((const uint8_t *)s,(unsigned)(p-s));}
static void enter(uint32_t next){state=next;started=CYCLES;}
static void fail(uint32_t code){error=code;enter(FL_FAILED);log_text("AI first-layer check failed; read ai-status.\n");}
void ai_first_layer_clear(void){
    unsigned i;
    state=FL_IDLE;error=loaded=chunk=patch_index=checked=0;
    frame_id=input_base=input_bytes=hardware_cycles=hardware_issues=output_h=output_w=0;
    bad_channel=0xffffffffu;expected_bad=actual_bad=0;started=CYCLES;
    for(i=0;i<4;i++)first_words[i]=0;
}
void ai_first_layer_init(void){ai_first_layer_clear();}
int ai_first_layer_busy(void){return state>FL_IDLE && state<FL_PASSED;}
int ai_first_layer_start(uint32_t id,uint32_t input,uint32_t bytes){
    if(ai_first_layer_busy())return -1;
    ai_first_layer_clear();frame_id=id;input_base=input;input_bytes=bytes;
    if(input!=PP_DEFAULT_BASE || bytes!=PP_TENSOR_BYTES){fail(1);return -1;}
    if(REG(0x30244u)!=16u){fail(2);return -1;}
    if((STATUS&25u)!=16u){fail(3);return -1;}
    enter(FL_UPLOAD);log_text("AI: loading real first-layer weights; 96x96x3 -> 48x48x32.\n");
    return 0;
}
static void read_block(uint32_t address,uint32_t bytes,uint32_t next){
    REG(0x31008u)=address;REG(0x3100cu)=bytes;REG(0x31000u)=1;enter(next);
}
static int io_done(void){
    uint32_t s=STATUS;
    if(s&1u){if(CYCLES-started>IO_TIMEOUT)fail(4);return 0;}
    if((s&14u)!=2u){fail(5);return 0;}
    return 1;
}
void ai_first_layer_poll(void){
    uint32_t i,s;
    switch(state){
    case FL_UPLOAD:
        if((STATUS&25u)!=16u){fail(3);break;}
        chunk=FL_ASSET_BYTES-loaded;if(chunk>256)chunk=256;
        for(i=0;i<chunk/4;i++)DATA[i]=fl_assets[loaded/4+i];
        REG(0x31008u)=WEIGHT_BASE+loaded;REG(0x3100cu)=chunk;REG(0x31000u)=3;
        enter(FL_UPLOAD_WAIT);break;
    case FL_UPLOAD_WAIT:
        if(io_done()){
            loaded+=chunk;
            enter(loaded==FL_ASSET_BYTES?FL_PATCH:FL_UPLOAD);
        }
        break;
    case FL_PATCH:
        read_block(input_base+((patch_index/2)*96+patch_index%2)*32,32,FL_PATCH_WAIT);break;
    case FL_PATCH_WAIT:
        if(!io_done())break;
        patch[patch_index][0]=(uint16_t)DATA[0];patch[patch_index][1]=(uint16_t)(DATA[0]>>16);
        patch[patch_index][2]=(uint16_t)DATA[1];
        for(i=0;i<3;i++)if(patch[patch_index][i]>255){fail(6);return;}
        if(++patch_index==4){fl_reference(patch,expected);enter(FL_START);}
        else enter(FL_PATCH);
        break;
    case FL_START:
        if((STATUS&25u)!=16u){fail(3);break;}
        REG(0x30208u)=input_base;REG(0x3020cu)=WEIGHT_BASE;REG(0x30210u)=BIAS_BASE;
        REG(0x30214u)=OUTPUT_BASE;REG(0x30218u)=0x00600060u;REG(0x3021cu)=0x00200003u;
        REG(0x30220u)=91;REG(0x30238u)=6;REG(0x3023cu)=QUANT_BASE;
        REG(0x30240u)=0;REG(0x30248u)=1;REG(0x30200u)=1;
        enter(FL_RUNNING);log_text("AI: first real model layer running on FPGA.\n");break;
    case FL_RUNNING:
        s=REG(0x30204u);
        if(s&1u){if(CYCLES-started>AI_TIMEOUT)fail(7);break;}
        hardware_cycles=REG(0x30228u);hardware_issues=REG(0x3022cu);
        output_h=REG(0x30230u);output_w=REG(0x30234u);
        if((s&14u)!=2u){fail(8);break;}
        if(output_h!=48 || output_w!=48 || hardware_issues!=1327104u){fail(9);break;}
        enter(FL_READ);break;
    case FL_READ:read_block(OUTPUT_BASE,64,FL_READ_WAIT);break;
    case FL_READ_WAIT:
        if(!io_done())break;
        for(i=0;i<4;i++)first_words[i]=DATA[i];
        for(i=0;i<32;i++){
            int16_t observed=(int16_t)(DATA[i/2]>>((i%2)*16));
            if(observed!=expected[i]){
                bad_channel=i;expected_bad=(uint32_t)(int32_t)expected[i];
                actual_bad=(uint32_t)(int32_t)observed;fail(10);return;
            }
            checked++;
        }
        enter(FL_PASSED);log_text("AI first layer passed: first output pixel, 32 channels checked. Not full YOLO.\n");break;
    default:break;
    }
}
void ai_first_layer_status(uint8_t *out){
    uint32_t values[COMM_AI_WORDS];unsigned i;
    values[0]=COMM_AI_ABI;values[1]=state;values[2]=error;values[3]=frame_id;
    values[4]=loaded;values[5]=REG(0x30204u);values[6]=REG(0x30224u);
    values[7]=hardware_cycles;values[8]=hardware_issues;values[9]=output_h;values[10]=output_w;
    values[11]=OUTPUT_BASE;values[12]=OUTPUT_BYTES;values[13]=checked;values[14]=bad_channel;
    values[15]=expected_bad;values[16]=actual_bad;values[17]=CYCLES-started;
    values[18]=input_base;values[19]=input_bytes;
    for(i=0;i<4;i++)values[20+i]=first_words[i];
    for(i=0;i<COMM_AI_WORDS;i++)comm_put32(out+i*4,values[i]);
}
