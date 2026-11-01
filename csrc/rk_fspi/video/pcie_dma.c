/*
 * RK3568 PCIe DMA 接收程序 - Step 1
 * BAR1 操作、缓冲区管理、MWr 触发
 */

#include "pcie_dma.h"
#include <time.h>

volatile int g_running = 1;

//++ [改动] 针对非缓存/WC 源内存的快速拷贝
// dma_buf 是 pgprot_writecombine 映射(非缓存)，普通 memcpy 读它 ~94MB/s。
// A55 是顺序执行核，用 4 路 128-bit 载入增加在途内存请求(MLP)，压住非缓存读延迟。
#if defined(__aarch64__)
#include <arm_neon.h>
static inline void wc_memcpy(void *dst, const void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    size_t blocks = n >> 6;                 // 每次 64 字节
    for (size_t i = 0; i < blocks; i++) {
        uint8x16_t a = vld1q_u8(s + 0);
        uint8x16_t b = vld1q_u8(s + 16);
        uint8x16_t c = vld1q_u8(s + 32);
        uint8x16_t e = vld1q_u8(s + 48);
        vst1q_u8(d + 0,  a);
        vst1q_u8(d + 16, b);
        vst1q_u8(d + 32, c);
        vst1q_u8(d + 48, e);
        s += 64; d += 64;
    }
    size_t rem = n & 63;
    if (rem) memcpy(d, s, rem);
}
#else
#define wc_memcpy memcpy
#endif
//-- [改动] 结束

//++ [改动] Cache 维护函数 —— ARMv8 (CMA cached DMA 路径专用)
// DC CVAC  = Clean to PoC (推送脏cache到DRAM, 不清除cache)
// DC CIVAC = Clean+Invalidate to PoC (推送到DRAM并失效cache行)
// DC IVAC  = Invalidate to PoC (仅失效, 丢弃脏数据)
//
// DMA 前: clean  —— 把 CPU 写入的哨兵/元数据推到 DRAM, FPGA DMA 可见
// DMA 后: invalidate —— 让 CPU 读到 FPGA 新写入的数据 (cache 旧行 stale)
// 轮询中: invalidate —— 每次轮询前失效哨兵位置的 cache 行, 迫使 CPU 读 DRAM
//         注: 此处用 civac 而非 ivac, 因为 civac 会把脏数据先 clean 再 invalidate,
//             即使误写也能保证不丢数据, 外设 DMA 场景是安全的。
//
// 仅在 CMA cached 路径使用；WC 路径不需要（WC 内存不缓存）。
#if defined(__aarch64__)
static inline void cache_clean_line(const volatile void *va)
{
    __asm__ volatile("dc cvac, %0" :: "r"(va) : "memory");
    __asm__ volatile("dsb sy" ::: "memory");
}
static inline void cache_invalidate_line(const volatile void *va)
{
    __asm__ volatile("dc civac, %0" :: "r"(va) : "memory");
    __asm__ volatile("dsb sy" ::: "memory");
}

void dma_cache_invalidate(void *va, size_t size_bytes)
{
    uintptr_t start = (uintptr_t)va & ~0x3FULL;
    uintptr_t end   = (uintptr_t)va + size_bytes;
    for (uintptr_t addr = start; addr < end; addr += 64)
        __asm__ volatile("dc civac, %0" :: "r"(addr) : "memory");
    __asm__ volatile("dsb sy" ::: "memory");
    __asm__ volatile("isb" ::: "memory");
}
#else
static inline void cache_clean_line(const volatile void *va){(void)va;}
static inline void cache_invalidate_line(const volatile void *va){(void)va;}
void dma_cache_invalidate(void *va, size_t size_bytes)
{
    (void)va; (void)size_bytes;
}
#endif
//-- [改动] 结束

// 采集耗时细分诊断：每次 transfer_frame 更新为本帧的两段耗时(毫秒)
double g_dma_wait_ms = 0.0;   // 触发 + 轮询等待 FPGA 写完
double g_dma_copy_ms = 0.0;   // 从非缓存 DMA 内存 memcpy 到 staging
static double pd_now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

// ==================== 虚拟地址转物理地址（pagemap） ====================
// ==================== 读取 sysfs 属性文件 ====================
static int read_sysfs_str(const char *path, char *buf, size_t len)
{
    FILE *fp = fopen(path, "r");
    if (!fp) return -1;
    if (fgets(buf, len, fp) == NULL) { fclose(fp); return -1; }
    fclose(fp);
    return 0;
}

