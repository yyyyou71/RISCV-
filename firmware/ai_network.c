#include "ai_network.h"
#include "rk_comm.h"
#include "../csrc/software/ai_postprocess.h"
#include "../csrc/rk_fspi/comm_protocol.h"
#define REG(a) (*(volatile uint32_t *)(a))
#define CYCLES REG(0x3000cu)
#define STATUS REG(0x31004u)
#define MODEL_ADDRESS 0x10000u
#define MODEL_LIMIT 0x02000000u
#define TASK_TIMEOUT 1500000000u /* 60s/layer, below a 32-bit CPU counter wrap. */
static uint32_t state,error,session,total,received,expected_hash,hash,tag,ready;
static uint32_t run_id,frame_id,raw_slot,input_base,current_task,total_tasks,task_tick;
static uint32_t last_offset,last_size,last_cycle;
static uint64_t elapsed;
static uint8_t last_data[COMM_MODEL_CHUNK_BYTES];
static ai_run_result run_result;
static ai_post_result post_result;

static void log_text(const char *s){const char *p=s;while(*p)p++;rk_comm_send((const uint8_t *)s,(unsigned)(p-s));}
static uint32_t hash_data(uint32_t value,const uint8_t *data,uint32_t size){
    for(uint32_t i=0;i<size;i++)value=(value^data[i])*16777619u;
    return value;
}
static void clear_results(void){
    uint32_t i;
    uint32_t *r=(uint32_t *)&run_result,*p=(uint32_t *)&post_result;
    for(i=0;i<8;i++){r[i]=0;p[i]=0;}
    run_result.failed_task=0xffffffffu;
    current_task=0xffffffffu;frame_id=0;raw_slot=0xffffffffu;input_base=0;elapsed=0;
    last_cycle=CYCLES;
}
void ai_network_init(void){
    state=NW_EMPTY;error=session=total=received=expected_hash=tag=ready=run_id=total_tasks=0;
    hash=2166136261u;last_offset=0xffffffffu;last_size=0;clear_results();
}
int ai_network_busy(void){return state==NW_LOADING || state==NW_QUEUED || state==NW_RUNNING || state==NW_POSTPROCESS;}
int ai_network_loading(void){return state==NW_LOADING;}
int ai_network_has_model(void){return ready!=0;}
int ai_network_result(uint32_t *run,uint32_t *frame,uint32_t *slot,uint32_t *count){
    if(state!=NW_DONE)return 0;
    *run=run_id;*frame=frame_id;*slot=raw_slot;*count=post_result.count;return 1;
}
void ai_network_clear_result(void){
    if(ai_network_busy())return;
    clear_results();error=0;state=ready?NW_READY:NW_EMPTY;
}
static void update_clock(void){uint32_t now=CYCLES;elapsed+=(uint32_t)(now-last_cycle);last_cycle=now;}
/* No calls from upload/command DDR accesses: that would recursively enter the
 * SPI dispatcher. During RUNNING/POST only cached queries are allowed. */
