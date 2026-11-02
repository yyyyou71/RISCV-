#include "rk_comm.h"
#include "preprocess_capture.h"
#include "ai_first_layer.h"
#include "ai_network.h"
#include "video_present.h"
#include "../csrc/rk_fspi/comm_protocol.h"

#define REG(a) (*(volatile uint32_t *)(a))
#define GPIO REG(0x30108u)
#define CYCLES REG(0x3000cu)
#define VIDEO_SHAPE REG(0x3061cu)
#define VIDEO_PERIOD REG(0x30620u)
#define WINDOW_STATUS REG(0x31004u)
#define RAW_CONTROL REG(0x30600u)
#define RAW_STATUS REG(0x30604u)
#define DDR_WAIT 75000000u
#define JOB_WAIT 6250000u
#define RAW_JOB_WAIT 250000000u

static uint32_t state,entered,error_stage,retries,failure_cycle;
static uint32_t failure_shape,failure_period,failure_status,failure_error;
static uint32_t first_pixel[2],last_pixel[2];
static uint32_t led_tick,led_phase;
static unsigned restart_after_release;
static uint32_t output_mode=VIDEO_OUTPUT_RAW,requested_mode=VIDEO_OUTPUT_RAW,raw_retry_tick;
static struct pp_frame frame;

/* Keep the status response layout stable. Raw mode owns the frame mailbox,
 * whereas AI mode owns the preprocessor's matching raw/tensor lease. */
static uint32_t capture_status(void){
    if(output_mode==VIDEO_OUTPUT_AI)return PP_REG(4);
    uint32_t s=RAW_STATUS;
    return (s&0x30u)|((s&2u)<<2)|((s&8u)>>1)|((s&4u)>>1)|(s&1u);
}
static uint32_t capture_error(void){return output_mode==VIDEO_OUTPUT_AI?PP_REG(0x18):(RAW_STATUS>>3)&1u;}