// ==================== 启用 PCIe 设备 ====================
static void enable_pcie_device(const char *bdf)
{
    char path[512];
    char buf[64];

    // 启用设备 (Memory Space Enable)
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/enable", bdf);
    if (read_sysfs_str(path, buf, sizeof(buf)) == 0) {
        if (buf[0] == '0') {
            FILE *fp = fopen(path, "w");
            if (fp) {
                fprintf(fp, "1\n");
                fclose(fp);
                printf("[INFO] Enabled PCIe device %s\n", bdf);
            }
        }
    }

    // Preserve other COMMAND bits; no external setpci process or function reset.
    snprintf(path,sizeof(path),"/sys/bus/pci/devices/%s/config",bdf);
    int fd=open(path,O_RDWR);uint16_t command=0;
    if(fd>=0){
        if(pread(fd,&command,sizeof(command),4)==sizeof(command)){
            command|=6u;
            if(pwrite(fd,&command,sizeof(command),4)!=sizeof(command))
                perror("[PCIe] enable memory/bus master");
        }
        close(fd);
    }
}

// ==================== BAR1 地址自动发现 ====================
// 匹配 Pango FPGA: Vendor=0x0755, Device=0x0755
#define FPGA_VENDOR_ID  "0x0755"
#define FPGA_DEVICE_ID  "0x0755"

uint64_t find_bar1_addr(void)
{
    fprintf(stderr, "[TRACE] find_bar1_addr enter\n"); fflush(stderr);
    const char *sysfs_path = "/sys/bus/pci/devices";
    DIR *dir = opendir(sysfs_path);
    if (!dir) {
        perror("[ERROR] opendir sysfs pci devices");
        return 0;
    }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.')
            continue;

        char path[512];
        char buf[64];

        // 检查 Vendor ID
        snprintf(path, sizeof(path), "%s/%s/vendor", sysfs_path, entry->d_name);
        if (read_sysfs_str(path, buf, sizeof(buf)) < 0) continue;
        buf[strcspn(buf, "\n")] = '\0';
        if (strcmp(buf, FPGA_VENDOR_ID) != 0) continue;

        // 检查 Device ID
        snprintf(path, sizeof(path), "%s/%s/device", sysfs_path, entry->d_name);
        if (read_sysfs_str(path, buf, sizeof(buf)) < 0) continue;
        buf[strcspn(buf, "\n")] = '\0';
        if (strcmp(buf, FPGA_DEVICE_ID) != 0) continue;

        printf("[INFO] Found FPGA device: %s (Vendor=%s Device=%s)\n",
               entry->d_name, FPGA_VENDOR_ID, FPGA_DEVICE_ID);

        // 自动启用设备（Memory Space + Bus Master）
        enable_pcie_device(entry->d_name);

        // 读取 resource 文件解析 BAR1
        snprintf(path, sizeof(path), "%s/%s/resource", sysfs_path, entry->d_name);
        FILE *fp = fopen(path, "r");
        if (!fp) continue;

        // resource 文件每行: start end flags
        // BAR0 = 第1行(line 0), BAR1 = 第2行(line 1)
        int line_num = 0;
        while (fgets(buf, sizeof(buf), fp) && line_num < 6) {
            uint64_t start = 0, end = 0, flags = 0;
            if (sscanf(buf, "0x%lx 0x%lx 0x%lx", &start, &end, &flags) == 3) {
                uint64_t size = (start != 0) ? (end - start + 1) : 0;
                printf("[INFO] BAR%d: 0x%08lx - 0x%08lx [size=%lu]\n",
                       line_num, start, end, size);
            }
            if (line_num == 1 && start != 0) {
                char cfg_path[512];uint32_t bar=0;uint16_t command=0;
                snprintf(cfg_path,sizeof(cfg_path),"%s/%s/config",sysfs_path,entry->d_name);
                int cfg=open(cfg_path,O_RDONLY);
                int valid=cfg>=0 && pread(cfg,&bar,4,0x14)==4 &&
                    pread(cfg,&command,2,4)==2 && (command&6u)==6u &&
                    (bar&~15u)==(uint32_t)start;
                if(cfg>=0)close(cfg);
                if(!valid){
                    fprintf(stderr,"[PCIe] Config BAR1 is unset/mismatched or COMMAND is disabled. "
                        "Re-enumerate the programmed FPGA on RK before running.\n");
                    fclose(fp);closedir(dir);errno=EPROTO;return 0;
                }

                printf("[INFO] Using BAR1: 0x%08lx\n", start);
                fclose(fp);
                closedir(dir);
                return start;
            }
            line_num++;
        }
        fclose(fp);
        fprintf(stderr, "[WARN] FPGA found but BAR1 is not valid\n");
    }
    closedir(dir);

    fprintf(stderr, "[WARN] No FPGA device (Vendor=%s) found via sysfs\n", FPGA_VENDOR_ID);
    errno=ENODEV;return 0;
}

