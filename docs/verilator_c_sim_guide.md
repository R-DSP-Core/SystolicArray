# 使用 Verilator 在 CV32E40X 上运行裸机 C 程序

本文说明如何在不使用 UVM 和商业仿真器的情况下：

1. 使用 Verilator 编译 CV32E40X RTL；
2. 将 C 程序编译成 RV32 裸机固件；
3. 把固件加载到 CV32E40X Verilator 仿真器中运行；
4. 生成波形、查看反汇编并添加自己的测试程序。

文中的命令默认在 CV32E40X 仓库根目录执行：

```sh
cd /home/xwy/cv32e40x
```

## 1. 目录结构

与本流程有关的目录如下：

```text
cv32e40x/
├── rtl/                         # CV32E40X RTL
├── bhv/                         # 仿真用时钟门控模型
├── tb/verilator/
│   ├── Makefile                 # Verilator 构建和运行入口
│   ├── sim_main.cpp             # C++ 仿真驱动、RAM 和 MMIO
│   ├── cv32e40x_verilator_top.sv# 只处理 XIF 的薄 RTL wrapper
│   └── cv32e40x_verilator.flist # RTL 文件列表
├── test_program/
│   ├── Makefile                 # 裸机 C 程序构建入口
│   ├── src/                     # 所有源文件
│   └── bin/                     # 仅保留 dis、bin 和 hex
└── build/verilator/             # Verilator 生成的 C++ 和可执行模型
```

这里存在两个相互独立的编译过程：

```text
SystemVerilog RTL ──Verilator──> C++ RTL 模型 ──┐
                                               ├──> Vcv32e40x_verilator_top
sim_main.cpp ──────────────────────────────────┘

C/汇编源代码 ──Clang 或 GCC──> ELF ──objcopy/od──> HEX
                                                   │
C++ 仿真器 <────────────────── +firmware=<HEX> ────┘
```

RTL 没有变化时，不需要因为修改 C 程序而重新设计 CPU；只需重新生成固件并再次启动仿真模型。

## 2. 所需工具

### 2.1 必需工具

```sh
verilator --version
make --version
clang --version
ld.lld --version
llvm-objcopy --version
llvm-objdump --version
```

当前构建系统支持以下两类 RISC-V 编译工具链。

第一类是 GNU 裸机工具链，程序会依次寻找：

```text
riscv64-unknown-elf-gcc
riscv32-unknown-elf-gcc
```

虽然第一种工具名称中包含 `riscv64`，但通过 `-march=rv32im_zicsr -mabi=ilp32`，它也能生成 RV32 程序。

第二类是 LLVM。当找不到 GNU 工具链时，Makefile 自动使用：

```text
clang --target=riscv32-unknown-elf
ld.lld
llvm-objcopy
llvm-objdump
```

本机当前使用的是 LLVM 流程。

### 2.2 可选工具

查看 VCD 波形可以安装 GTKWave：

```sh
gtkwave --version
```

## 3. 编译 CV32E40X Verilator 仿真器

执行：

```sh
make -C tb/verilator build
```

该命令主要完成以下步骤：

1. 读取 `tb/verilator/cv32e40x_verilator.flist`；
2. 编译 CV32E40X package、interface 和 RTL 模块；
3. 加入仿真时钟门控模型；
4. 编译薄 wrapper `cv32e40x_verilator_top.sv`；
5. 将生成的 RTL C++ 模型与 `sim_main.cpp` 编译、链接成可执行程序。

生成的仿真器为：

```text
build/verilator/Vcv32e40x_verilator_top
```

Makefile 中使用的核心 Verilator 选项包括：

```text
--cc
--exe tb/verilator/sim_main.cpp
--build
--top-module cv32e40x_verilator_top
-DCOREV_ASSERT_OFF
```

- `--cc`：把 RTL 转换成 C++ 模型；
- `--exe`：加入手写的 C++ 驱动；
- `--build`：编译并链接模型和驱动；
- `--top-module`：指定仿真顶层；
- `COREV_ASSERT_OFF`：不编译依赖完整 UVM/SVA 环境的 assertion wrapper。

不能直接把 `cv32e40x_core` 设为 Verilator 5.032 的顶层，因为它带有六组
SystemVerilog XIF `interface` 端口，Verilator 会报告
`Unsupported: Interfaced port on top level module`。因此薄 wrapper 只在 RTL 内部
实例化 XIF interface 并将其关闭，同时把普通 core 端口原样暴露给 C++。
它不生成时钟，不含 RAM，也不实现总线或 MMIO；这些行为全部位于 `sim_main.cpp`。

