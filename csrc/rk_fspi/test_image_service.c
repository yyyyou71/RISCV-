/* Execute the real firmware command service with a host MMIO/DDR substitute. */
#define _GNU_SOURCE
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#define main firmware_main
#define memset spi_image_memset
#include "../../firmware/spi_image.c"
#undef memset
#undef main
static uint32_t image_memory[IMAGE_WIDTH*IMAGE_HEIGHT];
static unsigned writes,reads,runs,presents;
void rk_comm_init(void){}
void rk_comm_poll(void){}
size_t rk_comm_send(const uint8_t *p,size_t n){(void)p;return n;}
void ai_network_init(void){}
int ai_network_busy(void){return 0;}
void ai_network_clear_result(void){}
void ai_network_poll(void){}
void video_present_init(void){}
int video_present_busy(void){return 0;}
void video_present_poll(int allow){assert(!allow);}
uint16_t ai_network_command(uint16_t op,const uint8_t *p,uint16_t n,uint8_t *out,uint16_t capacity,uint16_t *size,
    const struct pp_frame *f,int ready,int busy,int first){
    (void)p;(void)n;(void)out;(void)capacity;*size=0;
    assert(op==COMM_NETWORK_RUN&&ready&&!busy&&!first&&f->frame_id==17&&f->bytes==294912);runs++;return COMM_OK;
}
uint16_t video_present_command(int submit,uint8_t *out,const struct pp_frame *f,int ready,int busy){
    (void)out;assert(submit&&ready&&!busy&&f->frame_id==17&&f->raw_slot==0);presents++;return COMM_OK;
}
uint32_t ai_ddr_write(uint32_t address,const uint32_t *words,uint32_t bytes){
    assert(address>=INPUT_BASE&&address+bytes<=INPUT_BASE+sizeof(image_memory)&&bytes==256);
    for(unsigned i=0;i<64;i++)image_memory[(address-INPUT_BASE)/4+i]=words[i];
    writes++;return 0;
}
uint32_t ai_ddr_read(uint32_t address,uint32_t *words,uint32_t bytes){
    assert(address>=INPUT_BASE&&address+bytes<=INPUT_BASE+sizeof(image_memory)&&bytes==256);
    for(unsigned i=0;i<64;i++)words[i]=image_memory[(address-INPUT_BASE)/4+i];
    reads++;return 0;
}
static uint16_t send(unsigned op,const uint8_t *p,unsigned n){uint8_t out[240];uint16_t size;return rk_comm_application_command(op,p,n,out,sizeof(out),&size);}
static void upload(uint32_t checksum){
    uint8_t p[204];
    comm_put32(p,9);comm_put32(p+4,17);comm_put32(p+8,384);comm_put32(p+12,216);
    comm_put32(p+16,1);comm_put32(p+20,IMAGE_BYTES);comm_put32(p+24,checksum);comm_put32(p+28,0);
    assert(send(COMM_IMAGE_BEGIN,p,32)==COMM_OK);
    assert(send(COMM_IMAGE_BEGIN,p,32)==COMM_BUSY);
    for(unsigned offset=0;offset<IMAGE_BYTES;offset+=192){
        comm_put32(p,9);comm_put32(p+4,17);comm_put32(p+8,offset+1);
        for(unsigned i=0;i<192;i++)p[12+i]=(uint8_t)((offset+i)*29u);
        assert(send(COMM_IMAGE_DATA,p,204)==COMM_BAD_ARGUMENT);
        comm_put32(p+8,offset);assert(send(COMM_IMAGE_DATA,p,204)==COMM_OK);
    }
    for(unsigned i=0;i<IMAGE_WIDTH*IMAGE_HEIGHT;i++){
        uint32_t expected=(uint8_t)(i*3*29u)|((uint32_t)(uint8_t)((i*3+1)*29u)<<8)|((uint32_t)(uint8_t)((i*3+2)*29u)<<16);
        assert(image_memory[i]==expected);
    }
}
int main(void){
    assert(mmap((void *)0x30000,0x2000,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED,-1,0)==(void *)0x30000);
    WINDOW=16;PP_REG(4)=16;PP_REG(0x38)=0x53494d31;mode=0;clear_input();
    uint32_t checksum=2166136261u;
    for(unsigned i=0;i<IMAGE_BYTES;i++)checksum=(checksum^(uint8_t)(i*29u))*16777619u;
    upload(checksum^1u);
    uint8_t p[32]={0};comm_put32(p,9);comm_put32(p+4,17);comm_put32(p+8,IMAGE_BYTES);comm_put32(p+12,checksum^1u);
    assert(send(COMM_IMAGE_COMMIT,p,16)==COMM_BAD_PACKET&&state==IMAGE_ERROR&&PP_REG(0)==0);
    assert(send(COMM_VIDEO_RELEASE,0,0)==COMM_OK&&state==IMAGE_EMPTY);
    comm_put32(p,VIDEO_OUTPUT_AI);assert(send(COMM_VIDEO_MODE,p,4)==COMM_OK);
    upload(checksum);comm_put32(p,9);comm_put32(p+4,17);comm_put32(p+8,IMAGE_BYTES);comm_put32(p+12,checksum);
    assert(send(COMM_IMAGE_COMMIT,p,16)==COMM_OK&&state==IMAGE_PROCESSING&&PP_REG(0)==1);
    assert(send(COMM_IMAGE_ABORT,p,8)==COMM_BUSY);
    PP_REG(4)=26;PP_REG(0x1c)=294912;PP_REG(0x28)=165888;poll_image();
    assert(state==IMAGE_READY&&frame.frame_id==17&&frame.bytes==294912&&writes==2592&&reads==2592);
    assert(send(COMM_NETWORK_RUN,0,0)==COMM_OK&&runs==1);
    assert(send(COMM_PRESENT_RUN,0,0)==COMM_OK&&presents==1);
    assert(send(COMM_VIDEO_RELEASE,0,0)==COMM_OK&&state==IMAGE_RELEASING);
    PP_REG(4)=18;poll_image();assert(state==IMAGE_EMPTY);
    puts("PASS real image firmware: sequential upload, DDR RGBX packing/readback, checksum rejection, COMMIT, same-frame AI/presentation, release");
    return 0;
}
