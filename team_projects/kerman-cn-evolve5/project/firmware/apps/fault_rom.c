#include "soc.h"
int main(void) {
    // Must produce a precise store access fault; the following GPIO write must not run.
    MMIO32(0x00000000u)=0xdeadbeefu;
    GPIO_OUT=0xff;
    return 1;
}