Makefile 还关闭了若干当前上游 RTL 与 Verilator 5.032 之间的诊断项，其中最重要的是 `BLKANDNBLK`。它来自参数化 CSR RTL 对不同数组切片的生成式赋值，不是本测试程序产生的错误。

### 3.1 C++ 如何驱动 RTL

`sim_main.cpp` 创建 Verilator 生成的顶层 C++ 对象：

```cpp
Vcv32e40x_verilator_top top;
top.rst_ni = 0;
top.clk_i = 0;
top.eval();
```

每个仿真周期由 C++ 明确执行以下操作：

1. 把上一笔 OBI 请求的响应写入 `instr_rvalid_i/data_rvalid_i` 等输入；
2. 调用 `eval()` 得到当前的取指和访存请求；
3. 驱动 `instr_gnt_i/data_gnt_i` 并再次求值；
4. 保存被接受请求的地址、写使能、字节使能和写数据；
5. 将 `clk_i` 拉高并调用 `eval()`，让 RTL 完成上升沿状态更新；
6. 在 C++ RAM 或 MMIO 中处理请求，准备下一周期响应；
7. 将 `clk_i` 拉低并再次调用 `eval()`。

因此 RAM、HEX 加载、UART、tohost、超时和 VCD 都是 C++ 行为；RTL wrapper
没有 testbench 时序语句。以后修改等待周期或外设模型，主要修改
`tb/verilator/sim_main.cpp`。

### 3.2 运行内置 smoke test

```sh
make -C tb/verilator run
```

这不加载外部 C 程序，而是运行 C++ 驱动内置的一小段 RV32IM 机器码，用来快速检查：

- 取指；
- 整数加法；
- 乘法；
- load/store；
- 条件分支；
- 仿真退出接口。

成功输出类似：

```text
CV32E40X VERILATOR C++ TEST: PASS (cycles=18)
```

## 4. 裸机 C 程序的运行环境

测试程序没有 Linux、操作系统或标准 C 库。`test_program/src/` 中提供了最小运行环境。

### 4.1 启动代码

`crt0.S` 在复位后执行：

1. 将栈指针设置为 RAM 顶部；
2. 将 `.bss` 清零；
3. 开启 RTL 性能计数器并记录起始值；
4. 调用 C 函数 `main()`；
5. 记录并输出 `main()` 的性能统计；
6. 将 `main()` 返回值交给 `tb_exit()`。

每个 C 程序必须提供：

```c
int main(void)
{
    return 0;
}
```

返回 `0` 表示测试成功，非零值表示失败。

### 4.2 链接脚本和内存布局

`link.ld` 定义 64 KiB RAM：

| 地址 | 用途 |
|---|---|
| `0x0000_0000` | 程序入口和 `.text` |
| 程序之后 | `.rodata`、`.data`、`.bss` |
| `0x0000_FFFF` 附近 | 栈顶 |
| `0x1000_0000` | 仿真字符输出 UART |
| `0x1000_0004` | `tohost` PASS/FAIL 寄存器 |

对 `0x1000_0000` 进行字节写会在仿真终端输出字符。对 `0x1000_0004` 写入状态会结束仿真：

- `1`：PASS；
- 其他值：FAIL。

`runtime.c` 已经封装了这些操作：

```c
tb_putchar('A');
tb_puts("Hello");
tb_print_dec(42);
tb_print_hex(0x1234abcd);
```

通常不需要直接调用 `tb_exit()`；从 `main()` 返回即可。

## 5. 编译 C 程序

已有程序包括：

```text
test_program/src/hello.c
test_program/src/arithmetic.c
test_program/src/memory.c
test_program/src/matmul.c
```

例如编译 `hello.c`：

```sh
make -C test_program PROGRAM=hello
```

关键编译参数为：

```text
-march=rv32im_zicsr
-mabi=ilp32
-ffreestanding
-fno-builtin
-nostdlib
```

- `rv32im_zicsr`：生成 RV32I、乘除法和 CSR 指令；
- `ilp32`：使用 32 位整数、long 和指针 ABI；
- `ffreestanding`：声明这是无操作系统的独立环境；
- `fno-builtin`：不把运行库函数替换为宿主机库调用；
- `nostdlib`：不链接宿主机 C 库和默认启动文件。

最终需要使用的三个文件位于 `test_program/bin/`：

```text
hello.dis     # 带 C 源码的 RISC-V 反汇编
hello.bin     # 原始编译二进制镜像
hello.hex     # RTL 仿真器读入的 32 位十六进制镜像
```

链接所需的 `.o` 和临时 `.elf` 位于 `build/test_program/`，不会混入
`test_program/bin/`；构建不再生成 `.map` 文件。

构建过程可以概括为：

