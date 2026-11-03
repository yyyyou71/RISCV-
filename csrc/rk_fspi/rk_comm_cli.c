#define _POSIX_C_SOURCE 200809L
#include "rk_fspi.h"
#include "comm_protocol.h"
#include "network_status.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <sys/file.h>
static rk_fspi spi={.fd=-1};
static volatile sig_atomic_t stopped;
static int fail(int e){errno=e;return -1;}
static void stop_handler(int n){(void)n;stopped=1;}
static uint64_t milliseconds(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000u+t.tv_nsec/1000000u;}
static void pause_poll(void){struct timespec t={0,10000000};while(nanosleep(&t,&t)<0 && errno==EINTR && !stopped){}}
static int number(const char *s,uint32_t *v){
 char *end;unsigned long long x;errno=0;if(!s[0] || s[0]=='-')return -1;
 x=strtoull(s,&end,0);if(errno || *end || x>0xffffffffu)return -1;*v=(uint32_t)x;return 0;
}
static const char *video_state(uint32_t s){
 static const char *const names[]={"IDLE","WAIT_DDR","WAIT_VIDEO","CAPTURING","READ_FIRST_PIXEL","READ_LAST_PIXEL","SUCCESS_HELD","ERROR","RELEASING"};
 return s<sizeof(names)/sizeof(names[0])?names[s]:"UNKNOWN";
}
static const char *video_error(uint32_t s){
 static const char *const names[]={"none","DDR not ready/fault","reserved (legacy input precheck)","capture start rejected","capture/preprocessor fault","capture timed out","invalid frame descriptor","first tensor pixel read/format failed","last tensor pixel read/format failed","frame release failed/timed out"};
 return s<sizeof(names)/sizeof(names[0])?names[s]:"unknown stage";
}
static int print_ai(const uint8_t *p,unsigned size,int detailed){
 static const char *const names[]={"IDLE","UPLOAD","UPLOAD_WAIT","READ_INPUT","INPUT_WAIT",
  "START","RUNNING","READ_OUTPUT","OUTPUT_WAIT","PASSED_FIRST_PIXEL","FAILED"};
 uint32_t v[COMM_AI_WORDS];unsigned i;
 if(size!=COMM_AI_WORDS*4)return fail(EPROTO);
 for(i=0;i<COMM_AI_WORDS;i++)v[i]=comm_u32(p+i*4);
 if(v[0]!=COMM_AI_ABI)return fail(EPROTO);
 printf("[ai] first_layer=%s error=%u frame_id=%u checked_channels=%u hw_cycles=%u issues=%u\n",
  v[1]<sizeof(names)/sizeof(names[0])?names[v[1]]:"UNKNOWN",v[2],v[3],v[13],v[7],v[8]);
 if(detailed){
  printf("scope=first of 99 layers; compares ONLY the first output pixel (32 channels)\n");
  printf("loaded_asset_bytes=%u HW_STATUS=0x%08x HW_ERROR=%u output=%ux%ux32 bytes=%u\n",v[4],v[5],v[6],v[10],v[9],v[12]);
  printf("input_logical=0x%08x input_bytes=%u output_logical=0x%08x\n",v[18],v[19],v[11]);
  if(v[14]!=0xffffffffu)printf("mismatch: channel=%u expected=%d actual=%d\n",v[14],(int32_t)v[15],(int32_t)v[16]);
 }
 return 0;
}
static int print_present(const uint8_t *p,unsigned size){
 uint32_t v[COMM_PRESENT_WORDS];
 static const char *const names[]={"IDLE","PREPARING","WAIT_DMA","DONE","ERROR"};
 if(size!=COMM_PRESENT_WORDS*4)return fail(EPROTO);
 for(unsigned i=0;i<COMM_PRESENT_WORDS;i++)v[i]=comm_u32(p+i*4);
 if(v[0]!=COMM_PRESENT_ABI)return fail(EPROTO);
 printf("[present] state=%s error=%u hw=0x%08x PCIe_ready=%u locked=%u run=%u frame=%u slot=%u boxes=%u/16 hw_error=%u acknowledged_frame=%u words128=%u\n",
  v[1]<5?names[v[1]]:"UNKNOWN",v[2],v[3],(v[3]>>3)&1u,(v[3]>>5)&1u,v[4],v[5],v[6],v[7],v[8],v[9],v[10]);
 return 0;
}
static int print_video(const uint8_t *p,unsigned size,int detailed){
 uint32_t v[COMM_VIDEO_WORDS];unsigned i;
 if(size!=COMM_VIDEO_WORDS*4)return fail(EPROTO);
 for(i=0;i<COMM_VIDEO_WORDS;i++)v[i]=comm_u32(p+i*4);
 if(v[0]!=COMM_VIDEO_ABI)return fail(EPROTO);
 printf("[video] state=%s measured=%ux%u error_stage=%u CAPTURE_STATUS=0x%08x CAPTURE_ERROR=0x%08x",video_state(v[1]),v[5]&65535u,v[5]>>16,v[2],v[7],v[8]);
 if(v[6])printf(" last_frame_hz=%.3f",25000000.0/v[6]);
 putchar('\n');
 if(!detailed)return 0;
 printf("error: %s; retry_count=%u; cycles=%u\n",video_error(v[2]),v[22],v[3]);
 printf("last_period_ticks=%u (latched measurement; not a source-alive indicator)\n",v[6]);
 printf("DDR_READY=%u BUSY=%u DONE=%u HELD=%u ERROR=%u FAULT=%u written_bytes=%u\n",(v[7]>>4)&1u,v[7]&1u,(v[7]>>1)&1u,(v[7]>>3)&1u,(v[7]>>2)&1u,(v[7]>>5)&1u,v[9]);
 printf("frame_mailbox=0x%08x DDR_WINDOW_STATUS=0x%08x DDR_WINDOW_ERROR=0x%08x state_elapsed_ms=%.3f\n",v[10],v[11],v[12],v[4]/25000.0);
 if(v[2])printf("failure_snapshot: measured=%ux%u period_ticks=%u CAPTURE_STATUS=0x%08x CAPTURE_ERROR=0x%08x cycles=%u\n",v[13]&65535u,v[13]>>16,v[14],v[15],v[16],v[23]);
 if(v[1]==COMM_VIDEO_SUCCESS){
  printf("held_frame: id=%u raw_slot=%u raw_native_base=0x%08x tensor_logical_base=0x%08x bytes=%u\n",v[17],v[18],v[19],v[20],v[21]);
  if(v[21])printf("tensor_first_RGB=(%u,%u,%u) tensor_last_RGB=(%u,%u,%u)\n",v[24]&65535u,v[24]>>16,v[25]&65535u,v[26]&65535u,v[26]>>16,v[27]&65535u);
  else puts("RAW frame: tensor preprocessing/AI bypassed; PCIe image bytes=4147200");
 }
 return 0;
}
static int print_writer(const uint8_t *p,unsigned size){
 static const char *const states[]={"IDLE","LOAD_FIFO","WAIT_AW","PREPARE_W","WRITE_DDR"};
 uint32_t v[COMM_VIDEO_WRITER_WORDS],flags,slots;
 if(size!=sizeof(v))return fail(EPROTO);
 for(unsigned i=0;i<COMM_VIDEO_WRITER_WORDS;i++)v[i]=comm_u32(p+i*4);
 if(v[0]!=COMM_VIDEO_WRITER_ABI || v[1]!=0x56444731u)return fail(EPROTO);
 flags=v[2];slots=v[12];
 printf("[writer] pixel_SOF=%u decoded_SOF=%u completed_bursts=%u published=%u rejected=%u\n",
  v[3],v[4],v[5],v[8],v[9]);
 printf("last_frame_bursts=%u expected=%u last_invalid=%u last_dropped=%u last_source_fault=%u current_bursts=%u\n",
  v[6]&65535u,v[7],(v[6]>>16)&1u,(v[6]>>17)&1u,(v[6]>>18)&1u,(slots>>14)&65535u);
 printf("state=%s FIFO_words128=%u empty=%u source_fault=%u have_frame=%u drop=%u invalid=%u capture_ok=%u\n",
  (flags&7u)<5?states[flags&7u]:"UNKNOWN",(flags>>16)&1023u,(flags>>11)&1u,
  (flags>>12)&1u,(flags>>3)&1u,(flags>>4)&1u,(flags>>5)&1u,(flags>>6)&1u);
 printf("AWVALID=%u AWREADY=%u WREADY=%u WLAST=%u native_address=0x%08x last_burst_head=0x%08x\n",
  (flags>>7)&1u,(flags>>8)&1u,(flags>>9)&1u,(flags>>10)&1u,v[11],v[10]);
 printf("available=0x%02x protected=0x%02x write_slot=%u free_slot=%u\n",
  slots&31u,(slots>>5)&31u,(slots>>10)&7u,(slots>>13)&1u);
 puts("Counters are cumulative since FPGA reset. Compare two snapshots several seconds apart; RAW written_bytes is not a DDR write counter.");
 return 0;
}
static const char *debug_hint(uint32_t step){
 switch(step){
 case VD_WAIT_DDR:return "等待 DDR 初始化完成。";
 case VD_WAIT_SOURCE:return "等待整形模块输出帧头：检查输入时钟、VS/DE、复位及初始跳帧。";
 case VD_WAIT_FIFO:return "输入侧已有帧头，等待 FIFO 后的写控制器找到帧头。";
 case VD_WAIT_WRITE:return "写侧已找到帧头，等待 DDR 完成第一个写突发。";
 case VD_WAIT_PUBLISH:return "DDR 已有写入活动，等待完整帧通过计数检查并发布。";
 case VD_WAIT_LEASE:return "完整帧已有发布活动，等待软核取得可读帧。";
 case VD_WAIT_TENSOR:return "原图已有发布活动，等待对应张量及同帧检查完成。";
 case VD_CHECK_TENSOR:return "检查张量首尾数据格式。";
 case VD_FRAME_READY:return "原图/张量已保留，可以启动推理或 PCIe 回传。";
 case VD_MODEL_UPLOAD:return "正在接收并校验模型参数。";
 case VD_AI_RUNNING:return "正在执行 AI 任务；查看 task 当前任务号。";
 case VD_AI_POSTPROCESS:return "软核正在执行检测后处理。";
 case VD_AI_DONE:return "推理完成，等待画框和图像回传。";
 case VD_PRESENT_PREPARE:return "准备对应帧的画框和 PCIe 回传。";
 case VD_WAIT_PCIE_LINK:return "回传请求正在等待 PCIe 链路。";
 case VD_WAIT_PCIE_DMA:return "等待 PCIe 整帧发送完成；RK 需要启动 DMA 接收。";
 case VD_PCIE_DONE:return "FPGA 发送完成；RK 显示是否正确仍需检查接收端。";
 case VD_RELEASING:return "正在释放帧缓冲。";
 case VD_ERROR:return "流程失败；查看 last_stage 和错误前保留的硬件快照。";
 case VD_DIAG_UNAVAILABLE:return "尚未取得硬件诊断；检查是否烧录了包含诊断模块的新位流。";
 default:return "流程空闲。";
 }
}
static int print_debug(const uint8_t *p,unsigned size){
 uint32_t v[COMM_VIDEO_DEBUG_WORDS];uint8_t writer[COMM_VIDEO_WRITER_WORDS*4];
 if(size!=sizeof(v))return fail(EPROTO);
 for(unsigned i=0;i<COMM_VIDEO_DEBUG_WORDS;i++)v[i]=comm_u32(p+i*4);
 if(v[0]!=COMM_VIDEO_DEBUG_ABI)return fail(EPROTO);
 printf("[pipeline] step=%s output=%s video=%s error_stage=%u stage_elapsed_ms=%.3f frame=%u\n",
  video_debug_step_name(v[1]),v[5]==VIDEO_OUTPUT_AI?"AI":"RAW",video_state(v[3]),v[4],v[6]/25000.0,v[12]);
 printf("说明：%s\n",debug_hint(v[1]));
 printf("observed: DDR=%u input_SOF=%u FIFO_SOF=%u DDR_write=%u published=%u frame_held=%u tensor_ready=%u AI=%u present=%u PCIe_done=%u\n",
  v[11]&1u,(v[11]>>1)&1u,(v[11]>>2)&1u,(v[11]>>3)&1u,(v[11]>>4)&1u,
  (v[11]>>5)&1u,(v[11]>>6)&1u,(v[11]>>7)&1u,(v[11]>>8)&1u,(v[11]>>9)&1u);
 printf("sample: valid=%u pending=%u diagnostic_error=%u (1=timeout 2=signature) sequence=%u last_writer_progress_ms=%.3f\n",
  v[8]&1u,(v[8]>>1)&1u,v[51],v[10],v[50]/25000.0);
 if(v[8]&1u){
  printf("sample_age_ms=%.3f; hardware sampled approximately once per second\n",v[9]/25000.0);
  comm_put32(writer,COMM_VIDEO_WRITER_ABI);
  for(unsigned i=0;i<12;i++)comm_put32(writer+(i+1)*4,v[24+i]);
  if(print_writer(writer,sizeof(writer)))return -1;
 }
 printf("AI state=%u error=%u task=%u/%u; presentation state=%u error=%u hw=0x%08x; PP_STATUS=0x%08x PP_ERROR=0x%08x\n",
  v[13],v[14],v[15],v[16],v[17],v[18],v[19],v[20],v[21]);
 if(v[8]&8u){
  printf("last_stage=%s; snapshot retained until retry/reset\n",video_debug_step_name(v[2]));
  if(v[48]&1u){
   printf("last_sample_before_error_age_ms=%.3f (not a cycle-exact failure trace)\n",v[49]/25000.0);
   comm_put32(writer,COMM_VIDEO_WRITER_ABI);
   for(unsigned i=0;i<12;i++)comm_put32(writer+(i+1)*4,v[36+i]);
   if(print_writer(writer,sizeof(writer)))return -1;
  }else puts("No valid writer sample existed before this error.");
 }
 return 0;
}
/* Empty hardware reads return a complete FF frame; no TX ownership is used. */
static int receive(uint8_t *p){
 unsigned i;if(rk_fspi_read(&spi,p,SPI_TERM_FRAME))return -1;
 for(i=0;i<SPI_TERM_FRAME && p[i]==255;i++){}
 if(i==SPI_TERM_FRAME)return 0;
 if(!spi_term_valid(p))return fail(EBADMSG);
 return 1;
}
static int event(const uint8_t *p){
 unsigned kind=comm_u16(p+8),len=comm_u16(p+10);
 if(kind==SPI_TERM_LOG){fwrite(p+16,1,len,stdout);fflush(stdout);}
 else if(kind==SPI_TERM_VIDEO){if(print_video(p+16,len,0))return -1;}
 else if(kind==SPI_TERM_AI){if(print_ai(p+16,len,0))return -1;}
 else if(kind==SPI_TERM_NETWORK){if(network_print(p+16,len,0))return -1;}
 else if(kind==SPI_TERM_READY){
  if(len!=24 || comm_u32(p+16)!=SPI_TERM_ABI || comm_u32(p+20)!=SPI_TERM_FRAME)return fail(EPROTO);
 }else if(kind==SPI_TERM_RESPONSE){fprintf(stderr,"Previous command response sequence=%u received; no command is replayed.\n",comm_u32(p+4));}
 else return fail(EPROTO);
 fflush(stdout);return 0;
}
int main(int argc,char **argv){
 uint8_t tx[SPI_TERM_FRAME]={0},rx[SPI_TERM_FRAME];
 uint32_t a=0,b=0,sequence;uint16_t operation=0,payload=0;
 uint64_t deadline;int listen=0,once=0,rc=1,r,notice=0;
 struct sigaction action;stopped=0;
 if(argc<2)goto usage;
 if(argc==2 || (argc==3 && (!strcmp(argv[2],"listen") || !strcmp(argv[2],"logs"))))listen=1;
 else if(argc==3 && !strcmp(argv[2],"once")){listen=1;once=1;}
 else if(argc==3 && !strcmp(argv[2],"status"))operation=COMM_GET_STATUS;
 else if(argc==3 && !strcmp(argv[2],"video-status"))operation=COMM_VIDEO_STATUS;
 else if(argc==3 && !strcmp(argv[2],"video-writer"))operation=COMM_VIDEO_WRITER_STATUS;
 else if(argc==3 && !strcmp(argv[2],"video-debug"))operation=COMM_VIDEO_DEBUG;
 else if(argc==3 && !strcmp(argv[2],"video-retry"))operation=COMM_VIDEO_RETRY;
 else if(argc==3 && !strcmp(argv[2],"video-release"))operation=COMM_VIDEO_RELEASE;
 else if(argc==3 && !strcmp(argv[2],"ai-status"))operation=COMM_AI_STATUS;
 else if(argc==3 && !strcmp(argv[2],"network-status"))operation=COMM_NETWORK_STATUS;
 else if(argc==3 && !strcmp(argv[2],"present-status"))operation=COMM_PRESENT_STATUS;
 else if(argc==3 && !strcmp(argv[2],"present"))operation=COMM_PRESENT_RUN;
 else if(argc==5 && !strcmp(argv[2],"set") && !number(argv[3],&a) && a<COMM_PARAMS && !number(argv[4],&b)){
  operation=COMM_SET_PARAM;payload=8;comm_put32(tx+16,a);comm_put32(tx+20,b);
 }else if(argc==4 && !strcmp(argv[2],"get") && !number(argv[3],&a) && a<COMM_PARAMS){operation=COMM_GET_PARAM;payload=4;comm_put32(tx+16,a);}
 else goto usage;
 if(rk_fspi_open(&spi,argv[1],50000000)){perror("SPI open");goto done;}
 if(flock(spi.fd,LOCK_EX|LOCK_NB)){perror("Another client holds SPI");goto done;}
 memset(&action,0,sizeof(action));action.sa_handler=stop_handler;sigemptyset(&action.sa_mask);
 if(sigaction(SIGINT,&action,0) || sigaction(SIGTERM,&action,0)){perror("signal setup");goto done;}
 if(listen){
  fprintf(stderr,"SPI-only terminal: %s, 50 MHz mode 3; Ctrl+C to stop.\n",argv[1]);deadline=milliseconds()+5000;
  while(!stopped){
   r=receive(rx);if(r<0){if(stopped)break;goto io_error;}
   if(r){
    if(!once)deadline=milliseconds()+5000;
    notice=0;
    if(event(rx))goto io_error;
    if(once && comm_u16(rx+8)!=SPI_TERM_READY){rc=0;goto done;}
   }
   if(milliseconds()>=deadline){
    if(once){errno=ETIMEDOUT;goto io_error;}
    if(!notice && !r){fprintf(stderr,"No current data; check the root FPGA bitstream/CPU firmware if no messages appear.\n");notice=1;}
   }
   pause_poll();
  }
  rc=0;goto done;
 }
 /* READY is sent only after the CPU arms its fixed-length RX buffer. */
 deadline=milliseconds()+5000;
 for(;;){
  if(stopped)goto done;
  r=receive(rx);if(r<0)goto io_error;
  if(r){if(event(rx))goto io_error;if(comm_u16(rx+8)==SPI_TERM_READY && (comm_u32(rx+24)&4u))break;}
  if(milliseconds()>=deadline){errno=ETIMEDOUT;goto io_error;}pause_poll();
 }
 sequence=(uint32_t)(milliseconds()^((uint32_t)getpid()<<16));spi_term_seal(tx,sequence,operation,payload);
 if(rk_fspi_write(&spi,tx,SPI_TERM_FRAME))goto io_error;
 deadline=milliseconds()+5000;
 for(;;){
  if(stopped)goto done;
  r=receive(rx);if(r<0)goto io_error;
  if(r){if(comm_u16(rx+8)==SPI_TERM_RESPONSE && comm_u32(rx+4)==sequence)break;if(event(rx))goto io_error;}
  if(milliseconds()>=deadline){errno=ETIMEDOUT;goto io_error;}pause_poll();
 }
 payload=comm_u16(rx+10);
 if(payload<8 || comm_u32(rx+20)!=operation){errno=EPROTO;goto io_error;}
 a=comm_u32(rx+16);
 if(a!=COMM_OK){
  if(operation==COMM_VIDEO_WRITER_STATUS || operation==COMM_VIDEO_DEBUG)
   fprintf(stderr,"Writer diagnostic unavailable: status=%u. Requires the updated HDMI FPGA bitstream with diagnostic firmware; updating this RK client alone is insufficient.\n",a);
  else fprintf(stderr,"CPU application error=%u (4=busy; 5=hardware fault, inspect status/reset).\n",a);
  goto done;
 }
 if(operation==COMM_VIDEO_DEBUG){
  if(print_debug(rx+24,payload-8))goto io_error;
 }else if(operation==COMM_VIDEO_WRITER_STATUS){
  if(print_writer(rx+24,payload-8))goto io_error;
 }else if(operation==COMM_PRESENT_STATUS || operation==COMM_PRESENT_RUN){
  if(print_present(rx+24,payload-8))goto io_error;
  if(operation==COMM_PRESENT_RUN)puts("Queued; RK must arm the original PCIe DMA for 4147200 bytes (RGB565). Query present-status for completion.");
 }else if(operation==COMM_NETWORK_STATUS){
  if(network_print(rx+24,payload-8,1))goto io_error;
 }else if(operation==COMM_AI_STATUS){
  if(print_ai(rx+24,payload-8,1))goto io_error;
 }else if(operation>=COMM_VIDEO_STATUS && operation<=COMM_VIDEO_RELEASE){
  if(print_video(rx+24,payload-8,1))goto io_error;
  if(operation!=COMM_VIDEO_STATUS)puts("Request accepted; query video-status for completion.");
 }else if(operation==COMM_GET_STATUS){
  if(payload!=32){errno=EPROTO;goto io_error;}
  printf("SPI_ABI=%08x RX_packets=%u TX_packets=%u log_bytes=%u log_dropped=%u cycles=%u\n",comm_u32(rx+24),comm_u32(rx+28),comm_u32(rx+32),comm_u32(rx+36),comm_u32(rx+40),comm_u32(rx+44));
 }else{
  if(payload!=12){errno=EPROTO;goto io_error;}
  printf("parameter value = 0x%08x (%u)\n",comm_u32(rx+24),comm_u32(rx+24));
 }
 rc=0;goto done;
io_error:perror("SPI communication");fprintf(stderr,"No automatic command retry. Use the root video_diagnostic bitstream, not the standalone loopback bitstream.\n");
done:rk_fspi_close(&spi);return rc;
usage:fprintf(stderr,"Usage: %s SPI_DEVICE [listen|once|status|video-status|video-writer|video-debug|video-retry|video-release|ai-status|network-status|present-status|present|get INDEX|set INDEX VALUE]\nExample: %s /dev/spidev4.0\n",argv[0],argv[0]);return 2;
}
