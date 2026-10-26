#include "ai_runtime.h"
#define MMIO(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define DCTRL MMIO(0x31000)
#define STATUS MMIO(0x31004)
#define DADDR MMIO(0x31008)
#define DLEN MMIO(0x3100c)
#define ERROR MMIO(0x31010)
#define DATA ((volatile uint32_t *)(uintptr_t)0x31100)
#define ACTRL MMIO(0x30200)
#define AINPUT MMIO(0x30208)
#define AWEIGHT MMIO(0x3020c)
#define ABIAS MMIO(0x30210)
#define AOUTPUT MMIO(0x30214)
#define AHW MMIO(0x30218)
#define ACHANNELS MMIO(0x3021c)
#define ACONV MMIO(0x30220)
#define ACYCLES MMIO(0x30228)
#define AISSUES MMIO(0x3022c)
#define AOH MMIO(0x30230)
#define AOW MMIO(0x30234)
#define APOST MMIO(0x30238)
#define AQUANT MMIO(0x3023c)
#define AGROUP MMIO(0x30240)
#define AFORMAT MMIO(0x30244)
#define POLL_LIMIT 200000u

/* 64 位范围计算防止尺寸乘法回绕。end 是开区间上界。 */
static int region(uint32_t address,uint64_t bytes,uint32_t begin,uint32_t end)
{
    return !(address&15) && bytes && !(bytes&15) && address>=begin &&
           (uint64_t)address+bytes<=end;
}
static uint32_t wait_ready(void)
{
    for(uint32_t n=0;n<POLL_LIMIT;n++) {
        uint32_t s=STATUS;
        if(s&8)return AI_DDR_ERROR;
        if(s&16)return AI_OK;
    }
    return AI_POLL_TIMEOUT;
}
static uint32_t wait_done(uint32_t poll_limit)
{
    for(uint32_t n=0;!poll_limit || n<poll_limit;n++) {
        uint32_t s=STATUS;
        if(!(s&1))return (s&8) || (s&6)!=2 ? AI_DDR_ERROR:AI_OK;
    }
    return AI_POLL_TIMEOUT;
}
uint32_t ai_ddr_read(uint32_t address,uint32_t *words,uint32_t bytes)
{
    if(bytes>256 || !region(address,bytes,0,AI_DDR_BYTES))return AI_BAD_RANGE;
    uint32_t code=wait_ready();if(code)return code;
    DADDR=address;DLEN=bytes;DCTRL=1;
    code=wait_done(POLL_LIMIT);if(code)return code;
    for(uint32_t n=0;n<bytes/4;n++)words[n]=DATA[n];
    return AI_OK;
}
uint32_t ai_ddr_write(uint32_t address,const uint32_t *words,uint32_t bytes)
{
    if(bytes>256 || !region(address,bytes,0,AI_DDR_BYTES))return AI_BAD_RANGE;
    uint32_t code=wait_ready();if(code)return code;
    for(uint32_t n=0;n<bytes/4;n++)DATA[n]=words[n];
    DADDR=address;DLEN=bytes;DCTRL=3;
    return wait_done(POLL_LIMIT);
}

static uint32_t validate_task(const ai_model_header *h,const ai_task *t)
{
    if(t->opcode!=AI_OP_CONV2D)return AI_BAD_OPCODE;
    uint32_t wide=h->version==AI_MODEL_VERSION_W8A16;
    uint32_t ih=t->hw&65535,iw=t->hw>>16,ci=t->channels&65535,co=t->channels>>16;
    uint32_t k=t->conv&3,s=(t->conv>>2)&3,p=(t->conv>>4)&3;
    if(!ih || !iw || !ci || !co || (k!=1 && k!=3) || (s!=1 && s!=2) || p>1 ||
       t->conv&~127u)return AI_BAD_TASK;
    if(wide ? ((t->post!=4 && t->post!=6) || (t->group_split &&
        ((t->group_split&15) || t->group_split>=ci))) :
        (t->post&~3u || t->post==2 || t->group_split))return AI_BAD_TASK;
    for(uint32_t n=0;n<3;n++)if(t->reserved[n])return AI_BAD_TASK;
    if(ih+2*p<k || iw+2*p<k)return AI_BAD_TASK;
    uint32_t oh=((ih+2*p-k)>>(s==2))+1,ow=((iw+2*p-k)>>(s==2))+1;
    if(t->out_h!=oh || t->out_w!=ow)return AI_BAD_TASK;
    uint32_t cip=(ci+15)&~15u,cop=(co+3)&~3u;
    uint32_t quantized=wide || (t->post&1);
    uint64_t in_bytes=(uint64_t)ih*iw*cip*(wide ? 2u:1u),weights=(uint64_t)cop*k*k*cip;
    uint64_t out_bytes=(uint64_t)oh*ow*(quantized ? ((co+15)&~15u):cop)*(wide ? 2u:(quantized ? 1u:8u));
    /* 所有权重/偏置/量化表只能在只读区，所有输出只能在工作区。
       因此当前输出也不能覆盖后续任务或其它层尚未使用的模型资产。 */
    if(!region(t->input_addr,in_bytes,h->arena_begin,h->arena_end) ||
       !region(t->weight_addr,weights,h->arena_begin,h->readonly_end) ||
       !region(t->output_addr,out_bytes,h->readonly_end,h->arena_end) ||
       ((t->conv&64) && !region(t->bias_addr,(uint64_t)cop*4,h->arena_begin,h->readonly_end)) ||
       (quantized && !region(t->quant_addr,(uint64_t)cop*(wide ? 32u:16u),h->arena_begin,h->readonly_end)))return AI_BAD_RANGE;
    uint64_t in_end=(uint64_t)t->input_addr+in_bytes,out_end=(uint64_t)t->output_addr+out_bytes;
    if(t->input_addr<out_end && t->output_addr<in_end)return AI_BAD_RANGE;
    return AI_OK;
}

