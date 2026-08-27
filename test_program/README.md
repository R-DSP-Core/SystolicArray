# CV32E40X bare-metal C test programs

完整的中文编译、运行与调试指南见：

```text
docs/verilator_c_sim_guide.md
```

These programs run directly on CV32E40X without an operating system or C
library. Shared startup code clears `.bss`, initializes the stack, calls
`main`, and reports its return value to the Verilator C++ driver through
the simulated `tohost` MMIO register.

Available programs:

- `hello`: UART output and a basic addition check.
- `arithmetic`: RV32IM arithmetic, division, remainder, and logical operations.
- `memory`: array load/store, copy, comparison, and checksum.
- `matmul`: a small software 2x2 matrix multiplication useful as an accelerator baseline.

The directory layout is intentionally flat:

```text
test_program/
├── src/    # All C sources, startup code, and the linker script
└── bin/    # Disassembly, raw binary, and RTL hexadecimal images only
```

From the repository root, compile and run one program with:

```sh
make -C tb/verilator run-program PROGRAM=hello
make -C tb/verilator run-program PROGRAM=matmul
```

Run every program with:

```sh
make -C tb/verilator run-all-programs
```

Generate a waveform for one program with:

```sh
make -C tb/verilator trace-program PROGRAM=matmul
```

Build a program without running the simulator:

```sh
make -C tb/verilator program PROGRAM=arithmetic
```

The three final files are placed directly under `test_program/bin/`:

- `<program>.dis`: source-interleaved RISC-V disassembly;
- `<program>.bin`: raw binary image;
- `<program>.hex`: 32-bit hexadecimal words loaded by the RTL simulator.

Temporary objects and ELF files are kept outside this directory under
`build/test_program/`.

The Makefile uses `riscv64-unknown-elf-gcc` or
`riscv32-unknown-elf-gcc` when available. Otherwise it falls back to Clang,
LLD, and LLVM objcopy. A custom GNU toolchain prefix can be selected with:

```sh
make -C tb/verilator run-program PROGRAM=hello \
  CROSS_COMPILE=/opt/riscv/bin/riscv32-unknown-elf-
```
