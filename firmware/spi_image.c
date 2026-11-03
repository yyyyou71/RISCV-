#include "rk_comm.h"
#include "preprocess_capture.h"
#include "ai_network.h"
#include "video_present.h"
#include "../csrc/software/ai_runtime.h"
#include "../csrc/rk_fspi/comm_protocol.h"
#define REG(a) (*(volatile uint32_t *)(a))
#define CYCLES REG(0x3000cu)
#define WINDOW REG(0x31004u)
#define INPUT_BASE 0x03e00000u
static uint32_t state,error,session,id,received,expected,hash,mode,entered,upload_ticks,job_ticks;
static struct pp_frame frame;
/* Freestanding GCC may lower aggregate initialization to memset. */
void *memset(void *destination,int value,size_t count){
    volatile uint8_t *p=(volatile uint8_t *)destination;
    for(size_t i=0;i<count;i++)p[i]=(uint8_t)value;
    return destination;
}
static void log_text(const char *s){const char *p=s;while(*p)p++;rk_comm_send((const uint8_t *)s,(unsigned)(p-s));}
static uint32_t video_state(void){
    switch(state){
    case IMAGE_EMPTY:return COMM_VIDEO_IDLE;
    case IMAGE_LOADING:return COMM_VIDEO_WAIT_INPUT;
    case IMAGE_PROCESSING:return COMM_VIDEO_CAPTURE;
    case IMAGE_READY:return COMM_VIDEO_SUCCESS;
    case IMAGE_RELEASING:return COMM_VIDEO_RELEASING;
    default:return COMM_VIDEO_ERROR;
    }
}
static void snapshot(uint8_t *out){
    uint32_t v[COMM_IMAGE_WORDS]={COMM_IMAGE_ABI,state,error,session,id,received,IMAGE_BYTES,hash,expected,
        mode,PP_REG(4),PP_REG(0x18),PP_REG(0x1c),PP_REG(0x28),PP_REG(0x30),
        (IMAGE_HEIGHT<<16)|IMAGE_WIDTH,INPUT_BASE,upload_ticks,job_ticks,IMAGE_CHUNK_BYTES};
    for(unsigned i=0;i<COMM_IMAGE_WORDS;i++)comm_put32(out+i*4,v[i]);
}
static void video_snapshot(uint8_t *out){
    uint32_t v[COMM_VIDEO_WORDS]={0};
    v[0]=COMM_VIDEO_ABI;v[1]=video_state();v[2]=error;v[3]=CYCLES;v[4]=CYCLES-entered;
    v[5]=(IMAGE_HEIGHT<<16)|IMAGE_WIDTH;v[7]=PP_REG(4);v[8]=PP_REG(0x18);v[9]=PP_REG(0x1c);
    v[10]=REG(0x30604u);v[11]=WINDOW;v[12]=REG(0x31010u);
    v[17]=frame.frame_id;v[18]=frame.raw_slot;v[19]=frame.raw_native_base;
    v[20]=frame.tensor_logical_base;v[21]=frame.bytes;
    for(unsigned i=0;i<COMM_VIDEO_WORDS;i++)comm_put32(out+i*4,v[i]);
}
static int blocked(void){return ai_network_busy()||video_present_busy()||(WINDOW&1u);}
static void clear_input(void){
    state=IMAGE_EMPTY;error=session=id=received=expected=upload_ticks=job_ticks=0;
    hash=2166136261u;frame.frame_id=0;frame.raw_slot=0xffffffffu;
    frame.raw_native_base=0;frame.tensor_logical_base=0;frame.bytes=0;entered=CYCLES;
    ai_network_clear_result();
}
static uint16_t release(void){
    if(blocked()||state==IMAGE_PROCESSING||state==IMAGE_RELEASING)return COMM_BUSY;
    if((PP_REG(4)&PP_FAULT)||(WINDOW&8u))return COMM_IO_ERROR;
    if(PP_REG(4)&PP_HELD){PP_REG(0)=2;state=IMAGE_RELEASING;entered=CYCLES;}
    else clear_input();
    return COMM_OK;
}
static uint16_t image_command(unsigned op,const uint8_t *p,unsigned n){
    if(op==COMM_IMAGE_STATUS)return n?COMM_BAD_ARGUMENT:COMM_OK;
    if(blocked())return COMM_BUSY;
    if((PP_REG(4)&PP_FAULT)||(WINDOW&8u))return COMM_IO_ERROR;
    if(!(WINDOW&16u))return COMM_BUSY;
    if(op==COMM_IMAGE_ABORT){
        if(n!=8||comm_u32(p)!=session||comm_u32(p+4)!=id)return COMM_BAD_ARGUMENT;
        return release();
    }
    if(op==COMM_IMAGE_BEGIN){
        if(state!=IMAGE_EMPTY||(PP_REG(4)&(PP_BUSY|PP_HELD)))return COMM_BUSY;
        if(n!=32||!comm_u32(p)||!comm_u32(p+4)||comm_u32(p+8)!=IMAGE_WIDTH||comm_u32(p+12)!=IMAGE_HEIGHT||
           comm_u32(p+16)!=IMAGE_RGB888||comm_u32(p+20)!=IMAGE_BYTES||comm_u32(p+28))return COMM_BAD_ARGUMENT;
        session=comm_u32(p);id=comm_u32(p+4);expected=comm_u32(p+24);received=0;hash=2166136261u;
        error=0;upload_ticks=job_ticks=0;entered=CYCLES;state=IMAGE_LOADING;return COMM_OK;
    }
    if(state!=IMAGE_LOADING||n<8||comm_u32(p)!=session||comm_u32(p+4)!=id)return COMM_BAD_ARGUMENT;
    if(op==COMM_IMAGE_DATA){
        uint32_t io[64],verify[64],code;
        if(n!=12+IMAGE_CHUNK_BYTES||comm_u32(p+8)!=received||received>IMAGE_BYTES-IMAGE_CHUNK_BYTES)return COMM_BAD_ARGUMENT;
        for(unsigned i=0;i<64;i++)io[i]=(uint32_t)p[12+i*3]|((uint32_t)p[13+i*3]<<8)|((uint32_t)p[14+i*3]<<16);
        uint32_t address=INPUT_BASE+(received/IMAGE_CHUNK_BYTES)*256u;
        code=ai_ddr_write(address,io,256);
        if(!code)code=ai_ddr_read(address,verify,256);
        for(unsigned i=0;!code&&i<64;i++)if(io[i]!=verify[i])code=AI_DDR_ERROR;
        if(code){state=IMAGE_ERROR;error=0x100u+code;return COMM_IO_ERROR;}
        for(unsigned i=0;i<IMAGE_CHUNK_BYTES;i++)hash=(hash^p[12+i])*16777619u;
        received+=IMAGE_CHUNK_BYTES;return COMM_OK;
    }
    if(op==COMM_IMAGE_COMMIT){
        if(n!=16||comm_u32(p+8)!=IMAGE_BYTES||received!=IMAGE_BYTES)return COMM_BAD_ARGUMENT;
        if(hash!=expected||comm_u32(p+12)!=expected){state=IMAGE_ERROR;error=1;return COMM_BAD_PACKET;}
        if(PP_REG(0x38)!=0x53494d31u){state=IMAGE_ERROR;error=2;return COMM_IO_ERROR;}
        upload_ticks=CYCLES-entered;entered=CYCLES;
        PP_REG(0)=4;PP_REG(8)=id;PP_REG(0x2c)=mode;PP_REG(0)=1;state=IMAGE_PROCESSING;
        return COMM_OK;
    }
    return COMM_BAD_OPCODE;
}
uint16_t rk_comm_application_command(uint16_t op,const uint8_t *p,uint16_t n,
 uint8_t *out,uint16_t capacity,uint16_t *size){
    *size=0;
    if(op>=COMM_IMAGE_STATUS&&op<=COMM_IMAGE_ABORT){
        if(capacity<COMM_IMAGE_WORDS*4)return COMM_IO_ERROR;
        uint16_t code=image_command(op,p,n);snapshot(out);*size=COMM_IMAGE_WORDS*4;return code;
    }
    if(op==COMM_VIDEO_MODE){
        if((n!=0&&n!=4)||capacity<16)return COMM_BAD_ARGUMENT;
        if(n){
            if(comm_u32(p)>VIDEO_OUTPUT_AI)return COMM_BAD_ARGUMENT;
            if(state!=IMAGE_EMPTY||blocked())return COMM_BUSY;
            mode=comm_u32(p);
        }
        comm_put32(out,COMM_VIDEO_MODE_ABI);comm_put32(out+4,mode);comm_put32(out+8,mode);comm_put32(out+12,video_state());
        *size=16;return COMM_OK;
    }
    if(op==COMM_PRESENT_STATUS||op==COMM_PRESENT_RUN){
        if(n||capacity<COMM_PRESENT_WORDS*4)return COMM_BAD_ARGUMENT;
        *size=COMM_PRESENT_WORDS*4;
        return video_present_command(op==COMM_PRESENT_RUN,out,&frame,state==IMAGE_READY,ai_network_busy());
    }
    if(op>=COMM_MODEL_BEGIN&&op<=COMM_MODEL_ABORT){
        return ai_network_command(op,p,n,out,capacity,size,&frame,mode==VIDEO_OUTPUT_AI&&state==IMAGE_READY,
            state==IMAGE_LOADING||state==IMAGE_PROCESSING||state==IMAGE_RELEASING||video_present_busy(),0);
    }
    if(op==COMM_AI_STATUS){
        if(n||capacity<COMM_AI_WORDS*4)return COMM_BAD_ARGUMENT;
        for(unsigned i=0;i<COMM_AI_WORDS;i++)comm_put32(out+i*4,i?0:COMM_AI_ABI);
        *size=COMM_AI_WORDS*4;return COMM_OK;
    }
    if(op==COMM_VIDEO_STATUS||op==COMM_VIDEO_RELEASE){
        if(n||capacity<COMM_VIDEO_WORDS*4)return COMM_BAD_ARGUMENT;
        if(op==COMM_VIDEO_RELEASE){uint16_t code=release();if(code)return code;}
        video_snapshot(out);*size=COMM_VIDEO_WORDS*4;return COMM_OK;
    }
    return COMM_BAD_OPCODE;
}
static void poll_image(void){
    uint32_t status=PP_REG(4);
    if(state==IMAGE_PROCESSING){
        if(!(status&PP_BUSY)&&(status&PP_DONE)){
            job_ticks=CYCLES-entered;
            if((status&(PP_ERROR|PP_FAULT|PP_HELD))!=PP_HELD||PP_REG(8)!=id||
               PP_REG(0x28)!=IMAGE_WIDTH*IMAGE_HEIGHT*2u||PP_REG(0x1c)!=(mode==VIDEO_OUTPUT_AI?PP_TENSOR_BYTES:0u)){
                state=IMAGE_ERROR;error=0x200u+PP_REG(0x18);REG(0x30108u)=2;
            }else{
                frame.frame_id=id;frame.raw_slot=0;frame.raw_native_base=0;
                frame.tensor_logical_base=mode==VIDEO_OUTPUT_AI?PP_DEFAULT_BASE:0;
                frame.bytes=mode==VIDEO_OUTPUT_AI?PP_TENSOR_BYTES:0;state=IMAGE_READY;REG(0x30108u)=1;
                log_text("SPI image ready: original frame and requested tensor retained.\n");
            }
        }else if((uint32_t)(CYCLES-entered)>250000000u){state=IMAGE_ERROR;error=3;REG(0x30108u)=2;}
    }else if(state==IMAGE_RELEASING&&!(status&PP_BUSY)){
        if(status&(PP_ERROR|PP_HELD|PP_FAULT)){state=IMAGE_ERROR;error=4;}
        else{clear_input();REG(0x30108u)=0;}
    }
}
int main(void){
    rk_comm_init();ai_network_init();video_present_init();mode=VIDEO_OUTPUT_RAW;clear_input();
    log_text("SPI image input ready: 384x216 RGB888; awaiting upload.\n");
    for(;;){rk_comm_poll();poll_image();ai_network_poll();video_present_poll(0);}
}
