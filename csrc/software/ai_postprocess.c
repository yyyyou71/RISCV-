#include "ai_postprocess.h"

typedef struct { uint32_t score,index; } candidate;
typedef struct {
    ai_post_config config;
    ai_post_head heads[AI_POST_MAX_HEADS];
    uint32_t lut[64],io[64];
    candidate anchors[AI_POST_MAX_DETECTIONS],classes[AI_POST_MAX_DETECTIONS];
} post_workspace;

static uint32_t read_ddr(ai_post_result *r,uint32_t address,uint32_t *data,uint32_t bytes)
{
    r->read_calls++;r->read_bytes+=bytes;
    return ai_ddr_read(address,data,bytes);
}
static int region(uint32_t address,uint64_t bytes,uint32_t begin,uint32_t end)
{
    return !(address&15) && bytes && !(bytes&15) && address>=begin && (uint64_t)address+bytes<=end;
}
static int overlap(uint32_t a,uint32_t na,uint32_t b,uint32_t nb)
{
    return (uint64_t)a+na>b && (uint64_t)b+nb>a;
}
static int64_t rhu(int64_t value,uint32_t shift)
{
    return shift ? (value+((int64_t)1<<(shift-1)))>>shift:value;
}
static int32_t channel(const uint32_t *data,uint32_t c)
{
    uint32_t v=(data[c>>1]>>((c&1)*16))&65535;
    return (int32_t)(v^32768)-32768;
}
static uint32_t score(const post_workspace *w,const ai_post_head *h,int32_t raw)
{
    int64_t x=rhu((int64_t)raw*h->logit_multiplier,h->logit_shift)+32768;
    if(x<0)x=0;
    if(x>65535)x=65535;
    uint32_t index=(uint32_t)x>>11,frac=(uint32_t)x&2047;
    return w->lut[index]+((frac*w->lut[32+index])>>11);
}

/* 最差项在堆顶：低分更差，同分时较大的原始索引更差。
 * 第一次索引为全局anchor；第二次为(第一次排序名次*类别数+类别)。 */
static int better(candidate a,candidate b)
{
    return a.score>b.score || (a.score==b.score && a.index<b.index);
}
static void down(candidate *heap,uint32_t count,uint32_t at)
{
    candidate value=heap[at];
    while(at*2+1<count) {
        uint32_t child=at*2+1;
        if(child+1<count && better(heap[child],heap[child+1]))child++;
        if(!better(value,heap[child]))break;
        heap[at]=heap[child];at=child;
    }
    heap[at]=value;
}
static void keep(candidate *heap,uint32_t *count,uint32_t limit,candidate value)
{
    if(*count<limit) {
        uint32_t at=(*count)++;
        while(at && better(heap[(at-1)/2],value)) {
            heap[at]=heap[(at-1)/2];at=(at-1)/2;
        }
        heap[at]=value;
    } else if(better(value,heap[0])) {
        heap[0]=value;down(heap,*count,0);
    }
}
static void sorted(candidate *heap,uint32_t count)
{
    while(count>1) {
        candidate temp=heap[0];heap[0]=heap[count-1];heap[count-1]=temp;
        down(heap,--count,0);
    }
}
static const ai_post_head *locate(const post_workspace *w,uint32_t *anchor)
{
    for(uint32_t i=0;i<w->config.head_count;i++) {
        const ai_post_head *h=&w->heads[i];uint32_t n=h->height*h->width;
        if(*anchor<n)return h;
        *anchor-=n;
    }
    return 0; /* 描述符已验证，内部生成的anchor必能定位。 */
}

