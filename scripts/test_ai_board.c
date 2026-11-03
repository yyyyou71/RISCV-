/* Software-only loader/ownership test. The original network/RTL is not rerun. */
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/mman.h>
#include "ai_network.h"
#include "ai_postprocess.h"
#include "comm_protocol.h"
static unsigned char *memory;
static unsigned writes,network_calls;
static char log_capture[4096];
static size_t log_bytes;
uint32_t ai_ddr_read(uint32_t address,uint32_t *data,uint32_t bytes){assert(address+bytes<=0x2000000);memcpy(data,memory+address,bytes);return 0;}
uint32_t ai_ddr_write(uint32_t address,const uint32_t *data,uint32_t bytes){assert(address+bytes<=0x2000000);memcpy(memory+address,data,bytes);writes++;return 0;}
uint32_t ai_run_model_input(uint32_t address,uint32_t input,uint32_t size,ai_run_result *r){
    assert(address==0x10000 && input==0x3f00000 && size==294912);network_calls++;
    r->completed=99;r->code=0;return 0;
}
uint32_t ai_postprocess(uint32_t config,uint32_t model,ai_post_result *r){assert(config==0x5000 && model==0x10000);r->count=r->written=1;return 0;}
size_t rk_comm_send(const uint8_t *data,size_t size){
    assert(log_bytes+size<sizeof(log_capture));memcpy(log_capture+log_bytes,data,size);
    log_bytes+=size;log_capture[log_bytes]=0;return size;
}
void rk_comm_poll(void){}
int main(int argc,char **argv){
    uint8_t request[240]={0},reply[240];uint16_t size;
    unsigned total=0x60000;uint32_t hash=2166136261u;struct pp_frame frame={7,2,0x800000,0x3f00000,294912};
    FILE *model=NULL;
    if(argc>=2){
        model=fopen(argv[1],"rb");assert(model && !fseek(model,0,SEEK_END));
        long bytes=ftell(model);assert(bytes>0 && bytes<=0x2000000 && !(bytes&15));
        total=(unsigned)bytes;rewind(model);
    }
    memory=calloc(1,0x2000000);assert(memory);
    void *mapped=mmap((void *)0x30000,0x2000,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED,-1,0);assert(mapped!=(void *)-1);
    *(volatile uint32_t *)0x31004=16;*(volatile uint32_t *)0x30804=PP_DDR_READY|PP_HELD;
    ai_model_header h={AI_MODEL_MAGIC,2,64,64,99,0x10040,0x10000,total,0x11900,294912,0x5b000,32,0x5a000,1,0,0};
    /* Use a tiny structurally matching profile to exercise upload, not tasks. */
    ai_post_config p={AI_POST_MAGIC,1,64,64,3,0x5100,16384,300,0x8000,9600,0x10000,0x5200,96,96,0,0};
    unsigned char *blob=calloc(1,total);assert(blob);memcpy(blob+0x10000,&h,64);memcpy(blob+0x5000,&p,64);
    if(model){assert(fread(blob,1,total,model)==total);assert(!fclose(model));}
    for(unsigned i=0;i<total;i++)hash=(hash^blob[i])*16777619u;
    ai_network_init();comm_put32(request,123);comm_put32(request+4,total);comm_put32(request+8,hash);comm_put32(request+12,9);
    assert(ai_network_command(COMM_MODEL_BEGIN,request,16,reply,240,&size,&frame,1,0,0)==0);
    assert(ai_network_loading());
    for(unsigned offset=0;offset<total;){
        unsigned bytes=total-offset;if(bytes>224)bytes=224;
        comm_put32(request,123);comm_put32(request+4,offset);memcpy(request+8,blob+offset,bytes);
        assert(ai_network_command(COMM_MODEL_CHUNK,request,8+bytes,reply,240,&size,&frame,1,0,0)==0);
        unsigned before=writes;
        assert(ai_network_command(COMM_MODEL_CHUNK,request,8+bytes,reply,240,&size,&frame,1,0,0)==0 && writes==before);
        request[8]^=1;
        assert(ai_network_command(COMM_MODEL_CHUNK,request,8+bytes,reply,240,&size,&frame,1,0,0)==COMM_BAD_ARGUMENT);
        offset+=bytes;
    }
    comm_put32(request,123);
    if(argc==3){
        assert(!strcmp(argv[2],"--corrupt-after-upload"));
        memory[0x10000]^=1; /* Later DDR overwrite, after every chunk readback passed. */
        assert(ai_network_command(COMM_MODEL_COMMIT,request,4,reply,240,&size,&frame,1,0,0)==COMM_BAD_ARGUMENT);
        assert(comm_u32(reply+4)==NW_ERROR && comm_u32(reply+8)==0x1003u);
        assert(comm_u32(reply+28)==hash && comm_u32(reply+32)==hash);
        assert(strstr(log_capture,"model: 314d4940") && strstr(log_capture,"post:  31504941"));
        assert(strlen(strstr(log_capture,"Model validation failed:"))<512);
        puts("PASS model commit: later DDR corruption rejects header despite matching upload FNV; failing model/post words retained in SPI logs");
        return 0;
    }
    assert(ai_network_command(COMM_MODEL_COMMIT,request,4,reply,240,&size,&frame,1,0,0)==0 && ai_network_has_model());
    assert(ai_network_command(COMM_NETWORK_RUN,request,4,reply,240,&size,&frame,0,0,0)==COMM_BUSY);
    assert(ai_network_command(COMM_NETWORK_RUN,request,4,reply,240,&size,&frame,1,0,0)==0 && ai_network_busy());
    assert(ai_network_command(COMM_MODEL_ABORT,request,4,reply,240,&size,&frame,1,0,0)==COMM_BUSY);
    ai_network_poll();assert(network_calls==1 && !ai_network_busy());
    comm_put32(request+4,1);comm_put32(request+8,0);comm_put32(request+12,1);
    assert(ai_network_command(COMM_DETECTIONS,request,16,reply,240,&size,&frame,1,0,0)==0 && size==56 && comm_u32(reply+8)==7);
    comm_put32(request+4,2);
    assert(ai_network_command(COMM_DETECTIONS,request,16,reply,240,&size,&frame,1,0,0)==COMM_BAD_ARGUMENT);
    puts("PASS board model software: chunk readback, duplicate/different replay, CRC/header commit, frame lease, queued ownership, result identity");
    return 0;
}
