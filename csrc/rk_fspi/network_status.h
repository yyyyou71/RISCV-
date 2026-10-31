#ifndef RK_NETWORK_STATUS_H
#define RK_NETWORK_STATUS_H
#include "comm_protocol.h"
#include <stdio.h>
#include <errno.h>
static inline int network_decode(const uint8_t *p,unsigned bytes,uint32_t v[COMM_NETWORK_WORDS]){
    if(bytes!=COMM_NETWORK_WORDS*4 || comm_u32(p)!=COMM_NETWORK_ABI){errno=EPROTO;return -1;}
    for(unsigned i=0;i<COMM_NETWORK_WORDS;i++)v[i]=comm_u32(p+i*4);
    return 0;
}
static inline int network_print(const uint8_t *p,unsigned bytes,int detailed){
    static const char *const names[]={"EMPTY","LOADING","READY","QUEUED","RUNNING","POSTPROCESS","DONE","ERROR"};
    uint32_t v[COMM_NETWORK_WORDS];
    if(network_decode(p,bytes,v))return -1;
    printf("[network] state=%s error=%u model_bytes=%u/%u tasks=%u/%u detections=%u frame_id=%u run_id=%u\n",
      v[1]<8?names[v[1]]:"UNKNOWN",v[2],v[5],v[6],v[12],v[11],v[18],v[10],v[9]);
    if(detailed){
        uint64_t elapsed=((uint64_t)v[22]<<32)|v[21];
        printf("session=%08x model_tag=%08x FNV=%08x expected_FNV=%08x flags=%08x\n",v[3],v[4],v[7],v[8],v[23]);
        printf("task_index=%u failed_task=%08x hardware_error=%u engine_cycles=%u issues=%u post_code=%u post_reads=%u elapsed_ms=%.3f\n",
          v[20],v[13],v[14],v[15],v[16],v[17],v[19],elapsed/25000.0);
        printf("input_logical=%08x raw_slot=%u source=%ux%u (boxes use 96x96 input coordinates)\n",v[24],v[25],v[27]&65535u,v[27]>>16);
    }
    return 0;
}
#endif
