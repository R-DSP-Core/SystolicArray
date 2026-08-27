// SPDX-License-Identifier: Apache-2.0

#include "runtime.h"

#define DMA_BASE       0x40000000u
#define DMA_SRC        (*(volatile uint32_t *)(DMA_BASE + 0x00u))
#define DMA_DST        (*(volatile uint32_t *)(DMA_BASE + 0x04u))
#define DMA_LEN        (*(volatile uint32_t *)(DMA_BASE + 0x08u))
#define DMA_DIR        (*(volatile uint32_t *)(DMA_BASE + 0x0cu))
#define DMA_STATUS     (*(volatile uint32_t *)(DMA_BASE + 0x10u))
#define DMA_START      (*(volatile uint32_t *)(DMA_BASE + 0x14u))

// 与rtl/dma.sv当前的status_reg编码保持一致。
#define DMA_IDLE       0u
#define DMA_BUSY       1u
#define DMA_DONE       2u
#define DMA_ERROR      4u

// 防止RTL状态机或状态寄存器出现问题时，裸机程序永久卡在轮询循环中。
#define DMA_TIMEOUT_CYCLES 2048u

#define DMA_MEM_TO_SPM 0u
#define DMA_SPM_TO_MEM 1u

#define A_SPM_BASE     0x50000000u
#define B_SPM_BASE     0x50010000u
#define C_SPM_BASE     0x50020000u

#define NPU_ARRAY_DIM  8u
// systolic_controller直接使用arg1[0:1]：
//   bit0: 0=OS, 1=WS；bit1: 0=PROPAGATE, 1=COMPUTE。
// 第一轮权重装载选择PROPAGATE缓冲，装载完成后RTL会自动切到COMPUTE。
#define NPU_MODE_WS    ((1u << 0) | (0u << 1))
#define NPU_RSP_ERROR  0x80000000u

enum {
    NPU_MATMUL_OK                = 0,
    NPU_MATMUL_BAD_ARGUMENT      = -1,
    NPU_MATMUL_DMA_A_FAILED      = -2,
    NPU_MATMUL_DMA_B_FAILED      = -3,
    NPU_MATMUL_CONFIG_FAILED      = -4,
    NPU_MATMUL_LOAD_WEIGHT_FAILED = -5,
    NPU_MATMUL_COMPUTE_FAILED     = -6,
    NPU_MATMUL_DMA_C_FAILED       = -7
};

typedef struct {
    uint64_t dma_cycles;
    uint64_t config_cycles;
    uint64_t load_weight_cycles;
    uint64_t compute_cycles;
    uint64_t output_dma_cycles;
    uint64_t total_cycles;
} npu_matmul_perf_t;

// 当前SPM有8个8-bit bank，因此一个矩阵逻辑行固定占8字节。
// 不足8列的部分必须由软件补零，确保下一矩阵行从下一个SPM row开始。
// A是3x5矩阵：
//   [1, 2, 4, 7, 9]
//   [3, 4, 6, 0, 1]
//   [8, 3, 5, 2, 9]
static const uint8_t matrix_a_spm_layout[24] __attribute__((aligned(4))) = {
    1, 2, 4, 7, 9, 0, 0, 0,
    3, 4, 6, 0, 1, 0, 0, 0,
    8, 3, 5 ,2, 9, 0, 0, 0
};

// B是5x3矩阵，每一行同样补零到8字节：
//   [5, 6, 9]
//   [7, 8, 2]
//   [1, 4, 6]
//   [8, 2, 4]
//   [7, 0, 6]
static const uint8_t matrix_b_spm_layout[40] __attribute__((aligned(4))) = {
    5, 6, 9, 0, 0, 0, 0, 0,
    7, 8, 2, 0, 0, 0, 0, 0,
    1, 4, 6, 0, 0, 0, 0, 0,
    8, 2, 4, 0, 0, 0, 0, 0,
    7, 0, 6, 0, 0, 0, 0, 0
};

