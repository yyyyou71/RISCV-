#ifndef AI_FIRST_LAYER_QUANT_H
#define AI_FIRST_LAYER_QUANT_H
#include "ai_first_layer_assets.h"
/* Only for this layer's nonnegative 8-bit RGB codes. Dot products and both
 * scale products fit int64; generic network postprocessing remains separate.
 */
static inline int64_t fl_rhu(int64_t value,uint32_t shift){
    if(!shift)return value;
    if(shift>=64)return 0;
    return (value+((int64_t)1<<(shift-1)))>>shift;
}
static inline void fl_reference(const uint16_t rgb[4][3],int16_t out[32]){
    unsigned o,p,c;
    for(o=0;o<32;o++){
        int64_t sum=0,q,scaled;
        const uint32_t *quant=fl_assets+FL_QUANT_WORD+o*8;
        for(p=0;p<4;p++)for(c=0;c<3;c++){
            unsigned tap=(p/2+1)*3+p%2+1,byte=(o*9+tap)*16+c;
            int8_t weight=(int8_t)(fl_assets[byte/4]>>((byte%4)*8));
            sum+=(int32_t)rgb[p][c]*weight;
        }
        q=fl_rhu(sum*quant[0],quant[1])+(int32_t)fl_assets[FL_BIAS_WORD+o];
        if(q>2147483647LL)q=2147483647LL;
        if(q<(-2147483647LL-1))q=(-2147483647LL-1);
        if(q<0)q=0; /* This model's first layer enables ReLU. */
        scaled=fl_rhu(q*quant[4],quant[5]);
        out[o]=scaled>32767?32767:scaled< -32767?-32767:(int16_t)scaled;
    }
}
#endif
