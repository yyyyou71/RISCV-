#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#include "rk_control.h"
#include "network_status.h"
#include "video/pcie_dma.h"
#include "video/display.h"
#include "image_input.h"
#include "terminal_nav.h"
#include <time.h>

#define WIDTH IMAGE_WIDTH
#define HEIGHT IMAGE_HEIGHT
#define FRAME_BYTES (WIDTH*HEIGHT*2u)
#define PRESENT_HW_BUSY (1u<<0)
#define PRESENT_HW_ERROR (1u<<2)
#define PRESENT_HW_LOCKED (1u<<5)
#define PRESENT_HW_PREPARED (1u<<6)
static display_ctx_t screen;
static int have_screen;
static uint32_t timeout_ms=120000;
static int interactive;
static terminal_nav navigation;

static uint64_t now_ms(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000+t.tv_nsec/1000000;}
static int fail(int e){errno=e;return -1;}
static void stop(int sig){(void)sig;g_running=0;}
static int window_poll(void){
    if(interactive && terminal_nav_poll(&navigation)){g_running=0;return 1;}
    if(have_screen && display_poll_quit(&screen))g_running=0;
    return !g_running;
}
static int pause_status(void){
    if(window_poll())return fail(EINTR);
    struct timespec t={0,50000000};
    while(nanosleep(&t,&t)<0 && errno==EINTR && g_running){}
    return g_running?0:fail(EINTR);
}
static int number(const char *s,uint32_t *v){
    char *end;errno=0;unsigned long n=strtoul(s,&end,0);
    if(errno || !*s || *end || *s=='-' || n>UINT32_MAX)return -1;
    *v=(uint32_t)n;return 0;
}
static int command(unsigned op,const uint8_t *request,unsigned length){
    uint8_t reply[SPI_TERM_PAYLOAD];unsigned bytes;
    return rk_control_exchange(op,request,length,reply,sizeof(reply),&bytes);
}
static int present_status(uint32_t *v){return rk_control_status(COMM_PRESENT_STATUS,COMM_PRESENT_ABI,v,COMM_PRESENT_WORDS);}
static int network_status(uint32_t *v){return rk_control_status(COMM_NETWORK_STATUS,COMM_NETWORK_ABI,v,COMM_NETWORK_WORDS);}