// 双向DMA回读缓冲区。它们位于普通主存地址空间，由DMA的OBI master
// 写入，用于验证SPM->DMA FIFO->主存整条反向通路。
static uint8_t matrix_a_readback[24] __attribute__((aligned(4)));
static uint8_t matrix_b_readback[40] __attribute__((aligned(4)));
static const uint32_t c_spm_probe[16] __attribute__((aligned(4))) = {
    0x10203040u, 0x11223344u, 0x55667788u, 0x99aabbccu,
    0xdeadbeefu, 0x01020304u, 0x7fffffffu, 0x80000000u,
    0x13579bdfu, 0x2468ace0u, 0x00000000u, 0xffffffffu,
    0x31415926u, 0x27182818u, 0xa5a5a5a5u, 0x5a5a5a5au
};
static uint32_t c_spm_probe_readback[16] __attribute__((aligned(4)));
static int matrix_c_readback[3 * NPU_ARRAY_DIM] __attribute__((aligned(4)));
static int matrix_c_reference[3 * NPU_ARRAY_DIM] __attribute__((aligned(4)));

static int dma_wait_for_completion(void)
{
    uint64_t start_cycle = tb_read_mcycle();

    for (;;) {
        uint32_t status = DMA_STATUS;

        if (status == DMA_DONE)
            return 0;

        if (status == DMA_ERROR)
            return -1;

        if ((status != DMA_BUSY) && (status != DMA_IDLE)) {
            // 未定义的状态编码视为硬件错误。
            return -1;
        }

        if ((tb_read_mcycle() - start_cycle) > DMA_TIMEOUT_CYCLES)
            return -1;
    }
}

static int dma_copy_to_spm(const void *source, uint32_t destination,
                           uint32_t bytes)
{
    DMA_DIR   = DMA_MEM_TO_SPM;
    DMA_SRC   = (uint32_t)source;
    DMA_DST   = destination;
    DMA_LEN   = bytes;
    DMA_START = 1u;

    return dma_wait_for_completion();
}

static int dma_copy_from_spm(uint32_t source, void *destination,
                             uint32_t bytes)
{
    DMA_DIR   = DMA_SPM_TO_MEM;
    DMA_SRC   = source;
    DMA_DST   = (uint32_t)destination;
    DMA_LEN   = bytes;
    DMA_START = 1u;

    return dma_wait_for_completion();
}

static int bytes_equal(const uint8_t *lhs, const uint8_t *rhs,
                       uint32_t bytes)
{
    for (uint32_t i = 0; i < bytes; ++i) {
        if (lhs[i] != rhs[i])
            return 0;
    }
    return 1;
}

static int dma_bidirectional_self_test(void)
{
    if (dma_copy_to_spm(matrix_a_spm_layout, A_SPM_BASE,
                        sizeof(matrix_a_spm_layout)) != 0)
        return -1;
    if (dma_copy_from_spm(A_SPM_BASE, matrix_a_readback,
                          sizeof(matrix_a_readback)) != 0)
        return -2;
    if (!bytes_equal(matrix_a_spm_layout, matrix_a_readback,
                     sizeof(matrix_a_readback)))
        return -3;

    if (dma_copy_to_spm(matrix_b_spm_layout, B_SPM_BASE,
                        sizeof(matrix_b_spm_layout)) != 0)
        return -4;
    if (dma_copy_from_spm(B_SPM_BASE, matrix_b_readback,
                          sizeof(matrix_b_readback)) != 0)
        return -5;
    if (!bytes_equal(matrix_b_spm_layout, matrix_b_readback,
                     sizeof(matrix_b_readback)))
        return -6;

    if (dma_copy_to_spm(c_spm_probe, C_SPM_BASE,
                        sizeof(c_spm_probe)) != 0)
        return -7;
    if (dma_copy_from_spm(C_SPM_BASE, c_spm_probe_readback,
                          sizeof(c_spm_probe_readback)) != 0)
        return -8;
    for (uint32_t i = 0; i < 16u; ++i) {
        if (c_spm_probe[i] != c_spm_probe_readback[i]) {
            tb_puts("C_SPM probe mismatch index/write/read:");
            tb_print_dec((int)i);
            tb_putchar(' ');
            tb_print_hex(c_spm_probe[i]);
            tb_putchar(' ');
            tb_print_hex(c_spm_probe_readback[i]);
            tb_putchar('\n');
            return -9;
        }
    }

    return 0;
}

