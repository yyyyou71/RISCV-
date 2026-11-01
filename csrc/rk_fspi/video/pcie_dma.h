/*
 * RK3568 PCIe DMA 接收程序 - Step 1
 * 通过BAR1寄存器触发FPGA发送MWr TLP，host侧接收数据
 */

#ifndef PCIE_DMA_H
#define PCIE_DMA_H


#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <stdint.h>
#include <signal.h>
#include <errno.h>
#include <getopt.h>
#include <dirent.h>
#include <sys/ioctl.h>

//++ [改动] 使用 pcie_dma_memcpy 驱动分配非缓存 DMA 缓冲区（验证缓存假说）
#define DMA_DRV_PATH            "/dev/pcie_dma_memcpy"
#define DMA_DRV_CMD_SETUP       0x01000000
#define DMA_DRV_CMD_SHUTDOWN    0x04000000

typedef struct {
    uint32_t src_phys_addr;
    uint32_t dst_phys_addr;
    uint32_t direction;
    uint32_t chunk_size;
    uint32_t total_size;
} dma_drv_setup_t;
//-- [改动] 结束

//++ [改动] DMA-heap 分配器 —— 替代 pcie_dma_memcpy 驱动，用 CMA cached 内存做 DMA 目标
// /dev/dma_heap/reserved → CMA 物理连续、cached、pagemap 可查物理地址
// 收益: WC 读 153MB/s → cached 读 2205MB/s (14x)，消除 23ms 拷贝
#define CMA_HEAP_PATH           "/dev/dma_heap/reserved"
#define DMA_HEAP_IOC_MAGIC      'H'
#define DMA_HEAP_IOC_ALLOC      _IOWR(DMA_HEAP_IOC_MAGIC, 0x0, struct dma_heap_allocation_data)

struct dma_heap_allocation_data {
    unsigned long long len;
    unsigned int       fd;
    unsigned int       fd_flags;
    unsigned long long heap_flags;
};
//-- [改动] 结束

// ==================== BAR1 寄存器偏移（字节地址） ====================
// rx_top对BAR1直接使用TLP原始字节地址 mwr_addr[11:0]（不经过wr_ctrl右移）
// controller检查 i_bar1_wr_addr[8:0]，即BAR1内的字节偏移:
//   9'h100 => BAR1 + 0x100  DMA命令寄存器
//   9'h110 => BAR1 + 0x110  DMA低地址（host物理地址低32位）
//   9'h120 => BAR1 + 0x120  DMA高地址（host物理地址高32位）
// 注意：BAR1在IP核中需配置为至少512字节（建议4KB）
#define BAR1_REG_DMA_CMD        0x100
#define BAR1_REG_DMA_ADDR_LO    0x110
#define BAR1_REG_DMA_ADDR_HI    0x120
//++ [改动] 启用DMA软复位寄存器定义（需配合FPGA侧启用o_dma_soft_rst）
#define BAR1_REG_DMA_SOFT_RST   0x130
//-- [改动] 结束
//++ [改动] 车牌坐标寄存器 —— FPGA 在 DMA 前写入粗坐标 {x,y,w,h} 4×uint16
// BAR1+0x140 = [31:16]=x, [15:0]=y
// BAR1+0x144 = [31:16]=w, [15:0]=h
#define BAR1_REG_PLATE_COORD0   0x140
#define BAR1_REG_PLATE_COORD1   0x144

// DMA命令寄存器字段
// 原始代码: [9:0]=length-1, [16]=64bit, [24]=MWr
//++ [改动] 长度字段扩展到20位，64bit标志移至bit20
// [19:0] = length - 1 (单位: DWORD, max 1M DW = 4MB)
// [20]   = 0: 32位地址, 1: 64位地址
// [24]   = 0: 读(MRd), 1: 写(MWr)
#define DMA_CMD_WR_BIT          (1 << 24)
#define DMA_CMD_ADDR64_BIT      (1 << 20)
#define DMA_CMD_LEN_MASK        0xFFFFF
//-- [改动] 结束

// BAR1 mmap 大小（覆盖到 0x120 + 4，按页对齐）
#define BAR1_MMAP_SIZE          0x1000

// 传输大小
#define DEFAULT_DMA_SIZE_DW     32      // 32 DWORDs = 128 bytes
// 原始代码: #define MAX_DMA_SIZE_DW 1024  // TLP max payload
//++ [改动] FPGA控制器已支持大命令+自动TLP拆分（按MPS=128B拆分+地址自增）
// MAX_CHUNK_DW 为单条BAR1命令的最大DW数（受20位长度字段限制）
// FPGA内部自动拆分为MPS大小的TLP，host无需关心MPS
// 原始代码: #define MAX_CHUNK_DW (1024*1024)
//++ [改动] 修复20位溢出: 1048576=0x100000, FPGA做cmd[19:0]+1溢出为0
// length-1最大为0xFFFFF, 所以length最大为0xFFFFF=1048575
#define MAX_CHUNK_DW            (1024*1024 - 1) // 0xFFFFF, 避免FPGA 20位加法溢出
//-- [改动] 结束
#define MAX_DMA_SIZE_DW         (4*1024*1024) // 帧级别上限 16MB
//-- [改动] 结束