static int image_status(uint32_t *v){return rk_control_status(COMM_IMAGE_STATUS,COMM_IMAGE_ABI,v,COMM_IMAGE_WORDS);}
static int input_empty(void){
    uint32_t v[COMM_IMAGE_WORDS];uint64_t until=now_ms()+timeout_ms;
    if(image_status(v))return -1;
    while(v[1]==IMAGE_PROCESSING||v[1]==IMAGE_RELEASING){
        if(now_ms()>=until)return fail(ETIMEDOUT);
        if(pause_status()||image_status(v))return -1;
    }
    if(v[1]!=IMAGE_EMPTY){
        if(command(COMM_VIDEO_RELEASE,0,0))return -1;
        do{
            if(image_status(v))return -1;
            if(v[1]==IMAGE_EMPTY)return 0;
            if(v[1]==IMAGE_ERROR)return fail(EIO);
            if(pause_status())return -1;
        }while(now_ms()<until);
        return fail(ETIMEDOUT);
    }
    return 0;
}
static int image_exchange(unsigned op,const uint8_t *p,unsigned n,uint32_t session,uint32_t id,uint32_t committed){
    uint8_t reply[SPI_TERM_PAYLOAD];unsigned bytes;
    if(rk_control_exchange(op,p,n,reply,sizeof(reply),&bytes))return -1;
    if(bytes!=COMM_IMAGE_WORDS*4||comm_u32(reply)!=COMM_IMAGE_ABI||comm_u32(reply+12)!=session||
       comm_u32(reply+16)!=id||comm_u32(reply+20)!=committed)return fail(EPROTO);
    return 0;
}
static int upload_image(const uint8_t *rgb,uint32_t session,uint32_t id,int ai){
    uint8_t request[12+IMAGE_CHUNK_BYTES];uint32_t hash=2166136261u,v[COMM_IMAGE_WORDS];
    for(unsigned i=0;i<IMAGE_BYTES;i++)hash=(hash^rgb[i])*16777619u;
    comm_put32(request,session);comm_put32(request+4,id);comm_put32(request+8,WIDTH);
    comm_put32(request+12,HEIGHT);comm_put32(request+16,IMAGE_RGB888);comm_put32(request+20,IMAGE_BYTES);
    comm_put32(request+24,hash);comm_put32(request+28,0);
    uint64_t started=now_ms();rk_control_set_quiet(1);int result=-1;
    if(image_exchange(COMM_IMAGE_BEGIN,request,32,session,id,0))goto done;
    for(unsigned offset=0;offset<IMAGE_BYTES;offset+=IMAGE_CHUNK_BYTES){
        comm_put32(request,session);comm_put32(request+4,id);comm_put32(request+8,offset);
        memcpy(request+12,rgb+offset,IMAGE_CHUNK_BYTES);
        if(image_exchange(COMM_IMAGE_DATA,request,sizeof(request),session,id,offset+IMAGE_CHUNK_BYTES))goto done;
    }
    comm_put32(request,session);comm_put32(request+4,id);comm_put32(request+8,IMAGE_BYTES);comm_put32(request+12,hash);
    if(image_exchange(COMM_IMAGE_COMMIT,request,16,session,id,IMAGE_BYTES))goto done;
    uint64_t uploaded=now_ms(),until=uploaded+timeout_ms;
    do{
        if(image_status(v))goto done;
        if(v[3]!=session||v[4]!=id||v[5]!=IMAGE_BYTES||v[7]!=hash||v[8]!=hash){errno=EPROTO;goto done;}
        if(v[1]==IMAGE_ERROR){fprintf(stderr,"[image] error=%u hw_status=%08x hw_error=%u\n",v[2],v[10],v[11]);errno=EIO;goto done;}
        if(v[1]==IMAGE_READY){
            if((v[10]&0x2du)!=8u||v[12]!=(ai?294912u:0u)||v[13]!=FRAME_BYTES||
               v[15]!=((HEIGHT<<16)|WIDTH)||v[9]!=(uint32_t)ai){errno=EPROTO;goto done;}
            printf("[input] frame=%u upload=%.3fs prepare=%.3fs hw_cycles=%u RGB888=%u RGB565=%u\n",
                id,(uploaded-started)/1000.0,(now_ms()-uploaded)/1000.0,v[14],IMAGE_BYTES,FRAME_BYTES);
            result=0;goto done;
        }
        if(pause_status())goto done;
    }while(now_ms()<until);
    errno=ETIMEDOUT;
done:
    rk_control_set_quiet(0);return result;
}
static int infer(uint32_t frame_id,uint32_t *run_id){
    uint32_t v[COMM_NETWORK_WORDS];uint8_t request[4];unsigned last=UINT32_MAX;
    if(network_status(v))return -1;
    if(v[1]!=NW_READY && v[1]!=NW_DONE){
        fprintf(stderr,"[network] model is not ready (state=%u); use --model FILE.\n",v[1]);
        return fail(EBUSY);
    }
    comm_put32(request,v[3]);
    if(command(COMM_NETWORK_RUN,request,4))return -1;
    uint64_t until=now_ms()+timeout_ms;
    do{
        if(network_status(v))return -1;
        if(v[10]!=frame_id)return fail(EPROTO);
        if(v[12]!=last){printf("[network] frame=%u task=%u/%u state=%u\n",frame_id,v[12],v[11],v[1]);last=v[12];}
        if(v[1]==NW_ERROR){fprintf(stderr,"[network] error=%u task=%u\n",v[2],v[13]);return fail(EIO);}
        if(v[1]==NW_DONE){*run_id=v[9];return rk_control_results(frame_id,*run_id);}
        if(pause_status())return -1;
    }while(now_ms()<until);
    return fail(ETIMEDOUT);
}
static int prepare_present(uint32_t frame_id,uint32_t run_id){
    uint32_t v[COMM_PRESENT_WORDS];uint64_t until=now_ms()+10000;
    if(present_status(v))return -1;
    // AI firmware may already have queued this retained frame automatically.
    if(v[5]!=frame_id || (v[1]!=1 && v[1]!=2)){
        if(command(COMM_PRESENT_RUN,0,0))return -1;
    }
    do{
        if(present_status(v))return -1;
        if(v[1]==4 || (v[3]&(PRESENT_HW_ERROR|PRESENT_HW_LOCKED))){
            fprintf(stderr,"[present] error=%u hw_error=%u hw_status=0x%08x\n",v[2],v[8],v[3]);return fail(EIO);
        }
        if(v[5]==frame_id && v[1]==2 &&
           (v[3]&(PRESENT_HW_BUSY|PRESENT_HW_PREPARED))==(PRESENT_HW_BUSY|PRESENT_HW_PREPARED)){
            if(run_id && v[4]!=run_id)return fail(EPROTO);
            printf("[present] frame=%u run=%u boxes=%u; receiving PCIe image\n",frame_id,v[4],v[7]);
            return 0;
        }
        if(pause_status())return -1;
    }while(now_ms()<until);
    fprintf(stderr,"[present] waiting for DMA readiness timed out: state=%u hw_status=0x%08x frame=%u expected=%u\n",
            v[1],v[3],v[5],frame_id);
    return fail(ETIMEDOUT);
}
static int finish_present(uint32_t frame_id){
    uint32_t v[COMM_PRESENT_WORDS];uint64_t until=now_ms()+10000;
    do{
        if(present_status(v))return -1;
        if(v[1]==4)return fail(EIO);
        if(v[1]==3){
            if(v[5]!=frame_id || v[9]!=frame_id || v[10]!=WIDTH*HEIGHT/8u)
                return fail(EPROTO);
            if(!(v[3]&(PRESENT_HW_BUSY|PRESENT_HW_LOCKED|PRESENT_HW_PREPARED)))return 0;
        }
        if(pause_status())return -1;
    }while(now_ms()<until);
    return fail(ETIMEDOUT);
}
/* A previous process may have left a known frame queued. Drain it before
 * changing leases; never reset the prefetched stream or replay uncertain DMA. */