```text
crt0.S ───────┐
runtime.c ────┼──> *.o ──链接脚本──> hello.elf
hello.c ──────┘                       │
                                     ├──objcopy──> hello.bin
                                     └──objdump──> hello.dis

hello.bin ──od -tx4──> hello.hex
```

### 5.1 指定自己的 GNU 工具链

```sh
make -C test_program PROGRAM=hello \
  CROSS_COMPILE=/opt/riscv/bin/riscv32-unknown-elf-
```

`CROSS_COMPILE` 必须是包含路径的工具名前缀，Makefile 会在后面追加 `gcc`、`objcopy` 和 `objdump`。

## 6. 在 Verilator 仿真器中运行 C 程序

最常用的一条命令是：

```sh
make -C tb/verilator run-program PROGRAM=hello
```

它会自动执行：

1. 编译或更新 Verilator 模型；
2. 调用 `test_program/Makefile` 编译 `hello.c`；
3. 生成 `test_program/bin/hello.hex`；
4. 使用 `+firmware=` 将 HEX 文件传给 C++ 驱动；
5. 运行 CPU，直到程序报告 PASS、FAIL 或超时。

等效的手动运行命令是：

```sh
build/verilator/Vcv32e40x_verilator_top \
  +firmware=/home/xwy/cv32e40x/test_program/bin/hello.hex
```

C++ 驱动启动时会显示实际加载的文件：

```text
Loading firmware: /home/xwy/cv32e40x/test_program/bin/hello.hex
```

随后可以看到程序通过仿真 UART 打印的内容和最终状态：

```text
Hello from CV32E40X!
The answer should be 42:
42
RTL performance counters (main):
  mcycle delta:
0x00000000000001a7
  minstret delta:
0x000000000000012c
  CPI:
1.410
CV32E40X VERILATOR C++ TEST: PASS (cycles=997)
```

### 6.1 运行其他程序

```sh
make -C tb/verilator run-program PROGRAM=arithmetic
make -C tb/verilator run-program PROGRAM=memory
make -C tb/verilator run-program PROGRAM=matmul
```

### 6.2 运行所有程序

```sh
make -C tb/verilator run-all-programs
```

当前四个程序的参考结果为：

| 程序 | 结果 | 参考周期数 |
|---|---:|---:|
| `hello` | PASS | 997 |
| `arithmetic` | PASS | 1081 |
| `memory` | PASS | 1284 |
| `matmul` | PASS | 1125 |

周期数可能在修改程序、优化等级或内存模型后变化，不应该作为测试是否正确的唯一依据。

### 6.3 自动 RTL 性能统计

公共启动代码会在调用 `main()` 前执行 `tb_perf_start()`，并在 `main()`
返回后执行 `tb_perf_stop()`。统计值直接读取 CV32E40X RTL 实现的机器模式
硬件计数器：

CV32E40X 复位时默认通过 `mcountinhibit` 禁止这些计数器。`tb_perf_start()`
会先清零该 CSR 以开启计数，再保存起始值。

- `mcycle/mcycleh`：64 位核心周期计数；
- `minstret/minstreth`：64 位退休指令计数；
- `CPI`：`mcycle delta / minstret delta`。

每个 C 程序都会自动输出类似：

```text
RTL performance counters (main):
  mcycle delta:
0x0000000000000123
  minstret delta:
0x00000000000000f0
  CPI:
1.212
```

这些数字来自 CPU RTL 的 CSR，不是 Verilator 在宿主机上的运行时间。默认统计区间
覆盖整个 `main()`，因此包括 `main()` 内部的 UART 输出、普通内存访问和被调用函数。
性能报告本身发生在计数器终点之后，不计入该区间。

如需只测量某个内核，可以在 C 程序中直接调用：

```c
uint64_t cycle_start = tb_read_mcycle();
uint64_t inst_start = tb_read_minstret();

matrix_multiply();

uint64_t cycles = tb_read_mcycle() - cycle_start;
uint64_t instructions = tb_read_minstret() - inst_start;
```

读取函数采用“高位、低位、再次读取高位”的方式，避免 RV32 在低 32 位溢出时
得到不一致的 64 位计数值。

## 7. 生成和查看波形

为一个 C 程序生成 VCD：

```sh
make -C tb/verilator trace-program PROGRAM=matmul
```

生成文件：

```text
build/verilator/cv32e40x_verilator_top.vcd
```

用 GTKWave 打开：

```sh
gtkwave build/verilator/cv32e40x_verilator_top.vcd
```

建议首先观察：