void ai_runtime_poll(void){
    if(state==NW_RUNNING || state==NW_POSTPROCESS){update_clock();rk_comm_poll();}
}
int ai_runtime_abort_requested(void){return state==NW_RUNNING && (uint32_t)(CYCLES-task_tick)>TASK_TIMEOUT;}
void ai_runtime_progress(uint32_t task,uint32_t count,const ai_run_result *r){
    if(task!=current_task)task_tick=CYCLES;
    current_task=task;total_tasks=count;run_result=*r;
}
static void snapshot(uint8_t *out){
    uint32_t values[COMM_NETWORK_WORDS],s=STATUS;unsigned i;
    if(state==NW_RUNNING || state==NW_POSTPROCESS)update_clock();
    values[0]=COMM_NETWORK_ABI;values[1]=state;values[2]=error;values[3]=session;
    values[4]=tag;values[5]=received;values[6]=total;values[7]=hash;values[8]=expected_hash;
    values[9]=run_id;values[10]=frame_id;values[11]=total_tasks;values[12]=run_result.completed;
    values[13]=run_result.failed_task;values[14]=run_result.hardware_code;
    values[15]=run_result.cycles;values[16]=run_result.issues;
    values[17]=post_result.code;values[18]=post_result.count;values[19]=post_result.read_calls;
    values[20]=current_task;values[21]=(uint32_t)elapsed;values[22]=(uint32_t)(elapsed>>32);
    values[23]=ready|((s&8u)?2u:0u)|((s&1u)?4u:0u)|((PP_REG(4)&PP_FAULT)?8u:0u);
    values[24]=input_base;values[25]=raw_slot;values[26]=AI_POST_OUTPUT_MIN;
    values[27]=(1080u<<16)|1920u;
    for(i=0;i<COMM_NETWORK_WORDS;i++)comm_put32(out+i*4,values[i]);
}
static uint16_t load_chunk(const uint8_t *request,uint16_t length){
    uint32_t offset=comm_u32(request+4),bytes=length-8,code;
    uint32_t io[COMM_MODEL_CHUNK_BYTES/4],verify[COMM_MODEL_CHUNK_BYTES/4];unsigned i;
    if(state!=NW_LOADING || comm_u32(request)!=session)return COMM_BAD_ARGUMENT;
    if(!bytes || bytes>COMM_MODEL_CHUNK_BYTES || ((offset|bytes)&15u) ||
       offset>total || bytes>total-offset)return COMM_BAD_ARGUMENT;
    if(offset==last_offset && bytes==last_size){
        for(i=0;i<bytes;i++)if(last_data[i]!=request[8+i])return COMM_BAD_ARGUMENT;
        return COMM_OK; /* Last committed chunk may be explicitly resent. */
    }
    if(offset!=received)return COMM_BAD_ARGUMENT;
    if((STATUS&25u)!=16u)return COMM_BUSY;
    for(i=0;i<bytes/4;i++)io[i]=comm_u32(request+8+i*4);
    code=ai_ddr_write(offset,io,bytes);
    if(!code)code=ai_ddr_read(offset,verify,bytes);
    for(i=0;!code && i<bytes/4;i++)if(io[i]!=verify[i])code=AI_DDR_ERROR;
    if(code){ready=0;state=NW_ERROR;error=0x1001u;return COMM_IO_ERROR;}
    hash=hash_data(hash,request+8,bytes);received+=bytes;last_offset=offset;last_size=bytes;
    for(i=0;i<bytes;i++)last_data[i]=request[8+i];
    return COMM_OK;
}
static uint16_t commit_model(void){
    ai_model_header h;ai_post_config p;
    if(state==NW_READY || state==NW_DONE)return COMM_OK;
    if(state!=NW_LOADING || received!=total)return COMM_BAD_ARGUMENT;
    if(hash!=expected_hash){error=0x1002u;state=NW_ERROR;return COMM_BAD_PACKET;}
    if(ai_ddr_read(MODEL_ADDRESS,(uint32_t *)&h,64) ||
       ai_ddr_read(AI_POST_CONFIG_ADDR,(uint32_t *)&p,64)){
        error=0x1001u;state=NW_ERROR;return COMM_IO_ERROR;
    }
    if(h.magic!=AI_MODEL_MAGIC || h.version!=2 || h.header_bytes!=64 || h.task_bytes!=64 ||
       h.task_count!=99 || h.tasks_addr!=MODEL_ADDRESS+64 || h.arena_begin!=MODEL_ADDRESS ||
       h.arena_end!=total || h.readonly_end<=h.input_addr || h.readonly_end>=h.arena_end ||
       h.tasks_addr+(uint64_t)h.task_count*64>h.readonly_end ||
       h.input_addr<MODEL_ADDRESS+6400 || h.input_addr+(uint64_t)h.input_bytes>h.readonly_end ||
       (h.arena_begin|h.arena_end|h.readonly_end|h.input_addr|h.output_addr|h.output_bytes)&15u ||
       !h.output_bytes || h.output_addr<h.readonly_end || h.output_addr+(uint64_t)h.output_bytes>h.arena_end ||
       h.input_bytes!=PP_TENSOR_BYTES || h.flags!=1 || h.reserved0 || h.reserved1 ||
       p.magic!=AI_POST_MAGIC || p.version!=1 || p.header_bytes!=64 || p.head_bytes!=64 ||
       p.model_addr!=MODEL_ADDRESS || p.heads_addr!=0x5100u || p.lut_addr!=0x5200u ||
       p.flags || p.reserved || p.threshold_q16>65535 ||
       p.input_h!=96 || p.input_w!=96 || p.head_count!=3 || p.output_addr!=AI_POST_OUTPUT_MIN ||
       !p.max_detections || p.max_detections>300 || p.output_bytes!=p.max_detections*32){
        error=0x1003u;state=NW_ERROR;return COMM_BAD_ARGUMENT;
    }
    total_tasks=h.task_count;ready=1;error=0;state=NW_READY;
    log_text("Full model received and verified in DDR; infer uses the retained HDMI frame.\n");
    return COMM_OK;
}
uint16_t ai_network_command(uint16_t op,const uint8_t *request,uint16_t length,
 uint8_t *response,uint16_t capacity,uint16_t *size,const struct pp_frame *frame,
 int video_ready,int video_busy,int first_layer_busy){
    uint16_t result=COMM_OK;unsigned i;
    *size=0;
    if(op<COMM_MODEL_BEGIN || op>COMM_MODEL_ABORT)return COMM_BAD_OPCODE;
    if(capacity<COMM_NETWORK_WORDS*4)return COMM_IO_ERROR;
    if(op==COMM_NETWORK_STATUS){if(length)return COMM_BAD_ARGUMENT;snapshot(response);*size=COMM_NETWORK_WORDS*4;return COMM_OK;}
    if(state==NW_RUNNING || state==NW_POSTPROCESS || state==NW_QUEUED)return COMM_BUSY;
    if(first_layer_busy || video_busy || (STATUS&1u))return COMM_BUSY;
    if((STATUS&8u) || (PP_REG(4)&PP_FAULT))return COMM_IO_ERROR;
    if(op!=COMM_MODEL_ABORT && !(STATUS&16u))return COMM_BUSY;
    if(op==COMM_MODEL_BEGIN){
        if(length!=16 || !comm_u32(request) || (comm_u32(request+4)&15u) ||
           comm_u32(request+4)<=MODEL_ADDRESS+6400 || comm_u32(request+4)>MODEL_LIMIT)return COMM_BAD_ARGUMENT;
        if(state==NW_LOADING && session==comm_u32(request)){
            if(total!=comm_u32(request+4) || expected_hash!=comm_u32(request+8) || tag!=comm_u32(request+12))return COMM_BAD_ARGUMENT;
        }else{
            ready=0;clear_results();state=NW_LOADING;error=0;session=comm_u32(request);
            total=comm_u32(request+4);expected_hash=comm_u32(request+8);tag=comm_u32(request+12);
            received=0;hash=2166136261u;last_offset=0xffffffffu;last_size=0;
            log_text("SPI model upload started; video/AI scheduling paused.\n");
        }
    }else if(op==COMM_MODEL_ABORT){
        if(length!=4 || comm_u32(request)!=session)return COMM_BAD_ARGUMENT;
        ready=0;state=NW_EMPTY;error=0;clear_results();
    }else if(op==COMM_MODEL_CHUNK){
        if(length<24)return COMM_BAD_ARGUMENT;
        result=load_chunk(request,length);
    }else if(op==COMM_MODEL_COMMIT){
        if(length!=4 || comm_u32(request)!=session)return COMM_BAD_ARGUMENT;
        result=commit_model();
    }else if(op==COMM_NETWORK_RUN){
        if(length!=4 || comm_u32(request)!=session || !ready || state==NW_LOADING)return COMM_BAD_ARGUMENT;
        if(!video_ready || !(PP_REG(4)&PP_HELD) || frame->bytes!=PP_TENSOR_BYTES || frame->raw_slot>=5)return COMM_BUSY;
        clear_results();frame_id=frame->frame_id;raw_slot=frame->raw_slot;input_base=frame->tensor_logical_base;
        run_id++;if(!run_id)run_id++;state=NW_QUEUED;error=0;
    }else if(op==COMM_DETECTIONS){
        uint32_t count,start;
        if(length!=16 || comm_u32(request)!=session || comm_u32(request+4)!=run_id || state!=NW_DONE)return COMM_BAD_ARGUMENT;
        start=comm_u32(request+8);count=comm_u32(request+12);
        if(!count || count>6 || start>post_result.count || count>post_result.count-start)return COMM_BAD_ARGUMENT;
        if(capacity<24+count*32)return COMM_IO_ERROR;
        comm_put32(response,session);comm_put32(response+4,run_id);comm_put32(response+8,frame_id);
        comm_put32(response+12,post_result.count);comm_put32(response+16,start);comm_put32(response+20,count);
        for(i=0;i<count;i++){
            ai_detection record;
            if(ai_ddr_read(AI_POST_OUTPUT_MIN+(start+i)*32,(uint32_t *)&record,32))return COMM_IO_ERROR;
            const uint32_t *words=(const uint32_t *)&record;
            for(unsigned j=0;j<8;j++)comm_put32(response+24+i*32+j*4,words[j]);
        }
        *size=(uint16_t)(24+count*32);return COMM_OK;
    }
    snapshot(response);*size=COMM_NETWORK_WORDS*4;return result;
}
void ai_network_poll(void){
    if(state!=NW_QUEUED)return;
    if((PP_REG(4)&(PP_HELD|PP_FAULT))!=PP_HELD || (STATUS&8u)){
        error=AI_DDR_ERROR;state=NW_ERROR;return;
    }
    state=NW_RUNNING;task_tick=last_cycle=CYCLES;elapsed=0;
    log_text("AI network running: 99 tasks, retained HDMI input; SPI queries remain active.\n");
    error=ai_run_model_input(MODEL_ADDRESS,input_base,PP_TENSOR_BYTES,&run_result);
    if(!error){
        state=NW_POSTPROCESS;log_text("AI network complete; CPU detection postprocess started.\n");
        error=ai_postprocess(AI_POST_CONFIG_ADDR,MODEL_ADDRESS,&post_result);
    }
    update_clock();state=error?NW_ERROR:NW_DONE;
    log_text(error?"AI network/postprocess failed; read network-status.\n":"AI detection complete; read results (same frame_id).\n");
}