static int drain_pending(pcie_ctx_t *ctx,int *dma_pending){
    uint32_t v[COMM_PRESENT_WORDS];
    if(present_status(v))return -1;
    if(v[1]!=1 && v[1]!=2)return 0;
    if(prepare_present(v[5],v[4]))return -1;
    *dma_pending=1;
    if(transfer_frame(ctx) || finish_present(v[5]))return -1;
    *dma_pending=0;
    printf("[output] drained previously queued frame=%u before selecting mode\n",v[5]);
    return 0;
}
static int select_output(pcie_ctx_t *ctx,int *dma_pending,int ai){
    uint32_t v[COMM_VIDEO_MODE_WORDS];uint8_t request[4],reply[16];unsigned size;
    uint32_t mode=ai?VIDEO_OUTPUT_AI:VIDEO_OUTPUT_RAW;
    uint64_t until=now_ms()+timeout_ms;
    comm_put32(request,mode);
    do{
        if(drain_pending(ctx,dma_pending) || input_empty())return -1;
        if(!rk_control_exchange(COMM_VIDEO_MODE,request,4,reply,sizeof(reply),&size)){
            if(size!=sizeof(reply) || comm_u32(reply)!=COMM_VIDEO_MODE_ABI ||
               comm_u32(reply+8)!=mode)return fail(EPROTO);
            break;
        }
        /* Only an explicit BUSY rejection is safe to retry. */
        if(errno!=EBUSY || pause_status())return -1;
        if(now_ms()>=until)return fail(ETIMEDOUT);
    }while(1);
    do{
        if(rk_control_status(COMM_VIDEO_MODE,COMM_VIDEO_MODE_ABI,v,COMM_VIDEO_MODE_WORDS))return -1;
        if(v[1]==mode && v[2]==mode && v[3]!=COMM_VIDEO_RELEASING){
            printf("[output] %s\n",ai?"AI inference + same-frame detection boxes":"RAW original frame; preprocessing/AI bypassed");
            return 0;
        }
        if(pause_status())return -1;
    }while(now_ms()<until);
    return fail(ETIMEDOUT);
}