static inline uint32_t npu_config(uint32_t run_length, uint32_t mode_flags)
{
    uint32_t response;
    __asm__ volatile (
        ".insn r CUSTOM_0, 0, 0, %[rd], %[rs1], %[rs2]"
        : [rd] "=r" (response)
        : [rs1] "r" (run_length), [rs2] "r" (mode_flags)
        : "memory"
    );
    return response;
}

static inline uint32_t npu_load_weight(uint32_t b_spm_row,
                                       uint32_t row_count)
{
    uint32_t response;
    __asm__ volatile (
        ".insn r CUSTOM_0, 0, 1, %[rd], %[rs1], %[rs2]"
        : [rd] "=r" (response)
        : [rs1] "r" (b_spm_row), [rs2] "r" (row_count)
        : "memory"
    );
    return response;
}

static inline uint32_t npu_compute(uint32_t a_spm_row,
                                   uint32_t c_spm_base_row)
{
    uint32_t response;
    __asm__ volatile (
        ".insn r CUSTOM_0, 0, 2, %[rd], %[rs1], %[rs2]"
        : [rd] "=r" (response)
        : [rs1] "r" (a_spm_row), [rs2] "r" (c_spm_base_row)
        : "memory"
    );
    return response;
}

// 根据与硬件相同的8字节row布局计算软件黄金校验和。
// COMPUTE响应仍返回有效阵列输出之和；与此同时，c_spm_result_writer会把
// 完整结果矩阵写入C_SPM，因此程序同时检查checksum和逐元素结果。
// noinline和volatile读取保证固定测试矩阵不会被-O2提前折叠成常数，
// 这里测到的周期确实来自CPU逐元素执行乘加循环。
static __attribute__((noinline))
uint32_t matmul_reference_checksum(const volatile uint8_t *a,
                                   const volatile uint8_t *b,
                                   uint32_t m,
                                   uint32_t n,
                                   uint32_t k)
{
    uint32_t checksum = 0u;

    for (uint32_t row = 0; row < m; ++row) {
        for (uint32_t col = 0; col < n; ++col) {
            int accumulator = 0;

            for (uint32_t inner = 0; inner < k; ++inner) {
                int a_value = (int)(signed char)a[row * NPU_ARRAY_DIM + inner];
                int b_value = (int)(signed char)b[inner * NPU_ARRAY_DIM + col];
                accumulator += a_value * b_value;
            }

            checksum += (uint32_t)accumulator;
        }
    }

    return checksum;
}

static void matmul_reference_matrix(const volatile uint8_t *a,
                                    const volatile uint8_t *b,
                                    uint32_t m,
                                    uint32_t n,
                                    uint32_t k,
                                    int *c)
{
    for (uint32_t row = 0; row < m; ++row) {
        for (uint32_t col = 0; col < NPU_ARRAY_DIM; ++col) {
            int accumulator = 0;
            if (col < n) {
                for (uint32_t inner = 0; inner < k; ++inner) {
                    int a_value = (int)(signed char)
                        a[row * NPU_ARRAY_DIM + inner];
                    int b_value = (int)(signed char)
                        b[inner * NPU_ARRAY_DIM + col];
                    accumulator += a_value * b_value;
                }
            }
            c[row * NPU_ARRAY_DIM + col] = accumulator;
        }
    }
}