//++ [改动] PCIe设备完全重置：解决DMA卡死后必须重新上电的问题
// 方法1: sysfs reset (FLR/PM Reset/SBR，内核自动选择最佳方式)
//   - FLR: 重置PCIe Function，链路不断
//   - PM Reset: D3hot→D0，链路短暂中断
//   - SBR: 次级总线复位，链路完全重训练，触发FPGA core_rst_n
// 方法2: remove+rescan (更激进，强制设备重新枚举)
// 两种方法后都重新启用Bus Master
/* PCIe function reset intentionally omitted: it can reset the running FPGA. */
int pcie_bar1_init(pcie_ctx_t *ctx, uint64_t bar1_phys)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("[ERROR] open /dev/mem");
        fprintf(stderr, "[HINT] Try: sudo chmod 666 /dev/mem\n");
        return -1;
    }

    ctx->bar1_phys = bar1_phys;
    ctx->bar1_size = BAR1_MMAP_SIZE;
    ctx->bar1_base = mmap(NULL, ctx->bar1_size,
                          PROT_READ | PROT_WRITE,
                          MAP_SHARED, fd, bar1_phys);
    close(fd);

    if (ctx->bar1_base == MAP_FAILED) {
        perror("[ERROR] mmap BAR1");
        ctx->bar1_base = NULL;
        return -1;
    }

    printf("[INFO] BAR1 mapped: phys=0x%016lx virt=%p size=0x%x\n",
           bar1_phys, ctx->bar1_base, ctx->bar1_size);
    return 0;
}

// ==================== BAR1 清理 ====================
void pcie_bar1_cleanup(pcie_ctx_t *ctx)
{
    if (ctx->bar1_base && ctx->bar1_base != MAP_FAILED) {
        munmap((void *)ctx->bar1_base, ctx->bar1_size);
        ctx->bar1_base = NULL;
    }
}

// ==================== BAR1 寄存器读写 ====================
uint32_t read_bar1_reg(pcie_ctx_t *ctx, uint32_t offset)
{
    if (!ctx->bar1_base) return 0;
    return *((volatile uint32_t *)((uint8_t *)ctx->bar1_base + offset));
}

void write_bar1_reg(pcie_ctx_t *ctx, uint32_t offset, uint32_t value)
{
    if (!ctx->bar1_base) return;
    __sync_synchronize();
    *((volatile uint32_t *)((uint8_t *)ctx->bar1_base + offset)) = value;
    __sync_synchronize();
}

//++ [改动] 使用 pcie_dma_memcpy 驱动分配非缓存 DMA 缓冲区（验证缓存假说）
// 原始代码: alloc_dma_buffer 使用 MAP_ANONYMOUS + pagemap 方式（可缓存内存）
// 改动原因: 内核驱动用 dma_alloc_coherent + pgprot_writecombine，绕过 CPU 缓存
int alloc_dma_buffer(pcie_ctx_t *ctx, uint32_t size_bytes)
{
    uint32_t page_size = sysconf(_SC_PAGESIZE);
    size_bytes = (size_bytes + page_size - 1) & ~(page_size - 1);

    int dma_fd = open(DMA_DRV_PATH, O_RDWR);
    if (dma_fd < 0) {
        perror("[ERROR] open " DMA_DRV_PATH);
        fprintf(stderr, "[HINT] 驱动未加载或设备节点不存在\n");
        return -1;
    }

    dma_drv_setup_t cfg = {
        .src_phys_addr = 0x01000000,
        .dst_phys_addr = 0,
        .direction     = 0,
        .chunk_size    = size_bytes,
        .total_size    = size_bytes
    };

    fprintf(stderr, "[TRACE] alloc_dma_buffer: calling ioctl SETUP\n"); fflush(stderr);
    long ret = ioctl(dma_fd, DMA_DRV_CMD_SETUP, &cfg);
    fprintf(stderr, "[TRACE] alloc_dma_buffer: ioctl SETUP returned %ld\n", ret); fflush(stderr);
    if (ret <= 0) {
        fprintf(stderr, "[ERROR] DMA_CMD_SETUP failed (ret=%ld)\n", ret);
        close(dma_fd);
        return -1;
    }
    uint64_t phys_addr = (uint64_t)(uint32_t)ret;

    void *buf = mmap(NULL, size_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, dma_fd, 0);
    if (buf == MAP_FAILED) {
        perror("[ERROR] mmap DMA coherent buffer");
        ioctl(dma_fd, DMA_DRV_CMD_SHUTDOWN, 0);
        close(dma_fd);
        return -1;
    }

    ctx->dma_buf      = buf;
    ctx->dma_buf_phys = phys_addr;
    ctx->dma_buf_size = size_bytes;
    ctx->dma_drv_fd   = dma_fd;

    //++ [改动M] 分配缓存镜像缓冲区（普通malloc = cached内存）
    ctx->staging_buf = (uint8_t *)malloc(size_bytes);
    if (!ctx->staging_buf) {
        fprintf(stderr, "[ERROR] staging buffer malloc failed\n");
        munmap(buf, size_bytes);
        ioctl(dma_fd, DMA_DRV_CMD_SHUTDOWN, 0);
        close(dma_fd);
        return -1;
    }
    //-- [改动M] 结束

    printf("[INFO] DMA buffer (coherent/WC): virt=%p phys=0x%016llx size=%u bytes\n",
           ctx->dma_buf, (unsigned long long)ctx->dma_buf_phys, size_bytes);
    return 0;
}
//-- [改动] 结束