int main(int argc,char **argv){
    const char *model=0,*save=0,*input=0;uint32_t frames=0,frame_id=0,run_id=0,completed=0;
    image_list images={0};int loop=0;uint8_t *rgb=0;
    int ai=0,explicit_mode=-1,resume=0,headless=0,rc=1,spi_open=0,pcie_open=0,dma_allocated=0,dma_pending=0;
    pcie_ctx_t ctx={0};ctx.dma_drv_fd=ctx.cma_buf_fd=ctx.cma_heap_fd=-1;
    memset(&screen,0,sizeof(screen));have_screen=0;g_running=1;
    interactive=0;memset(&navigation,0,sizeof(navigation));timeout_ms=120000;
    if(argc<2)goto usage;
    for(int i=2;i<argc;i++){
        if(!strcmp(argv[i],"--input") && i+1<argc)input=argv[++i];
        else if(!strcmp(argv[i],"--loop"))loop=1;
        else if(!strcmp(argv[i],"--interactive"))interactive=1;
        else if(!strcmp(argv[i],"--model") && i+1<argc){model=argv[++i];ai=1;}
        else if(!strcmp(argv[i],"--use-loaded-model"))ai=1;
        else if(!strcmp(argv[i],"--resume"))resume=1;
        else if(!strcmp(argv[i],"--preview"))explicit_mode=VIDEO_OUTPUT_RAW;
        else if(!strcmp(argv[i],"--output") && i+1<argc){
            const char *mode=argv[++i];
            if(!strcmp(mode,"raw"))explicit_mode=VIDEO_OUTPUT_RAW;
            else if(!strcmp(mode,"ai"))explicit_mode=VIDEO_OUTPUT_AI;
            else goto usage;
        }
        else if(!strcmp(argv[i],"--headless"))headless=1;
        else if(!strcmp(argv[i],"--frames") && i+1<argc){if(number(argv[++i],&frames))goto usage;}
        else if(!strcmp(argv[i],"--wait-ms") && i+1<argc){if(number(argv[++i],&timeout_ms) || timeout_ms<1000)goto usage;}
        else if(!strcmp(argv[i],"--save") && i+1<argc)save=argv[++i];
        else goto usage;
    }
    if(explicit_mode>=0)ai=explicit_mode==VIDEO_OUTPUT_AI;
    if(!input || (resume&&!model) || (model&&!ai) || (interactive&&loop))goto usage;
    if(image_list_open(&images,input))goto error;
    navigation.count=images.count;
    if(interactive)terminal_nav_help();
    if(headless&&!save){fprintf(stderr,"--headless requires --save PREFIX for captured images.\n");goto usage;}
    signal(SIGINT,stop);signal(SIGTERM,stop);
    rk_control_set_idle_hook(window_poll);
    if(rk_control_open(argv[1]))goto error;
    spi_open=1;
    uint32_t input_info[COMM_IMAGE_WORDS];
    if(image_status(input_info) || input_info[15]!=((HEIGHT<<16)|WIDTH) || input_info[19]!=IMAGE_CHUNK_BYTES){
        fprintf(stderr,"This app requires the SPI image FPGA/firmware build.\n");goto error;
    }
    uint32_t mode_info[COMM_VIDEO_MODE_WORDS];
    if(rk_control_status(COMM_VIDEO_MODE,COMM_VIDEO_MODE_ABI,mode_info,COMM_VIDEO_MODE_WORDS)){
        fprintf(stderr,"Output selection requires the updated RAW/AI soft-core firmware and FPGA bitstream.\n");
        goto error;
    }
    uint64_t bar=find_bar1_addr();if(!bar)goto error;
    if(pcie_bar1_init(&ctx,bar))goto error;
    pcie_open=1;ctx.transfer_dw=FRAME_BYTES/4;ctx.skip_dma_reset=1;
    if(alloc_dma_buffer_cma(&ctx,FRAME_BYTES) && alloc_dma_buffer(&ctx,FRAME_BYTES))goto error;
    dma_allocated=1;
    // Reset DMA before any presentation is prepared, never between queue and DMA.
    uint32_t startup_present[COMM_PRESENT_WORDS];
    if(present_status(startup_present))goto error;
    if(startup_present[1]!=1 && startup_present[1]!=2){
        write_bar1_reg(&ctx,BAR1_REG_DMA_SOFT_RST,1);usleep(100);
    }
    if(!headless){
        if(display_init(&screen,WIDTH,HEIGHT)){
            fprintf(stderr,"Open from the RK desktop terminal with sudo -E, or use --headless --save PREFIX.\n");
            errno=EIO;
            goto error;
        }
        have_screen=1;
    }
    // Recover/replace a partial model before changing mode: firmware rejects
    // mode changes while NW_LOADING, so doing this after select_output deadlocks.
    if(model){
        if(drain_pending(&ctx,&dma_pending) || input_empty())goto error;
        if(rk_control_upload(model,resume))goto error;
    }
    if(select_output(&ctx,&dma_pending,ai))goto error;
    printf("[video-app] %s; SPI controls/results, PCIe RGB565 %ux%u, desktop SDL2 display\n",ai?"FPGA inference":"preview",WIDTH,HEIGHT);
    uint32_t session=(uint32_t)(now_ms()^((uint32_t)getpid()<<16));if(!session)session=1;
    unsigned image_index=0;
    while(g_running && !navigation.quit && (!frames || completed<frames) && (interactive || loop || completed<images.count)){
        uint64_t frame_started=now_ms();
        const char *path=images.paths[interactive?image_index:completed%images.count];
        if(interactive){navigation.index=image_index;navigation.requested=0;printf("[browse] image %u/%u: %s\n",image_index+1,images.count,path);}
        printf("[input] file=%s\n",path);
        rgb=image_load_384(path);if(!rgb)goto error;
        frame_id=completed+1;
        if(upload_image(rgb,session,frame_id,ai))goto error;
        free(rgb);rgb=0;
        uint64_t prepared=now_ms();
        run_id=0;
        if(ai && infer(frame_id,&run_id))goto error;
        uint64_t inferred=now_ms();
        if(prepare_present(frame_id,run_id))goto error;
        dma_pending=1;
        if(transfer_frame(&ctx))goto error;
        if(finish_present(frame_id))goto error;
        dma_pending=0;
        uint64_t returned=now_ms();
        const uint8_t *pixels=ctx.staging_buf?ctx.staging_buf:ctx.dma_buf;
        if(have_screen){display_show_frame(&screen,pixels,WIDTH,HEIGHT,WIDTH);if(display_poll_quit(&screen))g_running=0;}
        if(save){
            char filename[4096];
            if(snprintf(filename,sizeof(filename),"%s-%010u.ppm",save,frame_id)>=(int)sizeof(filename)){errno=ENAMETOOLONG;goto error;}
            if(save_ppm(filename,pixels,WIDTH,HEIGHT,WIDTH))goto error;
        }
        completed++;printf("[frame] displayed=%u frame_id=%u run_id=%u infer+results=%.3fs PCIe=%.3fs total=%.3fs bytes=%u\n",
            completed,frame_id,run_id,(inferred-prepared)/1000.0,(returned-inferred)/1000.0,(now_ms()-frame_started)/1000.0,FRAME_BYTES);
        if(command(COMM_VIDEO_RELEASE,0,0) || input_empty())goto error;
        if(interactive && (!frames || completed<frames)){
            printf("[browse] showing %u/%u; enter n, p or q: ",image_index+1,images.count);fflush(stdout);
            while(g_running && !navigation.quit && !navigation.requested){
                if(window_poll())break;
                struct timespec delay={0,50000000};nanosleep(&delay,0);
            }
            image_index=navigation.index;
        }
    }
    rc=0;goto done;
error:
    if(errno==EINTR && !g_running)rc=0;
    else{perror("video-app");fprintf(stderr,"Stopped; no uncertain SPI command or DMA frame was replayed.\n");}
done:
    if(dma_pending){
        write_bar1_reg(&ctx,BAR1_REG_DMA_SOFT_RST,1);usleep(100000);
        fprintf(stderr,"DMA interrupted: retained FPGA frame was not released; inspect/reset before restarting.\n");
    }
    free(rgb);image_list_close(&images);
    if(have_screen)display_cleanup(&screen);
    if(dma_allocated){if(ctx.use_cma)free_dma_buffer_cma(&ctx);else free_dma_buffer(&ctx);}
    if(pcie_open)pcie_bar1_cleanup(&ctx);
    if(spi_open)rk_control_close();
    return rc;
usage:
    fprintf(stderr,"Usage: %s SPI_DEVICE --input FILE_OR_DIR [--loop|--interactive] [--output raw|ai] [--model FILE|--use-loaded-model] [--preview] [--resume] [--frames N] [--wait-ms N] [--save PREFIX] [--headless]\n",argv[0]);
    return 2;
}