uint32_t ai_run_model(uint32_t header_address,ai_run_result *r)
{
    ai_model_header h;
    ai_task task;
    r->code=0;r->failed_task=0xffffffffu;r->hardware_code=0;r->completed=0;
    r->cycles=0;r->issues=0;r->out_h=0;r->out_w=0;
    if(!region(header_address,64,AI_MODEL_MIN,AI_DDR_BYTES))return r->code=AI_BAD_RANGE;
    uint32_t code=ai_ddr_read(header_address,(uint32_t *)&h,64);
    if(code){r->hardware_code=ERROR;return r->code=code;}
    uint32_t wide=h.version==AI_MODEL_VERSION_W8A16;
    if(h.magic!=AI_MODEL_MAGIC || (wide ? h.flags!=AI_MODEL_FLAG_W8A16 :
       (h.version!=AI_ABI_VERSION || h.flags)) || h.header_bytes!=64 || h.task_bytes!=64 ||
       !h.task_count || h.reserved0 || h.reserved1)return r->code=AI_BAD_HEADER;
    /* 计算位宽是综合配置；同一固件可识别两种包，拒绝在不匹配的硬件上启动。 */
    if(AFORMAT!=(wide ? 16u:8u))return r->code=AI_FORMAT_ERROR;
    if(h.arena_begin<AI_MODEL_MIN || (h.arena_begin|h.readonly_end|h.arena_end)&15 ||
       h.arena_begin>=h.readonly_end || h.readonly_end>=h.arena_end || h.arena_end>AI_DDR_BYTES ||
       !region(header_address,64,h.arena_begin,h.readonly_end) ||
       !region(h.tasks_addr,(uint64_t)h.task_count*64,h.arena_begin,h.readonly_end) ||
       !region(h.input_addr,h.input_bytes,h.arena_begin,h.readonly_end) ||
       !region(h.output_addr,h.output_bytes,h.readonly_end,h.arena_end) ||
       (header_address<(uint64_t)h.tasks_addr+(uint64_t)h.task_count*64 && h.tasks_addr<(uint64_t)header_address+64))
        return r->code=AI_BAD_RANGE;
    /* 两遍扫描：先检查全部描述符，再执行，避免格式错误到中途才被发现。
       量化记录仍由计算引擎按组验证；CPU 不复制整份参数表。 */
    for(uint32_t n=0;n<h.task_count;n++) {
        code=ai_ddr_read(h.tasks_addr+n*64,(uint32_t *)&task,64);
        if(!code)code=validate_task(&h,&task);
        if(code){r->failed_task=n;r->hardware_code=code==AI_DDR_ERROR ? ERROR:0;return r->code=code;}
    }
    for(uint32_t n=0;n<h.task_count;n++) {
        code=ai_ddr_read(h.tasks_addr+n*64,(uint32_t *)&task,64);
        if(code){r->failed_task=n;r->hardware_code=ERROR;return r->code=code;}
        /* CPU 仅配置任务，输入/权重供数和所有特征图写回均由引擎完成。 */
        AINPUT=task.input_addr;AWEIGHT=task.weight_addr;ABIAS=task.bias_addr;AOUTPUT=task.output_addr;
        AHW=task.hw;ACHANNELS=task.channels;ACONV=task.conv;APOST=task.post;AQUANT=task.quant_addr;
        AGROUP=task.group_split;
        /* 整层计算时间随模型变化，不能套用块搬运的短轮询上限。
           原生 DDR 故障仍由硬件看门狗返回；仿真另有全局超时。 */
        ACTRL=1;code=wait_done(0);
        r->cycles+=ACYCLES;r->issues+=AISSUES;
        if(code) {
            r->failed_task=n;r->hardware_code=ERROR;
            return r->code=code==AI_POLL_TIMEOUT ? code:((STATUS&8) ? AI_DDR_ERROR:AI_ENGINE_ERROR);
        }
        if(AOH!=task.out_h || AOW!=task.out_w){r->failed_task=n;return r->code=AI_SHAPE_ERROR;}
        r->completed++;r->out_h=AOH;r->out_w=AOW;
    }
    return AI_OK;
}