// 封装当前硬件支持的WS矩阵乘完整流程。
//
// 数据布局：
//   A_SPM[row][bank] = A[row][bank]
//   B_SPM[row][bank] = B[row][bank]
// 每个逻辑行都必须padding到NPU_ARRAY_DIM字节。
//
// 当前限制：
//   1. 尚未实现tiling，因此M/N/K限制在8以内；
//   2. N还没有独立下发到RTL，未使用的B bank必须由软件补零；
//   3. C_SPM每个bank为32位，一行结果占8个word（32字节）。
static int npu_matmul_ws(const uint8_t *a_spm_layout,
                         const uint8_t *b_spm_layout,
                         uint32_t m,
                         uint32_t n,
                         uint32_t k,
                         uint32_t *checksum_o,
                         int *c_spm_layout_o,
                         npu_matmul_perf_t *perf_o)
{
    uint32_t response;
    uint64_t total_start;
    uint64_t phase_start;

    if ((a_spm_layout == 0) || (b_spm_layout == 0) ||
        (checksum_o == 0) || (c_spm_layout_o == 0) || (perf_o == 0) ||
        (m == 0u) || (m > NPU_ARRAY_DIM) ||
        (n == 0u) || (n > NPU_ARRAY_DIM) ||
        (k == 0u) || (k > NPU_ARRAY_DIM)) {
        return NPU_MATMUL_BAD_ARGUMENT;
    }

    perf_o->dma_cycles         = 0u;
    perf_o->config_cycles      = 0u;
    perf_o->load_weight_cycles = 0u;
    perf_o->compute_cycles     = 0u;
    perf_o->output_dma_cycles  = 0u;
    perf_o->total_cycles       = 0u;
    total_start = tb_read_mcycle();

    // 一个逻辑矩阵行固定占NPU_ARRAY_DIM字节，而不是只搬运有效列数。
    phase_start = tb_read_mcycle();
    if (dma_copy_to_spm(a_spm_layout, A_SPM_BASE,
                        m * NPU_ARRAY_DIM) != 0) {
        return NPU_MATMUL_DMA_A_FAILED;
    }

    if (dma_copy_to_spm(b_spm_layout, B_SPM_BASE,
                        k * NPU_ARRAY_DIM) != 0) {
        return NPU_MATMUL_DMA_B_FAILED;
    }
    perf_o->dma_cycles = tb_read_mcycle() - phase_start;

    // 当前CONFIG的arg0表示需要读取的A_SPM row数，也就是M维运行长度。
    phase_start = tb_read_mcycle();
    response = npu_config(m, NPU_MODE_WS);
    perf_o->config_cycles = tb_read_mcycle() - phase_start;
    if (response != 0u) {
        return NPU_MATMUL_CONFIG_FAILED;
    }

    // B_SPM每个row对应B的一个K维切片，因此需要装载K个row。
    phase_start = tb_read_mcycle();
    response = npu_load_weight(0u, k);
    perf_o->load_weight_cycles = tb_read_mcycle() - phase_start;
    if (response != 1u) {
        return NPU_MATMUL_LOAD_WEIGHT_FAILED;
    }

    // arg0=0：从A_SPM第0行开始读取M行；
    // arg1=0：c_spm_result_writer从C_SPM第0行开始写结果。
    // 指令返回时，response是所有有效输出的校验和。
    phase_start = tb_read_mcycle();
    *checksum_o = npu_compute(0u, 0u);
    perf_o->compute_cycles = tb_read_mcycle() - phase_start;
    if ((*checksum_o & NPU_RSP_ERROR) != 0u) {
        return NPU_MATMUL_COMPUTE_FAILED;
    }

    // C_SPM为8个32位bank，一个逻辑结果行占8个word。
    phase_start = tb_read_mcycle();
    if (dma_copy_from_spm(C_SPM_BASE, c_spm_layout_o,
                          m * NPU_ARRAY_DIM * sizeof(int)) != 0) {
        return NPU_MATMUL_DMA_C_FAILED;
    }
    perf_o->output_dma_cycles = tb_read_mcycle() - phase_start;
    perf_o->total_cycles = tb_read_mcycle() - total_start;
    return NPU_MATMUL_OK;
}

static void print_cycles(const char *name, uint64_t cycles)
{
    tb_puts(name);
    if ((cycles >> 32) != 0u) {
        tb_print_hex((uint32_t)(cycles >> 32));
        tb_print_hex((uint32_t)cycles);
    } else {
        tb_print_dec((int)(uint32_t)cycles);
    }
    tb_putchar('\n');
}

