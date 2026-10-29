#include "video_capture.h"
#define REG(offset) (*(volatile uint32_t *)(uintptr_t)(VIDEO_CAPTURE_MMIO+(offset)))

uint32_t video_capture_start(const video_capture_config *c)
{
    if(!c || !c->width || !c->height || c->width>4096 || c->height>4096 ||
       !c->timeout_cycles || c->vs_active_high>1 || c->stride<((c->width+3)&~3u)*4)
        return VIDEO_BAD_SHAPE;
    if((c->base|c->stride)&15)return VIDEO_BAD_ALIGNMENT;
    if((uint64_t)c->base+(uint64_t)(c->height-1)*c->stride+((c->width+3)&~3u)*4>0x20000000ull)
        return VIDEO_BAD_RANGE;
    if(REG(0x24)!=VIDEO_CAPTURE_RGBX)return VIDEO_UNAVAILABLE;
    uint32_t s=REG(4);
    if(s&1)return VIDEO_BUSY;
    if(!(s&16))return VIDEO_NOT_READY;
    REG(8)=c->base;REG(12)=c->width|(c->height<<16);REG(16)=c->stride;
    REG(20)=c->vs_active_high;REG(32)=c->timeout_cycles;
    REG(0)=1;
    return VIDEO_OK;
}

uint32_t video_capture_wait(uint32_t poll_limit,video_capture_result *r)
{
    if(!r)return VIDEO_BAD_SHAPE;
    r->written_bytes=0;r->status=0;
    for(uint32_t n=0;!poll_limit || n<poll_limit;n++) {
        uint32_t s=REG(4);r->status=s;
        if(s&1)continue;
        r->written_bytes=REG(28);
        if((s&14)==2)r->code=VIDEO_OK;
        else if(s&12)r->code=REG(24);
        else r->code=VIDEO_NO_RESULT;
        return r->code;
    }
    /* 软件轮询超时不会取消正在抓取的帧，硬件仍由timeout_cycles看守。 */
    r->code=VIDEO_POLL_TIMEOUT;
    return r->code;
}
