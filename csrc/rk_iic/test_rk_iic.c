#include "rk_iic.h"
#include <assert.h>
#include <errno.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static uint8_t regs[256];
static unsigned commits, consumes, calls, closes;
static int inject_error, corrupt_shadow;
int __wrap_open(const char *path,int flags,...)
{ (void)flags; assert(!strcmp(path,"/mock")); return 42; }
int __wrap_close(int fd) { assert(fd==42); ++closes; return 0; }
int __wrap_ioctl(int fd,unsigned long request,...)
{
    va_list args;
    struct i2c_rdwr_ioctl_data *x;
    unsigned i;
    uint8_t addr,value;
    assert(fd==42);
    va_start(args,request);
    if(request==I2C_FUNCS) {
        *va_arg(args,unsigned long *)=I2C_FUNC_I2C;
        va_end(args); return 0;
    }
    if(request==I2C_SLAVE) {
        assert(va_arg(args,unsigned long)==0x66);
        va_end(args); return 0;
    }
    assert(request==I2C_RDWR);
    x=va_arg(args,struct i2c_rdwr_ioctl_data *); va_end(args);
    ++calls;
    if(inject_error) { inject_error=0; errno=EIO; return -1; }
    for(i=0;i<x->nmsgs;++i) assert(x->msgs[i].addr==0x66);
    assert(x->msgs[0].flags==0);
    addr=x->msgs[0].buf[0];
    if(x->nmsgs==2) {
        assert(x->msgs[0].len==1 && x->msgs[1].len==1);
        assert(x->msgs[1].flags==I2C_M_RD);
        x->msgs[1].buf[0]=regs[addr];
        if(corrupt_shadow && addr==0x12) x->msgs[1].buf[0]^=1;
    } else {
        assert(x->nmsgs==1 && x->msgs[0].len==2);
        value=x->msgs[0].buf[1];
        regs[addr]=value;
        if(addr==0x14 && value==1) { ++commits; ++regs[0x15]; }
        if(addr==0x22 && value==1) { ++consumes; regs[0x20]=0; }
    }
    return (int)x->nmsgs;
}

int main(void)
{
    rk_iic dev=RK_IIC_INIT;
    uint8_t byte=0x99,version,status;
    unsigned before;
    assert(rk_iic_open(&dev,"/mock",0x66)==0);
    regs[3]=1; regs[2]=1;
    assert(rk_iic_get_status(&dev,&version,&status)==0 && version==1 && status==1);
    regs[0x15]=255;
    assert(rk_iic_set_parameter(&dev,0x12345678)==0);
    assert(regs[0x10]==0x78 && regs[0x11]==0x56 && regs[0x12]==0x34 && regs[0x13]==0x12);
    assert(commits==1 && regs[0x15]==0);
    corrupt_shadow=1;
    assert(rk_iic_set_parameter(&dev,0xabcdef01)==-1 && commits==1);
    corrupt_shadow=0;
    assert(rk_iic_peek(&dev,&byte)==0 && byte==0x99 && consumes==0);
    regs[0x20]=1; regs[0x21]=0xa5;
    assert(rk_iic_peek(&dev,&byte)==1 && byte==0xa5 && consumes==0);
    assert(rk_iic_consume(&dev)==0 && consumes==1);
    before=calls; inject_error=1;
    assert(rk_iic_consume(&dev)==-1 && calls==before+1 && consumes==1);
    assert(rk_iic_peek(&dev,NULL)==-1 && errno==EINVAL);
    rk_iic_close(&dev); rk_iic_close(&dev);
    assert(closes==1 && dev.fd==-1);
    assert(rk_iic_read_reg(&dev,0,&byte)==-1 && errno==EBADF);
    puts("PASS: combined reads, endian order, commit/wrap, verification failure, mailbox, errors without retry");
    return 0;
}
