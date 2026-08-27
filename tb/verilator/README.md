# Minimal Verilator simulation

For a complete Chinese guide to building the simulator, compiling bare-metal
C programs, loading firmware, and debugging waveforms, see
`docs/verilator_c_sim_guide.md`.

This directory contains a self-contained, open-source CV32E40X simulation.
It does not require UVM, a commercial simulator, or a RISC-V cross compiler.

`sim_main.cpp` drives clock, reset, all scalar core inputs, one-cycle OBI
instruction/data memories, UART, tohost, timeout, and VCD tracing. Its embedded
RV32IM program checks integer arithmetic, load/store, branch, and multiplication.
A write to the `tohost` address ends the test.

`cv32e40x_verilator_top.sv` is only a structural wrapper. Verilator 5.032 does
not support the core's SystemVerilog XIF interface ports on the model top, so
the wrapper terminates the disabled XIF and exposes ordinary ports to C++.

The build disables Verilator's `BLKANDNBLK` diagnostic because the upstream
parameterized CSR RTL assigns disjoint slices of several arrays from generated
continuous and sequential blocks. The core RTL itself is not modified.

Run it from the repository root:

```sh
make -C tb/verilator run
```

Expected final line:

```text
CV32E40X VERILATOR C++ TEST: PASS (...)
```

To also generate a VCD waveform:

```sh
make -C tb/verilator clean
make -C tb/verilator trace
```

The waveform is written to `build/verilator/cv32e40x_verilator_top.vcd`.

## Bare-metal C programs

Simple C programs and their shared startup/runtime code are in the repository
root directory `test_program/src/`. Compiled files are written to
`test_program/bin/`.
The build automatically uses a GNU RISC-V cross compiler when one is present,
or falls back to Clang/LLD.

```sh
make -C tb/verilator run-program PROGRAM=hello
make -C tb/verilator run-program PROGRAM=arithmetic
make -C tb/verilator run-program PROGRAM=memory
make -C tb/verilator run-program PROGRAM=matmul
make -C tb/verilator run-all-programs
```

Use `trace-program` instead of `run-program` to generate a VCD for a C test.

## Extending the environment

The `cv32e40x_if_xif` instance is present in `cv32e40x_verilator_top.sv`.
To add a coprocessor, set the core's `X_EXT` parameter to `1`, remove the XIF
tie-offs, and connect the corresponding `coproc_*` modports to the accelerator.