// 以两位小数打印numerator/denominator。这里使用整数运算，避免裸机程序
// 引入浮点运行库。例如150会打印为1.50x。
static void print_speedup(const char *name,
                          uint64_t numerator,
                          uint64_t denominator)
{
    uint32_t ratio_x100;

    tb_puts(name);
    if ((denominator == 0u) ||
        (denominator > 0xffffffffu) ||
        (numerator > 0xffffffffu / 100u)) {
        tb_puts("N/A");
        return;
    }

    ratio_x100 = ((uint32_t)numerator * 100u) / (uint32_t)denominator;
    tb_print_dec((int)(ratio_x100 / 100u));
    tb_putchar('.');
    tb_putchar((char)('0' + ((ratio_x100 / 10u) % 10u)));
    tb_putchar((char)('0' + (ratio_x100 % 10u)));
    tb_putchar('x');
    tb_putchar('\n');
}

int main(void)
{
    const uint32_t m = 3u;
    const uint32_t n = 3u;
    const uint32_t k = 5u;
    uint32_t hardware_checksum;
    uint32_t reference_checksum;
    uint64_t cpu_reference_cycles;
    uint64_t cpu_start;
    npu_matmul_perf_t npu_perf;
    int status;

    tb_puts("CV32E40X + DMA + NPU end-to-end test");

    status = dma_bidirectional_self_test();
    if (status != 0) {
        tb_puts("DMA main-memory/SPM bidirectional self-test failed");
        tb_print_dec(status);
        tb_putchar('\n');
        return 3;
    }
    tb_puts("DMA main-memory/SPM bidirectional self-test PASS");

    status = npu_matmul_ws(matrix_a_spm_layout, matrix_b_spm_layout,
                           m, n, k, &hardware_checksum,
                           matrix_c_readback, &npu_perf);
    if (status != NPU_MATMUL_OK) {
        tb_puts("NPU matmul command sequence failed");
        tb_print_dec(status);
        tb_putchar('\n');
        return 1;
    }

    cpu_start = tb_read_mcycle();
    reference_checksum = matmul_reference_checksum(
        matrix_a_spm_layout, matrix_b_spm_layout, m, n, k);
    cpu_reference_cycles = tb_read_mcycle() - cpu_start;
    matmul_reference_matrix(matrix_a_spm_layout, matrix_b_spm_layout,
                            m, n, k, matrix_c_reference);

    tb_puts("NPU result checksum:");
    tb_print_dec((int)hardware_checksum);
    tb_putchar('\n');
    tb_puts("Reference checksum:");
    tb_print_dec((int)reference_checksum);
    tb_putchar('\n');

    if (hardware_checksum != reference_checksum) {
        tb_puts("NPU COMPUTE result mismatch");
        return 2;
    }

    for (uint32_t row = 0; row < m; ++row) {
        for (uint32_t col = 0; col < NPU_ARRAY_DIM; ++col) {
            uint32_t index = row * NPU_ARRAY_DIM + col;
            if (matrix_c_readback[index] != matrix_c_reference[index]) {
                tb_puts("C_SPM result mismatch at row/column:");
                tb_print_dec((int)row);
                tb_putchar(' ');
                tb_print_dec((int)col);
                tb_putchar('\n');
                tb_puts("C_SPM value / reference:");
                tb_print_dec((int)matrix_c_readback[index]);
                tb_putchar(' ');
                tb_print_dec((int)matrix_c_reference[index]);
                tb_putchar('\n');
                return 4;
            }
        }
    }
    tb_puts("C_SPM full matrix result PASS");

    tb_puts("Performance comparison (mcycle):");
    print_cycles("CPU reference GEMM cycles:", cpu_reference_cycles);
    print_cycles("NPU DMA cycles:", npu_perf.dma_cycles);
    print_cycles("NPU CONFIG cycles:", npu_perf.config_cycles);
    print_cycles("NPU LOAD_WEIGHT cycles:", npu_perf.load_weight_cycles);
    print_cycles("NPU COMPUTE command cycles:", npu_perf.compute_cycles);
    print_cycles("NPU output DMA cycles:", npu_perf.output_dma_cycles);
    print_cycles("NPU end-to-end cycles:", npu_perf.total_cycles);
    print_speedup("CPU/NPU compute-only speed ratio:",
                  cpu_reference_cycles, npu_perf.compute_cycles);
    print_speedup("CPU/NPU end-to-end speed ratio:",
                  cpu_reference_cycles, npu_perf.total_cycles);

    tb_puts("CV32E40X + DMA + NPU end-to-end test PASS");
    return 0;
}
