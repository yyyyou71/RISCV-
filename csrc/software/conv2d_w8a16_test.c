#include <stdint.h>
#define R(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define DCTRL R(0x31000)
#define STATUS R(0x31004)
#define DADDR R(0x31008)
#define DLEN R(0x3100c)
#define ERROR R(0x31010)
#define DATA ((volatile uint32_t *)(uintptr_t)0x31100)
#define ACTRL R(0x30200)
#define AINPUT R(0x30208)
#define AWEIGHT R(0x3020c)
#define ABIAS R(0x30210)
#define AOUTPUT R(0x30214)
#define AHW R(0x30218)
#define ACHANNELS R(0x3021c)
#define ACONV R(0x30220)
#define AISSUES R(0x3022c)
#define AOH R(0x30230)
#define AOW R(0x30234)
#define APOST R(0x30238)
#define AQUANT R(0x3023c)
#define AGROUP R(0x30240)
#define AFORMAT R(0x30244)

static int move(uint32_t addr,uint32_t len)
{
    DADDR=addr;DLEN=len;DCTRL=1;
    for(uint32_t n=0;n<200000;n++) {
        uint32_t s=STATUS;
        if(!(s&1))return !(s&12) && (s&2) && ERROR==0;
    }
    return 0;
}
static void configure(const uint32_t *d)
{
    AINPUT=d[0];AWEIGHT=d[1];ABIAS=d[2];AOUTPUT=d[3];
    AHW=d[4];ACHANNELS=d[5];ACONV=d[6];APOST=d[7];AQUANT=d[8];AGROUP=d[9];
}
static int finish(uint32_t code)
{
    /* 完整卷积的耗时随层尺寸变化，不套用分块传输的短超时。原生DDR故障仍由硬件上报。 */
    uint32_t s;do{s=STATUS;}while(s&1);
    return !(s&8) && ERROR==code && (s&6)==(code ? 4u:2u);
}
int main(void)
{
    uint32_t desc[32],actual[64];
    uint32_t ready=0;
    for(uint32_t n=0;n<200000;n++)if(STATUS&16){ready=1;break;}
    if(!ready || AFORMAT!=16)return 10;
    /* 描述符、输入和参数由仿真中的外部加载端预装DDR，模拟后续SPI加载。 */
    if(!move(0x1000,128))return 11;
    for(uint32_t i=0;i<32;i++)desc[i]=DATA[i];
    configure(desc);APOST=1;ACTRL=1;
    if(!finish(7))return 12; /* 旧W8A8格式不能静默在W8A16硬件执行。 */
    ACTRL=4;
    for(uint32_t layer=0;layer<2;layer++) {
        const uint32_t *d=desc+layer*16;
        configure(d);ACTRL=1;
        /* CPU忙时改写邮箱应被忽略；请求跨到DDR时钟域后仍是同一份配置。 */
        APOST=0;AQUANT=0xdeadbeef;AGROUP=0xffffffff;
        if(!finish(0) || APOST!=d[7] || AQUANT!=d[8] || AGROUP!=d[9] ||
            AISSUES!=d[12] || AOH!=d[13] || AOW!=d[14])return 20+layer;
    }
    /* 两层之间不通过CPU读取/重排特征图；第二层直接使用第一层DDR地址。 */
    for(uint32_t layer=0;layer<2;layer++) {
        const uint32_t *d=desc+layer*16;
        for(uint32_t off=0;off<d[10];off+=256) {
            uint32_t len=d[10]-off;if(len>256)len=256;
            if(!move(d[3]+off,len))return 30;
            for(uint32_t i=0;i<len/4;i++)actual[i]=DATA[i];
            if(!move(d[11]+off,len))return 31;
            for(uint32_t i=0;i<len/4;i++)if(actual[i]!=DATA[i])return 32;
        }
    }
    return 1;
}
