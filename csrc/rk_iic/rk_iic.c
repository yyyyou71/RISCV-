#define _POSIX_C_SOURCE 200809L
#include "rk_iic.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>
#include <unistd.h>

enum { STATUS=0x02, VERSION=0x03, PARAM=0x10, COMMIT=0x14,
       SEQ=0x15, COUNT=0x20, DATA=0x21, CONSUME=0x22 };
static int fail(int e) { errno=e; return -1; }

int rk_iic_open(rk_iic *dev, const char *path, uint8_t address)
{
    unsigned long funcs;
    int fd, saved;
    if (!dev || !path || address<0x08 || address>0x77) return fail(EINVAL);
    if (dev->fd>=0) return fail(EBUSY);
    fd=open(path,O_RDWR|O_CLOEXEC);
    if (fd<0) return -1;
    if (ioctl(fd,I2C_FUNCS,&funcs)<0) goto error;
    if (!(funcs&I2C_FUNC_I2C)) { errno=EOPNOTSUPP; goto error; }
    /* Respect kernel ownership; do not use I2C_SLAVE_FORCE. */
    if (ioctl(fd,I2C_SLAVE,(unsigned long)address)<0) goto error;
    dev->fd=fd; dev->address=address;
    return 0;
error:
    saved=errno; close(fd); return fail(saved);
}

void rk_iic_close(rk_iic *dev)
{
    if (dev && dev->fd>=0) { close(dev->fd); dev->fd=-1; }
}

static int transfer(rk_iic *dev, struct i2c_msg *msgs, unsigned int count)
{
    struct i2c_rdwr_ioctl_data request;
    unsigned int i;
    int result;
    if (!dev || dev->fd<0) return fail(EBADF);
    for(i=0;i<count;++i) msgs[i].addr=dev->address;
    request.msgs=msgs; request.nmsgs=count;
    result=ioctl(dev->fd,I2C_RDWR,&request);
    if(result<0) return -1;
    return result==(int)count ? 0 : fail(EIO);
}

int rk_iic_read_reg(rk_iic *dev, uint8_t reg, uint8_t *value)
{
    uint8_t data=0;
    struct i2c_msg msgs[2]={
        {.flags=0,.len=1,.buf=&reg},
        {.flags=I2C_M_RD,.len=1,.buf=&data}
    };
    if(!value) return fail(EINVAL);
    /* One combined transaction: write index, repeated START, read byte. */
    if(transfer(dev,msgs,2)<0) return -1;
    *value=data; return 0;
}

int rk_iic_write_reg(rk_iic *dev, uint8_t reg, uint8_t value)
{
    uint8_t bytes[2]={reg,value};
    struct i2c_msg msg={.flags=0,.len=2,.buf=bytes};
    return transfer(dev,&msg,1);
}

int rk_iic_get_status(rk_iic *dev, uint8_t *version, uint8_t *status)
{
    uint8_t v,s;
    if(!version || !status) return fail(EINVAL);
    if(rk_iic_read_reg(dev,VERSION,&v)<0 || rk_iic_read_reg(dev,STATUS,&s)<0)
        return -1;
    *version=v; *status=s; return 0;
}

int rk_iic_set_parameter(rk_iic *dev, uint32_t value)
{
    uint8_t before,after,byte;
    unsigned int i;
    if(rk_iic_read_reg(dev,SEQ,&before)<0) return -1;
    for(i=0;i<4;++i)
        if(rk_iic_write_reg(dev,(uint8_t)(PARAM+i),(uint8_t)(value>>(8*i)))<0)
            return -1;
    for(i=0;i<4;++i) {
        if(rk_iic_read_reg(dev,(uint8_t)(PARAM+i),&byte)<0) return -1;
        if(byte!=(uint8_t)(value>>(8*i))) return fail(EIO);
    }
    if(rk_iic_write_reg(dev,COMMIT,1)<0) return -1;
    if(rk_iic_read_reg(dev,SEQ,&after)<0) return -1;
    return after==(uint8_t)(before+1u) ? 0 : fail(EPROTO);
}

int rk_iic_peek(rk_iic *dev, uint8_t *value)
{
    uint8_t count;
    if(!value) return fail(EINVAL);
    if(rk_iic_read_reg(dev,COUNT,&count)<0) return -1;
    if(count==0) return 0;
    if(count!=1) return fail(EPROTO);
    if(rk_iic_read_reg(dev,DATA,value)<0) return -1;
    return 1;
}

int rk_iic_consume(rk_iic *dev)
{
    return rk_iic_write_reg(dev,CONSUME,1);
}
