/* SPI-only terminal transport. RK is the clock master and polls 256-byte
 * frames. Empty hardware reads return FF; no IIC or extra ready GPIO needed.
 */
#include "rk_comm.h"
#include "../csrc/rk_fspi/fspi_v2.h"
#include "../csrc/rk_fspi/comm_protocol.h"
#define REG(a) (*(volatile uint32_t *)(a))
#define CYCLES REG(0x3000cu)
#define LOG_SIZE 512u
static uint8_t rx[SPI_TERM_FRAME],tx[SPI_TERM_FRAME],response[SPI_TERM_FRAME],logs[LOG_SIZE];
static uint32_t parameters[COMM_PARAMS],received,transmitted,dropped,event_seq;
static uint32_t ready_tick,video_tick;
static unsigned log_rd,log_count,tx_log_count,tx_prepared,tx_inflight;
static unsigned response_pending,needs_arm,transport_fault;
static unsigned ai_due,network_due;

__attribute__((weak)) uint16_t rk_comm_application_command(uint16_t operation,
 const uint8_t *request,uint16_t length,uint8_t *out,uint16_t capacity,uint16_t *size){
 (void)operation;(void)request;(void)length;(void)out;(void)capacity;
 *size=0;return COMM_BAD_OPCODE;
}
uint32_t rk_comm_parameter(unsigned index){return index<COMM_PARAMS?parameters[index]:0;}
size_t rk_comm_send(const uint8_t *data,size_t n){
 size_t i=0;if(!data)return 0;
 while(i<n && log_count<LOG_SIZE){logs[(log_rd+log_count)&(LOG_SIZE-1)]=data[i++];log_count++;}
 dropped+=(uint32_t)(n-i);return i;
}
void rk_comm_init(void){
 static const uint8_t boot[]="RV32 SPI-only terminal ready\n";unsigned i;
 for(i=0;i<COMM_PARAMS;i++)parameters[i]=0;
 received=transmitted=dropped=event_seq=0;
 log_rd=log_count=tx_log_count=tx_prepared=tx_inflight=response_pending=0;
 needs_arm=1;transport_fault=!fspi_v2_present();
 ai_due=network_due=0;
 ready_tick=video_tick=CYCLES-25000000u;
 REG(0x30108u)=0;rk_comm_send(boot,sizeof(boot)-1);
}
static void process_packet(void){
 uint16_t status=COMM_OK,size=0,op=comm_u16(rx+8),len=comm_u16(rx+10);
 uint32_t key,value;unsigned i;
 for(i=0;i<SPI_TERM_FRAME;i++)response[i]=0;
 if(!spi_term_valid(rx))status=COMM_BAD_PACKET;
 else switch(op){
 case COMM_SET_PARAM:
  if(len!=8 || (key=comm_u32(rx+16))>=COMM_PARAMS){status=COMM_BAD_ARGUMENT;break;}
  value=comm_u32(rx+20);parameters[key]=value;if(!key)REG(0x30108u)=value&3u;
  comm_put32(response+24,value);size=4;break;
 case COMM_GET_PARAM:
  if(len!=4 || (key=comm_u32(rx+16))>=COMM_PARAMS){status=COMM_BAD_ARGUMENT;break;}
  comm_put32(response+24,parameters[key]);size=4;break;
 case COMM_GET_STATUS:
  if(len){status=COMM_BAD_ARGUMENT;break;}
  comm_put32(response+24,SPI_TERM_ABI);comm_put32(response+28,received);
  comm_put32(response+32,transmitted);comm_put32(response+36,log_count);
  comm_put32(response+40,dropped);comm_put32(response+44,CYCLES);size=24;break;
 default:
  status=rk_comm_application_command(op,rx+16,len,response+24,SPI_TERM_PAYLOAD-8,&size);
  if(size>SPI_TERM_PAYLOAD-8){status=COMM_IO_ERROR;size=0;}
  break;
 }
 comm_put32(response+16,status);comm_put32(response+20,op);
 spi_term_seal(response,comm_u32(rx+4),SPI_TERM_RESPONSE,size+8);
 response_pending=1;
}
static void prepare_tx(uint32_t owner){
 uint16_t size=0,status;unsigned i;uint32_t now=CYCLES;
 if(!response_pending && !log_count && !ai_due && !network_due &&
    !(now-ready_tick>=25000000u && (owner&4u)) && now-video_tick<25000000u)return;
 for(i=0;i<SPI_TERM_FRAME;i++)tx[i]=0;
 tx_log_count=0;
 if(response_pending){
  for(i=0;i<SPI_TERM_FRAME;i++)tx[i]=response[i];
  response_pending=0;tx_prepared=1;return;
 }
 if(now-ready_tick>=25000000u && (owner&4u)){
  comm_put32(tx+16,SPI_TERM_ABI);comm_put32(tx+20,SPI_TERM_FRAME);
  comm_put32(tx+24,owner);comm_put32(tx+28,received);
  comm_put32(tx+32,transmitted);comm_put32(tx+36,dropped);
  spi_term_seal(tx,++event_seq,SPI_TERM_READY,24);ready_tick=now;
 }else if(log_count){
  tx_log_count=log_count<SPI_TERM_PAYLOAD?log_count:SPI_TERM_PAYLOAD;
  for(i=0;i<tx_log_count;i++)tx[16+i]=logs[(log_rd+i)&(LOG_SIZE-1)];
  spi_term_seal(tx,++event_seq,SPI_TERM_LOG,(uint16_t)tx_log_count);
 }else if(ai_due){
  ai_due=0;
  status=rk_comm_application_command(COMM_AI_STATUS,tx,0,tx+16,SPI_TERM_PAYLOAD,&size);
  if(status!=COMM_OK || size>SPI_TERM_PAYLOAD)return;
  spi_term_seal(tx,++event_seq,SPI_TERM_AI,size);
  network_due=1;
 }else if(network_due){
  network_due=0;
  status=rk_comm_application_command(COMM_NETWORK_STATUS,tx,0,tx+16,SPI_TERM_PAYLOAD,&size);
  if(status!=COMM_OK || size>SPI_TERM_PAYLOAD)return;
  spi_term_seal(tx,++event_seq,SPI_TERM_NETWORK,size);
 }else if(now-video_tick>=25000000u){
  video_tick=now;
  status=rk_comm_application_command(COMM_VIDEO_STATUS,tx,0,tx+16,SPI_TERM_PAYLOAD,&size);
  if(status!=COMM_OK || size>SPI_TERM_PAYLOAD)return;
  spi_term_seal(tx,++event_seq,SPI_TERM_VIDEO,size);
  ai_due=1;
 }else return;
 tx_prepared=1;
}
void rk_comm_poll(void){
 uint32_t flags,owner;int result;
 if(transport_fault)return;
 flags=FSPI_V2_REG(8);if(flags&1u)return;
 owner=FSPI_V2_REG(0x18);
 if(tx_inflight && !(owner&2u)){
  tx_inflight=0;transmitted++;
  log_rd=(log_rd+tx_log_count)&(LOG_SIZE-1);log_count-=tx_log_count;tx_log_count=0;
 }
 /* Full fixed-length RX is retained until processed. A polling READ can
    overlap a CPU buffer access: retry that access, without executing twice. */
 if(!needs_arm && (owner&1u) && !response_pending && !tx_prepared){
  result=fspi_v2_receive(rx,SPI_TERM_FRAME);
  if(!result){received++;process_packet();needs_arm=1;}
  else if(result==-4)transport_fault=1;
 }
 if(needs_arm){
  result=fspi_v2_arm_rx(SPI_TERM_FRAME);
  if(!result)needs_arm=0;
  else if(result==-4)transport_fault=1;
 }
 /* A complete response gives the next-command RX credit to a bulk client.
    Do not publish it until the next RX buffer is actually armed. */
 if(needs_arm)return;
 flags=FSPI_V2_REG(8);if(flags&1u)return;
 owner=FSPI_V2_REG(0x18);
 if(!tx_inflight && !(owner&2u)){
  if(!tx_prepared)prepare_tx(owner);
  if(tx_prepared){
   result=fspi_v2_publish(tx,SPI_TERM_FRAME);
   if(!result){tx_prepared=0;tx_inflight=1;}
   else if(result==-4)transport_fault=1;
   /* Busy/rejection during a polling frame leaves TX uncommitted. The
      exact same software packet is retained and rewritten in the next gap. */
  }
 }
}