```text
cv32e40x_verilator_top.clk_i
cv32e40x_verilator_top.rst_ni
cv32e40x_verilator_top.instr_req_o
cv32e40x_verilator_top.instr_addr_o
cv32e40x_verilator_top.instr_rvalid_i
cv32e40x_verilator_top.instr_rdata_i
cv32e40x_verilator_top.data_req_o
cv32e40x_verilator_top.data_addr_o
cv32e40x_verilator_top.data_we_o
cv32e40x_verilator_top.data_wdata_o
```

矩阵乘或未来 XIF 协处理器调试时，再继续展开 `core` 内部流水线以及 XIF interface 信号。

## 8. 查看程序反汇编

例如查看算术程序：

```sh
less test_program/bin/arithmetic.dis
```

查找乘除法指令：

```sh
rg '\b(mul|div|rem)\b' test_program/bin/arithmetic.dis
```

这样可以确认 C 表达式确实被编译成目标 RISC-V 指令，而不是在编译期被完全计算掉。

如果临时需要查看程序 section 和符号地址，可以使用构建目录中的 ELF：

```sh
llvm-readelf -S build/test_program/hello.elf
llvm-readelf -s build/test_program/hello.elf
```

## 9. 添加自己的 C 测试程序

假设增加 `test_program/src/my_test.c`：

```c
#include "runtime.h"

int main(void)
{
    volatile int a = 6;
    volatile int b = 7;
    int result = a * b;

    tb_puts("Running my_test...");
    tb_print_dec(result);
    tb_putchar('\n');

    return result == 42 ? 0 : 1;
}
```

然后把 `my_test` 加入以下两个变量：

1. `test_program/Makefile` 中的 `SUPPORTED_PROGRAMS`；
2. `tb/verilator/Makefile` 中的 `PROGRAMS`。

运行：

```sh
make -C tb/verilator run-program PROGRAM=my_test
```

如果只想单独编译：

```sh
make -C test_program PROGRAM=my_test
```

## 10. 清理构建产物

只清理 C 程序：

```sh
make -C test_program clean
```

清理 C 程序和 Verilator 模型：

```sh
make -C tb/verilator clean
```

清理后会保留：

```text
test_program/bin/.gitkeep
```

其他 HEX、原始二进制、反汇编、临时 ELF、目标文件和 Verilator 生成文件都会被删除。

## 11. 常见问题

### 11.1 `Unknown PROGRAM=...`

程序名尚未加入 `SUPPORTED_PROGRAMS`，或者命令中的名称与 `src/<名称>.c` 不一致。

### 11.2 找不到 RISC-V GCC

如果系统中存在 Clang、LLD、LLVM objcopy 和 LLVM objdump，构建会自动回退到 LLVM，不要求必须安装 GNU 工具链。

如果两类工具链都不完整，需要安装其中一套，或者使用 `CROSS_COMPILE` 指向已有 GNU 工具链。

### 11.3 仿真 TIMEOUT

常见原因包括：

- 程序没有从 `main()` 返回；
- 程序进入死循环；
- 写错了 MMIO 地址；
- 链接入口不是 `0x0000_0000`；
- 加载了格式错误或超出 64 KiB 的 HEX；
- CPU 发生异常后跳到了未初始化的异常入口。

可以使用 `trace-program` 生成波形，并检查取指地址是否仍在预期程序范围内。

### 11.4 C 程序返回 FAIL

`runtime.c` 会将非零返回值编码为带最高位的失败状态。例如 `main()` 返回 `17` 时，仿真器会看到 `0x80000011`。

可以给每个检查分配不同的返回值，以便从 FAIL code 定位失败位置：

```c
if (first_check_failed)  return 1;
if (second_check_failed) return 2;
```

### 11.5 修改 C 文件后是否必须重新编译 RTL

不需要。只需重新执行 `run-program`。Make 会重新编译发生变化的 C 文件；Verilator 也会检查 RTL 是否需要更新。

### 11.6 为什么这里不用 `printf`

当前环境是 freestanding 裸机程序，没有链接 newlib、glibc 或操作系统。为了保持依赖最少，使用 `tb_puts`、`tb_print_dec` 和 `tb_print_hex` 输出。

## 12. Makefile 命令速查

```sh
# 查看帮助和可用程序
make -C tb/verilator help
make -C tb/verilator list-programs

# 只构建 Verilator 模型
make -C tb/verilator build

# 内置机器码 smoke test
make -C tb/verilator run

# 只编译一个 C 程序
make -C test_program PROGRAM=hello

# 编译并运行一个 C 程序
make -C tb/verilator run-program PROGRAM=hello

# 运行全部 C 程序
make -C tb/verilator run-all-programs

# 运行 C 程序并生成波形
make -C tb/verilator trace-program PROGRAM=matmul

# 清理
make -C test_program clean
make -C tb/verilator clean
```
