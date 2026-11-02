#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#include "rk_control.h"
#include "network_status.h"
#include "video/pcie_dma.h"
#include "video/display.h"
#include <time.h>

#define WIDTH 1920u
#define HEIGHT 1080u
#define FRAME_BYTES (WIDTH*HEIGHT*2u)
static display_ctx_t screen;
static int have_screen;
static uint32_t timeout_ms=120000;

static uint64_t now_ms(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000+t.tv_nsec/1000000;}
static int fail(int e){errno=e;return -1;}
static void stop(int sig){(void)sig;g_running=0;}
static int window_poll(void){
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
static int video_status(uint32_t *v){return rk_control_status(COMM_VIDEO_STATUS,COMM_VIDEO_ABI,v,COMM_VIDEO_WORDS);}
static int present_status(uint32_t *v){return rk_control_status(COMM_PRESENT_STATUS,COMM_PRESENT_ABI,v,COMM_PRESENT_WORDS);}
static int network_status(uint32_t *v){return rk_control_status(COMM_NETWORK_STATUS,COMM_NETWORK_ABI,v,COMM_NETWORK_WORDS);}

static int wait_video(uint32_t *frame_id,int new_capture,int ai){
    uint32_t v[COMM_VIDEO_WORDS];uint64_t until=now_ms()+15000;unsigned last=UINT32_MAX;
    if(video_status(v))return -1;
    if(new_capture || v[1]==COMM_VIDEO_ERROR || v[1]==COMM_VIDEO_IDLE){
        if(command(COMM_VIDEO_RETRY,0,0))return -1;
    }
    do{
        if(video_status(v))return -1;
        if(v[1]!=last){
            printf("[capture] state=%u measured=%ux%u error=%u\n",v[1],v[5]&65535,v[5]>>16,v[2]);
            last=v[1];
        }
        if(v[1]==COMM_VIDEO_ERROR)return fail(EIO);
        if(v[1]==COMM_VIDEO_SUCCESS){
            if(!(v[7]&8u) || v[18]>=5 || v[21]!=(ai?294912u:0u))return fail(EPROTO);
            *frame_id=v[17];return 0;
        }
        if(pause_status())return -1;
    }while(now_ms()<until);
    return fail(ETIMEDOUT);
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
        if(v[1]==4){fprintf(stderr,"[present] error=%u hw_error=%u\n",v[2],v[8]);return fail(EIO);}
        if(v[5]==frame_id && v[1]==2 && (v[3]&33u)==33u){
            if(run_id && v[4]!=run_id)return fail(EPROTO);
            printf("[present] frame=%u run=%u boxes=%u; receiving PCIe image\n",frame_id,v[4],v[7]);
            return 0;
        }
        if(pause_status())return -1;
    }while(now_ms()<until);
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
            if(!(v[3]&33u))return 0; /* allow lock-release CDC to settle */
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
        if(drain_pending(ctx,dma_pending))return -1;
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
    const char *model=0,*save=0;uint32_t frames=0,frame_id=0,run_id=0,completed=0;
    int ai=0,explicit_mode=-1,resume=0,headless=0,rc=1,spi_open=0,pcie_open=0,dma_allocated=0,dma_pending=0;
    pcie_ctx_t ctx={0};ctx.dma_drv_fd=ctx.cma_buf_fd=ctx.cma_heap_fd=-1;
    memset(&screen,0,sizeof(screen));have_screen=0;g_running=1;
    if(argc<2)goto usage;
    for(int i=2;i<argc;i++){
        if(!strcmp(argv[i],"--model") && i+1<argc){model=argv[++i];ai=1;}
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
    if((resume&&!model) || (model&&!ai))goto usage;
    if(headless&&!save){fprintf(stderr,"--headless requires --save PREFIX for captured images.\n");goto usage;}
    signal(SIGINT,stop);signal(SIGTERM,stop);
    rk_control_set_idle_hook(window_poll);
    if(rk_control_open(argv[1]))goto error;
    spi_open=1;
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
    if(select_output(&ctx,&dma_pending,ai) || wait_video(&frame_id,0,ai))goto error;
    if(model){
        if(rk_control_upload(model,resume))goto error;
        // Upload can take time. Infer a fresh frame, not the boot self-test image.
        if(wait_video(&frame_id,1,ai))goto error;
    }
    printf("[video-app] %s; SPI controls/results, PCIe RGB565 %ux%u, desktop SDL2 display\n",ai?"FPGA inference":"preview",WIDTH,HEIGHT);
    while(g_running && (!frames || completed<frames)){
        if(completed && wait_video(&frame_id,1,ai))goto error;
        run_id=0;
        if(ai && infer(frame_id,&run_id))goto error;
        if(prepare_present(frame_id,run_id))goto error;
        dma_pending=1;
        if(transfer_frame(&ctx))goto error;
        if(finish_present(frame_id))goto error;
        dma_pending=0;
        const uint8_t *pixels=ctx.staging_buf?ctx.staging_buf:ctx.dma_buf;
        if(have_screen){display_show_frame(&screen,pixels,WIDTH,HEIGHT,WIDTH);if(display_poll_quit(&screen))g_running=0;}
        if(save){
            char filename[4096];
            if(snprintf(filename,sizeof(filename),"%s-%010u.ppm",save,frame_id)>=(int)sizeof(filename)){errno=ENAMETOOLONG;goto error;}
            if(save_ppm(filename,pixels,WIDTH,HEIGHT,WIDTH))goto error;
        }
        completed++;printf("[frame] displayed=%u frame_id=%u run_id=%u bytes=%u\n",completed,frame_id,run_id,FRAME_BYTES);
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
    if(have_screen)display_cleanup(&screen);
    if(dma_allocated){if(ctx.use_cma)free_dma_buffer_cma(&ctx);else free_dma_buffer(&ctx);}
    if(pcie_open)pcie_bar1_cleanup(&ctx);
    if(spi_open)rk_control_close();
    return rc;
usage:
    fprintf(stderr,"Usage: %s SPI_DEVICE [--output raw|ai] [--model FILE|--use-loaded-model] [--preview] [--resume] [--frames N] [--wait-ms N] [--save PREFIX] [--headless]\n",argv[0]);
    return 2;
}