//++ [改动] 配合驱动分配方式的释放逻辑
// 原始代码: free_dma_buffer 仅 munmap（MAP_ANONYMOUS 方式）
void free_dma_buffer(pcie_ctx_t *ctx)
{
    if (ctx->dma_buf) {
        munmap(ctx->dma_buf, ctx->dma_buf_size);
        ctx->dma_buf = NULL;
    }
    if (ctx->dma_drv_fd >= 0) {
        ioctl(ctx->dma_drv_fd, DMA_DRV_CMD_SHUTDOWN, 0);
        close(ctx->dma_drv_fd);
        ctx->dma_drv_fd = -1;
    }
    //++ [改动M] 释放缓存镜像
    free(ctx->staging_buf);
    ctx->staging_buf = NULL;
    //-- [改动M] 结束
    ctx->dma_buf_phys = 0;
    ctx->dma_buf_size = 0;
}
//-- [改动] 结束

//++ [改动] CMA cached DMA 缓冲区分配 —— /dev/dma_heap/reserved
// 替代 pcie_dma_memcpy 驱动。CMA 物理连续、cached、pagemap 可查物理地址。
// 收益: WC 读 153MB/s → cached 读 2205MB/s (14.5x)
int alloc_dma_buffer_cma(pcie_ctx_t *ctx, uint32_t size_bytes)
{
    uint32_t page_size = sysconf(_SC_PAGESIZE);
    size_bytes = (size_bytes + page_size - 1) & ~(page_size - 1);

    int heap_fd = open(CMA_HEAP_PATH, O_RDWR);
    if (heap_fd < 0) {
        perror("[ERROR] open " CMA_HEAP_PATH);
        fprintf(stderr, "[HINT] 内核需启用 CMA + dma-heap\n");
        return -1;
    }

    struct dma_heap_allocation_data alloc;
    memset(&alloc, 0, sizeof(alloc));
    alloc.len = size_bytes;
    alloc.fd_flags = O_RDWR;

    if (ioctl(heap_fd, DMA_HEAP_IOC_ALLOC, &alloc) < 0) {
        perror("[ERROR] DMA_HEAP_IOCTL_ALLOC");
        close(heap_fd);
        return -1;
    }

    void *buf = mmap(NULL, size_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, alloc.fd, 0);
    if (buf == MAP_FAILED) {
        perror("[ERROR] mmap CMA dma_heap");
        close(alloc.fd);
        close(heap_fd);
        return -1;
    }

    // 触发缺页分配，使 pagemap present=1
    memset(buf, 0xAA, size_bytes);

    // pagemap 获取物理地址（CMA 物理连续，首页即可代表全块）
    uint64_t vaddr = (uint64_t)buf;
    uint64_t pfn_entry = 0;
    FILE *fp = fopen("/proc/self/pagemap", "rb");
    if (fp) {
        uint64_t offset = (vaddr / page_size) * 8;
        if (fseek(fp, (long)offset, SEEK_SET) == 0)
            if(fread(&pfn_entry, 8, 1, fp)!=1)pfn_entry=0;
        fclose(fp);
    }

    if (!(pfn_entry & (1ULL << 63)) || !(pfn_entry & ((1ULL<<55)-1))) {
        fprintf(stderr, "[ERROR] CMA page not present in pagemap after memset\n");
        munmap(buf, size_bytes);
        close(alloc.fd);
        close(heap_fd);
        return -1;
    }

    uint64_t pfn = pfn_entry & ((1ULL << 55) - 1);
    uint64_t phys = pfn * page_size + (vaddr % page_size);

    ctx->dma_buf      = (uint8_t *)buf;
    ctx->dma_buf_phys = phys;
    ctx->dma_buf_size = size_bytes;
    ctx->cma_buf_fd   = alloc.fd;
    ctx->cma_heap_fd  = heap_fd;
    ctx->use_cma      = 1;

    // CMA 路径下 staging_buf 不独立分配，直接指向 dma_buf（无拷贝）
    ctx->staging_buf = ctx->dma_buf;

    printf("[INFO] CMA DMA buffer (cached): virt=%p phys=0x%016llx size=%u bytes\n",
           ctx->dma_buf, (unsigned long long)ctx->dma_buf_phys, size_bytes);
    return 0;
}