// 帧显示默认参数
#define DEFAULT_FRAME_W         1280
#define DEFAULT_FRAME_H         720

// 全局运行标志
extern volatile int g_running;

// ==================== 数据结构 ====================
typedef struct {
    volatile void   *bar1_base;     // BAR1 mmap 虚拟地址
    uint64_t         bar1_phys;     // BAR1 物理地址
    uint32_t         bar1_size;     // BAR1 mmap 大小

    uint8_t         *dma_buf;       // DMA 接收缓冲区虚拟地址
    uint64_t         dma_buf_phys;  // DMA 接收缓冲区物理地址
    uint32_t         dma_buf_size;  // 缓冲区大小（字节）

    //++ [改动] 驱动 fd 用于非缓存 buffer 分配
    int              dma_drv_fd;    // /dev/pcie_dma_memcpy fd (-1 = 未使用)
    //-- [改动] 结束

    int              skip_dma_reset; /* controlled frame may already be prefetched */
    uint32_t         transfer_dw;   // 传输大小（DWORD 数量）

    //++ [改动M] 缓存镜像缓冲区，避免非缓存DMA内存的慢速读写
    uint8_t         *staging_buf;   // cached copy，所有后处理使用此缓冲区
    //-- [改动M] 结束

    //++ [改动] CMA 分配字段 —— 使用 dma_heap/reserved 时填充
    int              cma_buf_fd;    // dma_heap 返回的 fd
    int              cma_heap_fd;   // /dev/dma_heap/reserved 的 fd
    int              use_cma;       // 1=使用 CMA cached 路径, 0=旧 WC 路径
    //-- [改动] 结束
} pcie_ctx_t;

// ==================== 函数声明 ====================

// BAR1 地址发现
uint64_t find_bar1_addr(void);

// BAR1 初始化 / 清理
int  pcie_bar1_init(pcie_ctx_t *ctx, uint64_t bar1_phys);
void pcie_bar1_cleanup(pcie_ctx_t *ctx);

// BAR1 寄存器读写
uint32_t read_bar1_reg(pcie_ctx_t *ctx, uint32_t offset);
void     write_bar1_reg(pcie_ctx_t *ctx, uint32_t offset, uint32_t value);

// DMA 缓冲区分配 / 释放（Step 1: pagemap方式 / 驱动方式）
int  alloc_dma_buffer(pcie_ctx_t *ctx, uint32_t size_bytes);
void free_dma_buffer(pcie_ctx_t *ctx);

//++ [改动] CMA cached DMA 缓冲区 —— dma_heap/reserved, 无需内核驱动
int  alloc_dma_buffer_cma(pcie_ctx_t *ctx, uint32_t size_bytes);
void free_dma_buffer_cma(pcie_ctx_t *ctx);

//++ [改动] Cache 维护 —— DMA 完成后 invalidate 确保 CPU 读到 FPGA 新写入的数据
void dma_cache_invalidate(void *va, size_t size_bytes);

//++ [改动] 读取 FPGA 通过 BAR1 写入的车牌粗坐标 (旧接口，保留兼容)
void read_plate_coords(pcie_ctx_t *ctx, uint16_t *x, uint16_t *y,
                        uint16_t *w, uint16_t *h);

//++ [改动] FPGA 帧头元数据解析 —— 第0行内嵌车牌框信息
// 格式: px[0]=magic, px[1]=N, 然后每框6像素 [id:u32, xmin, xmax, ymin, ymax]
#define FPGA_METADATA_MAGIC     0xA55A
#define FPGA_METADATA_MAX_BOXES 16

typedef struct {
    uint32_t id;
    uint16_t xmin, xmax, ymin, ymax;
} fpga_box_t;

typedef struct {
    int         count;
    fpga_box_t  boxes[FPGA_METADATA_MAX_BOXES];
} fpga_metadata_t;

// 从帧第0行解析 FPGA 打包的框元数据。row0 = 帧首行像素(uint16数组)
// 返回 0=成功, -1=magic不匹配
int fpga_parse_metadata(const uint16_t *row0, uint32_t stride_px,
                        fpga_metadata_t *out);

// 触发 FPGA MWr（单次，最大 MAX_CHUNK_DW）
int trigger_mwr(pcie_ctx_t *ctx);

//++ [改动] 帧级别分块传输
// 改动原因: 完整帧超过单次 TLP 1024 DW 限制，需分块发送
int transfer_frame(pcie_ctx_t *ctx);
//-- [改动] 结束

//++ [改动] PCIe设备完全重置，解决DMA卡死后需重新上电的问题
/* Function reset is not part of the integrated application API. */
//-- [改动] 结束

// 帧头空白数据剥离（返回剥离的DWORD数，0表示无需剥离）
int strip_leading_zeros(pcie_ctx_t *ctx);

// 数据验证
void dump_buffer(pcie_ctx_t *ctx, int max_dwords);
int  verify_test_pattern(pcie_ctx_t *ctx);
void save_raw_data(pcie_ctx_t *ctx, const char *filename);

#endif /* PCIE_DMA_H */
