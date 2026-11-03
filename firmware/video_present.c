#include "video_present.h"
#include "ai_network.h"
#include "rk_comm.h"
#include "../csrc/software/ai_postprocess.h"
#include "../csrc/rk_fspi/comm_protocol.h"
#define P(a) (*(volatile uint32_t *)(0x30900u+(a)))
/* One retained frame per request. No pixel traffic passes through the CPU. */
static uint32_t state,error,run,frame_id,slot,count,index,limit,auto_run;
static uint32_t boxes[16][3];
static void log_text(const char *s){const char *p=s;while(*p)p++;rk_comm_send((const uint8_t *)s,(unsigned)(p-s));}
void video_present_init(void){state=error=run=frame_id=count=index=limit=auto_run=0;slot=0xffffffffu;}
int video_present_busy(void){return state==1 || state==2 || (P(4)&33u);}
void video_present_debug_status(uint32_t values[4]){
    values[0]=state;values[1]=error;values[2]=P(4);values[3]=frame_id;
}
static uint16_t start(const struct pp_frame *frame){
    uint32_t result_id,result_slot,detections,result_run;
    if(video_present_busy())return COMM_BUSY;
    int tensor=frame->bytes==PP_TENSOR_BYTES;
    int held=tensor?(PP_REG(4)&PP_HELD):(*(volatile uint32_t *)0x30604u&2u);
    if(!(P(4)&8u) || !held || frame->raw_slot>=5 || (frame->bytes && !tensor))return COMM_BUSY;
    run=0;limit=0;
    if(tensor && ai_network_result(&result_run,&result_id,&result_slot,&detections) &&
       result_id==frame->frame_id && result_slot==frame->raw_slot){
        run=result_run;limit=detections<16?detections:16;
    }
    if(run)auto_run=run;
    frame_id=frame->frame_id;slot=frame->raw_slot;index=count=error=0;state=1;
    return COMM_OK;
}
/* Q16 model coordinates -> inclusive original-image bounds. The current
 * preprocessor resizes the complete 1920x1080 image to 96x96, without padding. */
static uint32_t coordinate(int32_t q,int vertical,int upper){
    uint32_t size=vertical?1080u:1920u,shift=vertical?18u:16u;
    uint32_t factor=vertical?45u:20u;
    if(q<=0)return 0;
    if(q>=96*65536)return upper?size-1:size;
    uint32_t product=(uint32_t)q*factor;
    return upper?((product+((1u<<shift)-1u))>>shift)-1u:product>>shift;
}
static void snapshot(uint8_t *out){
    uint32_t v[COMM_PRESENT_WORDS]={COMM_PRESENT_ABI,state,error,P(4),run,frame_id,slot,count,P(0x24),P(0x28),P(0x2c),16};
    for(unsigned i=0;i<COMM_PRESENT_WORDS;i++)comm_put32(out+i*4,v[i]);
}
uint16_t video_present_command(int submit,uint8_t *out,const struct pp_frame *frame,int video_ready,int blocked){
    uint16_t code=COMM_OK;
    if(submit){
        if(blocked || !video_ready)code=COMM_BUSY;
        else code=start(frame);
    }
    snapshot(out);return code;
}
void video_present_poll(int allow_ai_auto){
    static const uint16_t colors[8]={0x07e0,0xf800,0x001f,0xffe0,0xf81f,0x07ff,0xffff,0xfd20};
    if(state==1){
        if(index<limit){
            ai_detection d;
            if(ai_ddr_read(AI_POST_OUTPUT_MIN+index*32,(uint32_t *)&d,32)){
                state=4;error=1;log_text("Presentation: detection read failed.\n");return;
            }
            index++;
            if(d.x2_q16<=d.x1_q16 || d.y2_q16<=d.y1_q16 || d.x2_q16<=0 || d.y2_q16<=0 ||
               d.x1_q16>=96*65536 || d.y1_q16>=96*65536)return;
            uint32_t x0=coordinate(d.x1_q16,0,0),y0=coordinate(d.y1_q16,1,0);
            uint32_t x1=coordinate(d.x2_q16,0,1),y1=coordinate(d.y2_q16,1,1);
            if(x0>x1 || y0>y1)return;
            boxes[count][0]=x0|(y0<<16);boxes[count][1]=x1|(y1<<16);
            boxes[count][2]=colors[d.class_id&7u];count++;
        }else{
            P(0)=4;P(8)=frame_id;P(12)=slot;P(16)=count;
            for(unsigned i=0;i<count;i++){
                P(20)=i;P(24)=boxes[i][0];P(28)=boxes[i][1];P(32)=boxes[i][2];
            }
            P(0)=1;state=2;
            log_text("Presentation queued: retained frame + top-16 boxes -> PCIe; RK must start DMA.\n");
        }
    }else if(state==2 && (P(4)&6u)){
        error=P(0x24);
        if(!(P(4)&4u) && P(0x28)!=frame_id)error=6;
        state=error?4:3;
        log_text(error?"Presentation failed; read present-status.\n":"Presentation DMA drained; original frame lease remains held.\n");
    }else if(allow_ai_auto && state!=1 && state!=2 && !(P(4)&32u)){
        uint32_t r,f,s,n;
        if(ai_network_result(&r,&f,&s,&n) && r!=auto_run && (P(4)&8u)){
            struct pp_frame retained={0};retained.frame_id=f;retained.raw_slot=s;retained.bytes=PP_TENSOR_BYTES;
            auto_run=r;(void)start(&retained);
        }
    }
}