void free_dma_buffer_cma(pcie_ctx_t *ctx)
{
    if (ctx->dma_buf) {
        munmap(ctx->dma_buf, ctx->dma_buf_size);
        ctx->dma_buf = NULL;
        ctx->staging_buf = NULL;
    }
    if (ctx->cma_buf_fd >= 0) {
        close(ctx->cma_buf_fd);
        ctx->cma_buf_fd = -1;
    }
    if (ctx->cma_heap_fd >= 0) {
        close(ctx->cma_heap_fd);
        ctx->cma_heap_fd = -1;
    }
    ctx->dma_buf_phys = 0;
    ctx->dma_buf_size = 0;
    ctx->use_cma = 0;
}

// 从 BAR1 读取 FPGA 写入的车牌粗坐标 [x,y,w,h]（4×uint16）
void read_plate_coords(pcie_ctx_t *ctx, uint16_t *x, uint16_t *y,
                        uint16_t *w, uint16_t *h)
{
    if (!ctx->bar1_base) {
        *x = 0; *y = 0; *w = 0; *h = 0;
        return;
    }
    uint32_t c0 = read_bar1_reg(ctx, BAR1_REG_PLATE_COORD0);
    uint32_t c1 = read_bar1_reg(ctx, BAR1_REG_PLATE_COORD1);
    *x = (uint16_t)((c0 >> 16) & 0xFFFF);
    *y = (uint16_t)(c0 & 0xFFFF);
    *w = (uint16_t)((c1 >> 16) & 0xFFFF);
    *h = (uint16_t)(c1 & 0xFFFF);
}

int fpga_parse_metadata(const uint16_t *row0, uint32_t stride_px,
                        fpga_metadata_t *out)
{
    memset(out, 0, sizeof(*out));
    if (!row0) return -1;
    if (row0[0] != FPGA_METADATA_MAGIC) return -1;

    int n = (int)row0[1];
    if (n > FPGA_METADATA_MAX_BOXES) n = FPGA_METADATA_MAX_BOXES;
    if (n < 0) n = 0;
    out->count = n;

    for (int i = 0; i < n; i++) {
        int base = 2 + i * 6;
        if (base + 5 >= (int)stride_px) break;
        out->boxes[i].id   = ((uint32_t)row0[base] << 16) | row0[base + 1];
        out->boxes[i].xmin = row0[base + 2];
        out->boxes[i].xmax = row0[base + 3];
        out->boxes[i].ymin = row0[base + 4];
        out->boxes[i].ymax = row0[base + 5];
    }
    return 0;
}
//-- [改动] 结束

