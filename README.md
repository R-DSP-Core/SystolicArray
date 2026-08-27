# SystolicArray

An NPU-like 8x8 systolic-array subsystem integrated with the OpenHW Group
CV32E40X RISC-V core.

## Contents

- `rtl/`: systolic array, processing element, scratchpads, DMA, arbitration,
  controller, XIF command frontend, and the CV32E40X interface/package changes
  required by the integration.
- `tb/verilator/`: Verilator wrapper, C++ simulation driver, file list, and
  build recipes.
- `test_program/`: bare-metal RV32 programs, including the end-to-end NPU test.
- `docs/`: Chinese build, simulation, and waveform-debugging guide.

## CV32E40X dependency

This repository contains the NPU-related RTL and verification additions, not a
complete copy of the upstream CPU. It is based on CV32E40X commit `d952cd63`:

<https://github.com/openhwgroup/cv32e40x/tree/d952cd63>

To reproduce the integrated tree, check out that CV32E40X revision and overlay
the directories from this repository onto it. In particular,
`rtl/cv32e40x_if_c_obi.sv` and `rtl/include/cv32e40x_pkg.sv` are modified
versions of upstream files.

```sh
git clone https://github.com/openhwgroup/cv32e40x.git
cd cv32e40x
git checkout d952cd63
cp -a /path/to/SystolicArray/rtl/. rtl/
cp -a /path/to/SystolicArray/tb/. tb/
cp -a /path/to/SystolicArray/test_program ./
cp -a /path/to/SystolicArray/docs/. docs/
```

## Simulation

After applying the overlay to CV32E40X:

```sh
make -C tb/verilator run
make -C tb/verilator run-program PROGRAM=npu_full
```

See `docs/verilator_c_sim_guide.md` and `tb/verilator/README.md` for details.

## Generated files

Build products, waveforms, firmware binaries, synthesis netlists, and timing
reports are intentionally not tracked.

## License

The CV32E40X-derived files retain the upstream Solderpad Hardware License. See
`LICENSE` for its terms. Individual files may additionally carry SPDX license
identifiers.
