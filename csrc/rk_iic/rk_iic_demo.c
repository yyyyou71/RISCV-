#include "rk_iic.h"
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int number(const char *text, uint32_t *value)
{
    char *end;
    unsigned long long n;
    if(!text[0] || text[0]=='-') return -1;
    errno=0; n=strtoull(text,&end,0);
    if(errno || *end || n>UINT32_MAX) return -1;
    *value=(uint32_t)n; return 0;
}

int main(int argc, char **argv)
{
    rk_iic dev=RK_IIC_INIT;
    uint8_t version,status,byte;
    uint32_t param=0;
    int result, exit_code=EXIT_FAILURE;
    if(argc<3 ||
       !((argc==3 && (!strcmp(argv[2],"status") || !strcmp(argv[2],"recv"))) ||
         (argc==4 && !strcmp(argv[2],"set") && number(argv[3],&param)==0))) {
        fprintf(stderr,"Usage: %s /dev/i2c-N status|recv|set VALUE%c",argv[0],10);
        return EXIT_FAILURE;
    }
    if(rk_iic_open(&dev,argv[1],RK_IIC_DEFAULT_ADDRESS)<0) {
        perror("open I2C"); return EXIT_FAILURE;
    }
    if(rk_iic_get_status(&dev,&version,&status)<0) goto error;
    if(version!=1) { errno=EPROTO; goto error; }
    if(!strcmp(argv[2],"status")) {
        printf("version=%u status=0x%02x uplink_available=%u%c",
               version,status,status&1u,10);
    } else if(!strcmp(argv[2],"set")) {
        if(rk_iic_set_parameter(&dev,param)<0) goto error;
        printf("Parameter committed: 0x%08" PRIx32 "%c",param,10);
    } else {
        result=rk_iic_peek(&dev,&byte);
        if(result<0) goto error;
        if(result==0) puts("Mailbox empty");
        else {
            if(printf("Received: 0x%02x%c",byte,10)<0 || fflush(stdout)==EOF)
                goto error;
            if(rk_iic_consume(&dev)<0) goto error;
        }
    }
    exit_code=EXIT_SUCCESS;
    goto done;
error:
    perror("I2C operation");
    fputs("No automatic retry: reconcile device state after commit/consume errors.",stderr);
    fputc(10,stderr);
done:
    rk_iic_close(&dev);
    return exit_code;
}