// ==================== 触发 FPGA MWr ====================
int trigger_mwr(pcie_ctx_t *ctx)
{
    if (!ctx->bar1_base || !ctx->dma_buf_phys || ctx->transfer_dw == 0) {
        fprintf(stderr, "[ERROR] trigger_mwr: not initialized\n");
        return -1;
    }

    uint32_t addr_lo = (uint32_t)(ctx->dma_buf_phys & 0xFFFFFFFF);
    uint32_t addr_hi = (uint32_t)(ctx->dma_buf_phys >> 32);
    int use_64bit = (addr_hi != 0);

    // 构造命令字
    // 原始代码: uint32_t cmd = ((ctx->transfer_dw - 1) & 0x3FF) | DMA_CMD_WR_BIT;
    //++ [改动] 使用20位长度字段
    uint32_t cmd = ((ctx->transfer_dw - 1) & DMA_CMD_LEN_MASK)
                 | DMA_CMD_WR_BIT;
    //-- [改动] 结束
    if (use_64bit)
        cmd |= DMA_CMD_ADDR64_BIT;

    printf("[INFO] Triggering MWr: addr=0x%08x_%08x len=%u DW cmd=0x%08x\n",
           addr_hi, addr_lo, ctx->transfer_dw, cmd);

    //++ [改动] 发命令前软复位DMA（需FPGA侧启用o_dma_soft_rst才生效）
    if (!ctx->skip_dma_reset) {
        write_bar1_reg(ctx, BAR1_REG_DMA_SOFT_RST, 1);
        usleep(10);
    }
    //-- [改动] 结束

    // 清空接收缓冲区，方便对比
    memset(ctx->dma_buf, 0xAA, ctx->transfer_dw * 4);

    // 写入顺序：先低地址，再高地址（如果64位），最后命令
    write_bar1_reg(ctx, BAR1_REG_DMA_ADDR_LO, addr_lo);
    if (use_64bit)
        write_bar1_reg(ctx, BAR1_REG_DMA_ADDR_HI, addr_hi);
    write_bar1_reg(ctx, BAR1_REG_DMA_CMD, cmd);

    // 诊断：尝试读BAR1（注意：FPGA BAR1无读回路径，读到的值不可靠）
    uint32_t rb_cmd    = read_bar1_reg(ctx, BAR1_REG_DMA_CMD);
    uint32_t rb_addr_l = read_bar1_reg(ctx, BAR1_REG_DMA_ADDR_LO);
    printf("[DIAG] BAR1 readback (仅参考，BAR1无读回路径): CMD=0x%08x ADDR_LO=0x%08x\n",
           rb_cmd, rb_addr_l);
    printf("[DIAG] Wrote: CMD=0x%08x ADDR_LO=0x%08x\n", cmd, addr_lo);

    // 原始代码: usleep(10000);
    //++ [改动] 轮询等待 DMA 完成（FIFO 模式下延迟不可预测）
    {
        volatile uint32_t *poll_ptr =
            (volatile uint32_t *)ctx->dma_buf + ctx->transfer_dw - 1;
        int timeout_ms = 500;
        while (*poll_ptr == 0xAAAAAAAA && timeout_ms > 0 && g_running) {
            usleep(1000);
            timeout_ms--;
        }
        if (timeout_ms == 0)
            printf("[WARN] trigger_mwr timeout (500ms)\n");
    }
    //-- [改动] 结束

    //++ [改动M] 拷贝到缓存镜像
    if (ctx->staging_buf)
        memcpy(ctx->staging_buf, ctx->dma_buf, ctx->transfer_dw * 4);
    //-- [改动M] 结束

    return 0;
}