static uint32_t validate(uint32_t address,uint32_t model_address,post_workspace *w,ai_post_result *r)
{
    ai_post_config *c=&w->config;ai_model_header m;
    if(!region(address,64,AI_POST_CONFIG_ADDR,AI_POST_OUTPUT_MIN) ||
       overlap(address,64,AI_POST_REPORT_ADDR,32))return AI_BAD_RANGE;
    uint32_t code=read_ddr(r,address,(uint32_t *)c,64);if(code)return code;
    if(c->magic!=AI_POST_MAGIC || c->version!=1 || c->header_bytes!=64 || c->head_bytes!=64 ||
       c->flags || c->reserved || !c->head_count || c->head_count>AI_POST_MAX_HEADS ||
       !c->max_detections || c->max_detections>AI_POST_MAX_DETECTIONS || c->threshold_q16>65535 ||
       !c->input_h || !c->input_w || c->input_h>4096 || c->input_w>4096)return AI_BAD_HEADER;
    if(c->model_addr!=model_address || !region(model_address,64,AI_MODEL_MIN,AI_DDR_BYTES) ||
       !region(c->heads_addr,c->head_count*64,AI_POST_CONFIG_ADDR,AI_POST_OUTPUT_MIN) ||
       !region(c->lut_addr,256,AI_POST_CONFIG_ADDR,AI_POST_OUTPUT_MIN) ||
       !region(c->output_addr,c->output_bytes,AI_POST_OUTPUT_MIN,AI_MODEL_MIN) ||
       c->output_bytes<c->max_detections*32 ||
       overlap(c->heads_addr,c->head_count*64,address,64) || overlap(c->lut_addr,256,address,64) ||
       overlap(c->heads_addr,c->head_count*64,c->lut_addr,256) ||
       overlap(c->heads_addr,c->head_count*64,AI_POST_REPORT_ADDR,32) ||
       overlap(c->lut_addr,256,AI_POST_REPORT_ADDR,32))return AI_BAD_RANGE;
    code=read_ddr(r,model_address,(uint32_t *)&m,64);if(code)return code;
    if(m.magic!=AI_MODEL_MAGIC || m.version!=AI_MODEL_VERSION_W8A16 || m.flags!=AI_MODEL_FLAG_W8A16 ||
       m.header_bytes!=64 || m.task_bytes!=64 || !m.task_count || m.reserved0 || m.reserved1)return AI_BAD_HEADER;
    if((m.arena_begin|m.readonly_end|m.arena_end)&15 || m.arena_begin<AI_MODEL_MIN ||
       m.arena_begin>=m.readonly_end || m.readonly_end>=m.arena_end || m.arena_end>AI_DDR_BYTES ||
       !region(model_address,64,m.arena_begin,m.readonly_end))return AI_BAD_RANGE;
    code=read_ddr(r,c->lut_addr,w->lut,256);if(code)return code;
    for(uint32_t i=0;i<32;i++) {
        if(w->lut[i]>65535 || w->lut[32+i]>65535 || w->lut[i]+w->lut[32+i]>65535 ||
           (i<31 && w->lut[i]+w->lut[32+i]>w->lut[i+1]))return AI_BAD_TASK;
    }
    uint64_t total=0;
    /* 全部检测头先检查完，再读取像素；描述符错误不会留下部分检测输出。 */
    for(uint32_t i=0;i<c->head_count;i++) {
        ai_post_head *h=&w->heads[i];
        code=read_ddr(r,c->heads_addr+i*64,(uint32_t *)h,64);if(code)return code;
        for(uint32_t j=0;j<6;j++)if(h->reserved[j])return AI_BAD_TASK;
        if(!h->height || !h->width || !h->classes || h->classes>AI_POST_MAX_CLASSES ||
           (i && h->classes!=w->heads[0].classes) || !h->stride || h->stride>4096 ||
           (uint64_t)h->height*h->stride!=c->input_h || (uint64_t)h->width*h->stride!=c->input_w ||
           !h->logit_multiplier || h->logit_multiplier>0x7fffffff || h->logit_shift>63 ||
           !h->box_multiplier || h->box_multiplier>0x7fffffff || h->box_shift>63)return AI_BAD_TASK;
        if(rhu((int64_t)32768*h->logit_multiplier,h->logit_shift)>0x7fffffff ||
           rhu((int64_t)32768*h->box_multiplier,h->box_shift)+
           ((int64_t)(c->input_h>c->input_w ? c->input_h:c->input_w)<<16)>0x7fffffff)return AI_BAD_TASK;
        uint64_t n=(uint64_t)h->height*h->width;
        if(!region(h->box_addr,n*32,m.readonly_end,m.arena_end) ||
           !region(h->cls_addr,n*((h->classes+15)&~15u)*2,m.readonly_end,m.arena_end))return AI_BAD_RANGE;
        total+=n;
    }
    if(total>65535)return AI_SHAPE_ERROR;
    r->anchors=(uint32_t)total;return AI_OK;
}

