/* Host orchestration only: fake SPI/PCIe/display, no hardware accesses. */
#define main rk_video_app_main
#include "rk_video_app.c"
#undef main
#include <assert.h>

volatile int g_running=1;
static unsigned captured,dma_count,shown,inferred,printed,submitted,resets,closed,mode_changes;
static uint32_t fid,rid,output;
static int presentation,dma_done,corrupt_words,corrupt_frame,model_ready,old_firmware;
int rk_control_open(const char *p){assert(!strcmp(p,"fake-spi"));return 0;}
void rk_control_close(void){closed++;}
void rk_control_set_idle_hook(int (*hook)(void)){(void)hook;}
int rk_control_upload(const char *p,int resume){assert(!strcmp(p,"fake-model"));assert(!resume);model_ready=1;return 0;}
int rk_control_results(uint32_t frame_id,uint32_t run_id){assert(frame_id==fid && run_id==rid);printed++;return 0;}
int rk_control_status(unsigned op,uint32_t abi,uint32_t *v,unsigned words){
    memset(v,0,words*4);v[0]=abi;
    switch(op){
    case COMM_VIDEO_MODE:
        if(old_firmware){errno=EPROTO;return -1;}
        assert(words==COMM_VIDEO_MODE_WORDS && abi==COMM_VIDEO_MODE_ABI);
        v[1]=v[2]=output;v[3]=COMM_VIDEO_SUCCESS;break;
    case COMM_VIDEO_STATUS:
        v[1]=COMM_VIDEO_SUCCESS;v[5]=(1080u<<16)|1919u;v[7]=24;
        v[17]=fid;v[18]=2;v[21]=output==VIDEO_OUTPUT_AI?294912:0;break;
    case COMM_AI_STATUS:v[1]=0;break;
    case COMM_NETWORK_STATUS:
        assert(output==VIDEO_OUTPUT_AI);
        v[1]=inferred?NW_DONE:NW_READY;v[3]=77;v[9]=rid;
        v[10]=fid+(corrupt_frame?1:0);v[11]=v[12]=99;break;
    case COMM_PRESENT_STATUS:
        if(dma_done)presentation=3;
        v[1]=presentation;v[3]=(presentation==2)?41:10;v[4]=rid;v[5]=fid;
        v[7]=(output==VIDEO_OUTPUT_AI && inferred)?1:0;v[9]=dma_done?fid:0;
        v[10]=WIDTH*HEIGHT/8-(corrupt_words?1:0);break;
    default:assert(0);
    }
    return 0;
}
int rk_control_exchange(unsigned op,const uint8_t *request,unsigned size,uint8_t *reply,unsigned cap,unsigned *bytes){
    *bytes=0;
    if(op==COMM_VIDEO_MODE){
        assert(size==4 && cap==16 && comm_u32(request)<=VIDEO_OUTPUT_AI);
        assert(presentation!=1 && presentation!=2);
        if(output!=comm_u32(request)){
            output=comm_u32(request);mode_changes++;fid++;captured++;
            presentation=0;dma_done=0;
        }
        comm_put32(reply,COMM_VIDEO_MODE_ABI);comm_put32(reply+4,output);
        comm_put32(reply+8,output);comm_put32(reply+12,COMM_VIDEO_SUCCESS);*bytes=16;
    }else if(op==COMM_VIDEO_RETRY){
        assert(!presentation || (presentation==3 && dma_done));
        fid++;captured++;presentation=0;dma_done=0;
    }else if(op==COMM_PRESENT_RUN){
        assert(!presentation || (presentation==3 && dma_done));
        presentation=2;dma_done=0;submitted++;
    }else if(op==COMM_NETWORK_RUN){
        assert(output==VIDEO_OUTPUT_AI && model_ready && size==4 && comm_u32(request)==77);
        inferred++;rid++;presentation=2;
    }else assert(0);
    return 0;
}
uint64_t find_bar1_addr(void){return 0xf0220000;}
int pcie_bar1_init(pcie_ctx_t *c,uint64_t bar){assert(bar==0xf0220000);c->bar1_base=(void *)1;return 0;}
void pcie_bar1_cleanup(pcie_ctx_t *c){c->bar1_base=0;}
int alloc_dma_buffer_cma(pcie_ctx_t *c,uint32_t size){
    assert(size==FRAME_BYTES);c->dma_buf=calloc(1,size);assert(c->dma_buf);
    c->staging_buf=c->dma_buf;c->dma_buf_phys=0x70000000;c->dma_buf_size=size;c->use_cma=1;return 0;
}
int alloc_dma_buffer(pcie_ctx_t *c,uint32_t size){(void)c;(void)size;assert(0);return -1;}
void free_dma_buffer_cma(pcie_ctx_t *c){free(c->dma_buf);c->dma_buf=0;}
void free_dma_buffer(pcie_ctx_t *c){(void)c;assert(0);}
void write_bar1_reg(pcie_ctx_t *c,uint32_t offset,uint32_t value){
    (void)c;assert(offset==BAR1_REG_DMA_SOFT_RST && value==1);
    assert(presentation!=2);resets++;
}
int transfer_frame(pcie_ctx_t *c){
    assert(presentation==2 && !dma_done && c->skip_dma_reset && c->transfer_dw==FRAME_BYTES/4);
    dma_count++;dma_done=1;return 0;
}
int display_init(display_ctx_t *d,uint32_t w,uint32_t h){assert(w==WIDTH && h==HEIGHT);d->sdl_ok=1;return 0;}
void display_cleanup(display_ctx_t *d){d->sdl_ok=0;}
int display_poll_quit(display_ctx_t *d){(void)d;return 0;}
void display_show_frame(display_ctx_t *d,const uint8_t *p,uint32_t w,uint32_t h,uint32_t stride){
    assert(d->sdl_ok && p && w==WIDTH && h==HEIGHT && stride==WIDTH);
    assert(dma_done && presentation==3 && !corrupt_words);shown++;
}
int save_ppm(const char *path,const uint8_t *p,uint32_t w,uint32_t h,uint32_t stride){
    (void)path;(void)p;(void)w;(void)h;(void)stride;assert(0);
    return -1;
}
static void reset_case(void){
    captured=1;dma_count=shown=inferred=printed=submitted=resets=closed=0;
    fid=42;rid=0;output=VIDEO_OUTPUT_RAW;mode_changes=0;
    presentation=dma_done=corrupt_words=corrupt_frame=model_ready=old_firmware=0;
}
int main(void){
    char *preview[]={"rk_video_app","fake-spi","--output","raw","--frames","2"};
    reset_case();assert(rk_video_app_main(6,preview)==0);
    assert(captured==2 && shown==2 && dma_count==2 && submitted==2 && resets==1 && closed==1);
    assert(!inferred && !mode_changes);
    char *pending_frame[]={"rk_video_app","fake-spi","--preview","--frames","1"};
    reset_case();presentation=2;assert(rk_video_app_main(5,pending_frame)==0);
    assert(shown==1 && dma_count==2 && submitted==1 && resets==0);
    char *ai[]={"rk_video_app","fake-spi","--output","ai","--model","fake-model","--frames","2"};
    reset_case();assert(rk_video_app_main(8,ai)==0);
    assert(captured==4 && shown==2 && dma_count==2 && inferred==2 && printed==2 && submitted==0 && mode_changes==1);
    reset_case();output=VIDEO_OUTPUT_AI;rid=9;inferred=1;presentation=2;
    assert(rk_video_app_main(6,preview)==0);
    assert(mode_changes==1 && shown==2 && dma_count==3 && inferred==1 && printed==0);
    reset_case();corrupt_words=1;assert(rk_video_app_main(6,preview)==1);
    assert(shown==0 && dma_count==1 && resets==2);
    reset_case();corrupt_frame=1;assert(rk_video_app_main(8,ai)==1);
    assert(shown==0 && dma_count==0 && inferred==1);
    reset_case();old_firmware=1;assert(rk_video_app_main(6,preview)==1);
    assert(!shown && !dma_count && !resets && closed==1);
    puts("PASS video app: RAW/AI selection, pending frame drained before switch, SPI/PCIe/display identity checks, old firmware rejected");
    return 0;
}
