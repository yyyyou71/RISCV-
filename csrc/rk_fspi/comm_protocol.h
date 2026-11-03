#ifndef RK_COMM_PROTOCOL_H
#define RK_COMM_PROTOCOL_H
#include <stdint.h>
#include <stddef.h>
#define COMM_HEADER 16u
#define COMM_PARAMS 16u
#define COMM_SET_PARAM 1u
#define COMM_GET_PARAM 2u
#define COMM_READ_LOG 3u
#define COMM_GET_STATUS 4u
#define COMM_VIDEO_STATUS 5u
#define COMM_VIDEO_RETRY 6u
#define COMM_VIDEO_RELEASE 7u
#define COMM_AI_STATUS 8u
#define COMM_AI_ABI 0x00010000u
#define COMM_AI_WORDS 24u
#define COMM_MODEL_BEGIN 9u
#define COMM_MODEL_CHUNK 10u
#define COMM_MODEL_COMMIT 11u
#define COMM_NETWORK_STATUS 12u
#define COMM_NETWORK_RUN 13u
#define COMM_DETECTIONS 14u
#define COMM_MODEL_ABORT 15u
#define COMM_PRESENT_STATUS 16u
#define COMM_PRESENT_RUN 17u
#define COMM_VIDEO_MODE 18u
#define COMM_VIDEO_MODE_ABI 0x00010000u
#define COMM_VIDEO_MODE_WORDS 4u
#define COMM_IMAGE_STATUS 19u
#define COMM_IMAGE_BEGIN 20u
#define COMM_IMAGE_DATA 21u
#define COMM_IMAGE_COMMIT 22u
#define COMM_IMAGE_ABORT 23u
#define COMM_IMAGE_ABI 0x00010000u
#define COMM_IMAGE_WORDS 20u
#define IMAGE_WIDTH 384u
#define IMAGE_HEIGHT 216u
#define IMAGE_RGB888 1u
#define IMAGE_BYTES (IMAGE_WIDTH*IMAGE_HEIGHT*3u)
#define IMAGE_CHUNK_BYTES 192u
#define IMAGE_EMPTY 0u
#define IMAGE_LOADING 1u
#define IMAGE_PROCESSING 2u
#define IMAGE_READY 3u
#define IMAGE_ERROR 4u
#define IMAGE_RELEASING 5u
#define VIDEO_OUTPUT_RAW 0u
#define VIDEO_OUTPUT_AI 1u
#define COMM_PRESENT_ABI 0x00010000u
#define COMM_PRESENT_WORDS 12u
#define COMM_NETWORK_ABI 0x00010000u
#define COMM_NETWORK_WORDS 28u
#define COMM_MODEL_CHUNK_BYTES 224u
#define NW_EMPTY 0u
#define NW_LOADING 1u
#define NW_READY 2u
#define NW_QUEUED 3u
#define NW_RUNNING 4u
#define NW_POSTPROCESS 5u
#define NW_DONE 6u
#define NW_ERROR 7u
/* Optional video diagnostic application. Existing transport ABI is unchanged. */
#define COMM_VIDEO_ABI 0x00010000u
#define COMM_VIDEO_WORDS 28u
#define COMM_VIDEO_IDLE 0u
#define COMM_VIDEO_WAIT_DDR 1u
#define COMM_VIDEO_WAIT_INPUT 2u
#define COMM_VIDEO_CAPTURE 3u
#define COMM_VIDEO_READ_FIRST 4u
#define COMM_VIDEO_READ_LAST 5u
#define COMM_VIDEO_SUCCESS 6u
#define COMM_VIDEO_ERROR 7u
#define COMM_VIDEO_RELEASING 8u
/* SPI-only fixed-size transport. */
#define SPI_TERM_MAGIC 0x31545053u /* little endian SPT1 */
#define SPI_TERM_ABI 0x00010000u
#define SPI_TERM_FRAME 256u
#define SPI_TERM_PAYLOAD (SPI_TERM_FRAME-COMM_HEADER)
#define SPI_TERM_READY 0x8000u
#define SPI_TERM_LOG 0x8001u
#define SPI_TERM_VIDEO 0x8002u
#define SPI_TERM_RESPONSE 0x8003u
#define SPI_TERM_AI 0x8004u
#define SPI_TERM_NETWORK 0x8005u
#define COMM_OK 0u
#define COMM_BAD_PACKET 1u
#define COMM_BAD_ARGUMENT 2u
#define COMM_BAD_OPCODE 3u
#define COMM_BUSY 4u
#define COMM_IO_ERROR 5u
static inline uint16_t comm_u16(const uint8_t *p){return (uint16_t)(p[0]|((uint16_t)p[1]<<8));}
static inline uint32_t comm_u32(const uint8_t *p){return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);}
static inline void comm_put16(uint8_t *p,uint16_t v){p[0]=(uint8_t)v;p[1]=(uint8_t)(v>>8);}
static inline void comm_put32(uint8_t *p,uint32_t v){unsigned i;for(i=0;i<4;i++)p[i]=(uint8_t)(v>>(8*i));}
/* FNV-1a detects transmission corruption; not an authentication mechanism. */
static inline uint32_t comm_hash(const uint8_t *p,size_t n){
 uint32_t h=2166136261u;size_t i;
 for(i=0;i<n;i++)if(i<12 || i>=16)h=(h^p[i])*16777619u;
 return h;
}
static inline void spi_term_seal(uint8_t *p,uint32_t seq,uint16_t kind,uint16_t payload){
 comm_put32(p,SPI_TERM_MAGIC);comm_put32(p+4,seq);comm_put16(p+8,kind);
 comm_put16(p+10,payload);comm_put32(p+12,comm_hash(p,COMM_HEADER+payload));
}
static inline int spi_term_valid(const uint8_t *p){
 unsigned size=COMM_HEADER+comm_u16(p+10);
 return comm_u32(p)==SPI_TERM_MAGIC && size<=SPI_TERM_FRAME &&
        comm_u32(p+12)==comm_hash(p,size);
}
#endif
