/* Host orchestration: image upload, model selection, SPI/PCIe/display identity. */
#define main rk_video_app_main
#include "rk_video_app.c"
#undef main
#include <assert.h>
volatile int g_running=1;
static unsigned captured,dma_count,shown,inferred,printed,submitted,resets,closed,mode_changes;
static uint32_t fid,rid,output,imstate,imsession,committed,imhash,expected_hash;
static int presentation,dma_done,corrupt_words,corrupt_frame,model_ready,old_firmware;
static unsigned arm_polls;
static int present_fault;
int image_list_open(image_list *list,const char *path){
    assert(!strcmp(path,"fake-dir"));list->count=2;list->paths=calloc(2,sizeof(char *));
    list->paths[0]=strdup("one.png");list->paths[1]=strdup("two.jpg");return 0;
}
void image_list_close(image_list *list){for(unsigned i=0;i<list->count;i++)free(list->paths[i]);free(list->paths);list->count=0;list->paths=0;}
uint8_t *image_load_384(const char *path){
    assert(!strcmp(path,"one.png")||!strcmp(path,"two.jpg"));uint8_t *p=malloc(IMAGE_BYTES);
    for(unsigned i=0;i<IMAGE_BYTES;i++)p[i]=(uint8_t)(i*29u);
    return p;
}
int rk_control_open(const char *p){assert(!strcmp(p,"fake-spi"));return 0;}
void rk_control_close(void){closed++;}
void rk_control_set_idle_hook(int (*hook)(void)){(void)hook;}
void rk_control_set_quiet(int value){(void)value;}
int rk_control_upload(const char *p,int resume){assert(!strcmp(p,"fake-model"));assert(!resume);model_ready=1;return 0;}
int rk_control_results(uint32_t frame_id,uint32_t run_id){assert(frame_id==fid&&run_id==rid);printed++;return 0;}
int rk_control_status(unsigned op,uint32_t abi,uint32_t *v,unsigned words){
    memset(v,0,words*4);v[0]=abi;
    switch(op){
    case COMM_IMAGE_STATUS:
        if(old_firmware){errno=EPROTO;return -1;}
        assert(words==COMM_IMAGE_WORDS&&abi==COMM_IMAGE_ABI);
        v[1]=imstate;v[3]=imsession;v[4]=fid;v[5]=committed;v[6]=IMAGE_BYTES;
        v[7]=imhash;v[8]=expected_hash;v[9]=output;v[10]=imstate==IMAGE_READY?26:16;
        v[12]=imstate==IMAGE_READY&&output==VIDEO_OUTPUT_AI?294912:0;
        v[13]=imstate==IMAGE_READY?FRAME_BYTES:0;v[15]=(HEIGHT<<16)|WIDTH;v[19]=IMAGE_CHUNK_BYTES;break;
    case COMM_VIDEO_MODE:
        assert(words==COMM_VIDEO_MODE_WORDS&&abi==COMM_VIDEO_MODE_ABI);
        v[1]=v[2]=output;v[3]=imstate==IMAGE_READY?COMM_VIDEO_SUCCESS:COMM_VIDEO_IDLE;break;
    case COMM_NETWORK_STATUS:
        assert(output==VIDEO_OUTPUT_AI);
        v[1]=inferred?NW_DONE:(model_ready?NW_READY:NW_EMPTY);v[3]=77;v[9]=rid;
        v[10]=fid+(corrupt_frame?1:0);v[11]=v[12]=99;break;
    case COMM_PRESENT_STATUS:
        if(dma_done)presentation=3;
        v[1]=presentation;v[3]=0x18u;v[4]=rid;v[5]=fid;
        if(presentation==2){
            // Actual RTL layout: bit 5=fault lock, bit 6=armed+reader started.
            v[3]|=1u;
            if(++arm_polls>=3)v[3]|=1u<<6;
            if(present_fault)v[3]|=(1u<<5)|(1u<<2);
        }
        v[7]=output==VIDEO_OUTPUT_AI&&inferred?1:0;v[9]=dma_done?fid:0;
        v[10]=WIDTH*HEIGHT/8-(corrupt_words?1:0);break;
    default:assert(0);
    }
    return 0;
}
int rk_control_exchange(unsigned op,const uint8_t *p,unsigned n,uint8_t *reply,unsigned cap,unsigned *bytes){
    *bytes=0;
    if(op==COMM_VIDEO_MODE){
        assert(n==4&&cap==16&&imstate==IMAGE_EMPTY);if(output!=comm_u32(p))mode_changes++;
        output=comm_u32(p);comm_put32(reply,COMM_VIDEO_MODE_ABI);comm_put32(reply+4,output);
        comm_put32(reply+8,output);comm_put32(reply+12,COMM_VIDEO_IDLE);*bytes=16;
    }else if(op==COMM_IMAGE_BEGIN){
        assert(imstate==IMAGE_EMPTY&&n==32&&comm_u32(p+8)==WIDTH&&comm_u32(p+12)==HEIGHT&&comm_u32(p+20)==IMAGE_BYTES);
        imstate=IMAGE_LOADING;imsession=comm_u32(p);fid=comm_u32(p+4);committed=0;imhash=2166136261u;expected_hash=comm_u32(p+24);
        dma_done=0;presentation=0;rid=0;
    }else if(op==COMM_IMAGE_DATA){
        assert(imstate==IMAGE_LOADING&&n==12+IMAGE_CHUNK_BYTES&&comm_u32(p)==imsession&&comm_u32(p+4)==fid&&comm_u32(p+8)==committed);
        for(unsigned i=0;i<IMAGE_CHUNK_BYTES;i++){assert(p[12+i]==(uint8_t)((committed+i)*29u));imhash=(imhash^p[12+i])*16777619u;}
        committed+=IMAGE_CHUNK_BYTES;
    }else if(op==COMM_IMAGE_COMMIT){
        assert(n==16&&comm_u32(p)==imsession&&comm_u32(p+4)==fid&&comm_u32(p+8)==IMAGE_BYTES);
        assert(committed==IMAGE_BYTES&&imhash==expected_hash&&comm_u32(p+12)==expected_hash);
        imstate=IMAGE_READY;captured++;
    }else if(op==COMM_NETWORK_RUN){
        assert(output==VIDEO_OUTPUT_AI&&model_ready&&imstate==IMAGE_READY);rid++;inferred++;
    }else if(op==COMM_PRESENT_RUN){assert(imstate==IMAGE_READY);submitted++;presentation=2;arm_polls=0;}
    else if(op==COMM_VIDEO_RELEASE){assert(presentation!=1&&presentation!=2);imstate=IMAGE_EMPTY;presentation=0;dma_done=0;}
    else assert(0);
    if(op>=COMM_IMAGE_BEGIN&&op<=COMM_IMAGE_COMMIT){
        uint32_t v[COMM_IMAGE_WORDS];assert(cap>=sizeof(v));rk_control_status(COMM_IMAGE_STATUS,COMM_IMAGE_ABI,v,COMM_IMAGE_WORDS);
        for(unsigned i=0;i<COMM_IMAGE_WORDS;i++)comm_put32(reply+i*4,v[i]);
        *bytes=sizeof(v);
    }
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
    assert(arm_polls>=3 && !present_fault); /* No DMA on BUSY alone or fault lock. */
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
    captured=dma_count=shown=inferred=printed=submitted=resets=closed=mode_changes=0;
    fid=rid=output=imstate=imsession=committed=expected_hash=0;imhash=2166136261u;
    presentation=dma_done=corrupt_words=corrupt_frame=model_ready=old_firmware=0;
    arm_polls=0;present_fault=0;
}
int main(void){
    char *raw[]={"rk_video_app","fake-spi","--input","fake-dir","--output","raw"};
    reset_case();assert(rk_video_app_main(6,raw)==0);
    assert(captured==2&&shown==2&&dma_count==2&&submitted==2&&resets==1&&closed==1&&!inferred);
    char *ai[]={"rk_video_app","fake-spi","--input","fake-dir","--output","ai","--model","fake-model"};
    reset_case();assert(rk_video_app_main(8,ai)==0);
    assert(captured==2&&shown==2&&inferred==2&&printed==2&&submitted==2&&mode_changes==1);
    reset_case();corrupt_words=1;assert(rk_video_app_main(6,raw)==1);assert(shown==0&&dma_count==1);
    reset_case();corrupt_frame=1;assert(rk_video_app_main(8,ai)==1);assert(shown==0&&dma_count==0&&inferred==1);
    reset_case();old_firmware=1;assert(rk_video_app_main(6,raw)==1);assert(!shown&&!dma_count&&closed==1);
    reset_case();present_fault=1;assert(rk_video_app_main(6,raw)==1);assert(!shown&&!dma_count&&closed==1);
    puts("PASS SPI image app: delayed DMA readiness, fault lock rejection, RAW/AI directory flow, same-frame DMA/display, bad counts/IDs and old firmware rejected");
    return 0;
}
