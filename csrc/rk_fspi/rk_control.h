#ifndef RK_CONTROL_H
#define RK_CONTROL_H
#include <stdint.h>
#include "comm_protocol.h"
/* Single caller owns the SPI fd and packet sequence. No command replay. */
int rk_control_open(const char *device);
void rk_control_close(void);
void rk_control_set_idle_hook(int (*hook)(void));
void rk_control_set_quiet(int value);
int rk_control_exchange(unsigned operation,const uint8_t *request,unsigned size,
                        uint8_t *reply,unsigned capacity,unsigned *bytes);
int rk_control_status(unsigned operation,uint32_t abi,uint32_t *values,unsigned words);
int rk_control_upload(const char *path,int resume);
int rk_control_results(uint32_t frame_id,uint32_t run_id);
#endif