//++ [改动] 帧级别分块传输（大命令版）
// 原始代码: 每次最多32 DW，逐块发命令 + usleep(100)，28800条命令/帧
// 改动原因: FPGA控制器已扩展到20位长度字段，内部自动按MPS拆分TLP
//           单条命令最大1M DW = 4MB，720p仅需1条命令，1080p仅需2条
int transfer_frame(pcie_ctx_t *ctx)
{
    if(!ctx || !ctx->bar1_base || !ctx->dma_buf || !ctx->dma_buf_phys ||
       !ctx->transfer_dw || ctx->transfer_dw>ctx->dma_buf_size/4){errno=EINVAL;return -1;}

    if (!ctx->bar1_base || !ctx->dma_buf_phys || ctx->transfer_dw == 0) {
        fprintf(stderr, "[ERROR] transfer_frame: not initialized\n");
        return -1;
    }

    uint32_t total_dw = ctx->transfer_dw;
    uint32_t max_chunk = MAX_CHUNK_DW;
    uint32_t offset_dw = 0;
    int chunk_num = 0;
    int total_chunks = (total_dw + max_chunk - 1) / max_chunk;

    //++ [改动] 发命令前软复位DMA（需FPGA侧启用o_dma_soft_rst才生效）
    if (!ctx->skip_dma_reset) {
        write_bar1_reg(ctx, BAR1_REG_DMA_SOFT_RST, 1);
        usleep(10);
    }
    //-- [改动] 结束

    // 原始代码: memset(ctx->dma_buf, 0xAA, total_dw * 4);
    //++ [改动M] 哨兵标记移入循环，避免4MB非缓存memset（~200ms→<1μs）

    // CMA cached 路径: DMA 前把整个 dma_buf clean 到 DRAM
    //   后续 write_bar1_reg 用于发送哨兵值, FPGA DMA 会直接覆盖
    //   必须先 clean, 否则哨兵在 cache 中 FPGA 看不到, 轮询永远超时
    if (ctx->use_cma)
        dma_cache_invalidate(ctx->dma_buf, total_dw * 4);

    int frame_bad = 0;
    double _t_wait0 = pd_now_ms();
    while (offset_dw < total_dw && g_running) {
        uint32_t this_chunk = total_dw - offset_dw;
        if (this_chunk > max_chunk)
            this_chunk = max_chunk;

        // [改动M] 只标记chunk末尾DWORD为哨兵（替代全缓冲区memset）
        {
            volatile uint32_t *sentinel =
                (volatile uint32_t *)ctx->dma_buf + offset_dw + this_chunk - 1;
            *sentinel = 0xDEADBEEF;
            // CMA: 哨兵值在 cache 中, FPGA 看不到 → clean 到 DRAM
            if (ctx->use_cma)
                cache_clean_line(sentinel);
        }

        uint64_t target_phys = ctx->dma_buf_phys + (uint64_t)offset_dw * 4;
        uint32_t addr_lo = (uint32_t)(target_phys & 0xFFFFFFFF);
        uint32_t addr_hi = (uint32_t)(target_phys >> 32);
        int use_64bit = (addr_hi != 0);

        uint32_t cmd = ((this_chunk - 1) & DMA_CMD_LEN_MASK) | DMA_CMD_WR_BIT;
        if (use_64bit)
            cmd |= DMA_CMD_ADDR64_BIT;

        write_bar1_reg(ctx, BAR1_REG_DMA_ADDR_LO, addr_lo);
        if (use_64bit)
            write_bar1_reg(ctx, BAR1_REG_DMA_ADDR_HI, addr_hi);
        write_bar1_reg(ctx, BAR1_REG_DMA_CMD, cmd);

        // [改动M] 100μs轮询（原1ms），总超时500ms
        // CMA: 每次轮询前 invalidate 哨兵位置, 迫使 CPU 读 DRAM 而非 cache
        {
            volatile uint32_t *poll_ptr =
                (volatile uint32_t *)ctx->dma_buf + offset_dw + this_chunk - 1;
            int timeout_us = 500000;
            while (timeout_us > 0 && g_running) {
                if (ctx->use_cma)
                    cache_invalidate_line(poll_ptr);
                if (*poll_ptr != 0xDEADBEEF)
                    break;
                usleep(100);
                timeout_us -= 100;
            }
            if (timeout_us <= 0) {
                printf("[WARN] Chunk %d/%d timeout\n",
                       chunk_num + 1, total_chunks);
                frame_bad = 1;
            }
        }

        chunk_num++;
        offset_dw += this_chunk;
    }
    g_dma_wait_ms = pd_now_ms() - _t_wait0;

    if (offset_dw!=total_dw)frame_bad=1;
    if (!frame_bad) {
        double _t_copy0 = pd_now_ms();
        if (ctx->use_cma) {
            // CMA: DMA 完成后 invalidate, 然后 fast memcpy → staging (pool[idx])
            dma_cache_invalidate(ctx->dma_buf, total_dw * 4);
            if (ctx->staging_buf && ctx->staging_buf != ctx->dma_buf)
                memcpy(ctx->staging_buf, ctx->dma_buf, total_dw * 4);
            g_dma_copy_ms = pd_now_ms() - _t_copy0;
        } else {
            // [改动M] WC 路径: 用 wc_memcpy(NEON) 把 WC 内存拷到 staging
            if (ctx->staging_buf)
                wc_memcpy(ctx->staging_buf, ctx->dma_buf, total_dw * 4);
            g_dma_copy_ms = pd_now_ms() - _t_copy0;
        }
        return 0;
    }
    //-- [改动M] 结束

    errno=g_running?ETIMEDOUT:EINTR;
    return -1;
}
//-- [改动] 结束

// ==================== 数据 hex dump ====================
void dump_buffer(pcie_ctx_t *ctx, int max_dwords)
{
    //++ [改动M] 读取缓存镜像
    if (!ctx->staging_buf) return;

    uint32_t *data = (uint32_t *)ctx->staging_buf;
    //-- [改动M] 结束
    int count = ctx->transfer_dw;
    if (max_dwords > 0 && count > max_dwords)
        count = max_dwords;

    printf("\n[DATA] Buffer dump (%d DWORDs):\n", count);
    for (int i = 0; i < count; i++) {
        if (i % 4 == 0)
            printf("  [%04x] ", i * 4);
        printf("%08x ", data[i]);
        if (i % 4 == 3 || i == count - 1)
            printf("\n");
    }
    printf("\n");
}