uint32_t ai_postprocess(uint32_t address,uint32_t model_address,ai_post_result *r)
{
    post_workspace w;
    r->code=0;r->count=0;r->anchors=0;r->selected_anchors=0;
    r->read_calls=0;r->read_bytes=0;r->written=0;r->reserved=0;
    uint32_t code=validate(address,model_address,&w,r);if(code)return r->code=code;
    uint32_t na=0,nc=0,global=0,limit=w.config.max_detections;
    /* 第一遍：每次只读一个位置的分类通道，维护最多300个anchor。
     * LUT单调、各类别共用正乘数，所以先找最大原始码再查表与逐类别求最大等价。 */
    for(uint32_t i=0;i<w.config.head_count;i++) {
        const ai_post_head *h=&w.heads[i];uint32_t bytes=((h->classes+15)&~15u)*2;
        for(uint32_t a=0;a<h->height*h->width;a++,global++) {
            code=read_ddr(r,h->cls_addr+a*bytes,w.io,bytes);if(code)return r->code=code;
            int32_t maximum=channel(w.io,0);
            for(uint32_t c=1;c<h->classes;c++)if(channel(w.io,c)>maximum)maximum=channel(w.io,c);
            candidate v={score(&w,h,maximum),global};keep(w.anchors,&na,limit,v);
        }
    }
    sorted(w.anchors,na);r->selected_anchors=na;
    uint32_t classes=w.heads[0].classes;
    /* 第二遍：按稳定anchor名次展开类别，再维护有界Top-K。
     * 提前丢弃低于阈值的项，与最后在Top-K结果中筛选等价；允许一个位置多个类别。 */
    for(uint32_t rank=0;rank<na;rank++) {
        uint32_t a=w.anchors[rank].index;const ai_post_head *h=locate(&w,&a);
        uint32_t bytes=((classes+15)&~15u)*2;
        code=read_ddr(r,h->cls_addr+a*bytes,w.io,bytes);if(code)return r->code=code;
        for(uint32_t c=0;c<classes;c++) {
            candidate v={score(&w,h,channel(w.io,c)),rank*classes+c};
            if(v.score>=w.config.threshold_q16)keep(w.classes,&nc,limit,v);
        }
    }
    sorted(w.classes,nc);
    for(uint32_t i=0;i<nc;i++) {
        candidate v=w.classes[i];uint32_t anchor=w.anchors[v.index/classes].index,a=anchor;
        const ai_post_head *h=locate(&w,&a);
        code=read_ddr(r,h->box_addr+a*32,w.io,16);if(code)return r->code=code;
        int32_t x=(int32_t)((a%h->width)*h->stride*65536+h->stride*32768);
        int32_t y=(int32_t)((a/h->width)*h->stride*65536+h->stride*32768);
        ai_detection d;
        d.x1_q16=x-(int32_t)rhu((int64_t)channel(w.io,0)*h->box_multiplier,h->box_shift);
        d.y1_q16=y-(int32_t)rhu((int64_t)channel(w.io,1)*h->box_multiplier,h->box_shift);
        d.x2_q16=x+(int32_t)rhu((int64_t)channel(w.io,2)*h->box_multiplier,h->box_shift);
        d.y2_q16=y+(int32_t)rhu((int64_t)channel(w.io,3)*h->box_multiplier,h->box_shift);
        d.score_q16=v.score;d.class_id=v.index%classes;d.anchor_id=anchor;d.reserved=0;
        code=ai_ddr_write(w.config.output_addr+i*32,(const uint32_t *)&d,32);
        if(code)return r->code=code;
        r->count++;r->written++;
    }
    return AI_OK;
}
