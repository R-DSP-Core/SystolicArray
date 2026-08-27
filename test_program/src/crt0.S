// SPDX-License-Identifier: Apache-2.0

  .section .text.init
  .globl _start
  .type _start, @function

_start:
  .option push
  .option norelax
  la sp, __stack_top
  la t0, __bss_start
  la t1, __bss_end
  .option pop

1:
  bgeu t0, t1, 2f
  sw zero, 0(t0)
  addi t0, t0, 4
  j 1b

2:
  call tb_perf_start
  call main
  mv s0, a0
  call tb_perf_stop
  mv a0, s0
  call tb_exit

3:
  j 3b

  .size _start, .-_start