// ==================== 验证测试数据模式 ====================
int verify_test_pattern(pcie_ctx_t *ctx)
{
    //++ [改动M] 读取缓存镜像
    if (!ctx->staging_buf) return -1;

    uint32_t *data = (uint32_t *)ctx->staging_buf;
    //-- [改动M] 结束
    int total = ctx->transfer_dw;
    int match_00ff = 0, match_ff00 = 0, all_zero = 0, all_aa = 0, other = 0;

    // FPGA test_green_data = 128'h00FF0000_00FF0000_00FF0000_00FF0000
    // endian_convert 对每个32位做字节翻转:
    //   00 FF 00 00 -> 00 00 FF 00 (0x0000FF00)
    for (int i = 0; i < total; i++) {
        if (data[i] == 0x0000FF00)
            match_ff00++;
        else if (data[i] == 0x00FF0000)
            match_00ff++;
        else if (data[i] == 0x00000000)
            all_zero++;
        else if (data[i] == 0xAAAAAAAA)
            all_aa++;
        else
            other++;
    }

    printf("[VERIFY] Results (%d DWORDs total):\n", total);
    if (match_ff00 > 0)
        printf("  0x0000FF00 (endian-converted green): %d\n", match_ff00);
    if (match_00ff > 0)
        printf("  0x00FF0000 (raw green, no endian):   %d\n", match_00ff);
    if (all_zero > 0)
        printf("  0x00000000 (zero):                   %d\n", all_zero);
    if (all_aa > 0)
        printf("  0xAAAAAAAA (untouched fill):          %d\n", all_aa);
    if (other > 0)
        printf("  other values:                        %d\n", other);

    if (match_ff00 == total) {
        printf("[OK] All data matches endian-converted test pattern!\n");
        return 0;
    } else if (match_00ff == total) {
        printf("[OK] All data matches raw test pattern (no endian convert)\n");
        return 0;
    } else if (all_aa == total) {
        printf("[FAIL] Buffer untouched - MWr not received\n");
        printf("[HINT] Check: FPGA test_tx_valid=1? BAR1 byte_en fixed? BAR1 address correct?\n");
        return -1;
    } else if (all_zero == total) {
        printf("[FAIL] Buffer all zeros - MWr may not have triggered\n");
        return -1;
    } else {
        printf("[WARN] Mixed data - partial transfer or address issue\n");
        return -1;
    }
}

// ==================== 帧头空白数据剥离 ====================
// FPGA FIFO在帧起始时可能为空，Change C的零填充机制会在TLP数据中
// 插入零值。这些零集中在帧头，导致画面左上角出现黑线/黑块。
// 剥离后数据前移，末尾用零填充（显示时被裁剪或位于不可见区域）。
int strip_leading_zeros(pcie_ctx_t *ctx)
{
    //++ [改动M] 操作缓存镜像（原始: ctx->dma_buf）
    if (!ctx->staging_buf || ctx->transfer_dw == 0) return 0;

    uint32_t *data = (uint32_t *)ctx->staging_buf;
    //-- [改动M] 结束
    uint32_t total = ctx->transfer_dw;
    uint32_t zeros = 0;

    while (zeros < total && data[zeros] == 0x00000000)
        zeros++;

    if (zeros == 0 || zeros == total)
        return 0;

    printf("[STRIP] Removed %u leading zero DWORDs (%u bytes, %u pixels)\n",
           zeros, zeros * 4, zeros * 2);

    memmove(data, data + zeros, (total - zeros) * 4);
    memset(data + total - zeros, 0, zeros * 4);

    return (int)zeros;
}

// ==================== 保存原始数据到文件 ====================
void save_raw_data(pcie_ctx_t *ctx, const char *filename)
{
    //++ [改动M] 保存缓存镜像数据（strip后的结果）
    if (!ctx->staging_buf) return;
    //-- [改动M] 结束

    FILE *fp = fopen(filename, "wb");
    if (!fp) {
        perror("[ERROR] fopen output");
        return;
    }

    fwrite(ctx->staging_buf, 1, ctx->transfer_dw * 4, fp);
    fclose(fp);
    printf("[INFO] Saved %u bytes to %s\n", ctx->transfer_dw * 4, filename);
}