static void log_text(const char *s){
    const char *p=s;
    while(*p)p++;
    rk_comm_send((const uint8_t *)s,(size_t)(p-s));
}
static void enter(uint32_t next){
    state=next;entered=CYCLES;led_tick=entered;led_phase=0;GPIO=0;
}
static void fail(unsigned stage){
    error_stage=stage;failure_cycle=CYCLES;
    failure_shape=VIDEO_SHAPE;failure_period=VIDEO_PERIOD;
    failure_status=capture_status();failure_error=capture_error();
    enter(COMM_VIDEO_ERROR);GPIO=2;
    log_text("Video self-test failed; read video-status, then video-retry.\n");
}
static void clear_result(void){
    ai_network_clear_result();
    ai_first_layer_clear();
    frame.frame_id=0;frame.raw_slot=0xffffffffu;frame.raw_native_base=0;
    frame.tensor_logical_base=output_mode==VIDEO_OUTPUT_AI?PP_DEFAULT_BASE:0;frame.bytes=0;
    first_pixel[0]=first_pixel[1]=last_pixel[0]=last_pixel[1]=0;
    error_stage=0;failure_cycle=0;
    failure_shape=failure_period=failure_status=failure_error=0;
}
static void start_waiting(void){
    clear_result();
    if(output_mode==VIDEO_OUTPUT_AI)PP_REG(0)=4;else RAW_CONTROL=4;
    enter(COMM_VIDEO_WAIT_DDR);
    log_text(output_mode==VIDEO_OUTPUT_AI?
        "Video AI mode: capture matching raw frame/tensor; dimensions are diagnostic only.\n":
        "Video RAW mode: DDR frame -> PCIe; preprocessing and AI are bypassed.\n");
}
static void read_pixel(uint32_t address,uint32_t next){
    REG(0x31008u)=address;REG(0x3100cu)=32;REG(0x31000u)=1;
    enter(next);
}
static int pixel_valid(uint32_t *sample){
    volatile uint32_t *data=(volatile uint32_t *)0x31100u;
    unsigned i;int valid;
    sample[0]=data[0];sample[1]=data[1];
    valid=!(sample[0]&0xff00ff00u) && !(sample[1]&0xffffff00u);
    for(i=2;i<8;i++)if(data[i])valid=0;
    return valid;
}
static void poll_video(void){
    uint32_t status=capture_status(),now=CYCLES,elapsed=now-entered;
    int result;
    switch(state){
    case COMM_VIDEO_WAIT_DDR:
        if(status&PP_FAULT)fail(1);
        else if(status&PP_DDR_READY)enter(COMM_VIDEO_WAIT_INPUT);
        else if(elapsed>DDR_WAIT)fail(1);
        break;
    case COMM_VIDEO_WAIT_INPUT:
        if(status&PP_FAULT){fail(3);break;}
        if(output_mode==VIDEO_OUTPUT_RAW){
            RAW_CONTROL=1;raw_retry_tick=now;enter(COMM_VIDEO_CAPTURE);
            log_text("Video RAW: waiting for a complete DDR frame.\n");
        }else if(pp_capture_start(PP_DEFAULT_BASE))fail(3);
        else{enter(COMM_VIDEO_CAPTURE);log_text("Video AI: direct tensor capture started.\n");}
        break;
    case COMM_VIDEO_CAPTURE:
        if(output_mode==VIDEO_OUTPUT_RAW){
            if(status&PP_FAULT){fail(4);break;}
            if((status&(PP_BUSY|PP_DONE|PP_ERROR|PP_HELD))==(PP_DONE|PP_HELD)){
                frame.frame_id=REG(0x3060cu);frame.raw_slot=REG(0x30608u);
                frame.raw_native_base=REG(0x30610u);frame.tensor_logical_base=0;frame.bytes=0;
                if(frame.raw_slot>=5)fail(6);
                else{enter(COMM_VIDEO_SUCCESS);log_text("Video RAW: complete original frame held; ready for PCIe.\n");}
            }else if(elapsed>RAW_JOB_WAIT)fail(5);
            else if(!(status&PP_BUSY) && (status&PP_ERROR) && now-raw_retry_tick>=250000u){
                /* No complete source frame yet: sample the ring again after
                 * 10 ms. This does not restart an in-flight native DDR burst. */
                RAW_CONTROL=4;RAW_CONTROL=1;raw_retry_tick=now;
            }
            break;
        }
        result=pp_capture_result(&frame);
        if(result<0)fail(4);
        else if(result>0){
            if(frame.bytes!=PP_TENSOR_BYTES || frame.raw_slot>=5)fail(6);
            else read_pixel(frame.tensor_logical_base,COMM_VIDEO_READ_FIRST);
        }else if(elapsed>JOB_WAIT)fail(5);
        break;
    case COMM_VIDEO_READ_FIRST:
    case COMM_VIDEO_READ_LAST:
        if(WINDOW_STATUS&1u){
            if(elapsed>JOB_WAIT)fail(state==COMM_VIDEO_READ_FIRST?7:8);
            break;
        }
        if((WINDOW_STATUS&14u)!=2u){fail(state==COMM_VIDEO_READ_FIRST?7:8);break;}
        if(state==COMM_VIDEO_READ_FIRST){
            if(!pixel_valid(first_pixel))fail(7);
            else read_pixel(frame.tensor_logical_base+frame.bytes-32,COMM_VIDEO_READ_LAST);
        }else if(!pixel_valid(last_pixel))fail(8);
        else{enter(COMM_VIDEO_SUCCESS);log_text("Video self-test passed; raw frame and tensor held.\n");}
        break;
    case COMM_VIDEO_RELEASING:
        if(status&PP_FAULT){fail(9);break;}
        if(!(status&(PP_BUSY|PP_HELD))){
            output_mode=requested_mode;
            if(restart_after_release)start_waiting();
            else{clear_result();enter(COMM_VIDEO_IDLE);log_text("Video frame released.\n");}
        }else if(elapsed>JOB_WAIT)fail(9);
        break;
    case COMM_VIDEO_SUCCESS:
        if(status&PP_FAULT){fail(4);break;}
        if(now-led_tick>=12500000u){led_tick=now;led_phase^=2;GPIO=led_phase;}
        break;
    default:break;
    }
}
static void snapshot(uint8_t *out){
    uint32_t values[COMM_VIDEO_WORDS];unsigned i;
    values[0]=COMM_VIDEO_ABI;values[1]=state;values[2]=error_stage;
    values[3]=CYCLES;values[4]=values[3]-entered;
    values[5]=VIDEO_SHAPE;values[6]=VIDEO_PERIOD;
    values[7]=capture_status();values[8]=capture_error();
    values[9]=output_mode==VIDEO_OUTPUT_AI?PP_REG(0x1c):0;
    values[10]=REG(0x30604u);values[11]=WINDOW_STATUS;values[12]=REG(0x31010u);
    values[13]=failure_shape;values[14]=failure_period;
    values[15]=failure_status;values[16]=failure_error;
    values[17]=frame.frame_id;values[18]=frame.raw_slot;values[19]=frame.raw_native_base;
    values[20]=frame.tensor_logical_base;values[21]=frame.bytes;values[22]=retries;
    values[23]=failure_cycle;
    values[24]=first_pixel[0];values[25]=first_pixel[1];
    values[26]=last_pixel[0];values[27]=last_pixel[1];
    for(i=0;i<COMM_VIDEO_WORDS;i++)comm_put32(out+i*4,values[i]);
}
static uint16_t request_video(int restart,uint32_t next_mode){
    uint32_t status=capture_status();
    if(video_present_busy() || ai_network_busy() || ai_first_layer_busy() ||
       state==COMM_VIDEO_CAPTURE || state==COMM_VIDEO_READ_FIRST || state==COMM_VIDEO_READ_LAST ||
       state==COMM_VIDEO_RELEASING || (status&PP_BUSY) || (WINDOW_STATUS&1u))return COMM_BUSY;
    if((status&PP_FAULT) || (WINDOW_STATUS&8u))return COMM_IO_ERROR;
    restart_after_release=restart;requested_mode=next_mode;
    if(restart)retries++;
    if(status&PP_HELD){
        if(output_mode==VIDEO_OUTPUT_AI){if(pp_capture_release())return COMM_BUSY;}
        else RAW_CONTROL=2;
        enter(COMM_VIDEO_RELEASING);
    }else{
        output_mode=requested_mode;
        if(restart)start_waiting();else{clear_result();enter(COMM_VIDEO_IDLE);}
    }
    return COMM_OK;
}
static uint16_t set_output_mode(uint32_t mode){
    if(mode>VIDEO_OUTPUT_AI)return COMM_BAD_ARGUMENT;
    if(mode==output_mode && state!=COMM_VIDEO_ERROR && state!=COMM_VIDEO_IDLE)
        return state==COMM_VIDEO_RELEASING?COMM_BUSY:COMM_OK;
    return request_video(1,mode);
}
uint16_t rk_comm_application_command(uint16_t operation,const uint8_t *request,
 uint16_t length,uint8_t *response,uint16_t capacity,uint16_t *response_length){
    *response_length=0;
    if(operation==COMM_VIDEO_MODE){
        if((length!=0 && length!=4) || capacity<COMM_VIDEO_MODE_WORDS*4)return COMM_BAD_ARGUMENT;
        uint16_t code=length?set_output_mode(comm_u32(request)):COMM_OK;
        comm_put32(response,COMM_VIDEO_MODE_ABI);comm_put32(response+4,output_mode);
        comm_put32(response+8,requested_mode);comm_put32(response+12,state);
        *response_length=COMM_VIDEO_MODE_WORDS*4;return code;
    }
    if(operation==COMM_PRESENT_STATUS || operation==COMM_PRESENT_RUN){
        if(length)return COMM_BAD_ARGUMENT;
        if(capacity<COMM_PRESENT_WORDS*4)return COMM_IO_ERROR;
        *response_length=COMM_PRESENT_WORDS*4;
        return video_present_command(operation==COMM_PRESENT_RUN,response,&frame,state==COMM_VIDEO_SUCCESS,
            ai_network_busy() || ai_first_layer_busy());
    }
    if(operation>=COMM_MODEL_BEGIN && operation<=COMM_MODEL_ABORT){
        int active=state==COMM_VIDEO_CAPTURE || state==COMM_VIDEO_READ_FIRST ||
                   state==COMM_VIDEO_READ_LAST || state==COMM_VIDEO_RELEASING || video_present_busy();
        return ai_network_command(operation,request,length,response,capacity,response_length,
            &frame,output_mode==VIDEO_OUTPUT_AI && state==COMM_VIDEO_SUCCESS,active,ai_first_layer_busy());
    }
    if(operation==COMM_AI_STATUS){
        if(length)return COMM_BAD_ARGUMENT;
        if(capacity<COMM_AI_WORDS*4)return COMM_IO_ERROR;
        ai_first_layer_status(response);*response_length=COMM_AI_WORDS*4;return COMM_OK;
    }
    if(operation!=COMM_VIDEO_STATUS && operation!=COMM_VIDEO_RETRY && operation!=COMM_VIDEO_RELEASE)
        return COMM_BAD_OPCODE;
    if(length)return COMM_BAD_ARGUMENT;
    if(capacity<COMM_VIDEO_WORDS*4)return COMM_IO_ERROR;
    if(operation!=COMM_VIDEO_STATUS){
        uint16_t code=request_video(operation==COMM_VIDEO_RETRY,output_mode);
        if(code!=COMM_OK)return code;
    }
    snapshot(response);*response_length=COMM_VIDEO_WORDS*4;
    return COMM_OK;
}
int main(void){
    rk_comm_init();ai_first_layer_init();ai_network_init();video_present_init();start_waiting();
    for(;;){
        rk_comm_poll();
        if(!ai_network_loading())poll_video();
        ai_first_layer_poll();
        ai_network_poll();
        video_present_poll(output_mode==VIDEO_OUTPUT_AI && state==COMM_VIDEO_SUCCESS);
    }
}
