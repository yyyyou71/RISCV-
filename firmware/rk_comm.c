#include "rk_comm.h"
#include "rk_link.h"
#include "../csrc/rk_fspi/fspi_v2.h"
#include "../csrc/rk_fspi/comm_protocol.h"
#define GPIO RK_REG(0x30108u)
#define CYCLES RK_REG(0x3000cu)
#define LOG_SIZE 512u
static uint8_t rx[COMM_MAX],tx[COMM_MAX],log_data[LOG_SIZE],ack[8];
static uint32_t parameters[COMM_PARAMS],received,transmitted,dropped;
static unsigned log_rd,log_count,consume_after_tx,expected,tx_length;
static unsigned state,ack_pos,ack_count;
static uint8_t transport_fault;
__attribute__((weak)) uint16_t rk_comm_application_command(uint16_t operation,
 const uint8_t *request,uint16_t length,uint8_t *response,uint16_t capacity,uint16_t *response_length){
 (void)operation;(void)request;(void)length;(void)response;(void)capacity;
 *response_length=0;return COMM_BAD_OPCODE;
}
uint32_t rk_comm_parameter(unsigned index){return index<COMM_PARAMS?parameters[index]:0;}
size_t rk_comm_send(const uint8_t *data,size_t n){
 size_t i=0;if(!data)return 0;
 while(i<n && log_count<LOG_SIZE){log_data[(log_rd+log_count)&(LOG_SIZE-1)]=data[i++];log_count++;}
 dropped+=(uint32_t)(n-i);return i;
}
static void reply(uint8_t token,uint8_t code,uint32_t value){
 ack[0]=COMM_ACK_MAGIC;ack[1]=token;ack[2]=code;ack[3]=1;
 comm_put32(ack+4,value);ack_pos=0;ack_count=8;
}
void rk_comm_init(void){
 unsigned i;static const uint8_t boot[]="RV32 communication ready\n";
 for(i=0;i<COMM_PARAMS;i++)parameters[i]=0;
 received=transmitted=dropped=0;log_rd=log_count=consume_after_tx=0;
 state=COMM_IDLE;ack_pos=ack_count=expected=tx_length=0;
 transport_fault=!fspi_v2_present();GPIO=0;
 rk_comm_send(boot,sizeof(boot)-1);
}
static void process_packet(void){
 unsigned n=0,i;uint16_t status=COMM_OK,op=comm_u16(rx+8),len=comm_u16(rx+10);
 uint32_t key,value;consume_after_tx=0;
 if(!comm_valid(rx,expected))status=COMM_BAD_PACKET;
 else switch(op){
 case COMM_SET_PARAM:
  if(len!=8 || (key=comm_u32(rx+16))>=COMM_PARAMS){status=COMM_BAD_ARGUMENT;break;}
  value=comm_u32(rx+20);parameters[key]=value;if(key==0)GPIO=value&3u;
  comm_put32(tx+16,value);n=4;break;
 case COMM_GET_PARAM:
  if(len!=4 || (key=comm_u32(rx+16))>=COMM_PARAMS){status=COMM_BAD_ARGUMENT;break;}
  comm_put32(tx+16,parameters[key]);n=4;break;
 case COMM_READ_LOG:
  if(len!=4 || (value=comm_u32(rx+16))>COMM_MAX-COMM_HEADER){status=COMM_BAD_ARGUMENT;break;}
  n=log_count;if(n>value)n=value;
  for(i=0;i<n;i++)tx[COMM_HEADER+i]=log_data[(log_rd+i)&(LOG_SIZE-1)];
  consume_after_tx=n;break;
 case COMM_GET_STATUS:
  if(len){status=COMM_BAD_ARGUMENT;break;}
  comm_put32(tx+16,COMM_ABI);comm_put32(tx+20,received);
  comm_put32(tx+24,transmitted);comm_put32(tx+28,log_count);
  comm_put32(tx+32,dropped);comm_put32(tx+36,CYCLES);n=24;break;
 default:{
  uint16_t size=0;
  status=rk_comm_application_command(op,rx+COMM_HEADER,len,tx+COMM_HEADER,COMM_MAX-COMM_HEADER,&size);
  if(size>COMM_MAX-COMM_HEADER){status=COMM_IO_ERROR;size=0;}
  n=size;break;
 }
 }
 comm_seal(tx,comm_u32(rx+4),status,(uint16_t)n);tx_length=n+COMM_HEADER;
}
void rk_comm_poll(void){
 uint32_t command,seq,owner,flags;unsigned op,token,arg;
 if(ack_count && rk_try_send(ack[ack_pos])){ack_pos++;ack_count--;}
 if(!transport_fault){
  flags=FSPI_V2_REG(8);owner=FSPI_V2_REG(0x18);
  if(state==COMM_RX && !(flags&1u) && (owner&1u)){
   if(fspi_v2_receive(rx,expected)){transport_fault=1;}
   else{
    received++;
    /* A short/extra frame is never accepted as a valid application command. */
    if(flags&6u){consume_after_tx=0;comm_seal(tx,comm_u32(rx+4),COMM_BAD_PACKET,0);tx_length=COMM_HEADER;}
    else process_packet();
    if(fspi_v2_publish(tx,tx_length))transport_fault=1;
    else state=COMM_TX;
   }
  }else if(state==COMM_TX && !(flags&1u) && !(owner&2u)){
   log_rd=(log_rd+consume_after_tx)&(LOG_SIZE-1);log_count-=consume_after_tx;
   consume_after_tx=0;transmitted++;state=COMM_IDLE;
  }
 }
 if(!ack_count && rk_get_parameter(&command,&seq)){
  op=command>>24;token=(command>>16)&255u;arg=command&65535u;
  rk_ack_parameter(seq);
  if(op==COMM_INFO)reply((uint8_t)token,COMM_OK,COMM_ABI);
  else if(op==COMM_POLL)reply((uint8_t)token,COMM_OK,
      (transport_fault?COMM_FAULT:state)|((uint32_t)tx_length<<16));
  else if(op==COMM_ARM){
   if(transport_fault)reply((uint8_t)token,COMM_IO_ERROR,0);
   else if(state!=COMM_IDLE)reply((uint8_t)token,COMM_BUSY,state);
   else if(arg<COMM_HEADER || arg>COMM_MAX)reply((uint8_t)token,COMM_BAD_ARGUMENT,arg);
   else{
    FSPI_V2_REG(12)=14;
    if(fspi_v2_arm_rx(arg))reply((uint8_t)token,COMM_IO_ERROR,0);
    else{expected=arg;tx_length=0;state=COMM_RX;reply((uint8_t)token,COMM_OK,arg);}
   }
  }else reply((uint8_t)token,COMM_BAD_OPCODE,op);
 }
}
